# Migration report: <application name> · Camunda 7 → Operaton

> Single source of truth for this migration. Keep it current after every step.
>
> **Branch gate (code migration): NOT READY**
> **Cut-over gate (production): NOT READY**
>
> Criteria for both gates: section 0. The agent may set the branch gate; only the humans who own the cut-over set the cut-over gate.
> Decisions marked `accepted (default, assumed)` were applied without a human to ask (e.g. Copilot cloud agent): confirm them in the review.

| | |
|---|---|
| Repository / branch | `<repo>` / `<branch>` |
| Report updated | <YYYY-MM-DD> by <name / agent> |
| Source | Camunda <7.24.N-ee / 7.24.0> (EE/CE), Spring Boot <4.0.x / 4.1.x / 3.5.x>, Java <17/21/25>, build: Maven/Gradle |
| Path | <Spring Boot 4 path: one recipe run, one cut-over / Spring Boot 3.5 path: Hop 1 (1.1.x checkpoint) + Hop 2, one cut-over> |
| Target | Operaton <2.1.5 / 2.2.x> (built with Spring Boot <x.y.z>)<; rehearsal only: 2.2.0-RC1 until 2.2.0 GA> |
| Camunda EE | <not used / EE repository access for the recipe run: user's settings or MAVEN_ARGS (never in the repo); removed after the run: yes/no> |
| Database | <vendor + version>, schema managed by <engine schema-update / Liquibase / Flyway / DBA scripts> |
| Mode so far | assess / migrate / hop2 (Spring Boot 3.5 path) / verify / cutover |
| Agent / environment | <Claude Code / Copilot CLI / VS Code / Copilot cloud agent (PR #…)> |
| Commit policy | <local commits per step on the migration branch, never pushed / no commits: throw-away clone `<path>`, result handed back as uncommitted changes / Copilot cloud agent branch, PR review> |

## 0. Gates

**Branch gate (code migration)** — READY when all of these hold (evidence in sections 3 and 6):
- [ ] Baseline on Camunda 7.24 recorded (`mvn -B verify`, test counts).
- [ ] Decisions D1, D3, D5, D6 recorded; D17 recorded for Camunda EE sources (every Spring Boot 4 project); D4 recorded
      if `camunda-forms:` keys exist; D9 recorded if exporters exist.
- [ ] Pre-migration release on Camunda 7.24 (package-free scripts D3, `formRef` D4) committed and green, or not needed (reason).
- [ ] Spring Boot 4 path: the recipe run (`migrate.sh`, one commit) green (`mvn -B clean verify`, counts).
      Spring Boot 3.5 path: Hop 1 green; Hop 2 green if D1 targets 2.x.
- [ ] Camunda EE sources: EE-only settings and calls removed, `tools.jackson.*` code next to Spin / REST / client back on
      Jackson 2, license files removed, EE repository and credentials removed; build green with Maven Central only.
- [ ] `verify-leftovers.sh` exit 0; every `.operaton-migration-ignore` entry listed with its reason (section 4).
- [ ] Local boot + `smoke-test.sh --require-operaton` PASS.
- [ ] Admin setup endpoint closed on a migrated database (local cut-over simulation).
- [ ] Every MUST item of the code resolved: compile/test fixes, configuration **in the repository**, models, tests,
      helpers (`AdminGroupMigrationPlugin`, `LegacyCamundaConfigGuard`) with their tests.
- [ ] Every flipped test expectation listed as a manual fix with its reason (section 4).

**Cut-over gate (production)** — READY only when the branch gate is READY and all of these hold (owners in section 5):
- [ ] D5, D6, D7, D8, D13, D14, D15, D18 accepted (D15 with point-of-no-return events, time cap, rollback triggers,
      decider); D17 accepted for EE sources (EE webapp features and Optimize replaced or accepted, query-expression
      mitigation chosen); no `accepted (default, assumed)` left unconfirmed.
- [ ] Target is a GA release matching the Spring Boot minor (no 2.2.0-RC1 in production).
- [ ] D18: `20-find-legacy-references.sql` run on a **production copy**; every hit converted, drained or recorded as a D15 hard stop.
- [ ] Pre-migration release (if any) deployed on production Camunda 7.24; instances on old definition versions migrated.
- [ ] D9: consumer sign-off for exported events (dual-read or frozen `eventClass` verified by each consumer owner).
- [ ] D5: `camunda-admin` has members on production (`00-preflight-checks.sql` P03), or a break-glass admin plan exists.
- [ ] D17 (EE sources): P11 of `00-preflight-checks.sql` on a production copy reviewed (stored filters with expressions).
- [ ] Configuration **outside the repository** renamed (Helm, ConfigMaps, Secrets, Config Server, CI variables, `SPRING_APPLICATION_JSON`), with owners.
- [ ] Setup-path block (`<app-path>/api/admin/setup/*`) prepared at the edge.
- [ ] Rehearsal on a production copy done, including the rollback; downtime measured.
- [ ] Cut-over runbook and SQL in `migration/` reviewed by DBA / ops / security (DRAFT marks removed).

## 1. Inventory

| Area | Findings (counts, files) |
|---|---|
| Modules & packaging | |
| Edition and Spring Boot line (`assess.sh` rows Edition, Spring Boot 4 artifacts, Migration path, Recommended target) | |
| Camunda dependencies (incl. EE, `-4` starters, `-jackson3`, community extensions) | |
| Camunda EE features (EE webapps, Optimize, license, EE-only settings, EE repository) | |
| Internal API usage (`org.camunda.bpm.engine.impl.*`) | |
| Engine plugins / extension points | |
| History or event exporters & their consumers | |
| SPI files (`META-INF/services`, `spring.factories`) | |
| Configuration (`camunda.bpm.*` keys, env vars, Helm/config server) | |
| Models (BPMN/DMN/CMMN count, script tasks & languages, `org.camunda` refs in scripts, `camunda-forms:` keys, connectors) | |
| Identity (DB identity / LDAP / Keycloak / OAuth2; members of `camunda-admin`) | |
| Database scripts (direct SQL on `ACT_*`, Liquibase/Flyway) | |
| Webapps (path, plugins, branding, embedded forms, EE features) | |
| Tests (frameworks, engine test setup, coverage libs) | |
| Operations (logger names, alerts, dashboards, probes, ingress, SSO) | |

`assess.sh` summary: <n> MUST · <n> SHOULD · <n> INFO (full output in appendix A)

## 2. Decisions

Status: `open` → `accepted` / `accepted (default)` / `accepted (default, assumed)` (no human to ask; confirm in review) /
`rejected` / `n/a` (with reason). Gate: which gate needs the decision. Mandatory: D5, D7, D8, D15, D17 (EE sources), D18.

| ID | Decision | Choice | Rationale | Owner | Gate | Status |
|---|---|---|---|---|---|---|
| D1 | Target version & path | e.g. Spring Boot 4 path: Camunda 7.24.N-ee on Spring Boot 4.0 → Operaton 2.1.5 in one run (Spring Boot 4.1 → 2.2.x); Spring Boot 3.5 path: Hop 1 → 1.1.5, Hop 2 → 2.1.5 | | | branch | open |
| D2 | Recipe toolchain | starter-pack composites via `migrate.sh` (path detected), dry run first | | | branch | open |
| D3 | BPMN/DMN namespace, script fixes | keep `camunda:`; scripts package-free on 7.24 | | | branch | open |
| D4 | Camunda Forms keys | | | | branch | open |
| D5 | Admin group migration | SQL / plugin / both | | | branch + cut-over | open |
| D6 | Webapp path | keep `/camunda` for cut-over | | | branch + cut-over | open |
| D7 | Cut-over strategy | big bang on same DB, rehearsed | | | cut-over | open |
| D8 | Schema management | `schema-update: false` + pre-flight | | | cut-over | open |
| D9 | History exporter semantics | after-commit / outbox; envelope v2, `eventClass` frozen until sign-off | | | branch + cut-over | open |
| D10 | Direct DB scripts | replace with API/REST | | | branch | open |
| D11 | Test stack | | | | branch | open |
| D12 | Modeler | Camunda Desktop Modeler while models use `camunda:` | | | — | open |
| D13 | Health probes | | | | cut-over | open |
| D14 | Support model | | | | cut-over | open |
| D15 | Rollback & point of no return | | | | cut-over | open |
| D16 | Webapps | classic webapps | | | — | open |
| D17 | Camunda EE features | e.g. EE webapp inventory + replacements; license rows kept; EE repository removed after the run; `enable-expressions-in-stored-queries: false` (P11 empty); `tools.jackson` → Jackson 2 | | | branch + cut-over | open |
| D18 | Variables with `org.camunda.*` objects | | | | cut-over | open |

## 3. Work log

| # | Step | Command / change | Result (evidence) |
|---|---|---|---|
| 1 | Baseline build | `mvn -B verify` | e.g. 42 tests, 0 failures |
| 2 | Pre-migration release (if needed) | package-free scripts / `formRef`, `mvn -B verify` on 7.24 | |
| 3 | Recipe dry run | `migrate.sh --dry-run [--target <v>]` (Spring Boot 3.5 path: `--hop 1 --dry-run`) | `==> Source: …`, n files in rewrite.patch |
| 4 | Recipe run | `migrate.sh --with-infra-env [--target <v>]` (Spring Boot 3.5 path: `--hop 1`, later `--hop 2`) | |
| … | | | |

## 4. Manual fixes and accepted leftovers

| # | File(s) | Problem (symptom) | Fix | Why the recipe missed it |
|---|---|---|---|---|

Accepted leftovers (copy of `.operaton-migration-ignore`, each with its reason):

```text
<RULE|*>  <path-glob>  ["<regex>"]  # reason
```

## 5. Open items

| # | Item | Severity (MUST/SHOULD) | Gate (branch/cut-over) | Owner | Status (open/blocked/resolved) |
|---|---|---|---|---|---|

## 6. Verification evidence

| Check | Command | Result |
|---|---|---|
| Build + tests (pre-migration release, 7.24) | `mvn -B verify` | |
| Build + tests (migration commit; Spring Boot 3.5 path: Hop 1) | `mvn -B clean verify` | |
| Build + tests (Spring Boot 3.5 path: Hop 2) | `mvn -B clean verify` | |
| Build with Maven Central only (EE sources) | `mvn -B -s <settings without the EE server> -Dmaven.repo.local=<fresh dir> clean verify` | |
| Leftover scan | `verify-leftovers.sh` | exit 0 / accepted leftovers listed |
| Boot + smoke test | `smoke-test.sh --base-url … --require-operaton` | |
| Admin setup endpoint closed on migrated DB | local cut-over simulation (identity reference §7) | |
| In-flight instances on affected definitions | `20-find-legacy-references.sql` on a prod copy (humans) | |
| Stored filters with expressions (EE sources) | `00-preflight-checks.sql` P11 on a prod copy (humans) | |

## 7. Cut-over & rollback (summary)

- Runbook: `migration/cutover-runbook.md` (stub at least; DRAFT until reviewed)
- SQL for review: `migration/sql/<vendor>/…` (target 2.2.x: also `<db>_engine_7.24_to_7.25.sql`)
- Point of no return: <event> or <time cap>
- Downstream teams notified: <list>

## Appendix A — assess.sh output

<paste>
