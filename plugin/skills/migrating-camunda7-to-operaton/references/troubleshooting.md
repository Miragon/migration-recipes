# Troubleshooting: error message → cause → fix

Guide chapter (error → fix tables, top tips, FAQ): https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/13-tips-tricks-and-troubleshooting.md
Messages are verbatim where the guide has them; `…` marks trimmed parts. Search this file for a distinctive fragment
(an `ENGINE-xxxxx` code, a class name, a quoted id). Snippets for most fixes: references/fix-catalog.md.

## Contents

1. How to triage
2. Build and recipe errors
3. Startup and configuration errors
4. Runtime errors (incidents, exceptions while running)
5. Silent failures (no error, wrong behaviour)
6. What to collect before asking upstream

## 1. How to triage

```text
fails at build/test compile   -> section 2
context does not start        -> section 3
incident / exception at runtime -> section 4
no error, wrong behaviour     -> section 5  (run verify-leftovers.sh first; grep deployment repos too)
```

- Run `bash "<skill-dir>/scripts/verify-leftovers.sh" <project-dir>` first: it finds most root causes below
  (Spring Boot 4 / Camunda EE sources: also `-4` starters, `-jackson3`, `-ee` versions and EE-only settings).
- Most failures are **silent**: leftover `camunda.bpm.*` keys, `CAMUNDA_BPM_*` env vars, logger names and string
  literals are ignored without a warning. A green build proves little; check section 5.
- Never verify a hypothesis by writing to a production engine or database (no `POST` to the setup endpoint, no SQL).

## 2. Build and recipe errors

