package com.example.orders.security;

import static org.camunda.bpm.engine.authorization.Authorization.AUTH_TYPE_GRANT;

import org.camunda.bpm.engine.AuthorizationService;
import org.camunda.bpm.engine.IdentityService;
import org.camunda.bpm.engine.ProcessEngine;
import org.camunda.bpm.engine.authorization.Authorization;
import org.camunda.bpm.engine.authorization.Groups;
import org.camunda.bpm.engine.authorization.Permission;
import org.camunda.bpm.engine.authorization.Permissions;
import org.camunda.bpm.engine.authorization.Resource;
import org.camunda.bpm.engine.authorization.Resources;
import org.camunda.bpm.engine.identity.Group;
import org.camunda.bpm.spring.boot.starter.event.PostDeployEvent;
import org.camunda.bpm.spring.boot.starter.property.CamundaBpmProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

/**
 * Typical production bootstrap code: makes sure the operations group exists and has the
 * permissions it needs in Cockpit/Tasklist, and that the admin group exists.
 *
 * <p>MIGRATION HOTSPOTS:
 * <ul>
 *   <li>{@code Groups.CAMUNDA_ADMIN} = "camunda-admin". Operaton renames the constant
 *       (OPERATON_ADMIN) AND its value ("operaton-admin"). Existing memberships in
 *       ACT_ID_MEMBERSHIP still point to "camunda-admin" -> admins lose admin rights after
 *       the upgrade unless the data is migrated too (see ops/sql/grant-admin.sql).</li>
 *   <li>{@code PostDeployEvent} and {@code CamundaBpmProperties} live in the Spring Boot
 *       starter package ({@code org.camunda.bpm.spring.boot.starter...}).</li>
 *   <li>Application resource ids ("cockpit", "tasklist") are stable, but URLs/paths are not
 *       (see {@code camunda.bpm.webapp.application-path}).</li>
 * </ul>
 */
@Component
public class AdminAuthorizationInitializer {

  public static final String OPS_GROUP_ID = "order-ops";
  public static final String PROCESS_DEFINITION_KEY = "order-fulfillment";

  private static final Logger LOG = LoggerFactory.getLogger(AdminAuthorizationInitializer.class);

  private final CamundaBpmProperties camundaBpmProperties;

  public AdminAuthorizationInitializer(CamundaBpmProperties camundaBpmProperties) {
    this.camundaBpmProperties = camundaBpmProperties;
  }

  /** Fired by the SpringBootProcessApplication once processes.xml has been deployed. */
  @EventListener
  public void onPostDeploy(PostDeployEvent event) {
    ProcessEngine engine = event.getProcessEngine();
    IdentityService identityService = engine.getIdentityService();
    AuthorizationService authorizationService = engine.getAuthorizationService();

    ensureGroup(identityService, Groups.CAMUNDA_ADMIN, "Camunda Administrators", Groups.GROUP_TYPE_SYSTEM);
    ensureGroup(identityService, OPS_GROUP_ID, "Order Operations", Groups.GROUP_TYPE_WORKFLOW);

    grant(authorizationService, Resources.APPLICATION, "cockpit", Permissions.ACCESS);
    grant(authorizationService, Resources.APPLICATION, "tasklist", Permissions.ACCESS);
    grant(authorizationService, Resources.PROCESS_DEFINITION, PROCESS_DEFINITION_KEY,
        Permissions.READ, Permissions.READ_INSTANCE, Permissions.READ_HISTORY);
    grant(authorizationService, Resources.TASK, Authorization.ANY, Permissions.READ, Permissions.UPDATE);

    // the configured admin user (camunda.bpm.admin-user.id) also works the ops queue
    String adminUserId = camundaBpmProperties.getAdminUser() == null ? null : camundaBpmProperties.getAdminUser().getId();
    if (adminUserId != null && identityService.createUserQuery().userId(adminUserId).count() == 1
        && identityService.createUserQuery().userId(adminUserId).memberOfGroup(OPS_GROUP_ID).count() == 0) {
      identityService.createMembership(adminUserId, OPS_GROUP_ID);
    }
    LOG.info("Authorizations for group '{}' and admin group '{}' ensured", OPS_GROUP_ID, Groups.CAMUNDA_ADMIN);
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
