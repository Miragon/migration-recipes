# 04 · Spring Boot dependencies and configuration

This chapter lists what changes in the build and the Spring configuration of a Spring Boot application: Maven
coordinates (including Camunda's Spring Boot 4 starters and EE artifacts), the EE repository, configuration keys,
EE-only engine settings, bean names, logging, health probes and security. It is for the developers who convert the
code and for ops, who own the configuration outside the repository. Use it during the conversion (the one recipe run
that turns your Camunda 7.24 EE code on Spring Boot 4 into Operaton 2.x code), and again for every environment
before the cut-over (the production switch from Camunda to Operaton).

> [!NOTE]
> **On Spring Boot 3.5?** Read [Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md)
> first. It covers the Operaton 1.1.5 checkpoint, its Spring Boot version and the guard registration for Spring
> Boot 3.5.

**In short**
- Maven coordinates map 1:1: `org.camunda.bpm[.springboot|.dmn|…]:camunda-*` → `org.operaton.bpm[…]:operaton-*`.
  There are two exceptions. Operaton's starters have **no `-4`** in their name, and Operaton has **no `-jackson3`**
  artifacts, so Camunda's Jackson 3 opt-ins go back to Jackson 2. Import `operaton-bom` with an **explicit**
  version, because Maven's release metadata can point to a release candidate. Keep Spring Boot on the minor version
  the Operaton release is built with: 4.0 for Operaton 2.1.5, 4.1 for 2.2.x. `org.camunda.feel:feel-engine` stays,
  because Operaton still uses the Camunda FEEL engine.
- **An EE build needs the Camunda EE repository and its credentials while the recipe runs**, because the rewrite
  plugin resolves all dependencies first. After the conversion the Operaton build no longer needs them: remove the
  repository, the credentials and the CI secrets from it. Revoke the credentials only after the rollback window has
  closed, because a rebuild of the Camunda rollback build still needs them. The recipe deletes
  `camunda.bpm.license-file`, because Operaton needs no license.
- **EE-only engine settings break in three ways.** As generic properties they stop the engine from starting, as Java
  calls they do not compile, and `operaton.bpm.authorization.validate-auth-resource-id-exists` is ignored silently.
  Remove them, and replace the protection they gave
  ([EE-only engine settings](#ee-only-engine-settings)).
- `camunda.bpm.*` → `operaton.bpm.*` is a pure prefix rename with **no alias**. Spring Boot ignores unknown keys, so
  a forgotten key silently falls back to a default. For example, a forgotten `authorization.enabled: true` falls
  back to `false`.
- `scripts/migrate.sh` renames the keys in your repository with the recipe
  `starterpack.operaton.MigrateSpringBoot4App` (an OpenRewrite recipe, i.e. an automated code transformation). The
  generic `MigrateFromCamunda` recipe does not rename them.
- No recipe reaches configuration outside the repository (Helm, Config Server, Vault, CI); you rename it yourself.
  Ship [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java),
  so that leftover keys stop the application start instead of being ignored.

## What to do

1. **Run the conversion.** First run `scripts/migrate.sh --dry-run <project>` and review the patch, then run
   `scripts/migrate.sh --with-infra-env <project>`. On Spring Boot 4.1, add `--target 2.2.0` once Operaton 2.2.0 is
   GA (due 2026-10-23), or `--target 2.2.0-RC1` for rehearsals, never for production. `--with-infra-env` also renames
   `CAMUNDA_BPM_*` in Dockerfiles, `.env`, compose and k8s/Helm YAML in the repository. Details:
   [OpenRewrite recipes](03-openrewrite-recipes.md).
2. **Check the build**, because each Operaton release supports only the Spring Boot version it is built with: Java
   17+, Spring Boot **4.0.8** for Operaton 2.1.5 or **4.1.x** for 2.2.x, an explicit `operaton.version`, no
   `camunda.version`, and no `-4`, `-jackson3` or `-ee` coordinates left.
3. **Remove the Camunda EE repository and its credentials from the Operaton build**, then prove that the build
   resolves from Maven Central alone, so that the Operaton build and its pipeline do not depend on EE access after
   the switch
   ([below](#camunda-ee-repository-and-credentials)).
4. **Remove EE-only engine settings and calls** ([below](#ee-only-engine-settings)), because they stop the start or
   silently do nothing, and plan the replacement for the security checks they controlled.
5. **Fix what the recipe cannot see** ([table](#where-more-than-the-prefix-changes)). Then run
   `scripts/verify-leftovers.sh <project>` to find leftovers, the Camunda references that no recipe converted.
   Exit code 1 means that MUST-FIX findings remain, which you have to fix.
6. **Copy `LegacyCamundaConfigGuard` into your service** with `fail-on-leftovers: true`, so that a forgotten key
   outside the repository stops the start instead of silently switching a setting back to its default.
7. **In every environment, rename the keys outside the repository**
   ([list](#configuration-outside-the-repository)).

## Dependencies

Most coordinates map 1:1 to an Operaton artifact, so most dependency changes are renames that the recipes do for
you: the official recipe, plus the starter-pack recipes `Boot4PreFixes`, `PostFixes` and `AlignVersionsOperaton2`
([what they add](03-openrewrite-recipes.md#what-the-composite-adds)). The version pairing, the EE versions and the
items in the list at the end of this section need care.

**Version pairing.** Each Operaton release supports one Spring Boot version: **2.1.5 ↔ 4.0.8**, 2.2 ↔ 4.1
(2.2.0-RC1 is built with 4.1.1). `scripts/latest-versions.sh --operaton <version>` prints the pairing. The official
recipe pins `1.0.x`, which is end of life (EOL), and keeps the `camunda.version` property name.
`starterpack.operaton.AlignVersionsOperaton2` repairs both on the Spring Boot 4 path:

- It moves every `org.operaton*` artifact to the target (`--target`, default 2.1.5) and removes explicit versions
  that `operaton-bom` manages anyway.
- It renames the property `camunda.version` to `operaton.version` (and `version.camunda` to `version.operaton`).
- It never downgrades Spring Boot. If your Spring Boot is on the target's minor line, it raises it to the patch the
  target is built with if lower (for example 4.0.5 → 4.0.8 for 2.1.5). If the minor differs, `migrate.sh` leaves
  Spring Boot as it is and prints a warning with the recommended target.

**EE versions.** `7.24.N-ee` versions exist only in the Camunda EE repository; no Operaton artifact has one. An EE
version such as `7.24.16-ee` also counts as newer than every Operaton 2.x version, so no upgrade recipe would ever
replace it. `Boot4PreFixes` therefore replaces `camunda-bom` with `operaton-bom` at the target version as its first
step, and sets the values of `camunda.version` and `version.camunda` to the target. If an `-ee` version survives,
let `operaton-bom` manage the version (`${operaton.version}`) and delete the `-ee` property. `scripts/verify-leftovers.sh` reports it as
`EE_VERSION`: MUST for a `<version>` or coordinate in a build file or a referenced property (the build needs the EE
repository or fails), WARN for an unused property or a value outside the build, such as a Docker image tag or a CI
variable.

### Spring Boot 4 starters and Jackson 3 artifacts

Camunda ships its Spring Boot 4 starters as separate artifacts with `-4` after `starter` (since 7.24.3-ee), and the
opt-in Jackson 3 artifacts with a `-jackson3` suffix (since 7.24.16-ee). Operaton has no `-4` starters and no
Jackson 3 variants of Spin, the REST API or the external task client. The official recipe (1.0.1) maps none of
these artifacts: on a `-4` project it renames the Java imports but leaves the starters behind, and the build breaks.
`Boot4PreFixes` maps them. The table shows the result; the Operaton artifacts get no `<version>`, because
`operaton-bom` manages them.

| Camunda 7.24 EE (`org.camunda.bpm.springboot`) | Operaton 2.x (`org.operaton.bpm.springboot`) | Note |
|---|---|---|
| `camunda-bpm-spring-boot-starter-4` | `operaton-bpm-spring-boot-starter` | No `-4` in Operaton |
| `camunda-bpm-spring-boot-starter-4-rest` | `operaton-bpm-spring-boot-starter-rest` | |
| `camunda-bpm-spring-boot-starter-4-webapp` | `operaton-bpm-spring-boot-starter-webapp` | |
| `camunda-bpm-spring-boot-starter-4-webapp-ee` | `operaton-bpm-spring-boot-starter-webapp` | EE webapp features are lost ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)) |
| `camunda-bpm-spring-boot-starter-4-webapp-core` | `operaton-bpm-spring-boot-starter-webapp-core` | |
| `camunda-bpm-spring-boot-starter-4-security` | `operaton-bpm-spring-boot-starter-security` | |
| `camunda-bpm-spring-boot-starter-4-external-task-client` | `operaton-bpm-spring-boot-starter-external-task-client` | |
| `camunda-bpm-spring-boot-starter-4-test` | `operaton-bpm-spring-boot-starter-test-junit5` | Via `-test`; see the note below the table |
| `camunda-bpm-spring-boot-starter-4-rest-jackson3` | `operaton-bpm-spring-boot-starter-rest` | Jackson 2 |

`-4-test` is first mapped to `operaton-bpm-spring-boot-starter-test`, the JUnit 4 flavour, as the official recipe
does for `-test`. `PostFixes` then adds `operaton-bpm-spring-boot-starter-test-junit5` if your tests use JUnit
Jupiter, and removes the JUnit 4 flavour unless JUnit 4 tests exist
([test-stack decision, D11](01-migration-path-and-decisions.md#d11)).

The other Jackson 3 artifacts go back to their Jackson 2 counterparts:

| Camunda 7.24.16-ee (Jackson 3 opt-in) | Operaton 2.x (Jackson 2) |
|---|---|
| `org.camunda.spin:camunda-spin-dataformat-json-jackson3` | `org.operaton.spin:operaton-spin-dataformat-json-jackson` |
| `org.camunda.spin:camunda-spin-dataformat-all-jackson3` | `org.operaton.spin:operaton-spin-dataformat-all` |
| `org.camunda.bpm:camunda-engine-rest-core-jakarta-jackson3` | `org.operaton.bpm:operaton-engine-rest-core` |
| `org.camunda.bpm:camunda-engine-rest-jakarta-jackson3` | `org.operaton.bpm:operaton-engine-rest` |
| `org.camunda.bpm:camunda-external-task-client-jackson3` | `org.operaton.bpm:operaton-external-task-client` |

Two Camunda artifacts can end up as one Operaton artifact, for example `-4-rest` and `-4-rest-jackson3`. Maven 3.10
refuses a pom with the same dependency twice, so `AlignVersionsOperaton2` removes duplicates first. Code that uses
`tools.jackson.*` with Spin, the engine REST API or the external task client is not rewritten by any recipe and does
not compile against the Jackson 2 artifacts. Port it to `com.fasterxml.jackson.*`. Details:
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#jackson-2-and-jackson-3).

Leftovers fail the leftover scan: a `-4` starter as `STARTER_4`, a `-jackson3` coordinate as `JACKSON3_ARTIFACT`
(both MUST-FIX).

### All other artifacts

The table maps the remaining Camunda 7.24 artifacts to Operaton. The last column says what to watch.

| Camunda 7.24 | Operaton | Note |
|---|---|---|
| `org.camunda.bpm:camunda-bom` | `org.operaton.bpm:operaton-bom` | Explicit version: the target |
| `org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter[-rest\|-webapp\|-security\|-external-task-client\|-test]` | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[…]` | `-test` is the JUnit 4 flavour |
| none | `…:operaton-bpm-spring-boot-starter-test-junit5` | Added by `PostFixes`, not by the official recipe ([test-stack decision, D11](01-migration-path-and-decisions.md#d11)) |
| `…-starter-webapp-core` | `…:operaton-bpm-spring-boot-starter-webapp-core` | Mapped by `Boot4PreFixes` only |
| `…-starter-webapp-ee`, `camunda-webapp-webjar-ee` | CE artifacts: `…-starter-webapp`, `org.operaton.bpm.webapp:operaton-webapp-webjar` | EE features vanish without an error ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)) |
| `org.camunda.bpm:camunda-engine-spring-6` | `org.operaton.bpm:operaton-engine-spring` | Removed in Camunda 7.24.6; see the list below |
| `org.camunda.{spin,connect,commons}:camunda-*` | `org.operaton.{spin,connect,commons}:operaton-*` | Spin stays on Jackson 2 |
| `camunda-engine-rest-openapi`, `org.camunda.bpm.distro:camunda-sql-scripts` | `operaton-engine-rest-openapi`, `org.operaton.bpm.distro:operaton-sql-scripts` | Mapped by `PostFixes` only |
| `org.camunda.feel:feel-engine` | **unchanged** | Never rename |

Check these points by hand:

- `camunda-engine-spring-6` was removed in Camunda 7.24.6, and `operaton-engine-spring-6` ended at 1.0.0-beta-3.
  Use `org.operaton.bpm:operaton-engine-spring` (Spring 7, managed by `operaton-bom`); the build fails otherwise.
  `scripts/verify-leftovers.sh` reports a leftover as `ENGINE_SPRING_6`.
- Gradle version catalogs (`gradle/libs.versions.toml`) are not migrated; `migrate.sh` warns about them. The Spring
  Boot 4 path has not been run end to end on a Gradle build, and its Maven-only steps (property values and renames,
  removal of redundant versions and of duplicate dependencies) do nothing there.
- Script engines (`org.apache.groovy:groovy-jsr223`, GraalJS) are still yours to add.
- Jackson modules for Spin (`jackson-datatype-jsr310`) must stay on Jackson **2** (`com.fasterxml.jackson.*`).
- In tests, `camunda.cfg.xml` must become `operaton.cfg.xml`, and the test properties must be renamed too
  (`migrate.sh` does both inside the repository). Otherwise the tests silently use a default engine. Details:
  [Testing](10-testing.md).

### Camunda EE repository and credentials

For the migration, the EE repository matters only while the recipe runs, dry runs included. The rewrite plugin
resolves all dependencies, including test dependencies, before any recipe starts, and the `7.24.N-ee` artifacts
exist only in the EE repository. After the conversion nothing in your build needs the EE repository any more,
because the Operaton artifacts come from Maven Central.

1. **Before the run,** give Maven the EE credentials: server id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or
   `MAVEN_ARGS="-s <settings with the EE credentials>"`. A settings file that only points to Maven Central does not
   work for this run. `migrate.sh` prints this hint for every EE build, and again after a failed run with resolution,
   401 or 403 errors.
2. **After the conversion,** remove the repository `https://artifacts.camunda.com/artifactory/private/` (id
   `camunda-bpm-nexus-ee`), its `<server>` credentials and the CI secrets from the Operaton build. The official
   recipe leaves `<repositories>` alone, so this is manual. Then prove that the build resolves from Maven Central
   alone. Keep the credentials themselves valid until the rollback window closes, because a rebuild or hotfix of the
   Camunda build you would roll back to needs them
   ([Cut-over, rollback and operations](11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)).
   `scripts/verify-leftovers.sh` reports what is left as `EE_REPOSITORY` (WARN), including in `.mvn/*.xml` and
   `.mvn/maven.config`.

Details on running the recipe: [OpenRewrite recipes](03-openrewrite-recipes.md).

## Configuration properties

Spring Boot does not complain about configuration keys that no component reads. The Operaton starter reads only
`operaton.bpm.*`, so a `camunda.bpm.*` key that you forget to rename gives no error: the engine starts, and the
setting silently falls back to its default. Several of these defaults switch off protection you had configured, as
the warning below shows.

Only the prefix changes; keys and types are identical. For the full key list, see the
[Operaton configuration reference](https://github.com/operaton/documentation/blob/main/docs/documentation/user-guide/spring-boot-integration/configuration.mdx).
The exceptions are the EE-only settings, which have no Operaton key at all
([below](#ee-only-engine-settings)).

> [!WARNING]
> A forgotten `camunda.bpm.*` key (or `CAMUNDA_BPM_*` variable) is ignored. This is what happens for some
> important keys:
> - `authorization.enabled: true` falls back to the default `false`: **every user can see and do everything**.
> - Without `webapp.*`, the webapps move to `/operaton`, and the CSRF, cookie and HSTS hardening is lost.
> - Without `database.*`, `schema-update` falls back to `true`. With a lost `table-prefix` / `schema-name`, the
>   engine may create an **empty** schema and start.
> - Without `job-execution.enabled: false`, the job executor starts on nodes that do not have your delegates.
> - Without `generic-properties.*`, the password policy, history TTL and whitelist settings are gone.
> - Without `client.*`, external task workers start cleanly and never fetch.
> - `history-level: audit` is the loud exception: the engine stops at startup with
>   `historyLevel mismatch: configuration says … and database says …`.

### Where more than the prefix changes

For the keys below, a prefix rename of `camunda.bpm.*` is not enough or does not apply. The last column says what
fixes each one: a recipe (`InfraEnvVars` is the one behind `--with-infra-env`), or "manual" if you edit it
yourself.

| Camunda 7.24 | Operaton | Fixed by |
|---|---|---|
| `management.health.camunda.enabled` | `management.health.operaton.enabled` | `PostFixes` |
| `CAMUNDA_BPM_*` (incl. `_CLIENT_`, `_OAUTH2_`) | `OPERATON_BPM_*` | `InfraEnvVars` (repo files only) |
| `MANAGEMENT_HEALTH_CAMUNDA_ENABLED`, `LOGGING_LEVEL_ORG_CAMUNDA_BPM_*` | `MANAGEMENT_HEALTH_OPERATON_ENABLED`, `LOGGING_LEVEL_ORG_OPERATON_BPM_*` | manual |
| `logging.level.org.camunda.(bpm\|spin\|connect\|commons)…` | `logging.level.org.operaton.…`; **keep** `org.camunda.feel` | recipe (YAML), `PostFixes` (`.properties`, logback/log4j2 XML) |
| `webapp.application-path` default `/camunda` | default `/operaton` | Set it explicitly ([webapp-path decision, D6](01-migration-path-and-decisions.md#d6)) |
| `webapp.webjar-classpath` set to the old default; `security-config-file`, `csrf.entry-points` with `/camunda/…` | Delete the first; adjust the others | manual |
| generic property `disableStrictCamundaFormParsing` | `disableStrictOperatonFormParsing` | `PostFixes` |
| `camunda-admin` in `generalResourceWhitelistPattern` / `groupResourceWhitelistPattern` | `operaton-admin` | `PostFixes` |
| `spring.autoconfigure.exclude: org.camunda…Camunda…AutoConfiguration` | `org.operaton…Operaton…AutoConfiguration` (package **and** class; a wrong name is ignored) | manual |
| Keycloak `useEmailAsCamundaUserId`, `useUsernameAsCamundaUserId`, `useGroupPathAsCamundaGroupId` | `useEmailAsOperatonUserId`, `useUsernameAsOperatonUserId`, `useGroupPathAsOperatonGroupId` | manual ([Identity, admin group and security](07-identity-admin-group-and-security.md)) |
| `camunda.bpm.license-file` | none: Operaton needs no license | recipe deletes it ([EE license](#the-ee-license-file)) |
| EE-only settings such as `authorization.validate-auth-resource-id-exists` | none | manual ([EE-only engine settings](#ee-only-engine-settings)) |

Environment variables bind in both spellings (`OPERATON_BPM_JOB_EXECUTION_ENABLED`,
`OPERATON_BPM_JOBEXECUTION_ENABLED`), so change only the prefix. Keep generic properties in YAML, because Spring Boot
lower-cases map keys that come from the environment. Database names and `spring.application.name` values that
contain `camunda` stay as they are.

### EE-only engine settings

Camunda EE patches added engine settings that Operaton does not have, because Operaton is a fork of the Community
Edition. After the conversion they fail in three different ways, and one of them is silent. The official recipe
renames the `camunda.bpm` prefix and carries the generic properties over unchanged, so the converted configuration
still contains them. The table shows what happens to each one:

| Camunda EE setting | Since | On Operaton |
|---|---|---|
| Generic properties `queryExpressionAllowListEnabled`, `allowedExpressionFunctionsInQueries`, `allowedExpressionBeansInQueries`, `allowedExpressionPropertiesInQueries` | 7.24.7-ee | **The engine does not start** (unknown property) |
| Generic property `validateAuthResourceIdExists` | 7.24.3-ee | **The engine does not start** (unknown property) |
| `camunda.bpm.authorization.validate-auth-resource-id-exists` | 7.24.3-ee | Becomes `operaton.bpm.authorization.validate-auth-resource-id-exists` and is **ignored silently** |
| Java calls `setQueryExpressionValidator`, `setAllowed*InQueries`, `setValidateAuthResourceIdExists` | 7.24.7-ee, 7.24.3-ee | Compile error |
| Java calls `ManagementService#setLicenseKey`, `getLicenseKey`, `deleteLicenseKey` | — | Compile error |
| Datasource autocommit check | 7.24.3-ee | Does not exist; keep `spring.datasource.hikari.auto-commit: false` |

Generic properties fail the start because the starter binds them strictly: `ignore-unknown-fields` defaults to
`false`. Do not switch it on to get past the error, because it would also hide every other leftover generic property.

What to do:

1. **Remove the settings and calls.** `scripts/verify-leftovers.sh` finds them in any spelling (camel case, kebab
   case, snake case, also under `operaton.bpm`) and reports them as `EE_QUERY_EXPRESSION_ALLOWLIST` and
   `EE_AUTH_RESOURCE_VALIDATION`, both MUST-FIX. License API calls are reported as `EE_LICENSE`.
2. **Replace the query-expression allow-list.** Operaton behaves like Camunda before 7.24.7: stored task filters
   evaluate any expression (Camunda security notice 157 describes expression injection through filters). Set the
   generic property `enable-expressions-in-stored-queries: false` unless your filters need expressions such as
   `${currentUser()}`, keep `enable-expressions-in-adhoc-queries` false, and restrict who may create and update
   filters. The filter check (P11) of `00-preflight-checks.sql` lists the filters that use expressions.
3. **Replace `validateAuthResourceIdExists`** by validating user and group ids in the code that creates
   authorizations.

These replacements are part of the mandatory
[Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17). Details on the security side:
[Identity, admin group and security](07-identity-admin-group-and-security.md).

### The EE license file

Operaton has no license mechanism. The recipe deletes `camunda.bpm.license-file`; remove the `camunda-license.txt`
file, license mounts and secrets yourself. The license API of `ManagementService` does not exist in Operaton, so
calls to it do not compile. Camunda stores the license key in the database as well; Operaton ignores these rows, so
keep them for a rollback. `scripts/verify-leftovers.sh` reports leftovers as `EE_LICENSE`: MUST for API calls in
code, WARN for the property, the file and license key text. Details:
[Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features).

### Configuration outside the repository

This is where migrations fail, because the recipes never see these places. In every environment, check:

- Helm `values*.yaml`, Kustomize overlays and Kubernetes Secrets
- Spring Cloud Config, Vault and other `spring.config.import` sources
- CI variables
- `-Dcamunda.bpm.*` in `JAVA_TOOL_OPTIONS`
- `SPRING_APPLICATION_JSON` (`{"camunda":{"bpm":…}}`)
- probes on `/camunda/app/…`
- log-shipping and JMX exporter rules

Run this search in each repository that holds such configuration:

```bash
grep -rnE 'camunda\.bpm\.|CAMUNDA_BPM_|management\.health\.camunda|MANAGEMENT_HEALTH_CAMUNDA|"camunda"\s*:\s*\{' \
  --include='*.y*ml' --include='*.properties' --include='*.json' --include='*.env' --include='Dockerfile*' --include='*.tf' .
```

While services migrate one by one, a shared Config Server may carry both prefixes. This works, because each starter
ignores the other prefix.

### Fail fast: `LegacyCamundaConfigGuard`

The guard turns the silent failure into a loud one. It is a self-contained `EnvironmentPostProcessor` that you copy
from the migrated example. It runs before the engine starts and scans every property source for `camunda.bpm.*`,
`CAMUNDA_BPM_*`, `management.health.camunda.*` and `MANAGEMENT_HEALTH_CAMUNDA_*`. If it finds one, it fails with the
key names and their sources, never the values, because values may be secrets:

```text
java.lang.IllegalStateException: Camunda 7 configuration found - Operaton ignores it silently. … Offending keys:
  [systemEnvironment] CAMUNDA_BPM_ADMIN_USER_ID
```

- On Spring Boot 4, implement `org.springframework.boot.EnvironmentPostProcessor` and register the guard under the
  same key in `META-INF/spring.factories`, because Spring Boot 4 moved this extension point. A guard registered
  under a key your Spring Boot line does not read is silently never loaded, so keep a test that starts a real
  `SpringApplication` (`LegacyCamundaConfigGuardTest`).
- Two switches control it: `orders.migration.legacy-config-guard.enabled` and `.fail-on-leftovers` (`false` means
  warn only). Remove the guard after the rollback window, the period in which you can still go back to Camunda
  ([rollback and point-of-no-return decision, D15](01-migration-path-and-decisions.md#d15)).
- It does not check values, logger names or bean names; `scripts/verify-leftovers.sh` covers those.

## Bean names

If you define engine beans yourself, the starter looks them up **by name**, and an old name is silently ignored.
`starterpack.operaton.PreFixes` renames them in Java and Kotlin. Search XML bean definitions, `@Resource(name = …)`
and SpEL yourself. The table shows the new names and what happens if you keep the old one.

| Camunda 7 | Operaton | If you keep the old name |
|---|---|---|
| `camundaBpmDataSource` | `operatonBpmDataSource` | The engine uses the `@Primary` datasource and may create `ACT_*` tables there |
| `camundaBpmTransactionManager` | `operatonBpmTransactionManager` | The primary transaction manager is used |
| `camundaBpmJdbcTemplate` | `operatonBpmJdbcTemplate` | The history level is read from the wrong database |
| `camundaTaskExecutor` | `operatonTaskExecutor` | Your tuned job-executor pool is ignored |

## Process applications and deployment

Existing deployments are identified by name, and the deployment descriptors need the Operaton namespace:

- Keep the `@EnableProcessApplication` name and the `<process-archive name>` values unchanged. They identify the
  deployments that the engine resumes.
- Every `processes.xml` (and `bpm-platform.xml`) needs
  `xmlns="http://www.operaton.org/schema/1.0/ProcessApplication"`. A missed one (in a second module or a library jar)
  fails with `cvc-elt.1.a: Cannot find the declaration of element 'process-application'.`
- Unchanged model files create **no** new versions on the first start
  ([BPMN/DMN namespace decision, D3](01-migration-path-and-decisions.md#d3)). Redeployment (`deployChangedOnly` and
  its form-key trap) and deploying `.form` files are covered in
  [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
- `The form with the resource name 'approve-order.form' cannot be found in deployment …` under plain `java -jar` is
  not caused by the migration: it also happens on Camunda. Use the extracted jar layout (see the example
  [`Dockerfile`](../examples/operaton-spring-boot-migrated/ops/docker/Dockerfile)).

## Spring event bridge

The starter can publish engine events as Spring application events. If you listen to them, three things change:

- The recipe moves the event types to `org.operaton.bpm.spring.boot.starter.event` and
  `org.operaton.bpm.engine.impl.history.event`.
- `operaton.bpm.eventing.{execution,task,history,skippable}` default to `true`. If your `history: false` is lost
  under an unrenamed key, every history event is published again (log `EVENTING-007`).
- Listeners run inside the engine transaction. Use `@TransactionalEventListener(phase = AFTER_COMMIT)` for side
  effects, but only on `TaskEvent`/`ExecutionEvent` or your own DTO, **never** on a raw `HistoryEvent`: after the
  commit it arrives mutated. Details: [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md),
  [history-exporters decision (D9)](01-migration-path-and-decisions.md#d9).

## Logging

Logger names follow the package rename, with one exception:

- Never search-and-replace `org.camunda` in logging configuration: **`org.camunda.feel` stays** (the Operaton docs'
  `org.operaton.feel.FeelEngine` is wrong).
- If you had set `org.camunda.bpm.engine.context` to `OFF` and the renamed key is missing, every failing job logs
  `ENGINE-16004` with a stack trace at ERROR.
- Message codes and MDC keys are unchanged. During the rollback window, log shipping and alerts should match
  `org\.(camunda|operaton)\.bpm`, so that they work with both engines.

## Health, metrics and JMX

Since **2.1**, the `processEngine` health indicator reports `DOWN` when the database is unreachable. If the liveness
probe includes it, all pods restart during a database failover. Keep it in readiness only
([health-probes decision, D13](01-migration-path-and-decisions.md#d13)):

```yaml
management:
  health:
    operaton:
      enabled: true          # was management.health.camunda.enabled (not operaton.bpm.management…, a docs error)
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

Engine metric names are unchanged. The JMX domains change from `org.camunda.bpm.platform…` to
`org.operaton.bpm.platform…`, so update your exporter rules.

## External task client starter

External task workers talk to the engine only through `/engine-rest`, so they can migrate independently of the
engine. What changes for them:

- Artifact: `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-external-task-client` (from Camunda's
  `-starter-external-task-client` or `-starter-4-external-task-client`). A worker on
  `camunda-external-task-client-jackson3` goes back to `operaton-external-task-client` on Jackson 2.
- Packages: `org.operaton.bpm.client.*`.
- Prefix: `operaton.bpm.client` (`OPERATON_BPM_CLIENT_*`), with the same keys.

A forgotten `camunda.bpm.client.*` key leaves the worker without its `base-url`: it starts cleanly and never fetches.
After deployment, watch `GET /engine-rest/external-task/count?notLocked=true`.

## Spring Security and the OAuth2 starter

- The starter is `operaton-bpm-spring-boot-starter-security` (from Camunda's `-starter-security` or
  `-starter-4-security`). Its keys move from `camunda.bpm.oauth2.*` to `operaton.bpm.oauth2.*`
  (`identity-provider.*`, `sso-logout.*`). `spring.security.oauth2.client.*` is unchanged.
- With an OAuth2 client registration, the starter protects only `<application-path>/app/**` and `…/api/**` and
  **permits everything else**, including `/engine-rest/**` and `/actuator/**`. Without a registration it permits
  everything, as on Camunda. Secure the REST API separately. Details:
  [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md).
- Admins must arrive as members of `operaton-admin`, because Operaton treats only that group as administrators.
  Change the role mapping in your identity provider (IdP). Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).

## Watch out

Each item names an error you may see, its cause and the fix.

- **Symptom:** `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing`
  (or the same for another `-4` starter).
  **Cause:** the `-4` starters were not mapped, because a recipe without the Spring Boot 4 mappings ran: the
  official recipe alone, or `migrate.sh` with `--source boot3`. The official recipe replaces `camunda-bom`, which
  managed their versions, but has no mapping for the `-4` starters.
  **Fix:** discard the result and run `scripts/migrate.sh` without `--source boot3` on the unchanged project. On
  Spring Boot 4 it runs `starterpack.operaton.MigrateSpringBoot4App`, which maps them.
- **Symptom:** `'dependencies.dependency.(groupId:artifactId:type:classifier)' must be unique`.
  **Cause:** two Camunda artifacts became the same Operaton artifact, for example `-4-rest` and `-4-rest-jackson3`.
  **Fix:** keep one of the two dependencies. The starter-pack recipe removes such duplicates itself.
- **Symptom:** `Group has an invalid id: 'operaton-admin' is not a valid resource identifier.`
  **Cause:** the whitelist regex still allows only `camunda-admin`.
  **Fix:** use `[a-zA-Z0-9]+|operaton-admin|<your groups>`, then migrate the admin group
  ([admin-group decision, D5](01-migration-path-and-decisions.md#d5)).
- **Symptom:** `ACT_*` tables appear in the business database, or the engine "lost" its data.
  **Cause:** a bean is still named `camundaBpmDataSource`.
  **Fix:** rename it, and set `schema-update: false` for the cut-over
  ([schema-management decision, D8](01-migration-path-and-decisions.md#d8)).
- **Symptom:** `… were left unbound` under `operaton.bpm.generic-properties.properties`.
  **Cause:** a generic property that Operaton does not know: `disableStrictCamundaFormParsing` was not renamed, or
  an EE-only setting such as `queryExpressionAllowListEnabled` is still there.
  **Fix:** rename the first to `disableStrictOperatonFormParsing`, and remove the EE-only settings
  ([EE-only engine settings](#ee-only-engine-settings)). Do not enable `ignore-unknown-fields`, which would make
  such leftovers silent.
- **Symptom:** compile errors on `setLicenseKey`/`LicenseKeyData`.
  **Cause:** they were removed in Operaton.
  **Fix:** delete the code.
- **Symptom:** all pods restart during a database failover (2.1+).
  **Cause:** the liveness probe includes `processEngine`.
  **Fix:** use the probe groups shown in [Health, metrics and JMX](#health-metrics-and-jmx).