| Message or symptom | Cause | Fix |
|---|---|---|
| `Could not transfer artifact org.rocksdb:rocksdbjni:jar:8.8.1 … Premature end of Content-Length delimited message body (expected: …; received: …)` | corporate Maven mirror truncates large downloads (unrelated to Operaton) | `MAVEN_ARGS="-s /tmp/m2-central-settings.xml"` with content `<settings/>` (Camunda EE builds: plus the EE `<server>` entry); never edit `~/.m2/settings.xml` |
| `401 Unauthorized` / `403` / `Could not transfer artifact` for `7.24.N-ee`, `camunda-bom:7.24.N-ee` or `camunda-bpm-spring-boot-starter-4*` during `migrate.sh` or the baseline build | Camunda EE build without EE repository credentials; the rewrite plugin resolves all (test) dependencies before a recipe runs | credentials in the user's settings (server id `camunda-bpm-nexus-ee`) or `MAVEN_ARGS="-s <settings with the EE credentials>"`; `migrate.sh` repeats this hint after such a failure. Copilot cloud agent: Agents secrets + `artifacts.camunda.com` on the allowlist (SKILL) |
| `ERROR: --hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2). This project is on Spring Boot 4 (detected: …)` | `--hop` on a Spring Boot 4 project | run `migrate.sh` without `--hop` (one run); references/recipes.md §9 |
| `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing` (also `-4-rest`, `-4-test`) | the official recipe alone, or Hop 1 forced with `--source boot3`, ran on a Spring Boot 4 project | reset to the pre-run commit and run `migrate.sh` without `--hop` |
| `'dependencies.dependency.(groupId:artifactId:type:classifier)' must be unique` | `-4-rest` and `-4-rest-jackson3` (or the two Spin JSON artifacts) mapped onto one Operaton artifact with a `rewrite.yml` that lacks `RemoveDuplicateDependencies` | use the bundled `assets/rewrite.yml` |
| `cannot find symbol` for `setQueryExpressionValidator`, `setAllowed…InQueries`, `setValidateAuthResourceIdExists`, `setLicenseKey` | Camunda EE APIs that Operaton does not have | delete the calls; D17 mitigation (references/fix-catalog.md §8) |
| `verify-leftovers.sh` reports dozens of MUST findings in `.claude/skills/`, `.github/skills/` or `.agents/skills/` | the skill is installed inside the project and holds `camunda` on purpose | `--exclude '<skill path>/**'` (SKILL "Skill inside the project") |
| `RecipeException: Recipe(s) not found: org.operaton.rewrite.spring.MigrateSpringBootApplication` | early recipe artifact without that recipe, or `rewrite.yml` / recipe jar not on the classpath | run via `migrate.sh` (release recipe, absolute config path) |
| `Could not find org.operaton:migrate-camunda-recipe:1.0.0-alpha-2-SNAPSHOT` | snapshots are not on Maven Central | release version (migrate.sh default) |
| `java.lang.IllegalArgumentException: Origin: https://github.com does not match the clone url: https://<ssh-host-alias>/…` | OpenRewrite git provenance vs SSH host alias / proxy remote | run on a clone with a plain `origin` URL, or set it temporarily |
| Gradle: `Could not find org.openrewrite:rewrite-bom:8.91.0` | Gradle plugin 7.40+ needs the Code Genome Project repository | keep migrate.sh's `--gradle-plugin-version` default |
| Gradle: `NoClassDefFoundError: org/openrewrite/shaded/jgit/treewalk/AbstractTreeIterator` | Gradle plugin incompatible with the recipe's rewrite version | keep the default Gradle plugin version |
| `[WARNING] Could not transfer metadata … camunda-nexus (https://artifacts.camunda.com/artifactory/internal): HTTP Status: 401` | repository declared in the parent POM of `org.camunda.feel:feel-engine` | harmless; do **not** rename FEEL |
| `cannot find symbol … ProcessEngineExtension`, or `org.operaton.bpm.engine.test.Deployment` not found | helpers live only in `operaton-engine` classifier jars; official recipe's `onlyIfUsing: org.junit.jupiter.Test` never fires; `operaton-bpm-junit5` is empty on 1.x | add `operaton-bpm-spring-boot-starter-test-junit5` or `operaton-engine:<v>:junit5` (test); remove `operaton-bpm-junit5` |
| `cannot find symbol` for `Mocks` / `MockExpressionManager` (package `org.operaton.bpm.engine.test.mock`) | moved to `org.operaton.bpm.engine.impl.mock`; official relocation never fires (ordering bug) | change imports and the `class=` in `operaton.cfg.xml` |
| `incompatible types` on `List<JobHandler> handlers = cfg.getCustomJobHandlers();` | generics since 1.1: `List<JobHandler<?>>`, `Map<String, JobHandler<?>>`, `List<TypedValueSerializer<?>>` | generic types + copy, add, set; `mvn clean` |
| `constructor AbstractOperatonConfiguration … cannot be applied` and `cannot find symbol camundaBpmProperties` | constructor injection since 1.0 | constructor taking `OperatonBpmProperties`, `super(properties)`; use `operatonBpmProperties` |
| `cannot find symbol CAMUNDA_TASK_EXECUTOR_QUALIFIER` | recipe renames the method, not the constant | `OPERATON_TASK_EXECUTOR_QUALIFIER` (bean `operatonTaskExecutor`) |
| `package org.operaton.bpm.impl.juel.jakarta.el does not exist` | shaded EL API mapped to a package that does not exist (bug B7) | `jakarta.el.*` imports (`PreFixes` does it) |
| `method does not override or implement a method from a supertype` on `getFeatureDescriptors` (Operaton 2.x; 3.5 path: Hop 2) | Jakarta EL 6.0 removed `ELResolver#getFeatureDescriptors` | delete the method |
| `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper` (German locale: `Inkompatible Typen: …`) | Spin is still Jackson 2. Spring Boot 4 sources: code written for Camunda's Jackson 3 opt-in (`-jackson3`, 7.24.16-ee). Spring Boot 3.5 path, Hop 2: the stock Jackson 3 migration rewrote a Spin `DataFormatConfigurator` | restore Jackson 2 imports (`com.fasterxml.jackson.*`) and `jackson-datatype-jsr310`; 3.5 path: use `UpgradeToOperaton2` |
| `operaton-bpm-spring-boot-starter-webapp-ee` cannot be resolved | never existed on Central; older `operaton-only-bom` versions list it as a phantom entry | `operaton-bpm-spring-boot-starter-webapp`; EE features are gone (D17) |
| Gradle: Java migrated, `gradle/libs.versions.toml` still `org.camunda.bpm` | catalogs are not touched by the recipe | edit the catalog by hand |
| code compiles, `META-INF/services/…` content still names old types | plugin < 6.36.0 renames the file, not its content | rerun with the migrate.sh default plugin, or fix the content |
| `@MockBean` cannot be resolved; `org.testcontainers:postgresql` (2.x) not found (3.5 path, Hop 2) | Spring Boot 4 removed `@MockBean`; Testcontainers 2 renamed artifacts | `@MockitoBean`; `testcontainers-postgresql`, `org.testcontainers.postgresql.PostgreSQLContainer` |
| compiler warning: `org.springframework.boot.env.EnvironmentPostProcessor` … deprecated and marked for removal | Spring Boot 3 SPI (e.g. `LegacyCamundaConfigGuard` in its Hop 1 form, or an own post-processor) on Spring Boot 4.0; still works | switch interface **and** `spring.factories` key to `org.springframework.boot.EnvironmentPostProcessor` (references/configuration.md §10) |
| `verify-leftovers.sh` reports MUST findings inside `AdminGroupMigrationPlugin`, `LegacyCamundaConfigGuard` or files under `migration/` | the helper marker line `// operaton-migration-helper: …` was removed while copying, or the run used `--strict` | keep the marker in copied helpers (they hold `camunda` literals on purpose); the default run skips them and `migration/` with one INFO line |
| `ERROR: working tree … is dirty` from `migrate.sh` | uncommitted changes besides `MIGRATION_REPORT.md`, `.operaton-migration-ignore`, `migration/` (those are ignored) | commit the previous step (with permission) or work in a throw-away clone; never `git stash`, never `--force` on the real repository |

