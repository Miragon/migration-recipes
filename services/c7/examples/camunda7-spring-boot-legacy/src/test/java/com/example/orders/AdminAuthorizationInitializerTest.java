package com.example.orders;

import static org.assertj.core.api.Assertions.assertThat;

import com.example.orders.security.AdminAuthorizationInitializer;
import org.camunda.bpm.engine.AuthorizationService;
import org.camunda.bpm.engine.IdentityService;
import org.camunda.bpm.engine.authorization.Groups;
import org.camunda.bpm.engine.authorization.Permissions;
import org.camunda.bpm.engine.authorization.Resources;
import org.camunda.bpm.engine.identity.Group;
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
    // admin user comes from camunda.bpm.admin-user in application.yaml
    assertThat(identityService.createUserQuery().userId("demo").singleResult()).isNotNull();
    assertThat(identityService.createUserQuery().userId("demo").memberOfGroup(Groups.CAMUNDA_ADMIN).count()).isEqualTo(1);

    // MIGRATION HOTSPOT: literal group ids in tests/config/SQL are not touched by the recipe.
    // After the migration the starter puts the admin user into "operaton-admin".
    assertThat(identityService.createGroupQuery().groupMember("demo").list())
        .extracting(Group::getId)
        .contains("camunda-admin", "order-ops");
  }
}
