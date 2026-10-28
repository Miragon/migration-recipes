# Migration report: order-fulfillment · Camunda 7 → Operaton

> A real run of the starter-pack tools on [`camunda7-spring-boot-legacy`](../camunda7-spring-boot-legacy/README.md);
> also the model for the report the Claude skill writes.
>
> **Branch gate (code migration): READY**
> **Cut-over gate (production): NOT READY** (open items in section 5)

| | |
|---|---|
| Repository / branch | `examples/operaton-spring-boot-migrated` (scratch git repo) |
| Report updated | 2026-10-07 by the starter-pack toolkit run |
| Source | Camunda 7.24.0 CE, Spring Boot 3.5.5, Java 17, Maven |
| Target | Hop 1: Operaton 1.1.5 / Spring Boot 3.5.16 · Hop 2: Operaton 2.1.5 / Spring Boot 4.0.8 |
| Database | H2; production PostgreSQL, `schema-update: false` |
| Tooling | `migrate-camunda-recipe` 1.0.1, `rewrite-maven-plugin` 6.46.1, `rewrite-spring` 6.37.0, JDK 21 |
| Mode so far | assess → migrate → hop2 → verify |
| Commit policy | local commits: unmodified recipe output, then fixes, per hop |

## 0. Gates

- **Branch gate READY:** baseline and decisions recorded; both hops green; leftover scan and smoke test PASS; setup
  endpoint closed on a migrated DB. No pre-migration release on 7.24 (recipe output kept, see D15).
- **Cut-over gate NOT READY:** O1, O2 (D18), O3; D13, D14 open.

## 1. Inventory

`scripts/assess.sh`: **7 MUST · 7 SHOULD · 4 INFO** (appendix A).

| Area | Findings |
|---|---|
| Dependencies | 6 Camunda coordinates; no EE, no community extensions |
| Code | 15 internal-API imports; 2 engine plugins; history handler registered twice; Spin `DataFormatConfigurator` + SPI file |
| Exporter | Kafka in production; field `eventClass` = engine class name |
| Configuration | 28 `camunda.bpm.*` keys; 10 `CAMUNDA_BPM_*` env vars; `camunda-admin` in the whitelist regex |
| Models | 1 BPMN (Groovy `import org.camunda.spin.Spin`, `camunda-forms:`), 1 DMN, 1 form |
| Identity | DB identity, webapps on → admin group migration mandatory |
| SQL | 3 scripts with DML on `ACT_*` |
| Operations | `/camunda` in ingress and health check; `org.camunda.*` loggers |

## 2. Decisions

