// operaton-migration-helper: remove after the rollback window (D15)
package com.example.orders.migration;

import java.util.ArrayList;
import java.util.List;
import org.operaton.bpm.engine.AuthorizationService;
import org.operaton.bpm.engine.IdentityService;
import org.operaton.bpm.engine.ProcessEngine;
import org.operaton.bpm.engine.ProcessEngineException;
import org.operaton.bpm.engine.authorization.Authorization;
import org.operaton.bpm.engine.authorization.Groups;
import org.operaton.bpm.engine.identity.Group;
import org.operaton.bpm.engine.identity.User;
import org.operaton.bpm.engine.impl.cfg.AbstractProcessEnginePlugin;
import org.operaton.bpm.engine.impl.persistence.entity.AuthorizationEntity;
import org.operaton.bpm.spring.boot.starter.configuration.Ordering;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.Ordered;

/**
 * Mirrors the members and authorizations of Camunda's admin group ({@code camunda-admin}) to
 * Operaton's admin group ({@code operaton-admin}) while the engine is being built, i.e. before the
 * web server accepts the first request (decision D5).
 *
 * <p>Why: Operaton only treats {@code operaton-admin} ({@link Groups#OPERATON_ADMIN}) as admin group.
 * On a database that was used by Camunda 7, nobody is a member of it. The webapps then consider the
 * engine "not set up" and the Admin setup endpoint
 * ({@code POST <app-path>/api/admin/setup/default/user/create}) lets an UNAUTHENTICATED caller create
 * an administrator. {@code operaton.bpm.admin-user} does not help: the starter skips an existing user.
 *
 * <p>What it does (idempotent, safe to run on every start):
 * <ol>
 *   <li>nothing if the legacy group has neither members nor authorizations (fresh database);</li>
 *   <li>logs a WARN (and does not fail) if {@code camunda-admin} exists but has no members (DB identity):
 *       nobody can be mirrored, and as long as {@code operaton-admin} has no member either, the setup
 *       endpoint stays open - add an administrator before the webapps are reachable;</li>
 *   <li>creates {@code operaton-admin} if missing (DB identity only), named
 *       {@value #DEFAULT_TARGET_GROUP_NAME} like the group Operaton itself creates;</li>
 *   <li>adds every member of {@code camunda-admin} to {@code operaton-admin} (DB identity only);</li>
 *   <li>copies every authorization of {@code camunda-admin} to {@code operaton-admin}; an existing
 *       GRANT for the same resource gets the missing permissions added, other existing rows are kept.</li>
 * </ol>
 * It never deletes or changes {@code camunda-admin} rows: they are needed for a rollback to Camunda
 * (decision D15). Remove them (and this plugin) after the rollback window has closed.
 *
 * <p>Read-only identity providers (LDAP, Keycloak, OAuth2): memberships live in the provider - rename
 * or map the group there, or register {@code AdministratorAuthorizationPlugin} with
 * {@code administratorGroupName=camunda-admin}. Authorizations are still copied (they live in the DB).
 *
 * <p>Generic: only depends on the Operaton engine and the Spring Boot starter; copy it into any
 * Operaton Spring Boot application. Register it as a bean (every {@code ProcessEnginePlugin} bean is
 * picked up by the starter), see {@link MigrationHelpersConfiguration}. SQL alternative for DBAs:
 * {@code sql/postgresql/10-migrate-admin-group.sql} in the starter pack.
 */
public class AdminGroupMigrationPlugin extends AbstractProcessEnginePlugin implements Ordered {

  /** Camunda 7's {@code Groups.CAMUNDA_ADMIN} value. */
  public static final String CAMUNDA_ADMIN = "camunda-admin";

  /**
   * Operaton's own display name for {@code operaton-admin}: the starter's admin-user creation and the Admin
   * webapp's setup endpoint use it, so does {@code sql/postgresql/10-migrate-admin-group.sql}.
   */
  public static final String DEFAULT_TARGET_GROUP_NAME = "operaton BPM Administrators";

  private static final Logger LOG = LoggerFactory.getLogger(AdminGroupMigrationPlugin.class);

  private boolean enabled = true;
  private String legacyGroupId = CAMUNDA_ADMIN;
  private String targetGroupId = Groups.OPERATON_ADMIN;
  private String targetGroupName = DEFAULT_TARGET_GROUP_NAME;
  /** After the starter's own configurations (order 0), e.g. the admin-user creation. */
  private int order = Ordering.DEFAULT_ORDER + 1;

