package com.example.orders.security;

import static org.operaton.bpm.engine.authorization.Authorization.AUTH_TYPE_GRANT;

import org.operaton.bpm.engine.AuthorizationService;
import org.operaton.bpm.engine.IdentityService;
import org.operaton.bpm.engine.ProcessEngine;
import org.operaton.bpm.engine.authorization.Authorization;
import org.operaton.bpm.engine.authorization.Groups;
import org.operaton.bpm.engine.authorization.Permission;
import org.operaton.bpm.engine.authorization.Permissions;
import org.operaton.bpm.engine.authorization.Resource;
import org.operaton.bpm.engine.authorization.Resources;
import org.operaton.bpm.engine.identity.Group;
import org.operaton.bpm.spring.boot.starter.event.PostDeployEvent;
import org.operaton.bpm.spring.boot.starter.property.OperatonBpmProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Typical production bootstrap code: makes sure the operations group exists and has the
 * permissions it needs in Cockpit/Tasklist, and that the admin group exists.
 *
 * <p>MIGRATED (Hop 1):
 * <ul>
 *   <li>{@code Groups.CAMUNDA_ADMIN} ("camunda-admin") became {@code Groups.OPERATON_ADMIN}
 *       ("operaton-admin") - the recipe changed a runtime VALUE here. On an existing database
 *       nobody is a member of operaton-admin yet; {@code migration.AdminGroupMigrationPlugin}
 *       mirrors camunda-admin members and authorizations before this listener runs
 *       (decision D5). Without it this listener would create an EMPTY operaton-admin group and
 *       the Admin webapp setup endpoint would stay open.</li>
 *   <li>{@code PostDeployEvent} and {@code OperatonBpmProperties} live in
 *       {@code org.operaton.bpm.spring.boot.starter...}.</li>
 *   <li>Group name "Camunda Administrators" became "operaton BPM Administrators", Operaton's own default
 *       (the starter's admin-user creation and the Admin webapp setup create the group with this name), so the
 *       group looks the same no matter who created it first.</li>
 * </ul>
 */
@Component
public class AdminAuthorizationInitializer {

  public static final String OPS_GROUP_ID = "order-ops";
  public static final String PROCESS_DEFINITION_KEY = "order-fulfillment";

  private static final Logger LOG = LoggerFactory.getLogger(AdminAuthorizationInitializer.class);

  private final OperatonBpmProperties operatonBpmProperties;

  public AdminAuthorizationInitializer(OperatonBpmProperties operatonBpmProperties) {
    this.operatonBpmProperties = operatonBpmProperties;
  }

  /** Fired by the SpringBootProcessApplication once processes.xml has been deployed. */
  @EventListener
  public void onPostDeploy(PostDeployEvent event) {
    ProcessEngine engine = event.getProcessEngine();
    IdentityService identityService = engine.getIdentityService();
    AuthorizationService authorizationService = engine.getAuthorizationService();

    ensureGroup(identityService, Groups.OPERATON_ADMIN, "operaton BPM Administrators", Groups.GROUP_TYPE_SYSTEM);
    ensureGroup(identityService, OPS_GROUP_ID, "Order Operations", Groups.GROUP_TYPE_WORKFLOW);

    grant(authorizationService, Resources.APPLICATION, "cockpit", Permissions.ACCESS);
    grant(authorizationService, Resources.APPLICATION, "tasklist", Permissions.ACCESS);
    grant(authorizationService, Resources.PROCESS_DEFINITION, PROCESS_DEFINITION_KEY,
        Permissions.READ, Permissions.READ_INSTANCE, Permissions.READ_HISTORY);
    grant(authorizationService, Resources.TASK, Authorization.ANY, Permissions.READ, Permissions.UPDATE);

    // the configured admin user (operaton.bpm.admin-user.id) also works the ops queue
    String adminUserId = operatonBpmProperties.getAdminUser() == null ? null : operatonBpmProperties.getAdminUser().getId();
    if (adminUserId != null && identityService.createUserQuery().userId(adminUserId).count() == 1
        && identityService.createUserQuery().userId(adminUserId).memberOfGroup(OPS_GROUP_ID).count() == 0) {
      identityService.createMembership(adminUserId, OPS_GROUP_ID);
    }
    LOG.info("Authorizations for group '{}' and admin group '{}' ensured", OPS_GROUP_ID, Groups.OPERATON_ADMIN);
  }

  private static void ensureGroup(IdentityService identityService, String id, String name, String type) {
    if (identityService.createGroupQuery().groupId(id).count() == 0) {
      Group group = identityService.newGroup(id);
      group.setName(name);
      group.setType(type);
      identityService.saveGroup(group);
      LOG.info("Created group '{}'", id);
    }
  }

  private static void grant(AuthorizationService authorizationService, Resource resource, String resourceId,
                            Permission... permissions) {
    boolean exists = authorizationService.createAuthorizationQuery()
        .groupIdIn(OPS_GROUP_ID)
        .resourceType(resource)
        .resourceId(resourceId)
        .count() > 0;
    if (exists) {
      return;
    }
    Authorization authorization = authorizationService.createNewAuthorization(AUTH_TYPE_GRANT);
    authorization.setGroupId(OPS_GROUP_ID);
    authorization.setResource(resource);
    authorization.setResourceId(resourceId);
    for (Permission permission : permissions) {
      authorization.addPermission(permission);
    }
    authorizationService.saveAuthorization(authorization);
  }
}
