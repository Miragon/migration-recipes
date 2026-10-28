// operaton-migration-helper: remove after the rollback window (D15)
package com.example.orders.migration;

import static org.assertj.core.api.Assertions.assertThat;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.operaton.bpm.engine.AuthorizationService;
import org.operaton.bpm.engine.IdentityService;
import org.operaton.bpm.engine.ProcessEngine;
import org.operaton.bpm.engine.authorization.Authorization;
import org.operaton.bpm.engine.authorization.Groups;
import org.operaton.bpm.engine.authorization.Permissions;
import org.operaton.bpm.engine.authorization.Resource;
import org.operaton.bpm.engine.authorization.Resources;
import org.operaton.bpm.engine.identity.Group;
import org.operaton.bpm.engine.impl.cfg.ProcessEnginePlugin;
import org.operaton.bpm.engine.impl.cfg.StandaloneInMemProcessEngineConfiguration;
import org.operaton.bpm.engine.impl.persistence.entity.AuthorizationEntity;
import org.slf4j.LoggerFactory;

/**
 * Simulates the cut-over: a database written in the Camunda era (admin group "camunda-admin" with
 * members and authorizations) is opened by an Operaton engine that has the plugin registered.
 *
 * <p>The "legacy" data is created through the engine API with Camunda's default whitelist
 * ({@code [a-zA-Z0-9]+|camunda-admin}); the ACT_ID_* / ACT_RU_AUTHORIZATION schema is identical in
 * Camunda 7.24 and Operaton, so the rows are the same as those Camunda would have written. The
 * end-to-end variant with a real Camunda 7.24 app is documented in MIGRATION_REPORT.md (boot checks).
 */
class AdminGroupMigrationPluginTest {

  private static final String CAMUNDA_WHITELIST = "[a-zA-Z0-9]+|camunda-admin";

  private final List<ProcessEngine> engines = new ArrayList<>();

  @AfterEach
  void closeEngines() {
    engines.forEach(ProcessEngine::close);
  }