  @Override
  public void postProcessEngineBuild(ProcessEngine processEngine) {
    if (!enabled) {
      LOG.info("Admin group migration {} -> {} is disabled", legacyGroupId, targetGroupId);
      return;
    }
    Result result = migrate(processEngine);
    if (result.nothingToDo()) {
      LOG.info("Admin group migration: no '{}' members or authorizations found - nothing to do", legacyGroupId);
    } else {
      LOG.warn("Admin group migration {} -> {}: group created={}, members added={} (already present={}), "
              + "authorizations copied={}, merged={}, unchanged={}. Keep '{}' until the rollback window has closed.",
          legacyGroupId, targetGroupId, result.groupCreated, result.membersAdded, result.membersPresent,
          result.authorizationsCopied, result.authorizationsMerged, result.authorizationsUnchanged, legacyGroupId);
    }
  }

  /** Runs the migration and returns what was done. Public for tests and for manual re-runs. */
  public Result migrate(ProcessEngine processEngine) {
    IdentityService identityService = processEngine.getIdentityService();
    AuthorizationService authorizationService = processEngine.getAuthorizationService();
    Result result = new Result();

    List<Authorization> legacyAuthorizations = authorizationService.createAuthorizationQuery()
        .groupIdIn(legacyGroupId)
        .list();
    boolean readOnly = identityService.isReadOnly();
    List<User> legacyMembers = readOnly
        ? List.of()
        : identityService.createUserQuery().memberOfGroup(legacyGroupId).list();
    boolean legacyGroupInUse = !legacyAuthorizations.isEmpty()
        || (!readOnly && identityService.createGroupQuery().groupId(legacyGroupId).count() > 0);
    if (!readOnly && legacyMembers.isEmpty() && legacyGroupInUse) {
      // warn, never fail: Camunda 7 had the same open setup endpoint with an empty camunda-admin
      result.legacyGroupWithoutMembers = true;
      warnLegacyGroupWithoutMembers(identityService);
    }
    if (legacyAuthorizations.isEmpty() && legacyMembers.isEmpty()) {
      result.nothingToDo = true;
      return result;
    }

    if (readOnly) {
      LOG.warn("Identity service is read-only (LDAP/Keycloak/OAuth2?): memberships of '{}' must be mapped in the "
          + "identity provider; only authorizations are copied to '{}'", legacyGroupId, targetGroupId);
    } else {
      result.groupCreated = ensureTargetGroup(identityService);
      for (User member : legacyMembers) {
        boolean present = identityService.createUserQuery()
            .userId(member.getId())
            .memberOfGroup(targetGroupId)
            .count() > 0;
        if (present) {
          result.membersPresent++;
        } else {
          identityService.createMembership(member.getId(), targetGroupId);
          result.membersAdded++;
        }
      }
    }

    for (Authorization legacy : legacyAuthorizations) {
      copyAuthorization(authorizationService, legacy, result);
    }
    return result;
  }

  /** Not an error (Camunda 7's setup endpoint was open as well), but it needs an operator's attention. */
  private void warnLegacyGroupWithoutMembers(IdentityService identityService) {
    long targetMembers = identityService.createUserQuery().memberOfGroup(targetGroupId).count();
    if (targetMembers == 0) {
      LOG.warn("Admin group migration: '{}' has no members, so nobody is added to '{}', which has no members either. "
              + "Until '{}' has a member, the Admin webapp setup endpoint lets an UNAUTHENTICATED caller create an "
              + "administrator: add one (Admin webapp, IdentityService) before the webapps are reachable.",
          legacyGroupId, targetGroupId, targetGroupId);
    } else {
      LOG.warn("Admin group migration: '{}' has no members, so nobody is added to '{}' ({} existing member(s) kept).",
          legacyGroupId, targetGroupId, targetMembers);
    }
  }

  private boolean ensureTargetGroup(IdentityService identityService) {
    if (identityService.createGroupQuery().groupId(targetGroupId).count() > 0) {
      return false;
    }
    Group group = identityService.newGroup(targetGroupId);
    group.setName(targetGroupName);
    group.setType(Groups.GROUP_TYPE_SYSTEM);
    try {
      identityService.saveGroup(group);
    } catch (ProcessEngineException e) {
      throw new ProcessEngineException("Cannot create group '" + targetGroupId + "'. If the message says 'not a valid "
          + "resource identifier', a custom *ResourceWhitelistPattern still allows 'camunda-admin' instead of '"
          + targetGroupId + "' (generic property groupResourceWhitelistPattern).", e);
    }
    return true;
  }