## 3. Startup and configuration errors

| Message or symptom | Cause | Fix |
|---|---|---|
| `ProcessEngineException: Group has an invalid id: 'operaton-admin' is not a valid resource identifier.` | a custom `groupResourceWhitelistPattern` / `generalResourceWhitelistPattern` **value** still says `camunda-admin`; the starter creates `operaton-admin` | replace `camunda-admin` with `operaton-admin` inside the pattern (YAML in references/configuration.md); `PostFixes` does `application*` files, env vars/Helm by hand. Then do D5 |
| `ENGINE-08043 Exception while performing 'Deployment of Process Application order-fulfillment-app' => 'Invoking @PostDeploy': Group has an invalid id: 'order-ops' is not a valid resource identifier.` | generic `MigrateFromCamunda` was used: the whole `camunda.bpm.*` block is ignored | rerun the migration with the composite (`migrate.sh`; 3.5 path: Hop 1) |
| `java.lang.IllegalStateException: Camunda 7 configuration found - Operaton ignores it silently. … Offending keys: [<source>] <key>` | `LegacyCamundaConfigGuard` found a leftover key in the named property source | rename at the source it names (Helm, ConfigMap, Config Server, CI var); never switch the guard off to pass |
| `cvc-elt.1.a: Cannot find the declaration of element "process-application"` | a `processes.xml` still uses the Camunda namespace (other module, library jar) | `xmlns="http://www.operaton.org/schema/1.0/ProcessApplication"`, or an empty `processes.xml` |
| `DOCTYPE is not allowed…` while parsing `processes.xml` | old namespace plus old `xsi:schemaLocation` | Operaton namespace and schema location |
| `historyLevel mismatch: configuration says … and database says …` | lost `camunda.bpm.history-level` / `CAMUNDA_BPM_HISTORY_LEVEL` (default `full` applies), or a custom `HistoryLevel` not re-registered | `operaton.bpm.history-level` = DB value (`ACT_GE_PROPERTY` `historyLevel`: 0/1/2/3 = none/activity/audit/full); same custom level id |
| `could not find class [org.springframework.boot.jersey.autoconfigure.JerseyAutoConfiguration]` or `Failed to generate bean name for imported class 'org.operaton.bpm.spring.boot.starter.rest.OperatonBpmRestJerseyAutoConfiguration'` | Operaton 2.x on Spring Boot 3 | Spring Boot 4 in the same commit (3.5 path: Hop 2), or stay on 1.1.x as a checkpoint only |
| `BeanDefinitionStoreException: IOException parsing XML document from class path resource [operaton.cfg.xml] … FileNotFoundException` (JUnit 5 on 1.0.x; JUnit 4 rule on every version, naming `activiti.cfg.xml`) | test config still named `camunda.cfg.xml` | rename to `operaton.cfg.xml` |
| start fails: `… were left unbound` under `operaton.bpm.generic-properties.properties` (e.g. `disable-strict-camunda-form-parsing`) | renamed engine setter; generic properties bind strictly | `disableStrictOperatonFormParsing`; never `ignore-unknown-fields: true` |
| same, naming `queryExpressionAllowListEnabled`, `allowedExpressionFunctionsInQueries` / `…BeansInQueries` / `…PropertiesInQueries` or `validateAuthResourceIdExists` | Camunda EE-only engine settings (7.24.3/7.24.7-ee); the official recipe carries them over verbatim | delete them, then the D17 mitigation (references/identity-and-admin.md §10) |
| `Expressions are forbidden in stored queries` | D17 mitigation `enable-expressions-in-stored-queries: false` meets a stored filter with expressions (P11 of the pre-flight lists them) | rewrite those filters, or keep expressions on and restrict filter create/update |
| `NoUniqueBeanDefinitionException: … expected single matching bean but found 2` (`HistoryEventHandler`) | the starter auto-wires exactly one `HistoryEventHandler` bean | register further handlers through a plugin |
| `ENGINE-12018 History Time To Live (TTL) cannot be null …` | a model without `historyTimeToLive` was redeployed (`enforceHistoryTimeToLive` is on for new deployments) | add it to the model, or global `history-time-to-live` generic property |
| Liquibase: `create table ACT_GE_PROPERTY` fails (table exists) | changelog now points at `operaton-changelog.xml`, every changeset looks new | Fix E (`changelog-sync-to-tag --tag=7.24.0`) or Fix D: references/database.md |
| Liquibase validation: "8 changesets check sums" | `logicalFilePath` wrapper without clearing checksums | Fix D includes a one-time `clear-checksums` |
| `Unique index or primary key violation … ACT_GE_SCHEMA_LOG(ID_) VALUES ('1300')` (H2); `ORA-00001 … insert into ACT_GE_SCHEMA_LOG values ('1300', …, '7.24.0')`; PostgreSQL `duplicate key value violates unique constraint "act_ge_schema_log_pkey"` | changesets `7.23-to-7.24` and `7.24.0-tag` authored `Operaton` instead of `Camunda`, so they re-run | Fix D (update `AUTHOR` for those ids, clear checksums once) |
| pods restart once after the Liquibase author fix | fix ran inside the same Liquibase run as the Operaton changelog | run it in an earlier, separate Liquibase bean / changelog / init job |
| SQL errors on `ACT_RU_EXECUTION.PROC_DEF_KEY_` or `ACT_HI_COMMENT.REV_` (older: `TASK_STATE_`, `BATCH_ID_`) | database is on Camunda 7.22 or older; `schema-update` never runs upgrade scripts | **stop**: run Camunda upgrade scripts up to 7.24 first; the newest `ACT_GE_SCHEMA_LOG` row (highest `ID_`) must be `7.24.0` (or a `7.24.N` EE patch row, or `7.25.0` after the Operaton 2.2 script) |
| pre-flight NO_GO `schema log is <v>, expected 7.24.0 (or a 7.24.N patch row): upgrade to Camunda 7.24 first` (7.23.x adds ` (7.23 lacks no DDL, only the 7.24.0 marker row, but skips the 7.24 changes)`) | P01: the database is not on Camunda 7.24 | same stop condition; a suffix such as `7.24.3-ee` would also be NO_GO (no evidence that Camunda writes one) |
| a new, empty set of `ACT_*` tables in another schema | `schema-name` / `table-prefix` key left behind, `schema-update: true` created a schema | migrate the key; `schema-update: false` for the cut-over (D8) |
| `required a bean of type 'org.springframework.kafka.core.KafkaTemplate' that could not be found` (2.x) | Spring Boot 4 modular auto-configuration | `org.springframework.boot:spring-boot-starter-kafka` |
| admins are sent to the "create initial admin user" page | nobody is a member of `operaton-admin`, DB identity is writable | **release blocker**: admin group migration (D5) and block the setup path (references/identity-and-admin.md) |
| unauthenticated `POST /<app-path>/api/admin/setup/default/user/create` returns **204** (Camunda 7.24: **403** `{"type":"InvalidRequestException","message":"Setup action not available"}`) | same cause; security issue | same fix. Production: only the non-mutating `GET <app-path>/app/admin/default/` check (`smoke-test.sh`); full probe only on a throw-away copy, expect the body `Setup action not available` (a bare 403 can come from the CSRF filter) |
| `ENGINE-03029 Required admin authenticated group or user.` for former admins | only `operaton-admin` is an admin group (authorization enabled) | D5 data migration |
| editing group `camunda-admin` fails: `Group has an invalid id: 'camunda-admin' is not a valid resource identifier.` | the default whitelist now allows `operaton-admin`, not `camunda-admin` | leave `camunda-admin` untouched until the rollback window closes; extend the whitelist temporarily if you must edit it |
| webapps 404 at `/camunda/app/…`, `/` redirects to `/operaton/app/` | default path is `/operaton`; key missing or still `camunda.bpm.webapp.application-path` | `operaton.bpm.webapp.application-path: /camunda` (D6) or move proxies/links |
| `/operaton/app/…` returns 404 | expected when `/camunda` is kept explicitly | none; runbook and smoke tests use the configured path |
| Kubernetes readiness never succeeds / Docker `HEALTHCHECK` fails | probe targets the webapp path, which moved (or the reverse) | probe `/actuator/health/readiness` |
| `JAXBContext implementation could not be found. WADL feature is disabled.` (2.x) | Jersey on Spring Boot 4 | harmless |

