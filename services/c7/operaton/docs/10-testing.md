# 10 · Testing

This chapter shows how to prove that the migration changes nothing you did not intend. Tests have two jobs here.
During the code change, they show that the migrated code behaves like the Camunda code. Before the cut-over, they
show that the migrated engine runs your real data. Developers need the first half from the start, while the
application still runs on Camunda 7.24; whoever runs the rehearsal needs the second half.

**In short**
- **Most breakage is invisible to the compiler**: scripts in models compile only when they run, and old
  configuration keys are silently ignored. So build the safety net (tests for behaviour no compiler checks) on
  **Camunda 7.24 first**, and keep the tests unchanged through the migration, apart from imports and coordinates.
  Every test that turns red then points at a real change.
- **On Spring Boot 4 your test platform stays as it is.** JUnit Jupiter 6 and the other Spring Boot 4 test changes
  are already in place, because your application runs on Spring Boot 4 today. The migration changes the engine test
  artifacts: Camunda's `camunda-bpm-spring-boot-starter-4-test` becomes
  `operaton-bpm-spring-boot-starter-test-junit5`.
- **The engine test helpers left the main jar**, so test code does not compile until you add them. Spring Boot
  modules need `operaton-bpm-spring-boot-starter-test-junit5`. Plain modules need `operaton-engine` with the
  classifier `junit5` or `junit6`. Never use `operaton-bpm-junit5` (empty on 1.x).
- **Rename `camunda.cfg.xml` to `operaton.cfg.xml`.** From 1.1, without it `ProcessEngineExtension` **silently** runs
  a default in-memory engine that has none of your settings, so your tests run against the wrong engine.
- **Some tests go red after the conversion on purpose**, because they pin data contracts such as the admin group
  name or exported class names. Change their expectation only with a decision.
- **A green build proves the code, not your data.** Verify on a production copy (a restored copy of the production
  database) with [`scripts/smoke-test.sh`](../scripts/smoke-test.sh).

## What to do

1. **On 7.24, move legacy test coordinates** (`org.camunda.bpm.extension:camunda-bpm-junit5`,
   `org.camunda.bpm.assert:*`) to `org.camunda.bpm:camunda-bpm-junit5` / `camunda-bpm-assert`. The recipes only map
   those; for the old JUnit 5 extension, the package rename would produce a package that does not exist.