  private void copyAuthorization(AuthorizationService authorizationService, Authorization legacy, Result result) {
    List<Authorization> existing = authorizationService.createAuthorizationQuery()
        .groupIdIn(targetGroupId)
        .authorizationType(legacy.getAuthorizationType())
        .resourceType(legacy.getResourceType())
        .resourceId(legacy.getResourceId())
        .list();
    int legacyPermissions = permissionsOf(legacy);

    if (existing.isEmpty()) {
      Authorization copy = authorizationService.createNewAuthorization(legacy.getAuthorizationType());
      copy.setGroupId(targetGroupId);
      copy.setResourceType(legacy.getResourceType());
      copy.setResourceId(legacy.getResourceId());
      if (copy instanceof AuthorizationEntity entity && legacy instanceof AuthorizationEntity source) {
        entity.setPermissions(legacyPermissions);
        entity.setRemovalTime(source.getRemovalTime());
        entity.setRootProcessInstanceId(source.getRootProcessInstanceId());
      } else {
        throw new IllegalStateException("Unexpected Authorization implementation " + copy.getClass().getName());
      }
      authorizationService.saveAuthorization(copy);
      result.authorizationsCopied++;
      return;
    }

    Authorization target = existing.get(0);
    if (legacy.getAuthorizationType() == Authorization.AUTH_TYPE_GRANT && target instanceof AuthorizationEntity entity) {
      int merged = entity.getPermissions() | legacyPermissions;
      if (merged != entity.getPermissions()) {
        entity.setPermissions(merged);
        authorizationService.saveAuthorization(entity);
        result.authorizationsMerged++;
        return;
      }
    }
    result.authorizationsUnchanged++;
  }

  private static int permissionsOf(Authorization authorization) {
    if (authorization instanceof AuthorizationEntity entity) {
      return entity.getPermissions();
    }
    throw new IllegalStateException("Unexpected Authorization implementation " + authorization.getClass().getName());
  }

  @Override
  public int getOrder() {
    return order;
  }

  public void setOrder(int order) {
    this.order = order;
  }

  public boolean isEnabled() {
    return enabled;
  }

  public void setEnabled(boolean enabled) {
    this.enabled = enabled;
  }

  public String getLegacyGroupId() {
    return legacyGroupId;
  }

  public void setLegacyGroupId(String legacyGroupId) {
    this.legacyGroupId = legacyGroupId;
  }

  public String getTargetGroupId() {
    return targetGroupId;
  }

  public void setTargetGroupId(String targetGroupId) {
    this.targetGroupId = targetGroupId;
  }

  public String getTargetGroupName() {
    return targetGroupName;
  }

  public void setTargetGroupName(String targetGroupName) {
    this.targetGroupName = targetGroupName;
  }

  /** Counters of one migration run. */
  public static final class Result {
    private boolean nothingToDo;
    private boolean legacyGroupWithoutMembers;
    private boolean groupCreated;
    private int membersAdded;
    private int membersPresent;
    private int authorizationsCopied;
    private int authorizationsMerged;
    private int authorizationsUnchanged;

    public boolean nothingToDo() {
      return nothingToDo;
    }

    /** {@code camunda-admin} exists (or has authorizations) but has no members - logged as WARN. */
    public boolean legacyGroupWithoutMembers() {
      return legacyGroupWithoutMembers;
    }

    public boolean groupCreated() {
      return groupCreated;
    }

    public int membersAdded() {
      return membersAdded;
    }

    public int membersPresent() {
      return membersPresent;
    }

    public int authorizationsCopied() {
      return authorizationsCopied;
    }

    public int authorizationsMerged() {
      return authorizationsMerged;
    }

    public int authorizationsUnchanged() {
      return authorizationsUnchanged;
    }

    @Override
    public String toString() {
      List<String> parts = new ArrayList<>();
      parts.add("nothingToDo=" + nothingToDo);
      parts.add("legacyGroupWithoutMembers=" + legacyGroupWithoutMembers);
      parts.add("groupCreated=" + groupCreated);
      parts.add("membersAdded=" + membersAdded);
      parts.add("membersPresent=" + membersPresent);
      parts.add("authorizationsCopied=" + authorizationsCopied);
      parts.add("authorizationsMerged=" + authorizationsMerged);
      parts.add("authorizationsUnchanged=" + authorizationsUnchanged);
      return "Result" + parts;
    }
  }
}
