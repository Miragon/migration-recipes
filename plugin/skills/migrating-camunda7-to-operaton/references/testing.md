# Testing and verification

Load this for the baseline (step 3), test fixes after the recipe run (step 4; Spring Boot 3.5 path: after each hop,
step 5), and the verification step (step 6). Most migration breakage is silent (scripts compile at runtime, unrenamed
keys are ignored, payload class names change), so tests must *execute* those paths. Guide chapter: https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/10-testing.md

## Contents

1. Baseline on Camunda 7.24 (before any change)
2. Test dependencies
3. `operaton.cfg.xml` and the guard test
4. `ProcessEngineExtension`, assert, Mocks, Spring Boot test properties
5. Community test libraries
6. The Spring Boot 4 test platform
7. Tests that fail on purpose (canaries and guards)
8. Plugin and exporter tests
9. Smoke test: `scripts/smoke-test.sh`
10. Local cut-over simulation
11. Rehearsal on a production copy (for humans)
12. Done criteria and evidence

## 1. Baseline on Camunda 7.24 (before any change)

- Run `mvn -B verify` on the **unchanged** project (log and wait; Camunda EE builds need the EE repository credentials);
  record test count, failures and duration in the report. Red baseline: report it and agree on how to proceed. Never
  "fix" anything by deleting or disabling tests. **Keep tests constant across the migration** (Spring Boot 3.5 path:
  across both hops): only imports and coordinates change; a changed expectation is a behaviour change and needs a
  decision in the report.
- While still on Camunda: move legacy test coordinates to the official ones the recipe maps:
  `org.camunda.bpm.extension:camunda-bpm-junit5` → `org.camunda.bpm:camunda-bpm-junit5`;
  `org.camunda.bpm.assert:*` / `org.camunda.bpm.extension:camunda-bpm-assert*` → `org.camunda.bpm:camunda-bpm-assert`.
- Gap check (SHOULD add tests where missing, against the public API): every **script** (tasks, listeners, I/O mappings,
  conditions, external files), every **form key** resolution, every **DMN** (incl. null/missing inputs), **timers** (execute the
  job), **async/retries/incidents**, **external tasks** (fetch-and-lock, complete, `handleFailure`, `handleBpmnError`),
  **message/signal correlation**, **event-bridge listeners**, **plugin/SPI registrations** (counts and types; Spin
  configurators, section 8 item 6), every persisted
  **variable type**, **admin-only operations** with authorization enabled.
- Golden master per important path: record activity sequence, variables and end state on 7.24, commit the files, keep the
  test unchanged through the migration (both hops on the Spring Boot 3.5 path). Plain text on purpose (independent of
  the Jackson 2 → 3 change):

```java
private List<String> fingerprint(String pid) {           // compare with src/test/resources/golden/<name>.txt
  List<String> lines = new ArrayList<>();                // write the file once on 7.24 with -Dgolden.update=true
  historyService().createHistoricActivityInstanceQuery().processInstanceId(pid)
      .orderByHistoricActivityInstanceStartTime().asc().orderPartiallyByOccurrence().asc().list()
      .forEach(a -> lines.add("activity " + a.getActivityId() + " " + a.getActivityType()));
  historyService().createHistoricVariableInstanceQuery().processInstanceId(pid).orderByVariableName().asc().list()
      .stream().filter(v -> !VOLATILE.contains(v.getName()))   // generated ids, timestamps
      .forEach(v -> lines.add("variable " + v.getName() + " " + v.getTypeName() + " " + v.getValue()));
  lines.add("state " + historyService().createHistoricProcessInstanceQuery().processInstanceId(pid).singleResult().getState());
  return lines;
}
```

- DMN golden master before the migration (newer FEEL engine, references/models-and-scripts.md §9; Spring Boot 3.5 path: before Hop 2):
  `@ParameterizedTest` + `@CsvSource` per decision table
  with `decisionService.evaluateDecisionByKey(key).variables(…).evaluate().getSingleEntry()`, including null/missing inputs.
- Contract tests for what leaves the engine: exported event envelope vs. a checked-in JSON file; REST fields clients read
  (`GET /task/{id}/form`: `camundaFormRef` → `operatonFormRef`); logger names used by alerts.