2. **On 7.24, write characterization, golden-master and contract tests** ([below](#safety-net-on-724)), and commit
   the baselines, so that you have a record of today's behaviour.
3. **Let the script migrate the test stack.** `scripts/migrate.sh` swaps the [test dependencies](#test-dependencies)
   and renames `camunda.cfg.xml` and `camunda.bpm` test properties (YAML **and** Java string literals);
   [`verify-leftovers.sh`](../scripts/verify-leftovers.sh) finds what is left. Swap community libraries by hand,
   because the recipe leaves them alone.
4. **Check that `mvn dependency:tree | grep org.operaton` shows one version** (import `operaton-bom`). Community
   forks pull other Operaton versions, which causes `NoSuchMethodError` in tests.
5. **Treat every red test as a behaviour change that needs a decision**, not a quick fix of the expectation.
6. **Rehearse on a production copy** ([below](#production-copy-rehearsal)).

## Safety net on 7.24

Write these tests while you are still on Camunda 7.24, because only there do they record the behaviour you want to
keep. After the conversion, the same tests, changed only in imports and coordinates, show you what the migration
changed. If you have to change a test's expectation, that is a behaviour change.

- **Characterization tests** record what the process does today, not what the specification says. Make sure that
  everything resolved at runtime runs at least once: scripts (including listeners and IO mappings), form keys, DMN, timers,
  async retries, external tasks, correlation, Spring event listeners, persisted variable types, admin-only
  operations, plugin registrations (assert counts and types).
- **History fingerprint ("golden master"):** per key scenario, write activity sequence, final variables and end
  state as plain text on 7.24, commit it, and run it unchanged after the conversion. Any difference is a change you
  have to explain. Plain text keeps the file independent of Jackson: if you used Camunda's Jackson 3 artifacts, Spin
  and the REST API go back to Jackson 2 on Operaton.
- **Contracts:** pin exported event class names, REST fields (`operatonFormRef`, `/version`) and logger names, so
  that their change becomes a red build instead of an incident in another team. Keep snapshots of your REST
  responses, so that a change in the JSON shows up as a red test. Add one Testcontainers test on your production
  database type, because H2 tests do not catch database-specific problems.

## Test dependencies

In Operaton, the engine test helpers (`@Deployment`, `ProcessEngineExtension`, `ProcessEngineRule`) are no longer in
the main engine jar. The table shows where each Camunda 7.24 test artifact went:

| Purpose | Camunda 7.24 | Operaton |
|---|---|---|
| Spring Boot 4 test starter | `camunda-bpm-spring-boot-starter-4-test` | `operaton-bpm-spring-boot-starter-test-junit5`; with JUnit 4 tests also `operaton-bpm-spring-boot-starter-test` |
| Spring Boot, JUnit 5/6 | — | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-test-junit5` |
| Spring Boot, JUnit 4 | `camunda-bpm-spring-boot-starter-test` | `operaton-bpm-spring-boot-starter-test` |
| `ProcessEngineExtension` / `ProcessEngineRule` | `camunda-bpm-junit5` / `camunda-engine` | `org.operaton.bpm:operaton-engine`, classifier `junit5`, `junit6` / `junit4` |
| Assertions | `camunda-bpm-assert` | `org.operaton.bpm:operaton-bpm-assert` |
| `Mocks` | `org.camunda.bpm.engine.test.mock` | `org.operaton.bpm.engine.impl.mock` |
| DMN | `DmnEngineRule` | `operaton-engine-dmn` (`DmnEngineRule`, `DmnEngineExtension`) |

`operaton-bom` manages them all. The official recipe maps to the empty `operaton-bpm-junit5`;
`starterpack.operaton.PostFixes` replaces it with the test starter.

How the recipe treats the Spring Boot 4 test starter: `camunda-bpm-spring-boot-starter-4-test` first becomes
`operaton-bpm-spring-boot-starter-test`, the JUnit 4 flavour. `PostFixes` then adds
`operaton-bpm-spring-boot-starter-test-junit5` if your tests use JUnit Jupiter, and removes the JUnit 4 flavour
unless JUnit 4 tests exist. The two starters bring:

- `operaton-bpm-spring-boot-starter-test-junit5`: `spring-boot-starter-test`, `operaton-bpm-assert` and
  `operaton-engine` with the classifier `junit6`. The `junit6` classifier provides the same test helper classes as
  `junit5`.
- `operaton-bpm-spring-boot-starter-test`: `spring-boot-starter-test`, `operaton-bpm-assert`, `junit:junit`,
  `junit-vintage-engine` and `operaton-engine` with the classifier `junit4`.

The **test-stack decision** ([D11 · Test stack](01-migration-path-and-decisions.md#d11)) recommends: the test starter
for Spring Boot modules, the classifier jar for plain engine modules, and `operaton.cfg.xml` with a guard test.

## What behaves differently

These changes do not break the build. Most of them change which engine your tests run against, or when things
happen, so tests turn flaky or test the wrong thing without telling you.

- **`camunda.cfg.xml` is never read.** From 1.1 the fallback engine has history `audit`, no `MockExpressionManager`,
  no plugins and enforced history TTL. Rename the file and the classes inside, then guard it. The guard checks the
  effective configuration, not only that the file exists:

  ```java
  var cfg = (ProcessEngineConfigurationImpl) processEngine.getProcessEngineConfiguration();
  assertThat(cfg.getHistory()).isEqualTo(ProcessEngineConfiguration.HISTORY_FULL);
  assertThat(cfg.getExpressionManager()).isInstanceOf(MockExpressionManager.class);
  ```

- **`@Deployment` deploys before `@BeforeEach`** (Camunda deployed after it). Mocks needed at deployment time go into
  an extension registered earlier (`@Order`) or `@BeforeAll`.
- **JUnit 4 `ProcessEngineRule`** fails loudly without `operaton.cfg.xml`. JUnit 6 deprecates the Vintage engine
  that runs JUnit 4 tests, so convert remaining JUnit 4 tests with
  `org.openrewrite.java.testing.junit5.JUnit4to5Migration` in a commit of their own. Do not combine the JUnit
  conversion with the migration commit.
- **Assertions:** same `BpmnAwareTests` API under `org.operaton.bpm.engine.test.assertions.bpmn`.
- **Spring Boot tests:** a leftover `camunda.bpm.job-execution.enabled: false` is ignored; the job executor runs and
  timer tests turn flaky. [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java)
  fails every context on leftover keys, which turns this silent problem into a clear failure.
- **DMN:** FEEL stays `org.camunda.feel`. Do not rename it.

Community libraries: process-test-coverage and the scenario runner exist as `io.github.ronalders` forks (pin them,
import `operaton-bom`); the recipe leaves `org.camunda.community.*` imports alone. All others:
[Ecosystem, support and resources](14-ecosystem-support-and-resources.md).

<a id="hop-2-test-platform-changes"></a>

## The test platform on Spring Boot 4

Your application runs on Spring Boot 4 today, so its test platform is already the one Operaton 2.x uses. Spring Boot
4.0.8 and 4.1.1 manage JUnit Jupiter 6.0.3, the version Operaton 2.1.5 and 2.2.0-RC1 are built with. `@MockitoBean`
and `@MockitoSpyBean` already replace the `@MockBean` and `@SpyBean` that Spring Boot 4 removed, and the MockMvc and
Testcontainers setup your tests use today stays. The recipe of the Spring Boot 4 path runs none of the Spring Boot 4
or Jackson 3 upgrade recipes, so it leaves this platform alone and changes only the engine test artifacts and names
described above. Teams that still move from Spring Boot 3.5 change the test platform during the migration; their table
is in [Tests across the two hops](15-coming-from-spring-boot-3.md#tests-across-the-two-hops).

<a id="tests-that-fail-on-purpose-after-hop-1"></a>

## Tests that fail on purpose after the conversion

Some tests exist to fail when a contract changes. This guide calls them canaries. The recipes leave literals such as
`"camunda-admin"` and `"org.camunda.bpm.engine."` alone: they are often data contracts. In the migrated example,
2 of 10 tests failed after the conversion on three expectations, each one right:

- **`camunda-admin` literal:** the admin group changed. Update the expectation and plan the data step (see the
  [admin-group decision, D5](01-migration-path-and-decisions.md#d5)).
- **Form key:** the expected key changed from `camunda-forms:` to `operaton-forms:`. This happens only if you ran
  `migrate.sh` with `--with-form-keys` (see the
  [Camunda Forms keys decision, D4](01-migration-path-and-decisions.md#d4)).
- **`eventClass` canary:** `Expecting actual "org.operaton.bpm.engine.impl.history.event.HistoricProcessInstanceEventEntity" to start with "org.camunda.bpm.engine."`.
  An exported payload changed. Flip the expectation only after consumers accept both prefixes (see the
  [history-exporters decision, D9](01-migration-path-and-decisions.md#d9)). A quick `sed` would hide what a Kafka
  consumer sees in production.

The one-step conversion of a Spring Boot 4 copy of the example, without `--with-form-keys`, failed on the same two
tests: on the `camunda-admin` and the `eventClass` expectations. Until you change the `eventClass` expectation, its
`"org.camunda.bpm.engine."` literal also stays a MUST-FIX finding (`CAMUNDA_PKG`) of `scripts/verify-leftovers.sh`.
If you keep it on purpose for now, add it to `.operaton-migration-ignore` with a comment.

## Verify the migrated engine

A green build proves the code. It does not prove that Operaton runs your data: in-flight instances on old model
versions, serialized variables, group memberships, due timers and failed jobs. Verification therefore goes through
six levels (L0 to L5), from the build to the watch period after the cut-over:

- **Build (L0):** the build and [`verify-leftovers.sh`](../scripts/verify-leftovers.sh).
- **Integration (L1):** Testcontainers tests on your production database type.
- **Rehearsal (L2):** the production-copy rehearsal ([below](#production-copy-rehearsal)).
- **Staging (L3):** staging with real workers, SSO and `smoke-test.sh --write`.
- **Cut-over (L4):** read-only checks in production, as in the [cut-over runbook](../checklists/cutover-runbook.md).
- **Hypercare (L5):** the watch period right after the cut-over; look for incidents mentioning `org.camunda`.

### Production-copy rehearsal

The rehearsal tests your application and data, not DDL, because Operaton runs on the same schema. Use a fresh,
isolated restore: no real outbound mail, REST calls or production topics. Then:

1. Run [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql),
   [`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql) and the admin-group step
   ([`10-migrate-admin-group.sql`](../sql/postgresql/10-migrate-admin-group.sql)), as at the real cut-over. Keep the
   outputs.
2. Start Operaton with `operaton.bpm.database.schema-update: false` and `operaton.bpm.job-execution.enabled: false`,
   so that no timer or async job fires yet; run `smoke-test.sh`.
3. Replay **old** instances per definition **and version** (complete tasks, `managementService.executeJob(id)`).
   Scripts on old versions fail here ([BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md)).
4. Switch jobs on, watch the catch-up of every timer that became due while the engine was down, and run
   `smoke-test.sh --write`.
5. Re-run the pre-flight and legacy-reference scripts, and compare the copy before and after. Never compare with
   production, because counts on a live system drift.
6. Rehearse the rollback: start the 7.24 build on the same copy (see the
   [rollback decision, D15](01-migration-path-and-decisions.md#d15)).

### `scripts/smoke-test.sh`

The script checks a running engine over HTTP, against Camunda 7 and Operaton. By default it only reads: it checks the
version, counts, incidents, the webapp path and that the **setup page is closed**. It never POSTs to the setup
endpoint, because on an open setup page a POST creates an admin. Exit codes: `0` ok, `1` FAIL, `2` usage error.

```bash
# reference run against the Camunda 7.24 build ("not Operaton" warning expected)
./scripts/smoke-test.sh --base-url http://localhost:8080 --webapp-path /camunda --user ops --password "$OPS_PASSWORD"
# Operaton candidate: fail if it is not Operaton
./scripts/smoke-test.sh --base-url http://localhost:8080 --webapp-path /camunda --require-operaton \
  --user ops --password "$OPS_PASSWORD"
# copies and staging only: deploy/start/complete/history/delete round trip
./scripts/smoke-test.sh --base-url http://localhost:8080 --require-operaton --write --user ops --password "$OPS_PASSWORD"
```

The script covers the generic checks; the rest comes from your characterization tests and the rehearsal steps. The
table shows the pass criterion per area and what the script checks (— means you check it yourself):

| Area | Pass criterion | `smoke-test.sh` |
|---|---|---|
| Startup, new instances | no schema exception; history equals the golden master | counts, `--write` |
| **Old instances**, variables | no `ClassNotFoundException`, no script compilation error | — |
| Jobs, external tasks, incidents | retries count down, no new incidents | counts |
| Security, webapps | admins are admins, setup page closed, plugins load | setup page, reachability |

**Performance:** run the same workload on the same copy with 7.24 first, then Operaton; compare `job-successful`,
`job-failed` and p95 latency. Expect differences from the dependency upgrades rather than from the engine, and
remember that job throughput right after the cut-over includes the catch-up burst.

## Watch out

Each item names what you see, its cause and the fix.

- **Symptom:** `cannot find symbol: class ProcessEngineExtension`.
  **Cause:** the test helpers are not in the main jar.
  **Fix:** add the test starter or the classifier jar.
- **Symptom:** mocks don't resolve, or "History Time To Live cannot be null".
  **Cause:** only `camunda.cfg.xml` exists, so the default engine runs.
  **Fix:** rename it to `operaton.cfg.xml`.
- **Symptom:** `Unknown property used in expression` at deployment.
  **Cause:** mocks are registered in `@BeforeEach`, which now runs after the deployment.
  **Fix:** register them earlier.
- **Symptom:** `Group has an invalid id: 'operaton-admin' is not a valid resource identifier`.
  **Cause:** `groupResourceWhitelistPattern` contains `camunda-admin`.
  **Fix:** replace it (`PostFixes` does this in Spring config).
- **Symptom:** `NoSuchMethodError` in tests only.
  **Cause:** forks pull other Operaton versions.
  **Fix:** import `operaton-bom`.
