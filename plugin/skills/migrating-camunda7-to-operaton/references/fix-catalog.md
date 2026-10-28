<a id="fix-catalog-what-breaks-after-hop-1-and-hop-2-and-the-exact-fix"></a>

# Fix catalog: what breaks after the recipe run, and the exact fix

Applies to both paths: the Spring Boot 4 path (one run, `MigrateSpringBoot4App`) and the Spring Boot 3.5 path (Hop 1,
Hop 2). Rows that only concern one path say so.

Guide chapters (read when an entry is not enough):
[03 recipes](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/03-openrewrite-recipes.md) ·
[04 config](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/04-spring-boot-dependencies-and-configuration.md) ·
[05 models](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/05-bpmn-dmn-forms-and-scripts.md) ·
[06 plugins](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/06-engine-plugins-and-history-exporters.md) ·
[10 testing](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/10-testing.md) ·
[12 Operaton 2 and Spring Boot 4](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/12-operaton-2-and-spring-boot-4.md) ·
[13 troubleshooting](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/13-tips-tricks-and-troubleshooting.md) ·
[07 security](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/07-identity-admin-group-and-security.md) and
[09 webapps](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/09-webapps-rest-api-and-clients.md) for Camunda EE (D17) ·
[15 Spring Boot 3.5 path](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/15-coming-from-spring-boot-3.md).
Versions: see references/versions.md.

## Contents

0. Workflow and hard rules
1. Build and dependencies
2. Java code (internal API, literals, SPI)
3. Configuration
4. Models and scripts
5. Tests
6. Operaton 2.x and Spring Boot 4
7. Scanner rule → fix
8. Camunda EE and Spring Boot 4 sources (decision D17)

## 0. Workflow and hard rules

1. `mvn -B clean verify` (always `clean`: incremental builds hide the generics errors; log and wait, SKILL
   "Long-running commands"). Gradle: `./gradlew clean build`.
2. Search this file for a fragment of the **first** error (class name, `ENGINE-` code, quoted id). Fix, rebuild, repeat.
3. `bash "<skill-dir>/scripts/verify-leftovers.sh" <project-dir>` until exit 0 (§7).
4. Record every manual fix in `MIGRATION_REPORT.md`: file, symptom, fix, why the recipe missed it.

Never: delete or `@Disabled` a failing test · blanket-replace `org.camunda` → `org.operaton` (breaks `org.camunda.feel`)
· flip a consumer-contract canary before the consumers signed off (D9) · rename persisted identifiers (`JobHandler.getType()`,
incident types, serializer names such as `spin://application/json`/`serializable`, history-level ids, data format names)
· set `generic-properties.ignore-unknown-fields: true` to silence an error (also not for EE-only properties, §8)
· downgrade Spring Boot to fit a target (pick the target that fits the Spring Boot minor, references/versions.md).

## 1. Build and dependencies

