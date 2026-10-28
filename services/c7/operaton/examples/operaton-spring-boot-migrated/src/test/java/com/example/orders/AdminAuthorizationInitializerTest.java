package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.orders.security.AdminAuthorizationInitializer;
import org.operaton.bpm.engine.AuthorizationService;
import org.operaton.bpm.engine.IdentityService;
import org.operaton.bpm.engine.authorization.Groups;
import org.operaton.bpm.engine.authorization.Permissions;
import org.operaton.bpm.engine.authorization.Resources;
import org.operaton.bpm.engine.identity.Group;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

class AdminAuthorizationInitializerTest extends AbstractProcessEngineTest {

  @Autowired
  IdentityService identityService;

  @Autowired
  AuthorizationService authorizationService;

  @Test
  void opsGroupIsCreatedWithAuthorizations() {
    Group ops = identityService.createGroupQuery().groupId(AdminAuthorizationInitializer.OPS_GROUP_ID).singleResult();
    assertThat(ops).isNotNull();
    assertThat(ops.getType()).isEqualTo(Groups.GROUP_TYPE_WORKFLOW);

    assertThat(authorizationService.createAuthorizationQuery()
        .groupIdIn("order-ops")
        .resourceType(Resources.PROCESS_DEFINITION)
        .resourceId("order-fulfillment")
        .hasPermission(Permissions.READ_INSTANCE)
        .count()).isEqualTo(1);
    assertThat(authorizationService.createAuthorizationQuery()
        .groupIdIn("order-ops")
        .resourceType(Resources.APPLICATION)
        .resourceId("cockpit")
        .hasPermission(Permissions.ACCESS)
        .count()).isEqualTo(1);
  }

  @Test
  void configuredAdminUserIsInAdminAndOpsGroup() {
    // admin user comes from operaton.bpm.admin-user in application.yaml
    assertThat(identityService.createUserQuery().userId("demo").singleResult()).isNotNull();
    assertThat(identityService.createUserQuery().userId("demo").memberOfGroup(org.operaton.bpm.engine.authorization.Groups.OPERATON_ADMIN).count()).isEqualTo(1);

    // MIGRATED (manual fix M1): the recipe does not touch literal group ids in tests/config/SQL.
    // The starter puts the configured admin user into "operaton-admin" (Groups.OPERATON_ADMIN).
    assertThat(identityService.createGroupQuery().groupMember("demo").list())
        .extracting(Group::getId)
        .contains("operaton-admin", "order-ops");
    // Operaton's own display name - the same whether the starter, the Admin webapp setup, the initializer,
    // AdminGroupMigrationPlugin or sql/postgresql/10-migrate-admin-group.sql created the group
    assertThat(identityService.createGroupQuery().groupId(Groups.OPERATON_ADMIN).singleResult().getName())
        .isEqualTo("operaton BPM Administrators");
  }
}
