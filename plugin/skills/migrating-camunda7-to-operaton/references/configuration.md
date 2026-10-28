# Configuration: properties, env vars, beans, loggers, health, webapp path, fail-fast guard

Guide chapters: [04 Spring Boot dependencies and configuration](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/04-spring-boot-dependencies-and-configuration.md) ·
[09 webapps and REST](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/09-webapps-rest-api-and-clients.md) ·
[11 operations](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/11-cutover-rollback-and-operations.md).

## Contents

1. Rules
2. Property keys: who renames what
3. Keys where more than the prefix changes
4. What a forgotten key does (prioritise these)
5. Environment variables
6. Well-known bean names
7. Logging, JMX, banner
8. Health and probes (decision D13)
9. Webapp path and overlays (decision D6)
10. `LegacyCamundaConfigGuard`: install, register, test, remove
11. Configuration outside the repository
12. Checklist

## 1. Rules

- `camunda.bpm.*` → `operaton.bpm.*` is a **pure prefix rename** (same keys, same types). There is no alias, no
  deprecation metadata and no compatibility layer: Spring Boot silently ignores leftover keys and Operaton runs on
  defaults. Only two defaults differ: `webapp.application-path` (`/operaton`) and `webapp.webjar-classpath`
  (`/META-INF/resources/webjars/operaton`).
- MUST rename keys and env vars at their **source** (file, Helm value, Config Server, CI variable), never alias them.
- MUST ship `LegacyCamundaConfigGuard` (`assets/snippets/`) with the migration commit (Spring Boot 3.5 path: in Hop 1)
  with `fail-on-leftovers: true` in every profile.
- MUST remove Camunda EE-only settings (D17): as generic properties they fail the Operaton start; the
  `validate-auth-resource-id-exists` key is ignored silently (§3).
- MUST set `operaton.bpm.webapp.application-path` **explicitly** according to D6 (recommended for the cut-over: `/camunda`).
- MUST keep `org.camunda.feel` logger names and every `LOGGING_LEVEL_ORG_CAMUNDA_FEEL*` variable unchanged.
- MUST NOT rename your own names that contain "camunda" (`spring.application.name`, JDBC URL `jdbc:…/camunda`, DB
  schema/user names, your own prefixes such as `datasource.camunda`). They are not Camunda configuration.
- Do not change files outside the repository yourself; produce a change list for the user (§11).

## 2. Property keys: who renames what

| Where the key lives | Done by |
|---|---|
| `camunda.bpm.*` in `application*.yaml/.properties` (main and test) | official `MigrateSpringBootApplication` (YAML stays nested with the migrate.sh setup) |
| `@Value("${camunda.bpm…}")`, `@ConditionalOnProperty(name=…)` | official recipe |
| `@ConditionalOnProperty(prefix = "camunda.bpm…")`, `@ConfigurationProperties("camunda.bpm…")` | `PreFixes` |
| `camunda.bpm.license-file` | deleted by the recipe; also delete it in Helm / Config Server |
| `camunda.bpm.authorization.validate-auth-resource-id-exists` (Camunda 7.24.3-ee) | renamed to `operaton.bpm.authorization.…` by the recipe, which Operaton ignores silently: **delete by hand** (`verify-leftovers.sh`: `EE_AUTH_RESOURCE_VALIDATION`) |
| EE-only generic properties (`queryExpressionAllowListEnabled`, `allowedExpression*InQueries`, `validateAuthResourceIdExists`) | carried over verbatim into `operaton.bpm.generic-properties.properties` by the recipe: **delete by hand**, the start fails otherwise (`EE_QUERY_EXPRESSION_ALLOWLIST`, `EE_AUTH_RESOURCE_VALIDATION`) |
| `management.health.camunda.*` | `PostFixes` |
| `logging.level.org.camunda…` | YAML: official recipe; `.properties`: `PostFixes` |
| whitelist values with `camunda-admin`, `disableStrictCamundaFormParsing` | `PostFixes` (only `application*`/`bootstrap*` files) |
| `CAMUNDA_BPM_*` in Dockerfiles, `.env`, compose, k8s/Helm YAML **in the repo** | `InfraEnvVars` (`--with-infra-env`) |
| `@SpringBootTest(properties = "camunda.bpm…")`, `@TestPropertySource` (Java literals) | `PreFixes` (`camunda.bpm` prefix in literals); verify with `verify-leftovers.sh` |
| `${camunda.bpm…}` placeholders outside `@Value` (`banner.txt`, XML, other text files) | manual (`verify-leftovers.sh` reports them) |
| Config Server, Vault, CI variables, `SPRING_APPLICATION_JSON`, `-D` flags, Helm values outside the repo | manual (§11) |