## 4. Runtime errors

| Message or symptom | Cause | Fix |
|---|---|---|
| `ScriptCompilation Unable to compile script: org.codehaus.groovy.control.MultipleCompilationErrorsException: startup failed: Script4.groovy: 4: unable to resolve class org.camunda.spin.Spin` | Groovy script in a model imports a Camunda class; scripts compile lazily, deploy succeeded | drop the import, use pre-bound `S(…)` (runs on both engines); `import org.operaton.spin.Spin` is Operaton-only (D15) |
| the same script error **after** fixing the BPMN, as an incident with `"retries":2` → 0 | instance runs on the old definition version (bytes in `ACT_GE_BYTEARRAY`) | migrate instances to a package-free fixed version (ideally on Camunda 7.24 before cut-over): references/models-and-scripts.md |
| `MissingPropertyException: No such property: org` (Groovy) | fully qualified `org.camunda.bpm…` reference | package-free script; else `org.operaton…` (Operaton-only) |
| `TypeError: Access to host class … is not allowed or does not exist` (JavaScript) | `Java.type('org.camunda…')` under GraalJS | package-free (`S(JSON.stringify(obj))`); else `Java.type('org.operaton…')` |
| `Can't find scripting engine for 'javascript'` | no GraalJS on the classpath | `org.graalvm.polyglot:polyglot`, `org.graalvm.polyglot:js` (type `pom`), `org.graalvm.js:js-scriptengine` |
| `importPackage(...)` / `JavaImporter` fails in JavaScript | Rhino/Nashorn helpers unsupported by GraalJS, even with Nashorn compatibility | rewrite with `Java.type(...)` |
| `ENGINE-09017 Cannot load class …` for `org.camunda.bpm.…` named in the model | your own classes lived under `org.camunda.bpm.*`, the recipe moved them, `camunda:class` still old | move code out of `org.camunda.*`, update the model |
| `org.springframework.expression.spel.SpelEvaluationException: EL1005E: Type cannot be found 'org.camunda.bpm.engine.impl.history.event.HistoricProcessInstanceEventEntity'`, `startProcessInstanceByKey` fails | `@EventListener(condition = "… T(org.camunda…)")` literal, evaluated inside the engine command | fix the literal (grep `T(org.camunda`) or use a typed parameter |
| consumer: `InvalidTypeIdException: Could not resolve type id 'org.camunda.bpm.engine.impl.history.event.HistoricActivityInstanceEventEntity' … no such class found` | payloads carry class names (`@class`, `__TypeId__`) | own DTOs, versioned topic, dual-read consumers (D9) |
| test/consumer expects `org.camunda.bpm.engine.` but gets `org.operaton.bpm.engine.impl.history.event.HistoricProcessInstanceEventEntity` | `getClass().getName()` changed | D9 default: freeze `eventClass` to the Camunda value in a v2 envelope (references/plugins-and-exporters.md §6), keep the test; flip only after consumer sign-off |
| `UnsupportedOperationException` at `cfg.getCustomJobHandlers().add(…)` | immutable empty list since 1.0 | `new ArrayList<>(cfg.getCustomJobHandlers())`, add, `setCustomJobHandlers(…)` |
| `Unknown property used in expression` during deployment (tests) | `@Deployment` now deploys before `@BeforeEach`; mocks registered too late | register mocks in an earlier extension or `@BeforeAll` |
| Groovy `Ambiguous method overloading for method …JacksonJsonNode#prop` | `prop(name, null)` matches two overloads | guard nulls or `S(map, 'application/json')` |
| `The form with the resource name 'approve-order.form' cannot be found in deployment …` | fat jar + `@EnableProcessApplication` deploys `BOOT-INF/classes/…` (same on Camunda) | extracted layout `java -Djarmode=tools -jar app.jar extract` |
| parse error "…If you are using a connector, make sure the connect process engine plugin is registered…" | `operaton-engine-plugin-connect` missing | add it plus a connector artifact |
| `ClassNotFoundException` / Spin deserialization error reading an old variable | Java-serialized or Spin type name `org.camunda.*` in data; no mapping layer | detect with `assets/sql/postgresql/20-find-legacy-references.sql`, convert or drain before cut-over (D18) |
| old definition with `http://activiti.org/bpmn` misbehaves or fails to parse (late) | Activiti namespace alias dropped | convert to `camunda:`, redeploy, migrate instances |
| on a Camunda node: `One of the attributes 'class', 'delegateExpression', 'type', or 'expression' is mandatory…` | `operaton:` definition executed by a Camunda job executor (mixed cluster) | no mixed clusters (D7); keep `camunda:` until the rollback window closes |
| DMN results differ on edge cases (`null` instead of `false`) | newer FEEL-Scala semantics | regression-test decision tables |
| burst of jobs right after start, or jobs stuck ~5 min | timers due during the window; locks of the stopped Camunda node (`LOCK_EXP_TIME_`) | expected; never reset locks while any engine runs |