- SHOULD: one `@SpringBootTest` per critical process on the production DB type via Testcontainers (`@ServiceConnection`,
  `spring-boot-testcontainers`), job executor off. Needs Docker in CI.

<a id="2-test-dependencies-per-hop"></a>

## 2. Test dependencies

The engine test helpers (`@Deployment`, `ProcessEngineExtension`, `ProcessEngineRule`) are **not** in the main
`operaton-engine` jar. All coordinates below are managed by `operaton-bom` (omit `<version>`).

| Purpose | Operaton |
|---|---|
| Spring Boot, JUnit 5/6 (**D11 default**; also the target of Camunda's `camunda-bpm-spring-boot-starter-4-test`) | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-test-junit5` (brings `operaton-bpm-assert` and `operaton-engine:junit6`) |
| Plain engine modules | `org.operaton.bpm:operaton-engine` classifier `junit5` (or `junit6` on 2.x, identical content) + `org.operaton.bpm:operaton-bpm-assert` + `h2` |
| JUnit 4 (`ProcessEngineRule`) | classifier `junit4`, or `operaton-bpm-spring-boot-starter-test` (brings Vintage) |
| Assertions | `org.operaton.bpm:operaton-bpm-assert`, static import `org.operaton.bpm.engine.test.assertions.bpmn.BpmnAwareTests.*` (same API) |
| Mocks | `org.operaton.bpm.engine.impl.mock.Mocks`, `MockExpressionManager` (main jar) |
| DMN unit tests | `DmnEngineExtension` / `DmnEngineRule` in `org.operaton.bpm.dmn:operaton-engine-dmn` |
| Spring Boot test helper | `org.operaton.bpm.spring.boot.starter.test.helper.StandaloneInMemoryTestConfiguration` |
| **Never** | `org.operaton.bpm:operaton-bpm-junit5` (empty on 1.1.x, deprecated shim on 2.x) |

What the recipes do: the official recipe maps `camunda-bpm-junit5` → `operaton-bpm-junit5` and its rule to add the right
test jar never fires; `starterpack.operaton.Boot4PreFixes` maps `-4-test` → `operaton-bpm-spring-boot-starter-test`
(Spring Boot 4 path); `starterpack.operaton.PostFixes` removes `operaton-bpm-junit5`, adds the test starter when
`org.junit.jupiter.api.*` is used, removes `operaton-bpm-spring-boot-starter-test` unless JUnit 4 is used, and renames
`camunda.cfg.xml`; `PreFixes` relocates `Mocks` and renames the `"camunda.cfg.xml"` literal. **Untouched:**
`org.camunda.community.*` imports and string literals in assertions (`"camunda-admin"`, `"org.camunda.bpm.engine."`,
form keys). Check alignment: `mvn dependency:tree | grep org.operaton` must show one version.

## 3. `operaton.cfg.xml` and the guard test

**`camunda.cfg.xml` is never read.** Operaton 1.0.x fails loudly; **1.1.0+ `ProcessEngineExtension` silently builds a
default in-memory engine** (history `audit`, no `MockExpressionManager`, no plugins, TTL enforced). Symptoms: unresolved
`Mocks`, "History Time To Live cannot be null", Spin failures, skipped history assertions. Rename the file, rename the
classes inside, and add a guard:

```xml
<!-- src/test/resources/operaton.cfg.xml -->
<bean id="processEngineConfiguration" class="org.operaton.bpm.engine.impl.cfg.StandaloneInMemProcessEngineConfiguration">
  <property name="history" value="full" />
  <property name="databaseSchemaUpdate" value="true" />
  <property name="jobExecutorActivate" value="false" />
  <property name="expressionManager"><bean class="org.operaton.bpm.engine.impl.mock.MockExpressionManager" /></property>
  <property name="processEnginePlugins"><list>
    <bean class="org.operaton.spin.plugin.impl.SpinProcessEnginePlugin" />   <!-- only if Spin is used -->
  </list></property>
</bean>
```

```java
@Test
void usesOperatonCfgXml(ProcessEngine processEngine) {     // class with @RegisterExtension ProcessEngineExtension
  assertThat(getClass().getClassLoader().getResource("operaton.cfg.xml")).isNotNull();
  assertThat(getClass().getClassLoader().getResource("camunda.cfg.xml")).isNull();
  ProcessEngineConfigurationImpl cfg = (ProcessEngineConfigurationImpl) processEngine.getProcessEngineConfiguration();
  assertThat(cfg.getHistory()).isEqualTo(ProcessEngineConfiguration.HISTORY_FULL);
  assertThat(cfg.getExpressionManager()).isInstanceOf(MockExpressionManager.class);
}
```

## 4. `ProcessEngineExtension`, assert, Mocks, Spring Boot test properties

- `@Deployment` resources are now deployed **before** the test class's `@BeforeEach` (Camunda: after). Mocks needed at
  deployment time (e.g. bean expressions in timer start events, error `Unknown property used in expression`) must be
  registered earlier: an `@RegisterExtension @Order(1) static BeforeEachCallback` before the `@Order(2)` engine extension, or
  `@BeforeAll`; `Mocks.reset()` in `@AfterEach`.
- The builder gained `configurator(cfg -> …)`, `closeEngineAfterAllTests()`, `randomEngineName()` (configure without XML).
- Spring tests: call `BpmnAwareTests.init(processEngine)` in `@BeforeEach`; prefer real beans or `@MockitoBean` over `Mocks`.
- **Rename test properties in YAML and in Java strings** (`@SpringBootTest(properties = …)`, `@TestPropertySource`). A missed
  `camunda.bpm.job-execution.enabled: false` starts the job executor in tests: flaky timer/async tests, no clear error.
- Several cached contexts: `spring.datasource.generate-unique-name: true`, `operaton.bpm.generate-unique-process-engine-name: true`.
- Error `Group has an invalid id: 'operaton-admin' is not a valid resource identifier` in every Spring test: a custom
  `groupResourceWhitelistPattern` still contains `camunda-admin` (`PostFixes` fixes it in Spring config files).
- JUnit 4 tests (Vintage is deprecated in JUnit 6): convert them (`org.openrewrite.java.testing.junit5.JUnit4to5Migration`)
  in a separate commit, never in the migration commit. Spring Boot 3.5 path: keep the JUnit 4 starter in Hop 1 and
  convert by Hop 2 at the latest.

## 5. Community test libraries

Versions: references/versions.md. Pin them and import `operaton-bom` (forks pull Operaton artifacts at compile scope).

| Camunda 7 library | Operaton option |
|---|---|
| `camunda-process-test-coverage-*` (`org.camunda.community.process_test_coverage`) | fork `io.github.ronalders:operaton-process-test-coverage-{junit5,starter,spring-test}`, package `org.operaton.community.process_test_coverage.*`; change artifact **and imports by hand**; no JUnit 4 module |
| Scenario runner `camunda-platform-scenario-runner` | fork `io.github.ronalders:operaton-platform-scenario-runner`, package `org.operaton.bpm.scenario` (matches the recipe's rename) |
| `camunda-platform-7-mockito` | unpublished fork only: replace with `Mocks` + Mockito or `@MockitoBean` |
| `camunda-bpm-data` | unpublished fork only: build it into the repo if heavily used |
| `bpmn-driven-testing`, `camunda-bpm-jgiven` | no Operaton support: rewrite with `BpmnAwareTests`/scenario runner, or fork + recipe |

Compare the coverage report per process with the 7.24 baseline: a drop means a path stopped being exercised. The
Operaton docs link `operaton-bpm-assert-scenario` / `operaton-bpm-process-test-coverage` repositories that return 404.

<a id="6-hop-2-the-test-platform-changes"></a>

## 6. The Spring Boot 4 test platform

Spring Boot 4 sources already made these changes while upgrading Camunda; check only that Spin-related tests stay on
Jackson 2 (code written for Camunda's `-jackson3` opt-in moves back). The Spring Boot 3.5 path meets them in Hop 2:

| Change (Spring Boot 4) | Do | Covered by `starterpack.operaton.UpgradeToOperaton2` (Hop 2) |
|---|---|---|
| JUnit Jupiter 6; Vintage deprecated | nothing for Jupiter tests; finish JUnit 4 conversion | version via BOM |
| `@MockBean`/`@SpyBean` removed | `@MockitoBean`/`@MockitoSpyBean` (`org.springframework.test.context.bean.override.mockito`); not in `@Configuration` classes | yes |
| MockMvc no longer implied by `@SpringBootTest` | `@AutoConfigureMockMvc`; technology test starters (`spring-boot-starter-webmvc-test`, `spring-boot-starter-security-test`) | yes, review |
| Testcontainers 2 | `org.testcontainers:testcontainers-postgresql`, `testcontainers-junit-jupiter`; `org.testcontainers.postgresql.PostgreSQLContainer` | yes |
| Jackson 3 for application code | tests building `ObjectMapper`s for Spin stay on `com.fasterxml.jackson` | Jackson step skips Operaton-typed code |

Re-run golden masters, DMN golden masters and every script test after the migration (Spring Boot 3.5 path: after Hop 2;
Groovy 5, GraalJS changes).

## 7. Tests that fail on purpose (canaries and guards)

| Test | Fails when | Rule |
|---|---|---|
| **Exporter class-name canary** (legacy example: `eventClass` starts with `org.camunda.bpm.engine.`) | the rename reaches an exported payload (`org.operaton.bpm.engine.impl.history.event.…`) | D9 default: keep it **unchanged** and freeze `eventClass` to the Camunda value in the v2 envelope (references/plugins-and-exporters.md §6); flip only after consumer sign-off, recorded as a manual fix. Add a contract test on the v2 envelope |
| **Admin canary** (test expecting the admin group, e.g. `AdminAuthorizationInitializerTest`) | expectation still `camunda-admin` | expect `operaton-admin` (`Groups.OPERATON_ADMIN`); data migration is separate (D5) |
| Form-key expectation (`hasFormKey("camunda-forms:…")`) | D4 changed the key | update per D4, in the same commit as the model change (`formRef`: pre-migration release on 7.24, SKILL step 3b) |
| `operaton.cfg.xml` guard (section 3) | default engine silently used | keep permanently |
| Legacy config guard (`assets/snippets/LegacyCamundaConfigGuard.java`) | `camunda.bpm.*`, `CAMUNDA_BPM_*`, `management.health.camunda.*` reach the app | keep until all environments are clean |
| Model lint (below) | a model script references a renamed package | keep permanently |
| Setup page closed (`smoke-test.sh`) | nobody in `operaton-admin` on the target DB | every environment switch |

Admin capability test (needs `authorization.enabled: true` in the test profile; protects code, not the data problem of an
existing DB):

```java
@Test
void configuredAdminCanStillDoAdminThings() {
  List<String> groups = identityService.createGroupQuery().groupMember("demo").list().stream().map(Group::getId).toList();
  identityService.setAuthentication("demo", groups);
  try { assertThatCode(() -> managementService.getProperties()).doesNotThrowAnyException(); }
  finally { identityService.clearAuthentication(); }
}
```

Model lint (repository models; deployed definitions: section 11):

```java
static final Pattern RENAMED = Pattern.compile("org\\.camunda\\.(bpm|spin|connect|commons)\\b");
@ParameterizedTest @MethodSource("bpmnFiles")          // Files.walk(Path.of("src/main/resources")) filtered on ".bpmn"
void scriptsDoNotReferenceRenamedPackages(Path file) {
  BpmnModelInstance model = Bpmn.readModelFromFile(file.toFile());
  Stream.concat(model.getModelElementsByType(ScriptTask.class).stream().filter(t -> t.getScript() != null)
                    .map(t -> t.getScript().getTextContent()),
                model.getModelElementsByType(OperatonScript.class).stream().map(OperatonScript::getTextContent))
      .forEach(script -> assertThat(RENAMED.matcher(script).find()).as("%s references org.camunda", file).isFalse());
}
```

## 8. Plugin and exporter tests

Start from the bundled tests in `assets/snippets/test/` (from the migrated example: package `com.example.orders.*`,
Operaton 2.x / Spring Boot 4). Copy each next to its helper, change the `package` line, and keep it in the build: the
helpers use internal API without a compatibility promise, so an upgrade must fail the build, not the cut-over.

| Bundled test | Kind | Adapt |
|---|---|---|
| `AdminGroupMigrationPluginTest` | plain engine on H2 in-memory, no Spring context: seeds a Camunda-era `camunda-admin`, reopens the DB with the plugin; mirrored members/authorizations, idempotency, merge, empty-group WARN, fresh DB, disabled | package only (uses logback's `ListAppender`, present with the Spring Boot starters) |
| `LegacyCamundaConfigGuardTest` | key detection on a hand-built environment, plus real `SpringApplication` starts (empty `@Configuration`, `WebApplicationType.NONE`) that prove the `spring.factories` registration | package; the property prefix if you renamed it. Spring Boot 3.5 path, Hop 1: the test is unchanged, the guard class and factories key use the Spring Boot 3 SPI (references/configuration.md §10) |
| `ExportingHistoryEventHandlerTest` | `@SpringBootTest`: rollback, after-commit, exactly-once, failing publisher | extends the example's `AbstractProcessEngineTest` (`@SpringBootTest` + `BpmnAwareTests.init(processEngine)`) and autowires its `InMemoryEventPublisher` (an `EventPublisher` `@Component` collecting events, with `eventsFor(processInstanceId)`); neither is bundled: use the project's test base class and a small collecting test double. Replace process key `order-fulfillment`, its start variables and the activity id `StartEvent_OrderReceived`. With the D9 v2 envelope filter on `entityType`, not `eventClass` |

Non-obvious engine-test details (they matter whenever a test opens the same database with a second engine):
- `StandaloneInMemProcessEngineConfiguration` defaults to `databaseSchemaUpdate = "create-drop"`: closing the seeding
  engine drops the schema. Use `setDatabaseSchemaUpdate("true")` and an H2 URL with `DB_CLOSE_DELAY=-1`
  (`jdbc:h2:mem:<unique>;DB_CLOSE_DELAY=-1`) so the next engine reopens the seeded database.
- Unique names: `setProcessEngineName("<test>-" + UUID.randomUUID())` and a unique in-memory DB per test. Engines register
  by name in the static `ProcessEngines` registry; equal names across tests replace each other. Close engines in `@AfterEach`.
- `setJobExecutorActivate(false)` and `setDbMetricsReporterActivate(false)` keep the test deterministic.
- Seeding Camunda-era data needs Camunda's whitelist on the seeding engine:
  `setGroupResourceWhitelistPattern("[a-zA-Z0-9]+|camunda-admin")` (Operaton's default rejects `camunda-admin`).

Tests to have (the bundled ones cover items 1 and 3 for the example's helpers):

1. **Plain-engine test per plugin** (no starter defaults; catches immutable lists):
   `new StandaloneInMemProcessEngineConfiguration()` + `setJdbcUrl("jdbc:h2:mem:plain-" + UUID.randomUUID() + ";DB_CLOSE_DELAY=-1")` +
   unique engine name + `getProcessEnginePlugins().add(new HistoryExportPlugin(event -> { }))` + `buildProcessEngine()`, then `close()`.
2. **Registration test** (counts and types): `Collections.frequency(cfg.getCustomHistoryEventHandlers(),
   plugin.exportingHandler()) == 1`, `isEnableDefaultDbHistoryEventHandler()`, `getIncidentHandler("failedJob")` type,
   custom `FailedJobCommandFactory` and identity provider factory types.
3. **Rollback and commit tests** (the engine joins a surrounding Spring transaction):

```java
@Test
void rolledBackTransactionPublishesNoEvents() {
  AtomicReference<String> pid = new AtomicReference<>();
  new TransactionTemplate(transactionManager).executeWithoutResult(status -> {
    pid.set(runtimeService().startProcessInstanceByKey("order-fulfillment", startVariables).getId());   // a valid start
    status.setRollbackOnly();
  });
  assertThat(historyService().createHistoricProcessInstanceQuery().processInstanceId(pid.get()).count()).isZero();
  assertThat(eventPublisher.eventsFor(pid.get())).isEmpty();      // in-transaction exporters fail: ghost events
}
```

   Commit test: inside the template, nothing is published yet; after it, events exist. Exactly-once: the process-instance
   `start` event appears once. Publisher failure: a throwing publisher must not reach the caller. Reference implementation:
   `assets/snippets/test/ExportingHistoryEventHandlerTest.java` (chapter 06,
   [Testing plugins and exporters](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/06-engine-plugins-and-history-exporters.md#14-testing-plugins-and-exporters)).
4. **Envelope contract test** against a checked-in JSON file; no engine class name outside a deliberate field (the frozen
   `eventClass` of the D9 v2 envelope).
5. Consumers: test with recorded payloads from **both** engines (dual-read).
6. **Spin configurator active**: assert a setting only **your** `DataFormatConfigurator` applies (e.g. JSON with an unknown
   property maps to your DTO because you disabled `FAIL_ON_UNKNOWN_PROPERTIES`), not an ISO `LocalDate` (the starter's JSR310
   configurator does that too); or check the log line `SPIN-01011 Discovered Spin data format configurator: class <yours>`.

## 9. Smoke test: `scripts/smoke-test.sh`

Read-only by default; works against Camunda 7 and Operaton; needs `bash` + `curl` (`jq` optional). Checks: `GET /version`
(warns, or FAILs with `--require-operaton`, if not Operaton), engine, definition/deployment counts (0 after a cut-over =
wrong/empty schema), incidents, jobs/external tasks without retries, webapp reachability at the path, **Admin setup page
closed** (GET without following redirects; never POSTs), actuator health if exposed.

```bash
bash "<skill-dir>/scripts/smoke-test.sh" --base-url http://localhost:8080 --webapp-path /camunda \
  --require-operaton --user demo --password demo
# REST-only app / token / custom health:  --no-webapp --header "Authorization: Bearer $TOKEN" --health-path /manage/health
# --write: deploy a tiny camunda: BPMN, start, complete, check history, delete (cascade).
#          Agents: only against a local throw-away engine. Humans: where the runbook says so (rehearsal copy, T0-12).
```

Other options: `--rest-path` (default `/engine-rest`), `--webapp-path auto` (probes `/operaton`, then `/camunda`; use the
D6 path explicitly), `--engine`, `--insecure`, `--timeout`. Exit codes: `0` no FAIL, `1` at least one FAIL, `2` usage error /
no curl. Paste the summary lines into the report's verification section. A bare 403 on the setup `POST` proves nothing (CSRF
filter); the GET-based check is the evidence.

## 10. Local cut-over simulation

Procedure (throw-away file DB, copies A/B, control run without the admin-group migration): references/identity-and-admin.md,
section 7. Use the same run as data evidence: before stopping the Camunda build, leave one instance waiting at a user task
(and, if models had broken scripts, one waiting at the async job before the script). On the migrated build, complete them
(`GET /task/{id}/form`, external task fetch-and-complete, history state `COMPLETED`). An old-version instance failing at a
fixed script is expected evidence for the in-flight remediation (references/models-and-scripts.md), not a test to "fix".
H2 compatibility is verified: a file DB written by H2 2.3.232 (Camunda 7.24 / Spring Boot 3.5.5) opened with H2 2.4.240
(Spring Boot 4.0.8): schema, identity, jobs and in-flight instances worked (skill run on a copy of the legacy example
on 2026-10-07, and the example's cut-over simulation). With other H2 versions, if the file does not open, report it; do not repair the file.

## 11. Rehearsal on a production copy (for humans)

Write it into the cut-over pack; never run it yourself. Fresh, isolated restore (no real mail, REST calls or topics):
1. Before: `00-preflight-checks.sql`, `20-find-legacy-references.sql` and the baseline SQL below; optionally the Camunda
   7.24 build + `smoke-test.sh` as reference.
2. Admin-group step (D5) on the copy.
3. First Operaton start with `operaton.bpm.database.schema-update: false`, `operaton.bpm.job-execution.enabled: false`, D6 path.
   Expected side effects: `operaton.installation.id` row, possibly a reconfigured `history-cleanup` job, new definition
   versions only for byte-changed resources.
4. `smoke-test.sh --require-operaton` (read-only); scan deployed resources; run report/UI history queries.
5. Old instances: per definition **and version**, complete tasks, correlate messages, `managementService.executeJob(id)`.
6. Job executor on: watch the catch-up (`job-successful`/`job-failed` metrics, new incident types, locks).
7. `smoke-test.sh --write` on the copy; re-run baseline SQL, `00-`, `20-`; explain every difference.
8. Rollback rehearsal: Camunda 7.24 build on the same copy before any Operaton-only artifact exists (D15).
9. Camunda EE sources (D17): open each stored filter that pre-flight P11 lists; with the mitigation
   `enable-expressions-in-stored-queries: false` they fail with `Expressions are forbidden in stored queries`, so
   rewrite them or keep expressions on (references/identity-and-admin.md §10). Walk through the EE Cockpit features
   operators used and check each replacement.

```sql
SELECT KEY_, max(VERSION_) AS latest, count(*) AS versions FROM ACT_RE_PROCDEF GROUP BY KEY_ ORDER BY KEY_;
SELECT count(*) AS process_instances FROM ACT_RU_EXECUTION WHERE ID_ = PROC_INST_ID_;
SELECT TYPE_, HANDLER_TYPE_, count(*), sum(CASE WHEN RETRIES_ = 0 THEN 1 ELSE 0 END) AS no_retries
  FROM ACT_RU_JOB GROUP BY TYPE_, HANDLER_TYPE_ ORDER BY 1, 2;
SELECT INCIDENT_TYPE_, count(*) FROM ACT_RU_INCIDENT GROUP BY INCIDENT_TYPE_;
SELECT TYPE_, count(*) FROM ACT_RU_VARIABLE GROUP BY TYPE_ ORDER BY 1;
```

Compare the copy before and after the Operaton start, never a copy with production. Deployed definitions that still
reference `org.camunda.*` (any database, via REST):

```bash
REST=http://localhost:8080/engine-rest
for d in $(curl -s "$REST/deployment" | jq -r '.[].id'); do
  for r in $(curl -s "$REST/deployment/$d/resources" | jq -r '.[] | select(.name | test("\\.(bpmn|bpmn20\\.xml|dmn|cmmn|groovy|js)$")) | .id'); do
    curl -s "$REST/deployment/$d/resources/$r/data" | grep -qE 'org\.camunda\.(bpm|spin|connect|commons)' && echo "deployment $d, resource $r"
  done
done
```

AI tooling (`operaton-mcp` and similar) is triage, not evidence. Released `operaton-mcp` npm versions up to 1.1.0 ignore
`OPERATON_GUARD`: never point any MCP server at production or a shared database; use a throw-away copy and a read-only
technical user (engine authorizations).

## 12. Done criteria and evidence

- [ ] Baseline recorded (`mvn -B verify` on 7.24: counts, duration); gaps in script/form/DMN/timer coverage closed or listed.
- [ ] After the recipe run: test starter added (`-4-test` mapped), `operaton-bpm-junit5` gone, `operaton.cfg.xml` + guard,
      `Mocks` relocated, test properties renamed, community libs swapped, one Operaton version in the tree, Spin tests on
      Jackson 2; `mvn -B clean verify` green with counts. Spring Boot 3.5 path: the same after Hop 1, then after Hop 2
      also `@MockitoBean`, `@AutoConfigureMockMvc`, Testcontainers 2; green with counts.
- [ ] Camunda EE sources: build green with Maven Central only (EE repository removed).
- [ ] Every flipped expectation (canaries, admin group, form keys) listed as a manual fix with its reason and owner.
- [ ] Helper tests from `assets/snippets/test/` adapted and green; exporter rollback/commit/exactly-once tests and model lint in the build.
- [ ] `smoke-test.sh --require-operaton` PASS on the locally booted app; setup page closed on a migrated DB (simulation).
- [ ] Rehearsal plan (section 11) in the cut-over pack; `verify-leftovers.sh` exit 0.