```yaml
# shape to aim for; keep the application's own VALUES (only names and the marked values change)
operaton:                          # was camunda:
  bpm:
    admin-user:                    # creates the user only on a FRESH DB; never adds an existing one to operaton-admin (D5)
      id: demo
    webapp:
      application-path: /camunda   # D6: write it explicitly; the default is now /operaton
    history-level: full            # unchanged value; must equal ACT_GE_PROPERTY historyLevel
    generic-properties:
      properties:
        groupResourceWhitelistPattern: "[a-zA-Z0-9]+|operaton-admin|order-ops"   # VALUE changed: camunda-admin -> operaton-admin
logging:
  level:
    org.operaton.bpm.engine.context: "OFF"   # was org.camunda.bpm.engine.context; org.camunda.feel stays
management:
  health:
    operaton:                      # was camunda; outside camunda.bpm
      enabled: true
```

`schema-update: false` for the production cut-over (D8) belongs in the production environment's configuration; do not
switch it off in files used by tests on in-memory databases.

## 3. Keys where more than the prefix changes

| Camunda 7 | Operaton | Action |
|---|---|---|
| `webapp.application-path` default `/camunda` | default `/operaton` | set explicitly (§9) |
| `webapp.webjar-classpath: /META-INF/resources/webjars/camunda` (explicit old default) | points to a path that does not exist | **delete** the key |
| `webapp.security-config-file`, `webapp.csrf.entry-points` with `/camunda/…` values | same keys | follow the new webjar path / app path |
| `management.health.camunda.enabled` | `management.health.operaton.enabled` | rename (Operaton docs' `operaton.bpm.management.health…` is wrong) |
| generic property `disableStrictCamundaFormParsing` / `disable-strict-camunda-form-parsing` | `disableStrictOperatonFormParsing` | rename; unknown generic properties fail the start |
| generic `generalResourceWhitelistPattern` / `groupResourceWhitelistPattern` values with `camunda-admin` | `operaton-admin` | rename value; a set `groupResourceWhitelistPattern` replaces the general one, so include `operaton-admin` |
| `spring.autoconfigure.exclude: org.camunda.bpm.spring.boot.starter…Camunda…AutoConfiguration` | `org.operaton.bpm.spring.boot.starter…Operaton…AutoConfiguration` | rename package **and** class (a stale exclude is ignored silently) |
| `${camunda.bpm.formatted-version}` in `banner.txt` | `${operaton.bpm.formatted-version}` | rename |
| Keycloak plugin keys `useEmailAsCamundaUserId`, `useUsernameAsCamundaUserId`, `useGroupPathAsCamundaGroupId` (own prefix, typically `plugin.identity.keycloak`) | `useEmailAsOperatonUserId`, `useUsernameAsOperatonUserId`, `useGroupPathAsOperatonGroupId` | rename; keep the user-id mode identical. Keep `administratorGroupName` as the realm has it |
| `camunda.bpm.client.*` (external task client starter) | `operaton.bpm.client.*` (same keys) | rename; worker silently never fetches otherwise |
| `camunda.bpm.oauth2.*` (security starter) | `operaton.bpm.oauth2.*` | rename (also Secrets holding client secrets) |
| `camunda.bpm.eventing.*` | `operaton.bpm.eventing.*` | rename; a lost `history: false` re-enables history events as Spring events |
| `camunda.bpm.authorization.validate-auth-resource-id-exists` (EE 7.24.3) | does not exist | delete; validate ids in code that creates authorizations (D17) |
| generic properties `queryExpressionAllowListEnabled`, `allowedExpressionFunctionsInQueries`, `allowedExpressionBeansInQueries`, `allowedExpressionPropertiesInQueries` (EE 7.24.7) | do not exist; unknown generic properties fail the start | delete; mitigation below (D17) |
| `spring.datasource.hikari.auto-commit: false` (recommended by the EE 7.24.3 autocommit check) | unchanged key; Operaton does not check it | keep it |

New Operaton-only keys (2.1 `webapp.session-cookie-path-enforcement`; 2.2 previews `job-executor-acquire-with-skip-locked`,
`webapp.neo.*`) stay **off** in the cut-over release.

Query expressions (D17; Operaton has no query-expression allow-list, only the two all-or-nothing switches
`enableExpressionsInAdhocQueries`, default false, and `enableExpressionsInStoredQueries`, default **true**). Default
mitigation, unless stored filters need expressions such as `${currentUser()}` (pre-flight P11 lists them; details:
references/identity-and-admin.md §10):

```yaml
operaton:
  bpm:
    generic-properties:
      properties:
        enable-expressions-in-stored-queries: false   # D17: replaces Camunda 7.24.7-ee's allow-list; P11 lists affected filters
        # enable-expressions-in-adhoc-queries stays false (the default)
```

## 4. What a forgotten key does (prioritise these)

| Forgotten `camunda.bpm.…` (or `CAMUNDA_BPM_…`) | Effect on Operaton |
|---|---|
| `authorization.enabled: true` | default `false`: **all authorization checks off** (silent, security) |
| `webapp.*` | webapps move to `/operaton`; CSRF/cookie/HSTS hardening lost (silent, security) |
| `history-level` set to `audit`, `activity` or `none` | default `full` → start fails `historyLevel mismatch` |
| `database.schema-update: false` | default `true` (DDL allowed) |
| `database.table-prefix` / `schema-name` | wrong schema; with `schema-update: true` an **empty** schema is created |
| `admin-user.*` | no admin bootstrapped on a fresh DB |
| `job-execution.enabled: false` | job executor runs (also on REST-only nodes, in tests) |
| `job-execution.*` tuning | pool 3/10, queue 3, `deployment-aware: false` |
| `generic-properties.*` | TTL, password policy, whitelist lost (later `ENGINE-12018`) |
| `deployment-resource-pattern`, `auto-deployment-enabled` | different resources (re)deployed; custom `.form` patterns lost |
| `eventing.history: false` | every history event published as a Spring event again |
| `client.*` | external task client unconfigured, tasks pile up |
| (EE) `authorization.validate-auth-resource-id-exists` | no effect either way: Operaton has no such validation (D17) |

Compare `history-level`, `authorization.*`, `database.*`, `job-execution.*` key by key with the **production** values.

## 5. Environment variables

| Camunda 7 | Operaton |
|---|---|
| `CAMUNDA_BPM_*` (incl. `CAMUNDA_BPM_CLIENT_*`, `CAMUNDA_BPM_OAUTH2_*`) | `OPERATON_BPM_*` |
| `MANAGEMENT_HEALTH_CAMUNDA_ENABLED` | `MANAGEMENT_HEALTH_OPERATON_ENABLED` (not covered by `InfraEnvVars`) |
| `LOGGING_LEVEL_ORG_CAMUNDA_BPM_*` (also `_SPIN_`, `_CONNECT_`, `_COMMONS_`) | `LOGGING_LEVEL_ORG_OPERATON_…` (not covered by `InfraEnvVars`); keep `LOGGING_LEVEL_ORG_CAMUNDA_FEEL*` |
| `CAMUNDA_BPM_LICENSE_FILE` | delete (`EE_LICENSE`; also `OPERATON_BPM_LICENSE_FILE`) |
| env var forms of `validate-auth-resource-id-exists` | delete (`EE_AUTH_RESOURCE_VALIDATION`) |
| `SPRING_DATASOURCE_*` | unchanged |

Change only the prefix and keep the team's spelling: `OPERATON_BPM_JOBEXECUTION_ENABLED` and
`OPERATON_BPM_JOB_EXECUTION_ENABLED` both bind to `operaton.bpm.job-execution.enabled`. Map-typed keys
(`generic-properties.properties.*`) are lower-cased from env vars: keep them in YAML or `SPRING_APPLICATION_JSON`.
`SPRING_APPLICATION_JSON` with `{"camunda":{"bpm":…}}` is invisible to a `CAMUNDA_BPM_` grep: check it explicitly.

## 6. Well-known bean names

The starter looks these up **by name**; an old name is silently ignored.

| Camunda 7 | Operaton | If the old name stays |
|---|---|---|
| `camundaBpmDataSource` | `operatonBpmDataSource` | engine runs on the `@Primary` DataSource; with `schema-update: true` it creates `ACT_*` there |
| `camundaBpmTransactionManager` | `operatonBpmTransactionManager` | primary transaction manager used |
| `camundaBpmJdbcTemplate` | `operatonBpmJdbcTemplate` | history level detection on the wrong DB |
| `camundaTaskExecutor` (`CAMUNDA_TASK_EXECUTOR_QUALIFIER`) | `operatonTaskExecutor` (`OPERATON_TASK_EXECUTOR_QUALIFIER`) | tuned executor ignored |
| `processEngineHealthIndicator`, `jobExecutorHealthIndicator`, `jobExecutor`, `historyLevelDeterminator`, `spinProcessEnginePlugin`, `connectProcessEnginePlugin`, `applicationContextClassloaderSwitchPlugin` | unchanged | – |

`PreFixes` rewrites the four names as whole Java/Kotlin literals. Grep XML bean files, `@Resource(name=…)`, SpEL and
suffixed variants yourself. Your own config prefixes (e.g. `@ConfigurationProperties("datasource.camunda")`) may stay.

## 7. Logging, JMX, banner

- Logger names are package names: `org.camunda.{bpm,spin,connect,commons}…` → `org.operaton.…` in YAML,
  `.properties`, `logback*.xml` (`<logger name>`), `log4j2*.xml` (`<Logger>`, `<AsyncLogger>`) and env vars. Example:
  `org.camunda.bpm.engine.context` (silences `ENGINE-16004` stack traces) → `org.operaton.bpm.engine.context`.
- FEEL stays `org.camunda.feel` / `org.camunda.feel.FeelEngine` (Operaton's logging docs listing `org.operaton.feel`
  are wrong). Never search-and-replace `org.camunda` in logging config.
- Unchanged: message codes (`ENGINE-16004`, `ENGINE-14006`, `STARTER-SB…`, `REST-…`, `WEBAPP-…`, `DMN-…`, `SPIN-…`),
  MDC keys (`processInstanceId`, `activityId`, …), engine metric names. Alerts keyed on codes survive.
- JMX domains: `org.camunda.bpm.platform…` → `org.operaton.bpm.platform…` (Prometheus JMX exporter rules, APM).
- Banner: `${camunda.bpm.formatted-version}` → `${operaton.bpm.formatted-version}`.
- Outside the repo (list for the user): log-shipping filters and alert rules on logger names (match
  `^org\.(camunda|operaton)\.bpm\.` during the rollback window), error-tracker ignore lists naming
  `org.camunda.bpm.engine.OptimisticLockingException`, JMX exporter rules, dashboards on `uri=~"/camunda/.*"`.

## 8. Health and probes (decision D13)

- Toggle: `management.health.operaton.enabled` (components `processEngine`, `jobExecutor` keep their names).
- From Operaton 2.1, `processEngine` reports **DOWN** when no valid DB connection is available. Put it in readiness
  only, never liveness:

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
      group:
        liveness:
          include: livenessState
        readiness:
          include: readinessState, db, processEngine
```

- Probes: `/actuator/health/liveness` and `/actuator/health/readiness`, never a webapp URL (`/camunda/app/…` moves with D6).
- `jobExecutor` is DOWN when job execution is inactive: leave it out of probes on nodes with `job-execution.enabled: false`.
- DB unreachable can block up to the pool's connection timeout (HikariCP default 30 s): size `timeoutSeconds` or lower
  `spring.datasource.hikari.connection-timeout`. A custom `org.operaton.bpm.engine.health.HealthService` bean replaces the default.

## 9. Webapp path and overlays (decision D6)

- Cut-over release: `operaton.bpm.webapp.application-path: /camunda` (or `OPERATON_BPM_WEBAPP_APPLICATION_PATH=/camunda`).
  Result: `/camunda/app/…` 200, `/operaton/app/…` 404, `/` → `/camunda/app/`. `/engine-rest` never moves.
  Accept the resulting `WEBAPP_PATH` warnings in `.operaton-migration-ignore` with reason "D6".
- Later move to `/operaton`: new ingress rules first, then `application-path: /operaton` plus a GET/HEAD redirect:
  `assets/snippets/LegacyWebappPathRedirectFilter.java`, wired by `assets/snippets/MigrationHelpersConfiguration.java`
  (`orders.migration.legacy-webapp-redirect.enabled=true`, `legacy-path=/camunda`, `status=302` → 301 when final;
  it refuses legacy path == app path). POSTs are deliberately not redirected. Update IdP redirect/post-logout URIs,
  WAF/proxy rules, probes, dashboards, generated links (derive from `OperatonBpmProperties#getWebapp().getApplicationPath()`).
- Overlays move regardless of the path: `git mv src/main/resources/META-INF/resources/webjars/camunda src/main/resources/META-INF/resources/webjars/operaton`
  (`config.js`, `user-styles.css`, logos, `securityFilterRules.json`). Verify: `curl -s <base>/<app-path>/app/cockpit/scripts/config.js | head -5`.
- `session-cookie-path-enforcement` (2.1+): not in the cut-over release. Users log in again after the switch (session
  attributes renamed): flush persisted session stores.
- Setup endpoint and admin group: references/identity-and-admin.md (release blocker, independent of D6).

## 10. `LegacyCamundaConfigGuard`: install, register, test, remove

An `EnvironmentPostProcessor` that runs after all config data is loaded and **before** the context and engine start. It
scans every enumerable property source (files, system properties, command line, OS env, `SPRING_APPLICATION_JSON`,
imported Config Server/Vault sources) for `camunda.bpm.*`, `CAMUNDA_BPM_*`, `management.health.camunda.*`,
`MANAGEMENT_HEALTH_CAMUNDA_*`, and fails the start listing **key names and their source, never values**.

1. Copy `assets/snippets/LegacyCamundaConfigGuard.java` into the app (e.g. `<base-package>.migration`); change the
   `package` line and keep the marker line `// operaton-migration-helper: remove after the rollback window (D15)`
   (the class holds `camunda.bpm` strings on purpose; `verify-leftovers.sh` skips marked files). Optionally rename the
   `orders.migration.legacy-config-guard` prefix (`PROPERTY_PREFIX`) to the app's convention, consistently with
   `MigrationHelpersConfiguration` and the YAML.
2. Register it in `src/main/resources/META-INF/spring.factories` (merge with existing entries; do not overwrite).
   The bundled snippet is the **Spring Boot 4 variant**: use it as shipped on the Spring Boot 4 path. The interface and
   key depend on the Spring Boot line:

| When | Spring Boot | `import` in the class | `spring.factories` key |
|---|---|---|---|
| Spring Boot 4 path; Spring Boot 3.5 path Hop 2 | 4.x | `org.springframework.boot.EnvironmentPostProcessor` (as shipped) | `org.springframework.boot.EnvironmentPostProcessor` |
| Spring Boot 3.5 path, Hop 1 | 3.5 | `org.springframework.boot.env.EnvironmentPostProcessor` | `org.springframework.boot.env.EnvironmentPostProcessor` |

   Spring Boot 3.5 path, Hop 1 edit, exactly: in the class replace the line `import org.springframework.boot.EnvironmentPostProcessor;` with
   `import org.springframework.boot.env.EnvironmentPostProcessor;` (nothing else changes: same method signature), and use
   the key `org.springframework.boot.env.EnvironmentPostProcessor`. Adjust the Javadoc sentence about the registration.

```properties
# Spring Boot 4 (Spring Boot 4 path; Spring Boot 3.5 path Hop 2)
org.springframework.boot.EnvironmentPostProcessor=\
com.example.orders.migration.LegacyCamundaConfigGuard
# Spring Boot 3.5 path, Hop 1 (Spring Boot 3.5): key org.springframework.boot.env.EnvironmentPostProcessor, same value
```

   Wrong key → guard silently never loads; Spring Boot 4 interface on Spring Boot 3 → does not compile. On the Spring
   Boot 3.5 path, switch interface **and** key to `org.springframework.boot.EnvironmentPostProcessor` in Hop 2: on Spring
   Boot 4.0 the Spring Boot 3 SPI (`org.springframework.boot.env.EnvironmentPostProcessor` and its factories key) still
   works but is deprecated for removal.
3. Add the test: copy `assets/snippets/test/LegacyCamundaConfigGuardTest.java` (change the package). It starts a real
   `SpringApplication` (empty `@Configuration`, `WebApplicationType.NONE`) with
   `--camunda.bpm.authorization.enabled=true --camunda.bpm.admin-user.password=s3cr3t` and asserts an
   `IllegalStateException` containing `Camunda 7 configuration found` and the key, **not** containing `s3cr3t`; plus
   one start with `--operaton.bpm.admin-user.id=demo` that must not throw. This proves the registration on either Spring
   Boot line.
4. Switches: `<prefix>.enabled` (default `true`), `<prefix>.fail-on-leftovers` (default `true`; `false` = stderr warning).
   Keep `true` everywhere, including local and CI. A failed first start in an environment is the desired outcome: fix
   the named source, not the guard. Use `fail-on-leftovers: false` only for services that share a Config Server with
   not-yet-migrated Camunda services (better: move shared keys to service-specific files).
5. Remove it after every environment started cleanly and the rollback window (D15) is closed.

Limits: it does not flag `operaton.bpm.*` keys with Camunda **values** (`/camunda` is legitimate under D6),
`logging.level.org.camunda.*` (FEEL must stay), bean names, or `operaton.bpm.authorization.validate-auth-resource-id-exists`
(renamed, but ignored): `verify-leftovers.sh` covers those in the repo. A legacy Spring Cloud bootstrap context is not
covered (not verified).

## 11. Configuration outside the repository

Recipes and `verify-leftovers.sh` only see the repository. For each environment, give the user this list (record it in
the report as open items with owners) and offer to grep repositories the user points to:

| Where | What to change | Typical miss |
|---|---|---|
| Helm `values*.yaml`, Kustomize overlays, ConfigMaps | `env:` entries, `configMapGenerator` literals, rendered `application.yaml` | `values-prod.yaml` that only exists in the deployment repo |
| Kubernetes Secrets | `CAMUNDA_BPM_ADMIN_USER_PASSWORD`, OAuth2 secrets under `camunda.bpm.oauth2.*` | values are base64: compare **key names** only (never decode or print secret values) |
| Spring Cloud Config repo | `application.yml`, `<app>.yml`, `<app>-<profile>.yml` | shared `application.yml`: both prefixes until all services are migrated (each starter ignores the other prefix) |
| Vault / AWS Secrets Manager / Azure Key Vault (`spring.config.import`) | keys like `camunda.bpm.admin-user.password` | renames need coordinated rotation |
| CI/CD variables (GitLab, GitHub Actions, Jenkins, Argo CD) | `CAMUNDA_BPM_*`, `-Dcamunda.bpm.*` in `JAVA_TOOL_OPTIONS` / `JAVA_OPTS` | variables injected only into the production stage (`InfraEnvVars` skips CI files on purpose) |
| `SPRING_APPLICATION_JSON` | `{"camunda":{"bpm":{…}}}` | invisible to a `CAMUNDA_BPM_` grep |
| probes, `HEALTHCHECK`, ingress, WAF, IdP clients | `/camunda/app/…` paths, `management.health.camunda.enabled` | probes failing after a D6 move |
| log shipping, alerting, APM, JMX exporter | logger names, `org.camunda.bpm.platform` | ERROR-rate alerts after the cut-over |
| Maven settings, CI, build servers (Camunda EE) | the EE repository `artifacts.camunda.com`, server id `camunda-bpm-nexus-ee`, license files and secrets | credentials left in CI after the migration (D17) |

```bash
# run in each deployment / Config Server repository the user provides (read-only)
grep -rnE 'camunda\.bpm\.|CAMUNDA_BPM_|management\.health\.camunda|MANAGEMENT_HEALTH_CAMUNDA|"camunda"\s*:\s*\{' \
  --include='*.y*ml' --include='*.properties' --include='*.json' --include='*.env' --include='Dockerfile*' --include='*.tf' .
```

The guard (§10) is the safety net for everything this list misses: the first start of the rehearsal must use the
**production** configuration sources, not a hand-written copy.

## 12. Checklist

- [ ] No `camunda.bpm.*` in `application*` files, test resources, `@SpringBootTest(properties)`, `@TestPropertySource`, placeholders.
- [ ] `management.health.operaton.enabled`; whitelist values contain `operaton-admin`; `disableStrictOperatonFormParsing`.
- [ ] `webjar-classpath` deleted; `csrf.entry-points`, `security-config-file`, `spring.autoconfigure.exclude`, `banner.txt`, Keycloak keys reviewed.
- [ ] `operaton.bpm.webapp.application-path` explicit per D6; overlays under `webjars/operaton`.
- [ ] `history-level`, `authorization.*`, `database.*`, `job-execution.*` equal to production values.
- [ ] Env vars renamed (incl. `MANAGEMENT_HEALTH_*`, `LOGGING_LEVEL_ORG_*`; FEEL kept); bean names `operaton…`.
- [ ] Logger names renamed in all config formats; JMX/log/alert changes listed for ops.
- [ ] Probe groups: `processEngine` in readiness only (D13).
- [ ] `LegacyCamundaConfigGuard` registered with the interface and key of the current Spring Boot line (Spring Boot 4:
      the snippet as shipped); `LegacyCamundaConfigGuardTest` green.
- [ ] Camunda EE (D17): license keys and files, `validate-auth-resource-id-exists` and the EE-only generic properties
      removed; `enable-expressions-in-stored-queries` set per D17; `spring.datasource.hikari.auto-commit: false` kept.
- [ ] Outside-repo change list in the report, with owners; `verify-leftovers.sh` exits 0.