| Symptom | Fix |
|---|---|
| `cannot find symbol … ProcessEngineExtension`, `org.operaton.bpm.engine.test.Deployment` not found | Test helpers left the main jar. Spring Boot module: add `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-test-junit5` (test). Plain engine module: `org.operaton.bpm:operaton-engine` classifier `junit5` (1.x) / `junit6` (2.x), test, plus `operaton-bpm-assert`. Remove `org.operaton.bpm:operaton-bpm-junit5` (empty). Snippet below |
| `operaton-bpm-spring-boot-starter-webapp-ee` cannot be resolved | never existed on Central: use `operaton-bpm-spring-boot-starter-webapp`. EE screens are gone either way (D17) |
| `-ee` artifacts compiled green | recipe mapped them to CE silently: record EE feature inventory (D17) in the report |
| Camunda EE Spring Boot 4 starters (`camunda-bpm-spring-boot-starter-4*`) still in the build (`STARTER_4`) | `MigrateSpringBoot4App` maps them; leftovers mean the official recipe or Hop 1 ran on a Spring Boot 4 project (references/recipes.md §9) or a coordinate sits where the recipe does not look (parent POM, profile). Mapping: §8 |
| pre-7.24 coordinates left (`org.camunda.bpm.extension.springboot`, `org.camunda.bpm.extension:camunda-bpm-spring-boot-starter`, `org.camunda.bpm.assert:camunda-bpm-assert`, `org.camunda.bpm.extension:camunda-bpm-junit5`) | not mapped: move to the Camunda 7.24 coordinates first, then rerun the migration (`migrate.sh`; 3.5 path: Hop 1) |
| Gradle: sources migrated, `gradle/libs.versions.toml` still `org.camunda.bpm…` | edit the catalog by hand with the official mapping file (https://github.com/operaton/migrate-from-camunda-recipe/blob/v1.0.1/camunda-to-operaton-mapping.md): groups `org.camunda.{bpm[.*],spin,connect,commons,template-engines}` → `org.operaton.…`, `camunda-*` → `operaton-*`, `-jakarta`/`-ee`/`-spring-6` variants collapse onto the plain artifact; keep `org.camunda.feel` |
| `org.camunda.community.*` imports/deps untouched | deliberate. process-test-coverage → `io.github.ronalders:operaton-process-test-coverage-junit5` (package `org.operaton.community.process_test_coverage.*`, pinned, BOM imported); scenario runner → `io.github.ronalders:operaton-platform-scenario-runner`; others: references/testing.md |
| `NoSuchMethodError` / `ClassNotFoundException` from Operaton classes (often tests only) | mixed Operaton versions (forks pull `operaton-engine:junit5` at compile scope). Import `org.operaton.bpm:operaton-bom` with an explicit version; the dependency tree must show one Operaton version (commands below the table) |
| dependency tree still shows `org.camunda` artifacts other than `org.camunda.feel` | a coordinate was missed (parent POM, BOM, profile): map it by hand |
| build resolves a `-RC`/`-M` version | Maven `<release>` points to a pre-release: pin every `org.operaton*` version; bots ignore `-M*`/`-RC*` |
| `<camunda.version>` still present / holds an Operaton version | rename to `operaton.version` (`AlignVersionsOperaton2` / Hop 1's `AlignVersions` do it) |
| Java release 11 in the build | Operaton needs Java 17+: raise `java.version` / `release` in the migration commit (Spring Boot 3.5 path: Hop 1) |
| `Can't find scripting engine for 'javascript'` / Groovy engine missing | engines are not bundled: add `org.apache.groovy:groovy-jsr223`, or GraalJS `org.graalvm.polyglot:polyglot`, `org.graalvm.polyglot:js` (type `pom`), `org.graalvm.js:js-scriptengine` |
| parse error "…make sure the connect process engine plugin is registered…" | add `org.operaton.bpm:operaton-engine-plugin-connect` and a connector artifact (`org.operaton.connect:operaton-connect-http-client` …) |
| Keycloak plugin | recipe maps only `camunda-platform-7-keycloak` → `org.operaton.bpm.extension:operaton-keycloak` at `1.0.x`: set the line matching the Operaton line (references/versions.md); change `-jwt`, `-all`, `-run` by hand |
| `camunda-engine-spring-6` (removed in Camunda 7.24.6) / `operaton-engine-spring-6` (ended at 1.0.0-beta-3) (`ENGINE_SPRING_6`) | `org.operaton.bpm:operaton-engine-spring` (Spring 7, managed by `operaton-bom`); the build fails otherwise |
| Liquibase include of `org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml` | do **not** just repoint to `operaton-changelog.xml` (every changeset looks new): follow references/database.md |
| Camunda EE repository (`artifacts.camunda.com/artifactory/private/`) in POM/settings | keep it while the recipe runs (EE builds resolve all dependencies first), then remove it and its credentials (CI secrets) from the Operaton build and prove a Central-only build (§8); revoke the credentials only after the rollback window (Camunda rollback build) |

```xml
<!-- Spring Boot module (added by PostFixes when org.junit.jupiter.api.* is used) -->
<dependency>
  <groupId>org.operaton.bpm.springboot</groupId>
  <artifactId>operaton-bpm-spring-boot-starter-test-junit5</artifactId>
  <scope>test</scope>
</dependency>
<!-- plain engine module instead -->
<dependency>
  <groupId>org.operaton.bpm</groupId><artifactId>operaton-engine</artifactId>
  <classifier>junit5</classifier><!-- junit6 on 2.x, identical content --><scope>test</scope>
</dependency>
```

```bash
mvn -B dependency:tree | grep -E 'org\.operaton'    # exactly one Operaton version
mvn -B dependency:tree | grep 'org\.camunda'        # only org.camunda.feel may remain
```

## 2. Java code (internal API, literals, SPI)

| Symptom | Fix |
|---|---|
| `incompatible types` on `List<JobHandler>` / `Map<String, JobHandler>` / `List<TypedValueSerializer>` | generics since 1.1: `List<JobHandler<?>>`, `Map<String, JobHandler<?>>`, `List<TypedValueSerializer<?>>`; use copy, add, set (below) |
| `UnsupportedOperationException` at `…getCustomJobHandlers().add(…)` (plugin `preInit`) | getter returns an immutable empty list, never `null`: copy, add, set. Same pattern for every configuration list |
| `constructor AbstractOperatonConfiguration … cannot be applied to given types` + `cannot find symbol: variable camundaBpmProperties` | constructor injection: add the `(OperatonBpmProperties)` constructor, use `operatonBpmProperties` (below). `Default*Configuration` subclasses need their full constructor, e.g. `DefaultJobConfiguration(OperatonBpmProperties, JobExecutor)` |
| `cannot find symbol CAMUNDA_TASK_EXECUTOR_QUALIFIER` | `DefaultJobConfiguration.JobConfiguration.OPERATON_TASK_EXECUTOR_QUALIFIER` (bean `operatonTaskExecutor`) |
| `package org.operaton.bpm.impl.juel.jakarta.el does not exist` | import `jakarta.el.*` (`ELResolver`, `ELContext`, `CompositeELResolver` …) in custom `ELResolver`/`ExpressionManager`/`ProcessApplicationElResolver` code (`PreFixes` does it when it runs) |
| `setLicenseKey`/`getLicenseKey`/`deleteLicenseKey`, `LicenseKeyData` not found (`EE_LICENSE`, MUST) | removed in Operaton: delete the code (the key stored in the database stays, inert, for rollback). `toggleTelemetry`/`isTelemetryEnabled` are deprecated for removal: delete the calls |
| `setQueryExpressionValidator`, `setAllowedExpression{Functions,Beans,Properties}InQueries`, `setValidateAuthResourceIdExists` (or another `queryExpressionAllowList*` setter) not found | Camunda EE 7.24.3/7.24.7 settings Operaton does not have: delete the calls and apply the D17 mitigation (§8) |
| `JtaProcessEngineConfiguration` not found | removed: `org.operaton.bpm.engine.impl.cfg.JakartaTransactionProcessEngineConfiguration` |
| deprecation warning `AbstractBpmnParseListener` | `implements BpmnParseListener` (all methods are default no-ops); register via `get/setCustomPreBPMNParseListeners` / `…PostBPMNParseListeners` (copy, add, set) |
| parse listener no longer finds `camunda:` extension elements | the recipe rewrote the **String** `BpmnParser.CAMUNDA_BPMN_EXTENSIONS_NS` to the operaton URI. Use the `Namespace` `BpmnParse.OPERATON_BPMN_EXTENSIONS_NS` (matches `operaton:` and `camunda:`) |
| deprecation `HistoryEvent.ACTIVITY_EVENT_TYPE_*` etc. | use `HistoryEventTypes` |
| `UnsupportedOperationException` on `AbstractTypedValueSerializer.BINARY_VALUE_TYPES.add(…)` | immutable `Set.of`: build your own set |
| empty `onDelete(…)` override in a `JobHandler` | now a `default` method: may delete it. Keep `getType()` byte-identical |
| `NoUniqueBeanDefinitionException … HistoryEventHandler … expected single matching bean but found 2` | the starter auto-registers exactly one `HistoryEventHandler` bean: register further handlers through a plugin |
| every history event exported twice | handler is a `@Component` **and** added by a plugin: let the plugin construct it (`new …Handler(publisher)`), remove `@Component` (references/plugins-and-exporters.md) |
| custom `FailedJobCommandFactory` ignored | the starter sets the default at order 0: annotate your plugin `@Order(Ordering.DEFAULT_ORDER + 1)` |
| `SpelEvaluationException: EL1005E: Type cannot be found 'org.camunda…'` (e.g. `startProcessInstanceByKey` fails) | SpEL `T(org.camunda…)` in `@EventListener(condition=…)` is a string: use a typed listener parameter or `T(org.operaton…)` |
| `"org.camunda.bpm…"` class-name literals (MUST in `verify-leftovers.sh`) | decide per literal: internal use (`Class.forName`, allow-lists, `spring.json.trusted.packages`) → `org.operaton…`; consumer contract (event payloads, `eventClass`, `__TypeId__`) → decision D9: by default keep the payload stable (v2 envelope, `eventClass` frozen to the Camunda value, references/plugins-and-exporters.md §6) and accept the literal in `.operaton-migration-ignore` until consumers sign off |
| `/engine-rest` auth filter: start fails or API open | provider configured as string `"org.camunda.bpm.engine.rest.security.auth.impl.HttpBasicAuthenticationProvider"`: use `HttpBasicAuthenticationProvider.class.getName()` (Operaton import); smoke test expects 401 without credentials |
| `"camunda-admin"` literals in code | group ids are data: use `Groups.OPERATON_ADMIN` for admin semantics; never rename the DB group; data migration = D5 (references/identity-and-admin.md) |
| bean names in `@Resource(name=…)`, XML bean files, SpEL, or variants like `"camundaBpmDataSource-replica"` | `PreFixes` only replaces whole literals: rename by hand to `operatonBpmDataSource`, `operatonBpmTransactionManager`, `operatonBpmJdbcTemplate`, `operatonTaskExecutor` |
| `@ConfigurationProperties`/`@ConditionalOnProperty`/`@Value` still say `camunda.bpm…` | rename to `operaton.bpm…` (LDAP silently off otherwise) |
| `ENGINE-09017 Cannot load class org.camunda.bpm…` (your own class) | your code lived under `org.camunda.bpm.*` and was moved: move it to your own package and update `camunda:class` in the model |
| MyBatis mapping `<include refid="org.camunda.bpm.engine.impl.persistence.entity…"/>` | change to `org.operaton.bpm.engine.impl.persistence.entity…` by hand |
| hard-coded `/camunda/app/…` links in code | derive from `OperatonBpmProperties#getWebapp().getApplicationPath()` |
| `runtimeService.newMigration(plan)….execute()` deprecated | use `executeAsync()` (batch) |
| Spin configurator / auto-configuration silently not loaded | SPI files: below |

```java
// copy, add, set (Operaton 1.1+ / 2.x) - replaces: List<JobHandler> h = cfg.getCustomJobHandlers(); if (h == null) …; h.add(…)
List<JobHandler<?>> handlers = new ArrayList<>(configuration.getCustomJobHandlers());
handlers.add(new ReExportJobHandler());
configuration.setCustomJobHandlers(handlers);
```

```java
// AbstractCamundaConfiguration subclass after the recipe
@Component
@Order(Ordering.DEFAULT_ORDER + 1)
public class ExportToggleConfiguration extends AbstractOperatonConfiguration {
  public ExportToggleConfiguration(OperatonBpmProperties operatonBpmProperties) {
    super(operatonBpmProperties);
  }
  @Override
  public void preInit(SpringProcessEngineConfiguration configuration) {
    if (operatonBpmProperties.getEventing().isHistory()) { /* was camundaBpmProperties */ }
  }
}
```

```diff
 # META-INF/services: file NAME renamed by the recipe; CONTENT naming relocated engine classes must change too
-org.camunda.spin.impl.json.jackson.format.JacksonJsonDataFormatProvider
+org.operaton.spin.impl.json.jackson.format.JacksonJsonDataFormatProvider
 # META-INF/spring.factories: KEYS are never renamed by the official recipe (PostFixes does it)
-org.camunda.spin.spi.DataFormatConfigurator=com.example.MyConfigurator
+org.operaton.spin.spi.DataFormatConfigurator=com.example.MyConfigurator
```

Keep `META-INF/services/org.camunda.feel.valuemapper.CustomValueMapper` and every `org.camunda.feel.*` import unchanged.

## 3. Configuration

Mapping tables, env vars, guard and outside-the-repo work: references/configuration.md. Errors you meet in the build:

| Symptom | Fix |
|---|---|
| `Group has an invalid id: 'operaton-admin' is not a valid resource identifier.` | whitelist **value** still names `camunda-admin`: replace it with `operaton-admin` inside the pattern (YAML below the table; also in env vars, Helm, Config Server). Then still do D5 |
| `ENGINE-08043 … Invoking @PostDeploy': Group has an invalid id: 'order-ops' …` | generic `MigrateFromCamunda` ran: whole `camunda.bpm` block ignored. Rerun the migration with the composite (`migrate.sh`; 3.5 path: Hop 1) |
| start fails, `… were left unbound` under `operaton.bpm.generic-properties.properties` | `disableStrictCamundaFormParsing` → `disableStrictOperatonFormParsing`; Camunda EE-only names (`queryExpressionAllowListEnabled`, `allowedExpression*InQueries`, `validateAuthResourceIdExists`) → delete them (§8) |
| `Expressions are forbidden in stored queries` when a Tasklist filter runs | the D17 mitigation `enable-expressions-in-stored-queries: false` meets a stored filter that uses expressions (pre-flight P11 lists them): rewrite the filter without expressions, or keep expressions on and restrict who may create/update filters (references/identity-and-admin.md §10) |
| `operaton.bpm.authorization.validate-auth-resource-id-exists` has no effect | Camunda 7.24.3-ee setting, not in Operaton, ignored silently: delete it; validate user and group ids in the code that creates authorizations (§8) |
| `historyLevel mismatch: configuration says … and database says …` | `operaton.bpm.history-level` = value in `ACT_GE_PROPERTY` (`SELECT VALUE_ FROM ACT_GE_PROPERTY WHERE NAME_ = 'historyLevel'`: 0 none, 1 activity, 2 audit, 3 full); re-register custom history levels with the same id |
| `cvc-elt.1.a: Cannot find the declaration of element 'process-application'` | every `processes.xml` (other modules, library jars): `xmlns="http://www.operaton.org/schema/1.0/ProcessApplication"` |
| `DOCTYPE is not allowed…` parsing `processes.xml` | also change `xsi:schemaLocation` to the operaton URL |
| test/app silently on defaults (job executor runs, no admin user, wrong path) | `camunda.bpm.*` left in `application-*.yaml`, `@SpringBootTest(properties=…)`, `@TestPropertySource`, `${camunda.bpm…}` placeholders: rename; ship `LegacyCamundaConfigGuard` |
| auto-configuration you excluded is active again | `spring.autoconfigure.exclude` names `org.camunda…Camunda…AutoConfiguration`: use the Operaton FQCN (package **and** class) |
| webapp branding/plugins gone | overlays under `META-INF/resources/webjars/camunda/…` → `git mv` to `…/webjars/operaton/…`; delete an explicit `webjar-classpath` key |
| silenced logger noisy again (`ENGINE-16004` stack traces) | logger names `org.camunda.{bpm,spin,connect,commons}` → `org.operaton.…` in logback/log4j2/`.properties`/env; keep `org.camunda.feel` |
| banner prints `${camunda.bpm.formatted-version}` | `${operaton.bpm.formatted-version}` |
| Keycloak users get new ids | `useEmailAsCamundaUserId`/`useUsernameAsCamundaUserId`/`useGroupPathAsCamundaGroupId` → `…AsOperatonUserId`/`…AsOperatonGroupId` |

```yaml
operaton:
  bpm:
    generic-properties:
      properties:
        groupResourceWhitelistPattern: "[a-zA-Z0-9]+|operaton-admin|order-ops"   # was ...|camunda-admin|order-ops
```

## 4. Models and scripts

Details, instance migration and namespace rules: references/models-and-scripts.md.

| Symptom (at runtime, deploy succeeded) | Fix |
|---|---|
| `ScriptCompilation … unable to resolve class org.camunda.spin.Spin` | drop the import, use pre-bound `S(…)` (below). Runs on Camunda 7.24 **and** Operaton: preferred, rollback-safe; belongs in the pre-migration release on 7.24 (SKILL step 3b). `import org.operaton.spin.Spin` works but is Operaton-only (D15 hard stop) |
| Groovy `MissingPropertyException: No such property: org` | fully qualified `org.camunda.bpm…` in a script: package-free rewrite, else `org.operaton…` (Operaton-only) |
| JS `TypeError: Access to host class org.camunda… is not allowed or does not exist` | `Java.type('org.camunda.spin.Spin').JSON(obj)` → `S(JSON.stringify(obj))` |
| JS `importPackage`/`importClass`/`JavaImporter` fails | GraalJS: rewrite with `Java.type(…)` |
| `JSON(…)`/`XML(…)` inside a script fails | only `S` is bound in scripts: `S(x, 'application/json')` / `S(x, 'application/xml')` |
| Groovy `Ambiguous method overloading … JacksonJsonNode#prop` | `prop(name, null)`: guard nulls or use `S(map, 'application/json')` |
| `MissingPropertyException: No such property: groovy` with `groovy.json.JsonOutput` | `groovy-json` is not in `groovy-jsr223`: use `S(…)` |
| same script error after the BPMN was fixed (incident, retries → 0) | instance runs on the **old** definition version: migrate instances (package-free fix, ideally on Camunda 7.24 before cut-over) |
| model uses `http://activiti.org/bpmn` | not accepted: convert to `camunda:`, redeploy, migrate instances |
| Tasklist shows Camunda Form as external link | `camunda-forms:` key: decision D4 (`formRef` rollback-safe, or `operaton-forms:` + instance migration) |
| `ENGINE-12018 History Time To Live (TTL) cannot be null` | add `historyTimeToLive` to the model, or `operaton.bpm.generic-properties.properties.history-time-to-live: P180D` |
| one script fix created new versions of every process | auto-deployment `deployChangedOnly` defaults to `false`: `generic-properties.properties.deployChangedOnly: true` (process application: `isDeployChangedOnly` per archive) |
| `The form with the resource name '…form' cannot be found in deployment` | fat jar deploys `BOOT-INF/classes/…`: extracted layout (`java -Djarmode=tools -jar app.jar extract`); or `.form` missing in `additionalResourceSuffixes` / resource pattern |

```groovy
// before (Camunda-only)
import org.camunda.spin.Spin
def summary = Spin.JSON([orderId: orderId, amount: amount])
execution.setVariable('orderSummary', summary)

// after (runs on Camunda 7.24 AND Operaton): S(object, format) is what Spin.JSON(object) does
def summary = S([orderId: orderId, amount: amount], 'application/json')
execution.setVariable('orderSummary', summary)
```

## 5. Tests

| Symptom | Fix |
|---|---|
| `package org.operaton.bpm.engine.test.mock does not exist` / `Mocks` not found | `import org.operaton.bpm.engine.impl.mock.Mocks;` (also `MockExpressionManager`, `MockElResolver`, `MocksResolverFactory`); same class name in `operaton.cfg.xml` |
| JUnit 5: `FileNotFoundException … operaton.cfg.xml` (1.0.x) · JUnit 4 rule fails, names `activiti.cfg.xml` | rename `camunda.cfg.xml` → `operaton.cfg.xml` (`src/test/resources`), class names inside → `org.operaton…` |
| tests green but `Mocks` don't resolve, history assertions skipped, "History Time To Live cannot be null", Spin fails | 1.1+: missing `operaton.cfg.xml` → silent default engine (history `audit`, no mocks, no plugins). Rename and add a guard test asserting `getHistory()` = `full` and `MockExpressionManager` |
| `Unknown property used in expression` while deploying | `@Deployment` now deploys **before** `@BeforeEach`: register mocks earlier (below) |
| timer/async tests flaky | `camunda.bpm.job-execution.enabled: false` not renamed (test YAML, `@SpringBootTest(properties)`) |
| `Expecting … ["operaton-admin", …] to contain ["camunda-admin", …]` | expected: the constant now yields `operaton-admin`; update the expectation |
| expects form key `camunda-forms:…`, found `operaton-forms:…` | consequence of D4 / `FormKeys`: update the expectation |
| `Expecting actual "org.operaton.bpm.engine.impl.history.event…" to start with "org.camunda.bpm.engine."` | consumer-contract canary: do not flip it. D9 default: freeze `eventClass` to the Camunda value in the v2 envelope (references/plugins-and-exporters.md §6), the canary stays green; flip only after consumer sign-off and record it in the report |
| `BpmnAwareTests` not found | `import static org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.*;` (dependency `org.operaton.bpm:operaton-bpm-assert`) |
| `camunda-bpm-spring-boot-starter-4-test` left, or test helpers missing after the Spring Boot 4 run | `Boot4PreFixes` maps it to `operaton-bpm-spring-boot-starter-test`, `PostFixes` turns that into `operaton-bpm-spring-boot-starter-test-junit5` when Jupiter is used (decision D11); a leftover is `STARTER_4` (§8) |
| several Spring contexts clash | `spring.datasource.generate-unique-name: true`, `operaton.bpm.generate-unique-process-engine-name: true` (+ `…-process-application-name` with a process application) |

```java
@RegisterExtension @Order(1)
static BeforeEachCallback mocks = context -> Mocks.register("checkInventoryDelegate", new CheckInventoryDelegate());
@RegisterExtension @Order(2)
static ProcessEngineExtension engine = ProcessEngineExtension.builder().build();
@AfterEach void resetMocks() { Mocks.reset(); }
```

<a id="6-hop-2-operaton-2x--spring-boot-4"></a>

## 6. Operaton 2.x and Spring Boot 4

Spring Boot 4 sources are already on Spring Boot 4, JUnit 6, Testcontainers 2 and Jackson 3 for Spring; for them the
rows marked "3.5 path" were done before the migration. The Spring Boot 3.5 path meets them in Hop 2.

| Symptom | Fix |
|---|---|
| `could not find class [org.springframework.boot.jersey.autoconfigure.JerseyAutoConfiguration]` / `Failed to generate bean name for imported class '…OperatonBpmRestJerseyAutoConfiguration'` | Operaton 2.x requires Spring Boot 4: move parent and Operaton in the **same** commit (3.5 path: `migrate.sh --hop 2`) |
| `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper` | Spin/engine/REST stay on Jackson 2: restore `com.fasterxml.jackson.*` imports in `DataFormatConfigurator`s and code calling `JacksonJsonDataFormat#getObjectMapper()`; re-add `registerModule(new JavaTimeModule())` and removed `disable(…)` lines; restore `com.fasterxml.jackson.datatype:jackson-datatype-jsr310`. Spring Boot 4 sources with the Camunda Jackson 3 opt-in: rewrite that code to Jackson 2 (§8) |
| Spin dates as arrays/timestamps, unknown-property failures (compiles fine) | the Jackson 3 rewrite (3.5 path) deleted configurator lines: same fix; keep a test that asserts a setting only your configurator applies (e.g. `FAIL_ON_UNKNOWN_PROPERTIES` off), or check for `SPIN-01011 Discovered Spin data format configurator: class <yours>` (references/plugins-and-exporters.md §8) |
| own Spring beans | Jackson 3: inject `tools.jackson.databind.ObjectMapper`, catch `tools.jackson.core.JacksonException`. 3.5 path: classes using both Operaton types and Spring's mapper were skipped by the recipe: migrate the Spring side by hand or split the class |
| `@MockBean`/`@SpyBean` cannot be resolved (3.5 path) | `@MockitoBean`/`@MockitoSpyBean` (`org.springframework.test.context.bean.override.mockito`); not allowed in `@Configuration` classes → `@MockitoBean(types = …)` on the test class |
| MockMvc / `TestRestTemplate` / `WebTestClient` not injected (3.5 path) | `@AutoConfigureMockMvc` (etc.); add technology test starters, e.g. `spring-boot-starter-webmvc-test`, `spring-boot-starter-security-test` for `@WithMockUser` |
| `org.testcontainers:postgresql` / `junit-jupiter` not found (3.5 path) | `org.testcontainers:testcontainers-postgresql`, `testcontainers-junit-jupiter`; class `org.testcontainers.postgresql.PostgreSQLContainer` (check catalogs, parent POMs) |
| JUnit 4 tests (Vintage engine deprecated in JUnit 6) | convert to Jupiter (separate commit) |
| `method does not override or implement a method from a supertype` on `getFeatureDescriptors` | Jakarta EL 6.0 removed it: delete the method |
| `required a bean of type 'org.springframework.kafka.core.KafkaTemplate' that could not be found` (3.5 path) | depend on `org.springframework.boot:spring-boot-starter-kafka` (also in parent POMs/shared BOMs) |
| licence scanner flags Liquibase (3.5 path) | Spring Boot 4 manages Liquibase 5 (FSL licence): get it reviewed or pin consciously; record the decision |
| Flyway auto-configuration missing (3.5 path) | `spring-boot-starter-flyway` instead of plain `flyway-core` |
| other relocated Spring Boot classes fail to compile (3.5 path) | e.g. `org.springframework.boot.autoconfigure.jersey.*` → `org.springframework.boot.jersey.autoconfigure.*`; follow the Spring Boot 4.0 migration guide |
| 2.1 internal API: `HistoryLevelSetupCommand`, `ExceptionHandlerHelper.INSTANCE`/`getInstance()`, `StartProcessVariableScope.getInstance()`, `VariableInstanceEntityFactory.INSTANCE`, `SimpleVariableInstanceFactory.INSTANCE` | `new DefaultHistoryLevelSetupCommand()`; static `dbCreateHistoryLevel(…)` is in `HistoryLevelUtils`; `ExceptionHandlerHelper` methods are static; the other singletons were removed |
| `LegacyCamundaConfigGuard` does not compile / never fires | Spring Boot 4 SPI (the snippet as shipped): implement `org.springframework.boot.EnvironmentPostProcessor`, factories key `org.springframework.boot.EnvironmentPostProcessor` (3.5 path, Hop 1: `org.springframework.boot.env.…`; references/configuration.md §10) |
| deprecation warning: `org.springframework.boot.env.EnvironmentPostProcessor` deprecated for removal (any own `EnvironmentPostProcessor`) | the Spring Boot 3 SPI still works on 4.0; switch interface **and** `spring.factories` key to `org.springframework.boot.EnvironmentPostProcessor` (3.5 path: in Hop 2; same method signature) |
| Groovy scripts fail only after Hop 2 (3.5 path) | Groovy 4 → 5: run every script path in a test, fix incompatibilities |
| DMN results differ (e.g. `null` instead of `false`) | newer FEEL-Scala semantics (Camunda 7.24.0 ships feel-engine 1.19.3, Operaton 2.1.5 1.21.1; check your EE patch with `mvn dependency:tree -Dincludes=org.camunda.feel`): regression-test decision tables; on 2.2 check Scala libs (`mvn dependency:tree -Dincludes=org.scala-lang`) |
| pods restart on DB blips | 2.1+ `processEngine` health is DOWN on DB failure: readiness group only (D13) |
| `JAXBContext implementation could not be found. WADL feature is disabled.` | harmless |

## 7. Scanner rule → fix (`verify-leftovers.sh`)

| Rule | Severity | Fix |
|---|---|---|
| `CAMUNDA_PKG` | MUST | §2 (literals, SPI), §4 (models), logging (§3); never for `org.camunda.feel` |
| `CAMUNDA_PROPERTY`, `CAMUNDA_ENV`, `HEALTH_CAMUNDA` | MUST | rename keys / env vars (references/configuration.md) |
| `CAMUNDA_CFG_XML` | MUST | §5 rename |
| `WEBJARS_CAMUNDA` | MUST | §3 overlays |
| `LIQUIBASE_CAMUNDA` | MUST | references/database.md |
| `STRICT_FORM_PARSING`, `CAMUNDA_BEAN_NAME`, `KEYCLOAK_CAMUNDA_KEY` | MUST | §3, §2 |
| `DESCRIPTOR_NAMESPACE`, `ACTIVITI_NAMESPACE` | MUST | §3 `processes.xml`; §4 activiti |
| `CAMUNDA_ADMIN` | WARN | data, D5; test literals §5 |
| `WEBAPP_PATH` | WARN | decision D6; accept in the ignore file if `/camunda` is kept |
| `CAMUNDA_FORMS_KEY`, `CAMUNDA_FORM_REF` | WARN | D4; REST clients read `operatonFormRef` |
| `CAMUNDA_COMMUNITY` | WARN | §1 community libraries |
| `CAMUNDA_NAMESPACE`, `MODELER_METADATA`, `CAMUNDA_FEEL` | INFO | keep (D3; FEEL is correct) |
| `STARTER_4`, `JACKSON3_ARTIFACT`, `ENGINE_SPRING_6`, `EE_ARTIFACT` | MUST | §8 (build files and XML only) |
| `EE_VERSION` | MUST / WARN | §8: MUST = a `7.24.N-ee` `<version>`/coordinate in a build file or a referenced `-ee` property; WARN = an unused property or a value outside the build (Docker tags, CI) |
| `EE_QUERY_EXPRESSION_ALLOWLIST`, `EE_AUTH_RESOURCE_VALIDATION` | MUST | §8 and references/identity-and-admin.md §10 |
| `EE_LICENSE` | MUST / WARN | §8: MUST = `.setLicenseKey(` / `.getLicenseKey(` / `.deleteLicenseKey(` in code; WARN = license-file keys, `*_BPM_LICENSE_FILE`, `camunda-license.txt`, license key text |
| `EE_REPOSITORY` | WARN | §8: remove after the recipe run (D17); not an accepted leftover |

In POMs the generic `CAMUNDA_PKG` finding for an `org.camunda` `<groupId>` line is dropped when a specific rule fired in
the same block. The top-level `.mvn/*.xml` and `.mvn/maven.config` are scanned (EE repository).

Skipped by default (one INFO line `skipped N helper files / migration/ pack`): files containing the marker
`operaton-migration-helper` (the bundled helpers, which hold `camunda` literals on purpose; keep the marker when you copy
them) and the project's `migration/` folder (cut-over pack, SQL copies). `--strict` scans those too and includes comments.

Accepted leftovers go into `<project>/.operaton-migration-ignore`, one rule per line, **each with a reason**:
`<RULE|*>  <path-glob>  ["<extended regex>"]  # reason` (e.g. `WEBAPP_PATH  src/main/resources/application.yaml  # D6`;
`CAMUNDA_PKG  src/test/java/**/OrderFulfillmentProcessTest.java  "org\.camunda\.bpm\.engine\."  # D9 canary, eventClass frozen until sign-off`).
Copy every accepted entry into the report.

## 8. Camunda EE and Spring Boot 4 sources (decision D17)

Every Spring Boot 4 project is Camunda EE (`7.24.N-ee`). `MigrateSpringBoot4App` maps the artifacts; the code, settings
and data below need you. The `assess.sh` findings named in the table are MUST unless marked SHOULD.

Artifact mapping (Operaton has no `-4` infix and no `-jackson3` artifacts; no `<version>`, `operaton-bom` manages it):

| Camunda 7.24 EE | Operaton 2.x |
|---|---|
| `org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4[-x]` (`-rest`, `-webapp`, `-webapp-core`, `-security`, `-external-task-client`) | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[-x]` |
| `camunda-bpm-spring-boot-starter-4-test` | `operaton-bpm-spring-boot-starter-test-junit5` (D11) |
| `camunda-bpm-spring-boot-starter-4-webapp-ee`, `camunda-bpm-spring-boot-starter-webapp-ee` | `operaton-bpm-spring-boot-starter-webapp` (EE features are lost, D17) |
| `org.camunda.bpm.webapp:camunda-webapp-webjar-ee` | `org.operaton.bpm.webapp:operaton-webapp-webjar` |
| `camunda-spin-dataformat-json-jackson3` / `camunda-spin-dataformat-all-jackson3` | `org.operaton.spin:operaton-spin-dataformat-json-jackson` / `operaton-spin-dataformat-all` |
| `camunda-bpm-spring-boot-starter-4-rest-jackson3` | `operaton-bpm-spring-boot-starter-rest` |
| `camunda-engine-rest(-core)-jakarta-jackson3` | `org.operaton.bpm:operaton-engine-rest(-core)` |
| `camunda-external-task-client-jackson3` | `operaton-external-task-client` |
| `camunda-engine-spring-6` | `org.operaton.bpm:operaton-engine-spring` |
| `org.camunda.bpm:camunda-bom:7.24.N-ee` | `org.operaton.bpm:operaton-bom:${operaton.version}` |

| Symptom / finding | Fix |
|---|---|
| `STARTER_4`: `camunda-bpm-spring-boot-starter-4*` (or an `operaton-…-4`) left in a build file | map it (table above), no `<version>`. Left as is, the build fails (no managed version, EE repository) |
| `JACKSON3_ARTIFACT`; assess: "Jackson 3 opt-in (`-jackson3` artifacts, 7.24.16-ee) or `tools.jackson` code next to Spin / engine REST / external task client" | map the artifacts (table above); rewrite Spin / REST / client code from `tools.jackson.*` to `com.fasterxml.jackson.*` (Operaton 2.x is Jackson 2 only there; it does not compile otherwise). Application code outside the engine may stay on Jackson 3 |
| assess SHOULD: Spin `DataFormatConfigurator` | keep it on Jackson 2 (`com.fasterxml.jackson`): `MigrateSpringBoot4App` renames it and runs no Jackson 3 step; never run `--hop 2` or the stock `UpgradeSpringBoot_4_0` recipe on it (they rewrite it to `tools.jackson` and drop module registrations) |
| `EE_ARTIFACT`: other `camunda-*-ee` artifacts (`-webapp-ee`, `camunda-webapp-webjar-ee`) | map them to the CE artifacts (table above); assess SHOULD "EE webapps": the EE Cockpit features (history view, heatmap, instance modification, migration UI, batches, reports) disappear without a build error: inventory their use and test a replacement for each (D17) |
| `EE_VERSION`: `7.24.N-ee` as `<version>` / coordinate, or a referenced `-ee` property | let `operaton-bom` manage the version (`${operaton.version}`), delete `-ee` properties; the build needs the EE repository or fails otherwise. WARN outside the build (Docker image tags, CI): update or remove |
| `ENGINE_SPRING_6` | `org.operaton.bpm:operaton-engine-spring` |
| `EE_QUERY_EXPRESSION_ALLOWLIST`: `queryExpressionAllowList*`, `allowedExpression(Functions\|Beans\|Properties)InQueries`, `QueryExpressionValidator` (any spelling) | delete them: as generic properties they **fail the engine start** (unknown property), the Java calls do not compile. Then mitigate (Camunda security notice 157, expression injection via stored filters): generic property `enable-expressions-in-stored-queries: false` unless filters need expressions such as `${currentUser()}`, keep `enable-expressions-in-adhoc-queries` false, restrict who may create/update filters (references/identity-and-admin.md §10) |
| `EE_AUTH_RESOURCE_VALIDATION`: `validate-auth-resource-id-exists` / `validateAuthResourceIdExists` (any spelling, also under `operaton.bpm`) | delete it: as generic property it fails the engine start, `setValidateAuthResourceIdExists` does not compile, `operaton.bpm.authorization.validate-auth-resource-id-exists` is ignored silently. Validate user and group ids in the code that creates authorizations |
| assess MUST: datasource autocommit check (7.24.3-ee) gone | keep `spring.datasource.hikari.auto-commit: false` |
| `EE_LICENSE` | delete `camunda.bpm.license-file` / `operaton.bpm.license-file` (the recipe deletes the Camunda key), `*_BPM_LICENSE_FILE`, `camunda-license.txt` and license mounts/secrets; delete `ManagementService` `set/get/deleteLicenseKey` calls (compile error, MUST). The key stored in the database (`ACT_GE_BYTEARRAY` `camunda-license-key`, `ACT_GE_PROPERTY` `camunda-license-key-id`) is inert: keep it for rollback |
| `EE_REPOSITORY`: `artifacts.camunda.com/artifactory/private` or `…/camunda-bpm-ee`, server id `camunda-bpm-nexus-ee` (POM, `.mvn/settings.xml`, CI) | only the recipe run needed it: remove the repository, its `<server>` credentials and CI secrets from the Operaton build, and prove that the build resolves from Maven Central alone (e.g. `-s` a settings file with `<settings/>` and a fresh `-Dmaven.repo.local`); revoke the credentials only after the rollback window |
| assess SHOULD: Spring Boot 4.1 | the matching Operaton line is **2.2.x** (GA scheduled for 2026-10-23): rehearse with `--target 2.2.0-RC1` (pre-release, never production), go live with `--target 2.2.0`; `migrate.sh`'s default 2.1.5 is built with Spring Boot 4.0.8 (unsupported on 4.1), and the recipe never downgrades Spring Boot (D1) |
| assess SHOULD: Spring Boot 4.2 | no Operaton release is built with it yet (2.1 = Spring Boot 4.0, 2.2 = 4.1): migrate on Spring Boot 4.1, or wait for the matching Operaton line (D1) |
| Gradle: `-4` / `-ee` coordinates in `gradle/libs.versions.toml` | catalogs are never migrated: map them by hand with the table above |