## 5. Silent failures (no error, wrong behaviour)

| Symptom | Cause | Fix |
|---|---|---|
| settings ignored: no admin user, default webapp path, job executor running in tests, eventing changed | `camunda.bpm.*` in a profile, Config Server, Helm, `SPRING_APPLICATION_JSON` | rename at the source; `LegacyCamundaConfigGuard` (references/configuration.md) |
| **authorization silently disabled** | `camunda.bpm.authorization.enabled: true` left behind (engine default `false`) | same; treat as a security incident if it reached production |
| `CAMUNDA_BPM_*` env vars have no effect | no recipe rewrites env vars outside `InfraEnvVars` scope | `OPERATON_BPM_*` |
| engine writes to the **business** database (`ACT_*` tables appear there) | `@Bean("camundaBpmDataSource")` no longer picked up; `@Primary` used | `operatonBpmDataSource` (+ `…TransactionManager`, `…JdbcTemplate`) |
| LDAP silently off, DB identity used | `@ConditionalOnProperty(prefix = "camunda.bpm.ldap")` / `@ConfigurationProperties("camunda.bpm.ldap")` literals | `operaton.bpm.ldap` |
| Keycloak users get new ids, authorizations stop matching | `useEmailAsCamundaUserId` & co. ignored | `use…AsOperatonUserId` / `useGroupPathAsOperatonGroupId` |
| Spin serializes dates as arrays/timestamps, modules ignored | configurator not loaded (services content / `spring.factories` key still `org.camunda…`), or a Jackson 3 rewrite (3.5 path: Hop 2 on un-renamed code or the stock recipe) removed its lines | fix SPI files; restore Jackson 2 configurator + `jackson-datatype-jsr310` |
| silenced loggers noisy (`ENGINE-16004 Exception while closing command context …` stack traces), log alerts never fire | logger names still `org.camunda…` | `org.operaton…`; keep `org.camunda.feel` |
| actuator health toggle has no effect | `management.health.camunda.enabled` | `management.health.operaton.enabled` |
| `@EventListener` for `TaskEvent`/`ExecutionEvent` never fires, or history events published again | `camunda.bpm.eventing.*` not migrated | `operaton.bpm.eventing.*` |
| Tasklist shows a Camunda Form as an "external form" link | Tasklist recognizes only `operaton-forms:` (according to the source) | D4: `formRef` or `operaton-forms:` + instance migration |
| REST client reads `camundaFormRef == null` | field renamed `operatonFormRef` in `TaskDto`/`FormDto` | update client / regenerate from `operaton-engine-rest-openapi` |
| integration refuses the engine or takes a legacy path | gates on `GET /engine-rest/version` starting with `7.` (now the Operaton version) | remove the gate |
| tests pass against the wrong engine (history `audit`, no mocks, no plugins) | `camunda.cfg.xml` ignored; 1.1+ JUnit 5 extension falls back silently | `operaton.cfg.xml` + guard test |
| external tasks pile up, worker starts cleanly | `camunda.bpm.client.*` not renamed (no `base-url`) | `operaton.bpm.client.*`; watch `GET /engine-rest/external-task/count?notLocked=true` |
| auto-configuration you excluded is active again | `spring.autoconfigure.exclude` names a class that no longer exists | Operaton FQCN |
| pods restart during short DB outages (2.1+) | `processEngine` health DOWN on DB failure, wired into liveness | readiness group only (D13) |
| a bot proposes, or the build resolves, an Operaton `-RC`/`-M` version | Maven `<release>` metadata points to a pre-release | pin versions; bots ignore `-M*`/`-RC*` (only a Spring Boot 4.1 rehearsal branch may target 2.2.0-RC1) |
| app runs, but on Spring Boot 4.1 with Operaton 2.1.5 (or 4.0 with 2.2.x) | target and Spring Boot minor differ; `migrate.sh` only warned | unsupported pairing: Spring Boot 4.1 → 2.2.x, 4.0 → 2.1.5 (references/versions.md) |
| `operaton.bpm.authorization.validate-auth-resource-id-exists` has no effect; authorizations with unknown user/group ids are saved | Camunda 7.24.3-ee validation does not exist in Operaton; the key is ignored | delete the key; validate ids in the code that creates authorizations (D17) |
| stored Tasklist filters evaluate any expression | Operaton has no query-expression allow-list (Camunda 7.24.7-ee): the behaviour of Camunda before 7.24.7 (security notice 157) | D17 mitigation (references/identity-and-admin.md §10) |
| EE Cockpit features (history view, heatmap, instance modification, migration UI, batches, reports) missing | Operaton has the CE webapps only; the recipe mapped `-webapp-ee` to CE without a build error | expected: D17 replacement plan |
| custom banner shows an empty version | `${camunda.bpm.formatted-version}` | `${operaton.bpm.formatted-version}` |
| all users must log in again after the switch | CSRF session attributes renamed (`CAMUNDA_CSRF_TOKEN` → `OPERATON_CSRF_TOKEN`) | expected; flush persisted sessions, announce it |
| webapp customization (`config.js`, branding, Cockpit plugin) disappeared | overlays under `META-INF/resources/webjars/camunda/…` | move to `…/webjars/operaton/…` |
| former admins see everything but are tenant-restricted | `camunda-admin` lost admin status (no tenant-check bypass) | D5 data migration |
| every history event exported twice | handler bean **and** plugin registration | register once |
| one small model fix created new versions of every process | auto-deployment `deployChangedOnly: false` | `deployChangedOnly: true` |

## 6. What to collect before asking upstream

Source edition and versions (Camunda `7.24.N-ee` or CE 7.24.0, Spring Boot), Operaton and Spring Boot target versions,
`rewrite-maven-plugin` / recipe / rewrite-spring versions, the full stack trace, the `migrate.sh` log
(`$TMPDIR/operaton-migrate.*/boot4.log`; Spring Boot 3.5 path: `hop<N>.log`), `verify-leftovers.sh` output, and what was
already tried from this file. Never include credentials or license keys. Forum: https://forum.operaton.org (the user
posts, not the agent). Operaton's own documentation claims compatibility with Camunda 7 CE 7.24 only: for Camunda EE
specifics, rely on this skill and the guide.
