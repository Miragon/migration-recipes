# 13 · Tips, tricks and troubleshooting

This chapter is the quick reference for problems: a short list of tips, a troubleshooting catalogue and a short FAQ.
Use it whenever something fails during the conversion, the first start or the first days on Operaton. The error
messages are quoted verbatim, so search this page for the text in front of you. Each table row gives the cause
and the fix; many rows link to the chapter with the details. On Spring Boot 3.5? The errors that only the two-hop
path produces are in [Coming from Spring Boot 3.5](15-coming-from-spring-boot-3.md#watch-out).

**In short**
- **Most failures are silent.** Operaton ignores leftover `camunda.bpm.*` keys, `CAMUNDA_BPM_*` env vars, logger
  names and string literals without a warning, and its defaults apply instead. Run
  [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh) in CI, and ship the fail-fast guard that stops the
  start when such a key is left (tip 5).
- **The worst one is silent too.** On a migrated database with DB identity (users stored in the engine database),
  nobody is in `operaton-admin`. The Admin webapp then re-opens its unauthenticated setup page, which lets anyone
  create an administrator. Migrate the admin group before the first start
  ([admin group, D5](01-migration-path-and-decisions.md#d5)).
- **Camunda EE (Enterprise Edition) features fail both ways.** EE-only engine settings stop the Operaton start, while
  the EE screens in Cockpit and the EE security hardening disappear without a message. Work through the
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17) before the first start (tip 11).
- **Search this page for the error text.** If it is not listed, run `verify-leftovers.sh`, then read
  [Silent failures](#silent-failures).

<a id="top-10-tips"></a>

## Top tips

These eleven tips prevent many of the problems in the tables below:

1. **Get to Camunda 7.24 first.** The newest `ACT_GE_SCHEMA_LOG` row must be `7.24.0`, or a `7.24.N` patch row on
   Camunda EE; check section P01 of [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql). A
   database on 7.22 or older boots, then fails at runtime on missing columns. Details:
   [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).
2. **Pin every version, and pick the Operaton line that matches your Spring Boot minor.** Maven Central's
   `<release>` for `org.operaton.bpm:*` can be a release candidate, so anything that resolves "the latest release"
   may pick it. Import `operaton-bom` with an explicit version, make bots ignore `-M*`/`-RC*`, and check with
   [`scripts/latest-versions.sh`](../scripts/latest-versions.sh). Operaton supports only the Spring Boot version each
   line is built with: Spring Boot 4.0 goes to Operaton 2.1.5, Spring Boot 4.1 to Operaton 2.2.x (GA due 2026-10-23;
   2.2.0-RC1 for rehearsals only). Details:
   [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#choosing-21x-or-22x).
3. **Convert with `scripts/migrate.sh`, and run it with `--dry-run` first:** `scripts/migrate.sh --dry-run <project-dir>`.
   It detects the Spring Boot version of your build; on Spring Boot 4 it runs the composite recipe
   `starterpack.operaton.MigrateSpringBoot4App` once. The pack tests this path with stub EE artifacts, not against
   the real Camunda EE repository, so the dry run on your own build is the first real test. Never use the generic
   `MigrateFromCamunda`: it does not rename `camunda.bpm.*` keys, so your configuration is silently ignored. Never
   run the official recipe alone on a Spring Boot 4 project either: it leaves the `-4` starters in place and writes
   Operaton 1.0.x. Details: [OpenRewrite recipes](03-openrewrite-recipes.md).
4. **Never blanket-replace `org.camunda` → `org.operaton`.** FEEL stays `org.camunda.feel`, because Operaton still
   uses the Camunda FEEL engine. Only `org.camunda.(bpm|spin|connect|commons)` moves. Find it with
   `git grep -nIE 'org\.camunda\.(bpm|spin|connect|commons)\b'`.
5. **Fail fast on `camunda.*` keys.** Spring Boot ignores unknown keys, so a leftover
   `camunda.bpm.authorization.enabled: true` turns authorization **off**: the default applies. Ship
   [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java),
   which stops the start when such a key is present. Details:
   [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).
6. **Rename outside the repo too:** `CAMUNDA_BPM_*`, `MANAGEMENT_HEALTH_CAMUNDA_*` and
   `LOGGING_LEVEL_ORG_CAMUNDA_{BPM,SPIN,CONNECT,COMMONS}_*` (keep `…_FEEL`) in Helm, Config Server, Vault, CI and alert
   rules. `migrate.sh --with-infra-env` only renames `CAMUNDA_BPM_*` in infra files inside the repository.
7. **Keep `camunda:` and `/camunda` for the cut-over**, the one production switch to Operaton. Converting models to
   `operaton:` creates new versions that Camunda cannot run, so it blocks a rollback
   ([BPMN/DMN namespace, D3](01-migration-path-and-decisions.md#d3)). Set
   `operaton.bpm.webapp.application-path: /camunda` ([webapp path, D6](01-migration-path-and-decisions.md#d6)),
   because Operaton's default path is `/operaton`.
8. **Make scripts package-free.** A script with `import org.camunda.spin.Spin` deploys, then fails on first execution.
   A package-free script references no `org.camunda.*` or `org.operaton.*` class, only process variables and the
   pre-bound `S(...)`, so it works on both engines. Deploy the fixed script on 7.24 before the cut-over, and
   migrate the affected instances there. Details: [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
9. **Close the setup endpoint.** Run [`10-migrate-admin-group.sql`](../sql/postgresql/10-migrate-admin-group.sql) or
   [`AdminGroupMigrationPlugin`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java)
   to mirror `camunda-admin` to `operaton-admin`, and deny `<app-path>/api/admin/setup/` at the proxy. Verify with the
   `GET` check of [`scripts/smoke-test.sh`](../scripts/smoke-test.sh). Details:
   [Identity, admin group and security](07-identity-admin-group-and-security.md).
10. **Rename `camunda.cfg.xml` → `operaton.cfg.xml` and add a guard test.** Since 1.1, the JUnit 5 extension silently
    builds a default engine without it, so a green test no longer proves your configuration. Details:
    [Testing](10-testing.md).
11. **Settle the Camunda EE features before the first start**
    ([Camunda EE features, D17](01-migration-path-and-decisions.md#d17)), because Operaton is a fork of the Community
    Edition and has none of them:
    - Remove the EE-only engine settings and calls. As generic properties they stop the start, the Java calls do not
      compile, and `validate-auth-resource-id-exists` is silently ignored.
    - Replace the missing EE hardening: set the generic property `enable-expressions-in-stored-queries: false`
      unless your stored filters need expressions (the pre-flight check P11 lists them), restrict who may create and
      update filters, and keep `spring.datasource.hikari.auto-commit: false`.
    - Remove the EE repository from your build once the recipe has run, but keep valid credentials and the license
      for the Camunda rollback build until the rollback window closes. Leave the license rows in the database.

> [!WARNING]
> Never `POST` to the setup endpoint in production: if it is open, the request creates an administrator. A 403 proves
> nothing (the CSRF filter answers 403 even when setup is open).

## Build and recipe errors

These errors appear while you run the recipes or build the converted code. On a Spring Boot 4 project,
`scripts/migrate.sh` runs the composite recipe `MigrateSpringBoot4App`. It runs `Boot4PreFixes` and `PreFixes`
before the official recipe, and `PostFixes`, `ScriptImports` and `AlignVersionsOperaton2` after it. All of them are
`starterpack.operaton.*` recipes in [`rewrite/rewrite.yml`](../rewrite/rewrite.yml), so `migrate.sh` normally
applies the fixes that a row attributes to one of them. The first rows are messages of `migrate.sh` itself.

| Error | Cause | Fix |
|---|---|---|
| `ERROR: --hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2). This project is on Spring Boot 4 …` | `--hop` on a Spring Boot 4 project, for example from older instructions | Run without `--hop`. Add `--source boot3` only if the detection is wrong. |
| `WARN: --source boot3 overrides the detected source boot4 …`, and afterwards nothing is renamed, the Spin configurator uses `tools.jackson`, and a Spring Boot 4.1 parent went down to 4.0.8 | `--source boot3 --hop 2` overrode the detection, so `migrate.sh` ran `UpgradeToOperaton2`, a platform-upgrade recipe that is not meant for Spring Boot 4 projects | Discard the result, and run `migrate.sh` without `--source` and `--hop` |
| `ERROR: Spring Boot 4 path failed (exit …)`, after `Camunda EE build (…): the run needs the Camunda EE repository and its credentials`; the log shows `401`, `403`, `Unauthorized` or `Could not resolve` | The rewrite plugin resolves all dependencies, test scope included, before a recipe runs, and the `7.24.N-ee` artifacts exist only in the EE repository | Add the server `camunda-bpm-nexus-ee` with your credentials to `~/.m2/settings.xml`, or pass `MAVEN_ARGS="-s <settings with the EE credentials>"`. A settings file with Maven Central only does not work for this run. Details: [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md#camunda-ee-repository-and-credentials) |
| `WARN: Operaton 2.1.5 is built with Spring Boot 4.0.8 (only that pairing is supported), the project is on Spring Boot 4.1.1. …` | The target and your Spring Boot minor do not match. `migrate.sh` never downgrades Spring Boot and never raises its minor, so it leaves Spring Boot as it is. | Spring Boot 4.1: `--target 2.2.0` once it is GA (2026-10-23), `--target 2.2.0-RC1` for rehearsals. Spring Boot 4.0 with a 2.2 target: `--target 2.1.5`, or upgrade to Spring Boot 4.1 first in its own commit. |
| `WARN: --target 2.2.0-RC1 is a pre-release; use released versions for production (decision D1)` | A release candidate as the target | Fine for rehearsals. Never release it to production. |
| `Premature end of Content-Length delimited message body` | A corporate Maven mirror truncates downloads | `mvn -s /tmp/m2-central-settings.xml …` with the content `<settings/>`, i.e. Maven Central only. On a Camunda EE build, the recipe run also needs the EE repository, so add it and its credentials to these settings. |
| `IllegalArgumentException: Origin: https://github.com does not match the clone url` | SSH host alias or proxy remote | Run on a clone with a plain `origin` |
| Gradle: `Could not find org.openrewrite:rewrite-bom:8.91.0` or `NoClassDefFoundError: org/openrewrite/shaded/jgit/…` | Plugin version mismatch | Pin `org.openrewrite:plugin:7.39.0` |
| `Could not transfer metadata … camunda-nexus … HTTP Status: 401` | Parent POM of `org.camunda.feel:feel-engine` | Harmless. Do **not** rename FEEL. |
| `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing` (also for other `-4` starters) | The official recipe alone, or `migrate.sh` with `--source boot3`, ran on a Spring Boot 4 project. Neither maps the `-4` starters, so they stay without a managed version. | Discard that result and run `migrate.sh` without `--hop` and `--source`, so that `MigrateSpringBoot4App` maps the starters. `verify-leftovers.sh` reports leftovers as `STARTER_4`. |
| `'dependencies.dependency.(groupId:artifactId:type:classifier)' must be unique` | Two Camunda artifacts became one Operaton artifact (`-4-rest` and `-4-rest-jackson3`; `camunda-spin-dataformat-json-jackson` and `-json-jackson3`), and an older `rewrite.yml` without the duplicate removal ran | Use the current `rewrite/rewrite.yml`: `AlignVersionsOperaton2` removes duplicates first. |
| An artifact with a `7.24.N-ee` version cannot be resolved once the EE repository is gone | A `-ee` version or a referenced `-ee` property is left in the build | Let `operaton-bom` manage the version (`${operaton.version}`), and delete `-ee` properties. `verify-leftovers.sh` reports them as `EE_VERSION`. |
| `operaton-bpm-spring-boot-starter-webapp-ee` cannot be resolved | Never published | Use `operaton-bpm-spring-boot-starter-webapp`. The EE screens are gone ([Camunda EE features, D17](01-migration-path-and-decisions.md#d17)). |
| `operaton-engine-spring-6` cannot be resolved | Camunda removed `camunda-engine-spring-6` in 7.24.6, and `operaton-engine-spring-6` ended at 1.0.0-beta-3 | Use `org.operaton.bpm:operaton-engine-spring` (Spring 7, managed by `operaton-bom`). `verify-leftovers.sh` reports it as `ENGINE_SPRING_6`. |
| `cannot find symbol CAMUNDA_TASK_EXECUTOR_QUALIFIER` | The recipe does not map this constant | Use `OPERATON_TASK_EXECUTOR_QUALIFIER` |
| `cannot find symbol … ProcessEngineExtension`, or `org.operaton.bpm.engine.test.Deployment` not found | Test helpers moved to `operaton-engine` classifier jars, and the recipe never adds them | Add `operaton-bpm-spring-boot-starter-test-junit5` or `operaton-engine:<v>:junit5` (test scope), not `operaton-bpm-junit5`. `PostFixes` does it. |
| `cannot find symbol` for `Mocks` / `MockExpressionManager` | Moved to `org.operaton.bpm.engine.impl.mock` | Fix the imports and `class=` in `operaton.cfg.xml`. `PreFixes` does it. |
| `incompatible types` on `List<JobHandler> handlers = cfg.getCustomJobHandlers();` | Generic types since 1.1 (`List<JobHandler<?>>`) | Use the generic types, and run `mvn clean` |
| `constructor AbstractOperatonConfiguration … cannot be applied`, `cannot find symbol camundaBpmProperties` | Constructor injection | Add a constructor that takes `OperatonBpmProperties` and calls `super(properties)` |
| `package org.operaton.bpm.impl.juel.jakarta.el does not exist` | The recipe maps the shaded EL API to a package that does not exist | Import `jakarta.el.*`. `PreFixes` does it. |
| `method does not override or implement a method from a supertype` on `getFeatureDescriptors` | Removed in Jakarta EL 6.0, which Operaton 2.x uses | Delete the method |
| `cannot find symbol` for `setLicenseKey`, `setQueryExpressionValidator`, `setAllowed…InQueries` or `setValidateAuthResourceIdExists` | Camunda EE API (the license API, and the hardening of 7.24.3-ee and 7.24.7-ee) that Operaton does not have | Remove the calls and replace the hardening ([Camunda EE features, D17](01-migration-path-and-decisions.md#d17); details: [EE-only engine settings](04-spring-boot-dependencies-and-configuration.md#ee-only-engine-settings)) |
| `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper`, or other compile errors in Spin, REST or client code on `tools.jackson.*`, for example in a Spin `DataFormatConfigurator` | The code uses Jackson 3, but Operaton 2.x Spin, REST and external task client are Jackson 2 only. It was written for Camunda's `-jackson3` opt-in (7.24.16-ee), or a Jackson 3 recipe such as the stock `UpgradeSpringBoot_4_0` rewrote it. | Port it to `com.fasterxml.jackson.*`; no recipe does that. `MigrateSpringBoot4App` runs no Jackson 3 step. Details: [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in) |

Two different 401 errors appear in this table, from repositories with similar names. The FEEL message names
`camunda-nexus` and is harmless. A 401 from the EE repository (id `camunda-bpm-nexus-ee`) stops the run, which then
needs your EE credentials.

## Startup and configuration errors

These errors stop the application start or appear right after it. Most come from configuration that was not
renamed, from the database, or from the admin group.

| Error | Cause | Fix |
|---|---|---|
| `Group has an invalid id: 'operaton-admin' is not a valid resource identifier.` | The id whitelist regex (`groupResourceWhitelistPattern`) still names `camunda-admin` | Change the value. `PostFixes` covers `application*` files, not env vars or Helm. |
| `ENGINE-08043 … Group has an invalid id: '…' is not a valid resource identifier.` (your own group) | The whole `camunda.bpm.*` block is ignored, because the generic recipe `MigrateFromCamunda` left the keys unrenamed | Re-run with `scripts/migrate.sh`, whose composite recipe runs the official `MigrateSpringBootApplication` |
| The engine does not start because of an unknown generic property such as `queryExpressionAllowListEnabled`, `allowedExpression…InQueries` or `validateAuthResourceIdExists` | Camunda EE settings (7.24.3-ee, 7.24.7-ee) that Operaton does not have. The starter binds generic properties strictly: `ignore-unknown-fields` defaults to `false`. | Delete them, also outside the repository. Do not set `ignore-unknown-fields: true`, because it would hide every other leftover. Replace the hardening ([Camunda EE features, D17](01-migration-path-and-decisions.md#d17)). |
| `cvc-elt.1.a: Cannot find the declaration of element 'process-application'` or `DOCTYPE is not allowed` | `processes.xml` uses the Camunda namespace | Use the Operaton namespace and `schemaLocation`. `PostFixes` does it. |
| `historyLevel mismatch: configuration says … and database says …` | Leftover `camunda.bpm.history-level`, so the default `full` applies | Set `operaton.bpm.history-level` |
| Liquibase: `create table ACT_GE_PROPERTY` fails, table exists | The changelog path changed | Fix E (`changelog-sync-to-tag --tag=7.24.0`) or Fix D. Details: [Database](08-database-schema-data-and-sql-scripts.md) |
| `duplicate key value violates unique constraint "act_ge_schema_log_pkey"`, H2: `Unique index or primary key violation … ACT_GE_SCHEMA_LOG(ID_) VALUES ('1300')`, Oracle: `ORA-00001` | Two changesets are authored `Operaton`, not `Camunda` | Fix D, run **before** the Operaton changelog |
| `ENGINE-12018 History Time To Live (TTL) cannot be null` | A model without `historyTimeToLive` was redeployed | `operaton.bpm.generic-properties.properties.history-time-to-live: P180D` |
| SQL errors on `ACT_RU_EXECUTION.PROC_DEF_KEY_` or `ACT_HI_COMMENT.REV_` | Database on 7.22 or older | Run the Camunda upgrade scripts up to 7.24 |
| `ENGINE-03029 Required admin authenticated group or user.` | `camunda-admin` is no longer an admin group | Mirror it to `operaton-admin` ([admin group, D5](01-migration-path-and-decisions.md#d5)) |
| 404 at `/camunda/app/…`, `/` redirects to `/operaton/app/` | The default path is `/operaton` | Set `operaton.bpm.webapp.application-path: /camunda`, and probe `/actuator/health/readiness` |
| `JAXBContext implementation could not be found. WADL feature is disabled.` | Jersey on Spring Boot 4 | Harmless |
| `could not find class [org.springframework.boot.jersey.autoconfigure.JerseyAutoConfiguration]` or `Failed to generate bean name for imported class 'org.operaton.bpm.spring.boot.starter.rest.OperatonBpmRestJerseyAutoConfiguration'` | Operaton 2.x on Spring Boot 3, for example after `--source boot4` on a Spring Boot 3.5 project (`migrate.sh` warns that the Spring Boot 4 path does not upgrade Spring Boot) | Run Operaton 2.x only with Spring Boot 4. Details: [Coming from Spring Boot 3.5](15-coming-from-spring-boot-3.md#watch-out) |

The Liquibase fixes keep your existing `DATABASECHANGELOG` working with Operaton's changelog: Fix E syncs Liquibase to
the Operaton changelog, Fix D keeps the old changelog path and updates the changeset author.

## Runtime errors

These errors appear while processes run, often days after the start. The engine compiles a script only when a token
reaches it and parses an old definition only when something touches it, so a broken model fails late.

| Error | Cause | Fix |
|---|---|---|
| `unable to resolve class org.camunda.spin.Spin` | A BPMN script imports a Camunda class | Drop the import, and use `S(...)` (tip 8) |
| Same error **after** fixing the BPMN | The instance runs on the old definition version | Migrate it to a package-free fixed version (Migration API, `executeAsync()`), ideally on 7.24 |
| `MissingPropertyException: No such property: org` (Groovy), `TypeError: Access to host class … is not allowed or does not exist` (JS) | Fully qualified `org.camunda…` in a script | Make the script package-free. `org.operaton…` would be a rollback hard stop, because Camunda cannot run it. |
| `Can't find scripting engine for 'javascript'` | The starter ships no script engine | Add `org.graalvm.polyglot:polyglot`, `org.graalvm.polyglot:js` (type `pom`) and `org.graalvm.js:js-scriptengine` |
| `SpelEvaluationException: EL1005E: Type cannot be found 'org.camunda.bpm…'` | `T(org.camunda…)` in `@EventListener(condition = …)`; the process start fails | Fix the literal |
| `InvalidTypeIdException: Could not resolve type id 'org.camunda.bpm…'` (consumer) | Event payloads carry class names | Own DTOs, and dual-read consumers that accept the old and the new format ([history exporters, D9](01-migration-path-and-decisions.md#d9)) |
| `UnsupportedOperationException` at `cfg.getCustomJobHandlers().add(…)` | The list is immutable | Copy it into a new `ArrayList`, then call `setCustomJobHandlers` |
| `The form with the resource name '….form' cannot be found in deployment` | Fat jar plus `@EnableProcessApplication` (also on 7.24) | Run the extracted layout: `java -Djarmode=tools -jar app.jar extract` |
| Parse error: "…make sure the connect process engine plugin is registered…" | The optional Connect plugin is missing | Add `org.operaton.bpm:operaton-engine-plugin-connect` plus a connector |
| `ClassNotFoundException` reading an old variable | A Java-serialized `org.camunda.*` object | Find them with [`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql), then convert or drain them first ([legacy variables, D18](01-migration-path-and-decisions.md#d18)) |
| `Expressions are forbidden in stored queries` when a task filter is listed or counted | `enable-expressions-in-stored-queries: false`, the mitigation for the missing EE allow-list, while the filter still uses expressions such as `${currentUser()}` | The pre-flight check P11 lists these filters. Rewrite them without expressions, or keep the switch on and restrict who may create and update filters (authorization resource type 5, Filter). |
| Old definition fails to parse (`http://activiti.org/bpmn`) | Operaton dropped the Activiti namespace | Convert to `camunda:` before the cut-over |
| Burst of jobs after start, or jobs stuck ~5 min | Timers that fell due during the downtime, and locks held by the stopped node | Expected. Never reset locks while an engine runs. |

To **drain** variables means to let the affected process instances finish on Camunda before the cut-over; to
**convert** them means to read them in a Camunda 7.24 release and set them again as JSON, primitives or your own DTO.

## Silent failures

These problems produce no error: the application starts and behaves differently. Most come from a Camunda name that
Operaton ignores, so its default applies. Each row starts with what you notice.

| Symptom | Cause | Fix |
|---|---|---|
| **Authorization off**, no admin user, default webapp path, eventing off | `camunda.bpm.*` keys in a profile, Config Server, Helm or `SPRING_APPLICATION_JSON` | Rename the keys, and add the guard (tip 5). Authorization off in production is a security incident. |
| Admins land on "create initial admin user"; former admins are tenant-restricted | `camunda-admin` is no admin group, and nobody is in `operaton-admin` | Mirror the admin group (tip 9) |
| New, empty `ACT_*` tables in another schema | Leftover `schema-name`/`table-prefix` plus `schema-update: true` | Migrate the key, and use `schema-update: false` for the cut-over |
| Engine writes to the **business** database | The bean `camundaBpmDataSource` is ignored | Rename it to `operatonBpmDataSource` (also `…TransactionManager`, `…JdbcTemplate`). `PreFixes` does it. |
| LDAP off, DB identity used | `prefix = "camunda.bpm.ldap"` literals | Use `operaton.bpm.ldap`. `PreFixes` does it. |
| Keycloak users get new ids, authorizations stop matching | `useEmailAsCamundaUserId` and friends are ignored | Use `use…AsOperatonUserId`, `useGroupPathAsOperatonGroupId` |
| Spin writes dates as arrays | `DataFormatConfigurator` not loaded (`META-INF/services` or `spring.factories` still `org.camunda…`), or a Jackson 3 recipe rewrote the configurator and dropped `JavaTimeModule` | Register `org.operaton.spin.spi.DataFormatConfigurator`, and restore the Jackson 2 code |
| Silenced loggers are noisy (`ENGINE-16004 …`), log alerts never fire | Logger names are still `org.camunda…` | Rename to `org.operaton…`, keep `org.camunda.feel`. `PostFixes` does it. |
| Cockpit lacks the history view, heatmap, instance modification, migration UI, batches and reports | Operaton has the CE webapps only; the recipe maps the EE webapps to them without a build error | Use the REST replacements ([Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features)) |
| Stored task filters evaluate any expression again | Operaton has no query-expression allow-list (7.24.7-ee), and `enableExpressionsInStoredQueries` defaults to true (Camunda security notice 157) | `enable-expressions-in-stored-queries: false` unless filters need expressions, and restrict who may create and update filters ([Camunda EE features, D17](01-migration-path-and-decisions.md#d17)) |
| Authorizations with invalid user, group or resource references are saved without an error | `operaton.bpm.authorization.validate-auth-resource-id-exists` does not exist in Operaton and is ignored silently | Remove the key, and validate user and group ids in the code that creates authorizations |
| Tasklist shows a Camunda Form as an external link | Tasklist only knows `operaton-forms:` | Use `operaton-forms:` or `formRef` ([Camunda Forms keys, D4](01-migration-path-and-decisions.md#d4)) |
| REST client reads `camundaFormRef == null` | Renamed to `operatonFormRef` | Regenerate the client |
| Tests pass against the wrong engine | `camunda.cfg.xml` is ignored | Rename it and add a guard test (tip 10) |
| `Mocks.register(...)` has no effect at deployment | Operaton deploys before `@BeforeEach` | Register in `@BeforeAll` |
| Pods restart during database blips (2.1+) | `processEngine` health in liveness | Readiness only ([health probes, D13](01-migration-path-and-decisions.md#d13)) |
| Webapp customization gone | Overrides under `META-INF/resources/webjars/camunda/…` | Move them to `…/webjars/operaton/…` |

## FAQ

**Can we keep our database?** Yes, because the schema is the same. Three conditions apply: the database is on 7.24,
Liquibase users fix `DATABASECHANGELOG`, and the admin group is migrated first. Camunda EE patch levels do not change
the schema, and Operaton ignores the EE license rows. Details:
[Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).

**Do we have to change BPMN and DMN files?** Mostly no, because `camunda:` still works. Change scripts that reference
`org.camunda.(bpm|spin|connect|commons)`, models in the `activiti:` namespace, and `camunda:class` values of moved
classes. Details: [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

**Will running instances survive?** Yes, because they are rows in the shared database. The exceptions are instances on
versions with broken scripts, and variables holding Java-serialized `org.camunda.*` objects.

**Can Camunda 7 and Operaton run side by side on one database?** No: the job executors take each other's jobs. Stop
all Camunda nodes, then start Operaton ([cut-over strategy, D7](01-migration-path-and-decisions.md#d7)).

**Can we roll back?** Yes, to the last Camunda EE build, until Operaton writes Operaton-only artifacts that Camunda
cannot read or run ([rollback and point of no return, D15](01-migration-path-and-decisions.md#d15)). Keep that
build's image, its license and access to the EE repository until the rollback window closes. Details:
[Cut-over, rollback and operations](11-cutover-rollback-and-operations.md).

**Which version should we target?** The latest patch of the Operaton line that matches the Spring Boot minor of your
application, pinned ([target version and path, D1](01-migration-path-and-decisions.md#d1)). Spring Boot 4.0 goes to
Operaton 2.1.5, and Spring Boot 4.1 to Operaton 2.2.x once its GA (general availability) is out, due 2026-10-23.
Until then you rehearse with 2.2.0-RC1, never in production. No Operaton line is built with Spring Boot 4.2 yet.

**What do we lose by leaving Camunda EE?** The EE screens in Cockpit, Optimize, the EE security hardening of the
7.24.x patches, the Jackson 3 opt-in of 7.24.16-ee, and Camunda's EE maintenance, which covers 7.24 until 13 Apr 2030.
Operaton needs no license. Plan the replacements in the
[Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17), and the support in the
[support-model decision (D14)](01-migration-path-and-decisions.md#d14).
