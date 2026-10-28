// operaton-migration-helper: remove after the rollback window (D15)
package com.example.orders.migration;

import org.operaton.bpm.spring.boot.starter.property.OperatonBpmProperties;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.boot.web.servlet.FilterRegistrationBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.Ordered;

/**
 * Spring wiring of the migration helpers. {@link LegacyCamundaConfigGuard} is not a bean: it runs
 * before the context exists and is registered in {@code META-INF/spring.factories}.
 *
 * <pre>
 * orders.migration.admin-group.enabled=true                 # default: mirror camunda-admin -> operaton-admin
 * orders.migration.admin-group.legacy-group-id=camunda-admin
 * orders.migration.legacy-webapp-redirect.enabled=false     # opt-in, for when D6 moves /camunda -> /operaton
 * orders.migration.legacy-webapp-redirect.legacy-path=/camunda
 * orders.migration.legacy-webapp-redirect.status=302
 * orders.migration.legacy-config-guard.enabled=true         # see LegacyCamundaConfigGuard
 * </pre>
 */
@Configuration(proxyBeanMethods = false)
public class MigrationHelpersConfiguration {

  /** Picked up by the Operaton starter like every ProcessEnginePlugin bean. */
  @Bean
  @ConditionalOnProperty(prefix = "orders.migration.admin-group", name = "enabled", havingValue = "true", matchIfMissing = true)
  public AdminGroupMigrationPlugin adminGroupMigrationPlugin(
      @Value("${orders.migration.admin-group.legacy-group-id:" + AdminGroupMigrationPlugin.CAMUNDA_ADMIN + "}") String legacyGroupId) {
    AdminGroupMigrationPlugin plugin = new AdminGroupMigrationPlugin();
    plugin.setLegacyGroupId(legacyGroupId);
    return plugin;
  }

  @Bean
  @ConditionalOnProperty(prefix = "orders.migration.legacy-webapp-redirect", name = "enabled", havingValue = "true")
  public FilterRegistrationBean<LegacyWebappPathRedirectFilter> legacyWebappPathRedirectFilter(
      OperatonBpmProperties operatonBpmProperties,
      @Value("${orders.migration.legacy-webapp-redirect.legacy-path:/camunda}") String legacyPath,
      @Value("${orders.migration.legacy-webapp-redirect.status:302}") int status) {
    LegacyWebappPathRedirectFilter filter = new LegacyWebappPathRedirectFilter(
        legacyPath, operatonBpmProperties.getWebapp().getApplicationPath(), status);
    FilterRegistrationBean<LegacyWebappPathRedirectFilter> registration = new FilterRegistrationBean<>(filter);
    registration.addUrlPatterns(filter.getLegacyPath(), filter.getLegacyPath() + "/*");
    registration.setOrder(Ordered.HIGHEST_PRECEDENCE);
    registration.setName("legacyWebappPathRedirectFilter");
    return registration;
  }
}