  @Test
  void mirrorsMembersAndAuthorizationsBeforeTheWebappsCanBeReached() {
    String db = newDatabase();
    seedCamundaEraAdminGroup(db);

    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    ProcessEngine operaton = engine(db, null, plugin);   // default whitelist [a-zA-Z0-9]+|operaton-admin
    IdentityService identity = operaton.getIdentityService();
    AuthorizationService authorizations = operaton.getAuthorizationService();

    Group admins = identity.createGroupQuery().groupId(Groups.OPERATON_ADMIN).singleResult();
    assertThat(admins).isNotNull();
    assertThat(admins.getType()).isEqualTo(Groups.GROUP_TYPE_SYSTEM);
    // Operaton's own default name (starter admin-user creation, Admin webapp setup, 10-migrate-admin-group.sql)
    assertThat(admins.getName()).isEqualTo("operaton BPM Administrators");
    assertThat(identity.createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).list())
        .extracting(u -> u.getId())
        .containsExactlyInAnyOrder("demo", "jane");
    // = the condition of the webapps' ProcessEnginesFilter.needsInitialUser(): with a member the setup
    //   endpoint (POST .../api/admin/setup/default/user/create) is closed again
    assertThat(identity.createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).count()).isPositive();

    // every authorization of camunda-admin exists for operaton-admin with the same permissions
    List<Authorization> legacy = authorizations.createAuthorizationQuery().groupIdIn("camunda-admin").list();
    assertThat(legacy).hasSize(Resources.values().length + 1);
    for (Authorization source : legacy) {
      Authorization copy = authorizations.createAuthorizationQuery()
          .groupIdIn(Groups.OPERATON_ADMIN)
          .authorizationType(source.getAuthorizationType())
          .resourceType(source.getResourceType())
          .resourceId(source.getResourceId())
          .singleResult();
      assertThat(copy).as("copy of %s/%s", source.getResourceType(), source.getResourceId()).isNotNull();
      assertThat(((AuthorizationEntity) copy).getPermissions()).isEqualTo(((AuthorizationEntity) source).getPermissions());
    }
    assertThat(authorizations.createAuthorizationQuery().groupIdIn(Groups.OPERATON_ADMIN)
        .authorizationType(Authorization.AUTH_TYPE_REVOKE).count()).isEqualTo(1);

    // camunda-admin stays untouched (rollback to Camunda must remain possible, decision D15)
    assertThat(identity.createUserQuery().memberOfGroup("camunda-admin").count()).isEqualTo(2);
    assertThat(authorizations.createAuthorizationQuery().groupIdIn("camunda-admin").count()).isEqualTo(legacy.size());
  }

  @Test
  void isIdempotent() {
    String db = newDatabase();
    seedCamundaEraAdminGroup(db);
    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    ProcessEngine operaton = engine(db, null, plugin);
    long members = operaton.getIdentityService().createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).count();
    long grants = operaton.getAuthorizationService().createAuthorizationQuery().groupIdIn(Groups.OPERATON_ADMIN).count();

    AdminGroupMigrationPlugin.Result second = plugin.migrate(operaton);

    assertThat(second.groupCreated()).isFalse();
    assertThat(second.membersAdded()).isZero();
    assertThat(second.membersPresent()).isEqualTo(2);
    assertThat(second.authorizationsCopied()).isZero();
    assertThat(second.authorizationsMerged()).isZero();
    assertThat(operaton.getIdentityService().createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).count()).isEqualTo(members);
    assertThat(operaton.getAuthorizationService().createAuthorizationQuery().groupIdIn(Groups.OPERATON_ADMIN).count())
        .isEqualTo(grants);

    // a restart runs the plugin again during the engine build - still no duplicates
    operaton.close();
    engines.remove(operaton);
    ProcessEngine restarted = engine(db, null, new AdminGroupMigrationPlugin());
    assertThat(restarted.getAuthorizationService().createAuthorizationQuery().groupIdIn(Groups.OPERATON_ADMIN).count())
        .isEqualTo(grants);
  }

  @Test
  void mergesMissingPermissionsIntoAnExistingGrant() {
    String db = newDatabase();
    ProcessEngine legacy = engine(db, CAMUNDA_WHITELIST + "|operaton-admin");
    IdentityService identity = legacy.getIdentityService();
    saveGroup(identity, "camunda-admin");
    saveGroup(identity, Groups.OPERATON_ADMIN);   // e.g. created empty by a first Operaton start
    grant(legacy.getAuthorizationService(), "camunda-admin", Resources.PROCESS_DEFINITION, "order-fulfillment",
        Permissions.READ, Permissions.UPDATE);
    grant(legacy.getAuthorizationService(), Groups.OPERATON_ADMIN, Resources.PROCESS_DEFINITION, "order-fulfillment",
        Permissions.READ);
    close(legacy);

    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    ProcessEngine operaton = engine(db, null);
    AdminGroupMigrationPlugin.Result result = plugin.migrate(operaton);

    assertThat(result.groupCreated()).isFalse();
    assertThat(result.authorizationsMerged()).isEqualTo(1);
    Authorization merged = operaton.getAuthorizationService().createAuthorizationQuery()
        .groupIdIn(Groups.OPERATON_ADMIN).resourceType(Resources.PROCESS_DEFINITION).resourceId("order-fulfillment")
        .singleResult();
    assertThat(merged.isPermissionGranted(Permissions.READ)).isTrue();
    assertThat(merged.isPermissionGranted(Permissions.UPDATE)).isTrue();
  }

  @Test
  void warnsButDoesNotFailWhenTheLegacyGroupHasNoMembers() {
    String db = newDatabase();
    ProcessEngine legacy = engine(db, CAMUNDA_WHITELIST);
    saveGroup(legacy.getIdentityService(), "camunda-admin");   // e.g. admins were removed, or only LDAP users
    grant(legacy.getAuthorizationService(), "camunda-admin", Resources.APPLICATION, Authorization.ANY, Permissions.ALL);
    close(legacy);

    Logger logger = (Logger) LoggerFactory.getLogger(AdminGroupMigrationPlugin.class);
    ListAppender<ILoggingEvent> log = new ListAppender<>();
    log.start();
    logger.addAppender(log);
    try {
      AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
      ProcessEngine operaton = engine(db, null, plugin);   // the engine build does not fail

      assertThat(log.list)
          .filteredOn(event -> event.getLevel() == Level.WARN)
          .extracting(ILoggingEvent::getFormattedMessage)
          .anyMatch(message -> message.contains("'camunda-admin' has no members")
              && message.contains("UNAUTHENTICATED"));
      // authorizations are still mirrored, nobody became an operaton-admin member
      assertThat(operaton.getAuthorizationService().createAuthorizationQuery().groupIdIn(Groups.OPERATON_ADMIN).count())
          .isEqualTo(1);
      assertThat(operaton.getIdentityService().createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).count()).isZero();

      // idempotent: a second run warns again but changes nothing
      AdminGroupMigrationPlugin.Result second = plugin.migrate(operaton);
      assertThat(second.legacyGroupWithoutMembers()).isTrue();
      assertThat(second.groupCreated()).isFalse();
      assertThat(second.membersAdded()).isZero();
      assertThat(second.authorizationsCopied()).isZero();
      assertThat(second.authorizationsUnchanged()).isEqualTo(1);
    } finally {
      logger.detachAppender(log);
    }
  }

  @Test
  void doesNothingOnAFreshDatabase() {
    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    ProcessEngine operaton = engine(newDatabase(), null, plugin);

    AdminGroupMigrationPlugin.Result result = plugin.migrate(operaton);
    assertThat(result.nothingToDo()).isTrue();
    assertThat(result.legacyGroupWithoutMembers()).as("no camunda-admin group at all - no warning").isFalse();
    assertThat(operaton.getIdentityService().createGroupQuery().groupId(Groups.OPERATON_ADMIN).count()).isZero();
  }

  @Test
  void canBeDisabled() {
    String db = newDatabase();
    seedCamundaEraAdminGroup(db);
    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    plugin.setEnabled(false);

    ProcessEngine operaton = engine(db, null, plugin);

    assertThat(operaton.getIdentityService().createGroupQuery().groupId(Groups.OPERATON_ADMIN).count()).isZero();
    assertThat(operaton.getIdentityService().createUserQuery().memberOfGroup(Groups.OPERATON_ADMIN).count()).isZero();
  }

  // ------------------------------------------------------------------------------------------------

  /** Camunda's starter: group camunda-admin, GRANT ALL on '*' for every resource; plus one custom REVOKE. */
  private void seedCamundaEraAdminGroup(String db) {
    ProcessEngine legacy = engine(db, CAMUNDA_WHITELIST);
    IdentityService identity = legacy.getIdentityService();
    AuthorizationService authorizations = legacy.getAuthorizationService();
    saveGroup(identity, "camunda-admin");
    for (String userId : List.of("demo", "jane", "bob")) {
      identity.saveUser(identity.newUser(userId));
    }
    identity.createMembership("demo", "camunda-admin");
    identity.createMembership("jane", "camunda-admin");
    for (Resources resource : Resources.values()) {
      grant(authorizations, "camunda-admin", resource, Authorization.ANY, Permissions.ALL);
    }
    Authorization revoke = authorizations.createNewAuthorization(Authorization.AUTH_TYPE_REVOKE);
    revoke.setGroupId("camunda-admin");
    revoke.setResource(Resources.PROCESS_DEFINITION);
    revoke.setResourceId("payroll");
    revoke.removePermission(Permissions.DELETE);
    authorizations.saveAuthorization(revoke);
    close(legacy);
  }

  private static void saveGroup(IdentityService identity, String id) {
    Group group = identity.newGroup(id);
    group.setName(id);
    group.setType(Groups.GROUP_TYPE_SYSTEM);
    identity.saveGroup(group);
  }

  private static void grant(AuthorizationService authorizations, String groupId, Resource resource, String resourceId,
                            org.operaton.bpm.engine.authorization.Permission... permissions) {
    Authorization grant = authorizations.createNewAuthorization(Authorization.AUTH_TYPE_GRANT);
    grant.setGroupId(groupId);
    grant.setResource(resource);
    grant.setResourceId(resourceId);
    for (var permission : permissions) {
      grant.addPermission(permission);
    }
    authorizations.saveAuthorization(grant);
  }

  private static String newDatabase() {
    return "jdbc:h2:mem:admin-migration-" + UUID.randomUUID() + ";DB_CLOSE_DELAY=-1";
  }

  private ProcessEngine engine(String jdbcUrl, String groupWhitelist, ProcessEnginePlugin... plugins) {
    StandaloneInMemProcessEngineConfiguration configuration = new StandaloneInMemProcessEngineConfiguration();
    configuration.setProcessEngineName("admin-migration-" + UUID.randomUUID());
    configuration.setJdbcUrl(jdbcUrl);
    configuration.setDatabaseSchemaUpdate("true");   // keep the schema when an engine closes
    configuration.setJobExecutorActivate(false);
    configuration.setDbMetricsReporterActivate(false);
    if (groupWhitelist != null) {
      configuration.setGroupResourceWhitelistPattern(groupWhitelist);
    }
    configuration.getProcessEnginePlugins().addAll(List.of(plugins));
    ProcessEngine engine = configuration.buildProcessEngine();
    engines.add(engine);
    return engine;
  }

  private void close(ProcessEngine engine) {
    engine.close();
    engines.remove(engine);
  }
}
