// operaton-migration-helper: remove after the rollback window (D15)
package com.example.orders.migration;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.TreeMap;
import org.springframework.boot.EnvironmentPostProcessor;
import org.springframework.boot.SpringApplication;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.env.EnumerablePropertySource;
import org.springframework.core.env.PropertySource;

/**
 * Fails the application start when Camunda-era configuration is still around.
 *
 * <p>Operaton binds {@code operaton.bpm.*}. Spring Boot silently ignores leftover {@code camunda.bpm.*}
 * keys, {@code CAMUNDA_BPM_*} environment variables and {@code management.health.camunda.*}: the engine
 * then starts with defaults (authorization off, history level full, no admin user, job executor
 * tuning lost, webapp path {@code /operaton} ...). Leftovers typically hide in places the recipes never
 * see: Helm values, Kubernetes ConfigMaps, CI/CD variables, config servers, {@code -D} flags.
 *
 * <p>The guard inspects every enumerable property source after the config files were loaded and
 * before the application context (and the engine) starts. It reports the offending keys together with
 * the property source they come from - never their values (they may be secrets).
 *
 * <p>Registration: {@code META-INF/spring.factories} under {@code org.springframework.boot.EnvironmentPostProcessor}
 * (Spring Boot 4.0 SPI). On Spring Boot 3.x (Operaton 1.x / Hop 1) the interface is
 * {@code org.springframework.boot.env.EnvironmentPostProcessor} and the factories key is the same FQCN.
 *
 * <p>Opt out with {@code orders.migration.legacy-config-guard.enabled=false}, or only log a warning with
 * {@code orders.migration.legacy-config-guard.fail-on-leftovers=false}. Keep it for the first releases
 * after the cut-over; remove it once all environments are clean.
 */
public class LegacyCamundaConfigGuard implements EnvironmentPostProcessor, Ordered {

  public static final String PROPERTY_PREFIX = "orders.migration.legacy-config-guard";
  public static final String ENABLED_PROPERTY = PROPERTY_PREFIX + ".enabled";
  public static final String FAIL_PROPERTY = PROPERTY_PREFIX + ".fail-on-leftovers";

  /** Relaxed-binding forms that Spring Boot would have bound to the Camunda starter. */
  private static final String[] LEGACY_PREFIXES = {
      "camunda.bpm.", "camunda_bpm_", "management.health.camunda.", "management_health_camunda_"
  };
  private static final String[] LEGACY_EXACT = {"camunda.bpm", "management.health.camunda"};

  @Override
  public void postProcessEnvironment(ConfigurableEnvironment environment, SpringApplication application) {
    if (!environment.getProperty(ENABLED_PROPERTY, Boolean.class, Boolean.TRUE)) {
      return;
    }
    Map<String, List<String>> leftovers = findLegacyKeys(environment);
    if (leftovers.isEmpty()) {
      return;
    }
    String message = describe(leftovers);
    if (environment.getProperty(FAIL_PROPERTY, Boolean.class, Boolean.TRUE)) {
      throw new IllegalStateException(message);
    }
    // Logging is not initialised for all sources yet; stderr is always visible in container logs.
    System.err.println("WARN " + LegacyCamundaConfigGuard.class.getSimpleName() + ": " + message);
  }

  /** Offending property names grouped by property source name (sorted, without values). */
  public static Map<String, List<String>> findLegacyKeys(ConfigurableEnvironment environment) {
    Map<String, List<String>> result = new TreeMap<>();
    for (PropertySource<?> source : environment.getPropertySources()) {
      if (!(source instanceof EnumerablePropertySource<?> enumerable)) {
        continue;
      }
      if ("configurationProperties".equals(source.getName())) {
        continue; // ConfigurationPropertySourcesPropertySource wraps all other sources
      }
      List<String> names = new ArrayList<>();
      for (String name : enumerable.getPropertyNames()) {
        if (isLegacy(name)) {
          names.add(name);
        }
      }
      if (!names.isEmpty()) {
        names.sort(String::compareTo);
        result.put(source.getName(), names);
      }
    }
    return result;
  }

  static boolean isLegacy(String propertyName) {
    String name = propertyName.toLowerCase(Locale.ROOT);
    for (String exact : LEGACY_EXACT) {
      if (name.equals(exact)) {
        return true;
      }
    }
    for (String prefix : LEGACY_PREFIXES) {
      if (name.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  private static String describe(Map<String, List<String>> leftovers) {
    StringBuilder sb = new StringBuilder("Camunda 7 configuration found - Operaton ignores it silently. ")
        .append("Rename camunda.bpm.* -> operaton.bpm.*, CAMUNDA_BPM_* -> OPERATON_BPM_*, ")
        .append("management.health.camunda.* -> management.health.operaton.*. Offending keys:");
    leftovers.forEach((source, names) -> sb.append("\n  [").append(source).append("] ").append(String.join(", ", names)));
    sb.append("\n(Opt out: ").append(ENABLED_PROPERTY).append("=false; warn only: ")
        .append(FAIL_PROPERTY).append("=false)");
    return sb.toString();
  }

  /** After ConfigDataEnvironmentPostProcessor (application.yaml etc. must be loaded first). */
  @Override
  public int getOrder() {
    return Ordered.LOWEST_PRECEDENCE;
  }
}
