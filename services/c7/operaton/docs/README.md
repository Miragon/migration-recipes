# The guide

Sixteen chapters, one per topic, for moving an embedded Camunda 7.24 engine in a Spring Boot app to Operaton 2.x. The main
path starts from Camunda 7.24 Enterprise Edition (EE) on Spring Boot 4: the code changes in one step, and production
switches once, at the cut-over. For the order of the work, start with the
[step-by-step overview](../README.md#step-by-step). Each chapter opens with an *In short* summary, so you can decide
quickly whether you need the rest. Unfamiliar words are explained in [Terms used in this guide](#terms-used-in-this-guide)
below.

| # | Chapter | Read it when … |
|---|---|---|
| 00 | [Why Operaton and what changes](00-why-operaton-and-what-changes.md) | you want the big picture: why to move now, and what changes in code, configuration and data |
| 01 | [Migration path and decisions](01-migration-path-and-decisions.md) | you plan the path and the 18 migration decisions (D1–D18) |
| 02 | [Assessment](02-assessment.md) | you run `assess.sh` and the database scans to size the migration |
| 03 | [OpenRewrite recipes](03-openrewrite-recipes.md) | you run `migrate.sh` to convert the code |
| 04 | [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md) | you rename properties, environment variables and loggers |
| 05 | [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md) | your models contain scripts or forms |
| 06 | [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md) | you extend the engine with plugins or export history events |
| 07 | [Identity, admin group and security](07-identity-admin-group-and-security.md) | before the first Operaton start on a database with real users, and to make up for the EE security hardening Operaton lacks |
| 08 | [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md) | you use Liquibase or direct SQL, or store `org.camunda.*` objects in variables |
| 09 | [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md) | you use the webapps (Cockpit, Tasklist, Admin), EE webapp features or REST clients |
| 10 | [Testing](10-testing.md) | you build the safety net on Camunda 7.24, or tests break after the conversion |
| 11 | [Cut-over, rollback and operations](11-cutover-rollback-and-operations.md) | you plan the production switch and the way back |
| 12 | [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md) | you check the Spring Boot 4 details (Jackson 2 next to Jackson 3) or choose between Operaton 2.1.x and 2.2.x |
| 13 | [Tips, tricks and troubleshooting](13-tips-tricks-and-troubleshooting.md) | you have an error message |
| 14 | [Ecosystem, support and resources](14-ecosystem-support-and-resources.md) | you need an extension or support |
| 15 | [Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md) | your application is still on Spring Boot 3.5 (Camunda 7.24.0 CE, or EE not yet on Spring Boot 4) |

## Where to start

Pick the reading path for your role. Everyone should know the [Things that bite](../README.md#things-that-bite).

- **Tech lead:** read [Why Operaton and what changes](00-why-operaton-and-what-changes.md), then
  [Migration path and decisions](01-migration-path-and-decisions.md) and [Assessment](02-assessment.md). Then open the
  [decision log](../checklists/decision-log-template.md) and start recording the decisions.
- **Developer:** read [Assessment](02-assessment.md), then chapters 03 to 06
  ([OpenRewrite recipes](03-openrewrite-recipes.md),
  [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md),
  [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md),
  [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md)), [Testing](10-testing.md) and
  [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md). Keep
  [Tips, tricks and troubleshooting](13-tips-tricks-and-troubleshooting.md) open while you work.
- **Ops / DBA:** read [Identity, admin group and security](07-identity-admin-group-and-security.md), then
  [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md) and
  [Cut-over, rollback and operations](11-cutover-rollback-and-operations.md). Then work with the
  [cut-over runbook](../checklists/cutover-runbook.md) and the [SQL toolkit (`sql/`)](../sql/README.md).
- **Team on Spring Boot 3.5** (Camunda 7.24.0 CE, or EE not yet on Spring Boot 4): read
  [Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md) first, because your code conversion
  differs from the main path. Then follow the reading path for your role.
- **Team that lets an AI coding agent do the conversion** (Claude Code, or GitHub Copilot with a Claude model in VS
  Code, the Copilot CLI or the cloud agent): install the migration skill as described in
  [Use it with Claude Code or GitHub Copilot](../README.md#let-claude-drive). The skill runs the same scripts and
  follows these chapters, but the decisions, the reviews and everything that touches a real database stay with you.

## Terms used in this guide

Short definitions of the words this guide uses most, grouped by topic.

**The path**

- **Spring Boot 4 path** – the main path of this guide: Camunda 7.24 EE (7.24.3-ee or later) on Spring Boot 4 →
  Operaton 2.x in **one code change** (one recipe run, `starterpack.operaton.MigrateSpringBoot4App`, one commit) and one
  cut-over. Spring Boot 4.0 goes to Operaton 2.1.5, Spring Boot 4.1 to Operaton 2.2.x (GA due 2026-10-23).
- **Step 0** – bring code *and* database to Camunda 7.24 EE (7.24.3-ee or later) on Spring Boot 4 and Java 17 before
  anything else. Operaton also starts on an older database, but then fails at runtime with SQL errors on missing
  columns.
- **Cut-over** – the one production switch of the database from Camunda to Operaton: stop all Camunda nodes and start the
  Operaton build against the *same* database. No schema migration is needed, because the schema is identical.
- **Recipe** – an OpenRewrite recipe, i.e. an automated code transformation. Operaton publishes the official one, and this pack
  wraps it in composite recipes (`starterpack.operaton.*`) that add fixes for what it misses.
- **Leftovers** – Camunda references that no recipe converted and that Operaton ignores or fails on.
  `scripts/verify-leftovers.sh` finds them (exit 1 = must fix).
- **Spring Boot 3.5 path, Hop 1 and Hop 2** – the path for teams still on Spring Boot 3.5 (Camunda 7.24.0 CE, or EE on
  Spring Boot 3.5). Their code changes twice: Hop 1 renames Camunda to an Operaton 1.1.5 checkpoint that never goes to
  production, and Hop 2 moves it to Operaton 2.x and Spring Boot 4. Production still switches once. The terms appear in
  `migrate.sh` (`--hop`) and its messages. Details:
  [Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md).

**Data and safety**

- **Production copy** – a restored copy of the production database for tests and rehearsals. Never the live database.
- **Pre-flight gate** – `sql/postgresql/00-preflight-checks.sql`: read-only checks that end in `GO`, `GO_WITH_WARNINGS` or
  `NO_GO` (exit code 3). Start Operaton only after a GO. The gate exists because the engine itself checks almost nothing at
  startup (only `schema.version = 'fox'`, which every Camunda 7 database has).
- **Admin group and setup page** – Camunda's webapps treat members of `camunda-admin` as administrators. Operaton hard-codes
  `operaton-admin`, and nothing migrates the group. With users stored in the engine database (**DB identity**), nobody is
  then an Operaton admin. The webapps think this is a fresh installation and open the **setup page**, which lets anyone who
  can reach it create an admin user without logging in.
- **Mirroring the admin group** – copying the members and authorizations of `camunda-admin` to `operaton-admin` before the
  first Operaton start, with `sql/postgresql/10-migrate-admin-group.sql` or `AdminGroupMigrationPlugin`. If
  `camunda-admin` has members, this closes the setup page.
- **Package-free script** – a script in a BPMN/DMN model that references no `org.camunda.*` (or `org.operaton.*`) class, only
  process variables and the pre-bound `S(…)` function. It runs on both engines, so you can deploy it on Camunda 7.24 before
  the cut-over and keep the option to roll back.
- **Safety-net tests** – tests you add on Camunda 7.24 for behaviour no compiler checks (scripts, forms, DMN results, timers,
  external tasks, exporters). Anything the migration breaks then shows up as a red test.
- **Legacy variables** – process variables stored as Java-serialized objects or with type names from `org.camunda.*`.
  Operaton has no such classes and fails with `ClassNotFoundException`. You **convert** them on Camunda 7.24, or you
  **drain** them: let the affected instances finish on Camunda before the cut-over instead of changing or migrating them.
- **Instance migration** – the Migration API that moves running process instances to another version of their process
  definition. You need it because running instances keep using the model version they started on.

**Cut-over and rollback**

- **Mixed cluster** – Camunda and Operaton nodes working on the same database at the same time. Never allowed.
- **Rollback and point of no return (PoNR)** – a rollback redeploys the last Camunda build on the same database. That works
  until the point of no return, the first moment Operaton has written something Camunda 7.24 cannot read or run. After it,
  going back means restoring the backup and losing the work since the cut-over.
- **Rollback window and time cap** – the period in which a rollback is still allowed. It ends at the point of no return
  or at an agreed time cap (e.g. 72 h after the cut-over), whichever comes first. The rollback decider closes it by an
  explicit decision.
- **Hard stop** – a change that creates such Operaton-only data and so reaches the point of no return: deployed versions
  with `operaton:` attributes, `org.operaton.*` script references or `operaton-forms:` keys that have running instances,
  and Java-serialized `org.operaton.*` variables.
- **Hypercare** – the watch period right after the cut-over (e.g. 72 h) while a rollback is still possible.

**Names and labels**

- **History exporter / consumers** – code that publishes engine history events to other systems (Kafka etc.) / the teams
  and services that read those events.
- **`camunda:` / `operaton:` namespace** – the XML prefix of engine extension attributes in BPMN/DMN files. Operaton reads
  both, but Camunda 7.24 silently ignores `operaton:`.
- **Webapp path** – the URL prefix of Cockpit, Tasklist and Admin: `/camunda` on Camunda, `/operaton` by default on
  Operaton.
- **CE / EE** – the Community Edition and the Enterprise Edition of Camunda 7. CE ended with 7.24.0 on Spring Boot 3.5.
  Spring Boot 4 on Camunda 7.24 exists only in EE, from 7.24.3-ee on. EE versions look like `7.24.16-ee` and come from
  Camunda's EE repository (`https://artifacts.camunda.com/artifactory/private/`, server id `camunda-bpm-nexus-ee`), which
  needs credentials.
- **`-4` starters** – Camunda's Spring Boot 4 starters, with a `-4` after `starter` in the artifact name
  (`org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4`, `-4-rest`, `-4-webapp`, `-4-webapp-core`,
  `-4-security`, `-4-test`, `-4-external-task-client`, and the EE webapps `-4-webapp-ee`). Operaton's starters have no
  `-4`: they become `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[-x]`, `-4-test` becomes
  `operaton-bpm-spring-boot-starter-test-junit5`, and `-4-webapp-ee` becomes the CE webapp starter.
- **`-jackson3` artifacts** – Camunda's opt-in Jackson 3 variants of Spin, the REST API and the external task client
  (from 7.24.16-ee). Operaton 2.x has no such artifacts: Spin, REST and the client stay on Jackson 2.
- **MUST / SHOULD / INFO / KEEP** – severity labels in tables and reports. MUST breaks the build, the start, runtime
  behaviour or security if you skip it. In the chapter tables, SHOULD means that something degrades silently if you skip
  it. In the `assess.sh` report, SHOULD means that the recipes handle it but it is worth a review, or that it is a
  decision with a safe default. INFO is planning context, such as counts and versions. KEEP means: do not change this.
- **IDs** – `D1`–`D18` are the decisions in [Migration path and decisions](01-migration-path-and-decisions.md#decisions).
  `P01`–`P11` (no hyphen) are the checks in the pre-flight script, `L1`–`L9` the sections of
  `20-find-legacy-references.sql`.
  `T−14`, `T−7`, `T−1` and `T0` are the phases of the [cut-over runbook](../checklists/cutover-runbook.md) (days before
  cut-over day `T0`). Its step IDs carry the phase as a prefix: `P-01` preparation, `R-01` rehearsal, `F-01` freeze,
  `T0-01` cut-over day, `H-01` hypercare. `R1`–`R3` are the three rollback paths (`R1-1` is a step of path R1).
  `CP…` is evidence for the change ticket, and `C1`–`C3` is the compatibility checkpoint (are there Operaton-only
  deployments, instances on them, or variables only Operaton can read?).
