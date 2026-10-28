// operaton-migration-helper: remove after the rollback window (D15)
package com.example.orders.migration;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.builder.SpringApplicationBuilder;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.env.MapPropertySource;
import org.springframework.core.env.StandardEnvironment;
import org.springframework.core.env.SystemEnvironmentPropertySource;

class LegacyCamundaConfigGuardTest {

  /** Deliberately empty: the guard runs before any bean (and the engine) is created. */
  @Configuration(proxyBeanMethods = false)
  static class EmptyConfiguration {
  }

  @Test
  void findsCamundaKeysEnvVarsAndHealthToggleButNotOperatonKeysWithCamundaValues() {
    StandardEnvironment environment = new StandardEnvironment();
    environment.getPropertySources().addFirst(new MapPropertySource("helm-values", Map.of(
        "camunda.bpm.admin-user.id", "admin",
        "management.health.camunda.enabled", "false",
        "operaton.bpm.webapp.application-path", "/camunda",
        "spring.datasource.url", "jdbc:postgresql://db/camunda")));
    environment.getPropertySources().addFirst(new SystemEnvironmentPropertySource("k8s-configmap", Map.of(
        "CAMUNDA_BPM_HISTORY_LEVEL", "audit",
        "OPERATON_BPM_ADMIN_USER_ID", "admin")));

    Map<String, java.util.List<String>> leftovers = LegacyCamundaConfigGuard.findLegacyKeys(environment);

    assertThat(leftovers).containsOnlyKeys("helm-values", "k8s-configmap");
    assertThat(leftovers.get("helm-values")).containsExactly("camunda.bpm.admin-user.id", "management.health.camunda.enabled");
    assertThat(leftovers.get("k8s-configmap")).containsExactly("CAMUNDA_BPM_HISTORY_LEVEL");
  }

  @Test
  void failsTheStartWithTheOffendingKeysButWithoutTheirValues() {
    // proves the Spring Boot 4 registration in META-INF/spring.factories (org.springframework.boot.EnvironmentPostProcessor)
    assertThatThrownBy(() -> start("--camunda.bpm.admin-user.password=s3cr3t", "--camunda.bpm.authorization.enabled=true"))
        .isInstanceOf(IllegalStateException.class)
        .hasMessageContaining("Camunda 7 configuration found")
        .hasMessageContaining("camunda.bpm.admin-user.password")
        .hasMessageContaining("camunda.bpm.authorization.enabled")
        .hasMessageContaining("[commandLineArgs]")
        .hasMessageNotContaining("s3cr3t");
  }

  @Test
  void startsWithOperatonConfiguration() {
    assertThatCode(() -> start("--operaton.bpm.admin-user.id=demo")).doesNotThrowAnyException();
  }

  @Test
  void canBeSwitchedOffOrToWarnOnly() {
    assertThatCode(() -> start("--camunda.bpm.history-level=audit",
        "--" + LegacyCamundaConfigGuard.ENABLED_PROPERTY + "=false")).doesNotThrowAnyException();
    assertThatCode(() -> start("--camunda.bpm.history-level=audit",
        "--" + LegacyCamundaConfigGuard.FAIL_PROPERTY + "=false")).doesNotThrowAnyException();
  }

  private static void start(String... args) {
    SpringApplication application = new SpringApplicationBuilder(EmptyConfiguration.class)
        .web(WebApplicationType.NONE)
        .bannerMode(org.springframework.boot.Banner.Mode.OFF)
        .logStartupInfo(false)
        .build();
    try (ConfigurableApplicationContext ignored = application.run(args)) {
      // started
    }
  }
}