| ID | Choice | Status |
|---|---|---|
| [D1](../../docs/01-migration-path-and-decisions.md#d1) | Two commits: Hop 1 → 1.1.5, Hop 2 → 2.1.5; production C7.24 → 2.1.5 | accepted |
| [D2](../../docs/01-migration-path-and-decisions.md#d2) | Starter-pack composite + infra env + form keys, dry run first | accepted |
| [D3](../../docs/01-migration-path-and-decisions.md#d3) | Keep `camunda:`; fix the script import | accepted |
| [D4](../../docs/01-migration-path-and-decisions.md#d4) | `operaton-forms:` (v1 instances keep `camunda-forms:`, still resolved) | accepted, Tasklist check O3 |
| [D5](../../docs/01-migration-path-and-decisions.md#d5) | `AdminGroupMigrationPlugin`; `sql/postgresql/10-migrate-admin-group.sql` for DBAs | accepted |
| [D6](../../docs/01-migration-path-and-decisions.md#d6) | Keep `/camunda`; redirect filter ready for the move | accepted |
| [D7](../../docs/01-migration-path-and-decisions.md#d7) | Big bang on the same DB, rehearsed | accepted |
| [D8](../../docs/01-migration-path-and-decisions.md#d8) | `OPERATON_BPM_DATABASE_SCHEMA_UPDATE=false` + pre-flight SQL (schema 7.24.0 on both) | accepted |
| [D9](../../docs/01-migration-path-and-decisions.md#d9) | After commit, registered once; `eventClass` kept, consumers dual-read | accepted, O1 |
| [D10](../../docs/01-migration-path-and-decisions.md#d10) | SQL → `IncidentRecoveryService` / REST | accepted |
| [D11](../../docs/01-migration-path-and-decisions.md#d11) | Operaton test starter + `operaton-bpm-assert` | accepted |
| [D13](../../docs/01-migration-path-and-decisions.md#d13), [D14](../../docs/01-migration-path-and-decisions.md#d14) | Health probes, support model | open |
| [D15](../../docs/01-migration-path-and-decisions.md#d15) | Rollback until the first instance runs on BPMN v2, cap 72 h; `camunda-admin` rows kept | accepted |
| [D17](../../docs/01-migration-path-and-decisions.md#d17) | No EE features | n/a |
| [D18](../../docs/01-migration-path-and-decisions.md#d18) | JSON variables only (`javaSerializationFormatEnabled: false`); run `20-find-legacy-references.sql` on a production copy | open |

Not taken: package-free script (`S('{}').prop(…)`) + `formRef` deployed on 7.24 first would keep the rollback open longer.

## 3. Work log

| # | Command | Result |
|---|---|---|
| 1 | `mvn -B verify` (Camunda 7.24) | 10/10 |
| 2 | `scripts/assess.sh .` | 7 MUST · 7 SHOULD · 4 INFO |
| 3 | `scripts/migrate.sh --hop 1 --with-infra-env --with-form-keys .` (`--dry-run` first) | 26 files, +139 / -134 |
| 4 | `mvn -B clean verify` | **8/10**, deliberate (section 4) |
| 5 | `scripts/verify-leftovers.sh .` | 1 MUST (canary literal) + WARNs |
| 6 | M1–M3, C1–C6 | 10/10 on 1.1.5 |
| 7 | `scripts/migrate.sh --hop 2 --target 2.1.5 .`, `mvn -B clean verify` | parent, `operaton.version`, `InMemoryEventPublisher` → Jackson 3; 10/10, no manual fix |
| 8 | helpers, exporter, `IncidentRecoveryService`, `ops/`, C7 | 34/34 |
| 9 | `scripts/verify-leftovers.sh .` | **PASS** |

`UpgradeToOperaton2` keeps the Spin configurator on Jackson 2; the stock Boot 4 recipe breaks it with `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper`.

## 4. Manual fixes and accepted leftovers

| # | File | Problem (symptom) | Fix |
|---|---|---|---|
| M1 | `AdminAuthorizationInitializerTest` | `Expecting ArrayList ["operaton-admin", "order-ops"] to contain ["camunda-admin", "order-ops"]` | expect `operaton-admin`; group ids are data (D5) |
| M2 | `OrderFulfillmentProcessTest` | `Expecting Task … to have a form key 'camunda-forms:deployment:approve-order.form', but found … 'operaton-forms:…'` | expect `operaton-forms:` (D4, `--with-form-keys`) |
| M3 | `OrderFulfillmentProcessTest` (after M2) | `Expecting actual "org.operaton.bpm.engine.impl.history.event.HistoricProcessInstanceEventEntity" to start with "org.camunda.bpm.engine."` | expect `org.operaton.bpm.engine.`; tell consumers (D9, O1) |
| C1 | `AdminAuthorizationInitializer` | `operaton-admin` named "Camunda Administrators" | `operaton BPM Administrators` |
| C2–C4 | fields, artifactId, comments | Camunda names | renamed, `MIGRATED:` notes |
| C5 | `ops/sql/*.sql` | DML on `ACT_*` | `IncidentRecoveryService` (D10) |
| C6 | `ExportingHistoryEventHandler` | publishes inside the transaction: rollbacks leak ghost events | after commit (D9) |
| C7 | `ExportingHistoryEventHandler`, `HistoryExportPlugin` | `@Component` **and** plugin: every event exported twice | plugin constructs the handler, no `@Component` |

Recipes leave Java literals, most comments, SQL and runtime semantics alone. Accepted leftovers
(`.operaton-migration-ignore`): helper tests and `WEBAPP_PATH` (D6); `migration/*` is skipped via its
`operaton-migration-helper` marker.

### Deliberate test failures after Hop 1

M1–M3 are test literals the recipes leave alone (group id, form key, exported class name). After Hop 1, 2 of 10
tests fail **on purpose**: `OrderFulfillmentProcessTest` on M2, then (once fixed) on M3. The CI end-to-end job therefore
builds both hops with `-DskipTests`.

## 5. Open items

| # | Item | Severity | Owner |
|---|---|---|---|
| O1 | History consumers accept `org.operaton…` in `eventClass` (dual read) | MUST | consumers |
| O2 | v1 instances before the script task fail there on Operaton: find them (`20-find-legacy-references.sql`), drain on Camunda or migrate to v2 (`executeAsync()`) | MUST | ops |
| O3 | `operaton-forms:` rendering in Tasklist on staging | SHOULD | QA |
| O4 | Log alerts keyed on `org.camunda.bpm` | SHOULD | ops |
| O5 | REST clients: `camundaFormRef` → `operatonFormRef` | SHOULD | clients |
| O6 | After the rollback window (D15): remove `migration/*`, ignore entries, `camunda-admin` rows | SHOULD | team |
| O7 | Health probes (D13) once actuator is added | INFO | team |

## 6. Verification evidence

| Check | Result |
|---|---|
| `mvn -B clean verify` | **34 tests, 0 failures** |
| `verify-leftovers.sh` legacy / Hop 1 raw / final | 103 MUST / 1 MUST / **PASS** |
| Resolved versions | Jackson 2.21.5 (Spin) **and** `tools.jackson` 3.1.5 (Spring); `org.camunda.feel:feel-engine` 1.21.1 (not renamed) |

Cut-over simulation: legacy app on a file H2 (two admins, in-flight `LEGACY-1`), then this app on the same file:

| Check | Result |
|---|---|
| Startup log | `Admin group migration camunda-admin -> operaton-admin: … members added=2 …` |
| Anonymous `POST /camunda/api/admin/setup/default/user/create` | **403** `Setup action not available`; with `--orders.migration.admin-group.enabled=false`: **204**, admin created |
| `LEGACY-1` (v1, `camunda-forms:`) | completes on Operaton |
| New instance (v2) | `operaton-forms:`, script runs |
| `smoke-test.sh --webapp-path /camunda --require-operaton` | PASSED |
| Config guard (`--camunda.bpm.history-level=audit`) | exit 1: `IllegalStateException: Camunda 7 configuration found - Operaton ignores it silently.` |
| Redirect filter on | GET `/camunda/app/…` → 302 `/operaton/app/…`; POST not redirected |

## 7. Cut-over & rollback (summary)

- Runbook: [`checklists/cutover-runbook.md`](../../checklists/cutover-runbook.md).
- Before the first start: `sql/postgresql/00-preflight-checks.sql`, `20-find-legacy-references.sql` (O2), backup.
- Point of no return (D15): v2 instances before the `org.operaton.spin.Spin` script or with open `operaton-forms:` tasks; else 72 h.
- Notify: consumers (O1), REST clients (O5), ops (O4).

## Appendix A — assess.sh output

MUST: `org.camunda.*` in a BPMN script; admin group (D5); `CAMUNDA_BPM_*`; history exporter (D9); handler registered
twice; class names in literals; DML on `ACT_*` (D10). SHOULD and INFO: see section 1.

Reproduce: [`examples/README.md`](../README.md#reproduce-the-migration).
