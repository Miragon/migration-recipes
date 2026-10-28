# 01 · Migration path and decisions

This chapter shows the route from Camunda 7 to Operaton, the phased plan that takes one service along it, and the 18
decisions you make on the way, each with a recommendation. It describes the main path: Camunda 7.24 Enterprise Edition
(EE) on Spring Boot 4, moved to Operaton 2.x. Tech leads use it to plan the migration. Everyone else uses it to look up
what a decision ID such as D5 means and why its recommendation matters.

<a id="hop-1--rename-camunda-724--operaton-115"></a>
<a id="hop-2--platform-operaton-115--operaton-2x"></a>
<a id="when-one-hop-is-fine-and-when-to-go-live-on-115"></a>

On Spring Boot 3.5 (Camunda 7.24 CE, or EE without the Spring Boot 4 starters)? Read
[Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md) first. It describes the two code
changes, the Operaton 1.1.5 checkpoint between them, when one combined run is fine and when going live on 1.1.5 is
acceptable.

**In short**
- **Change the code once, change production once.** If your application runs Camunda 7.24 EE on Spring Boot 4,
  `scripts/migrate.sh` converts the code to Operaton 2.x in one recipe run, which you commit as one change. Production
  then switches in a single rehearsed event, the cut-over.
- **Pick the Operaton line that matches your Spring Boot minor version.** Spring Boot 4.0 goes to Operaton 2.1.5.
  Spring Boot 4.1 goes to Operaton 2.2.x, whose GA (general availability, the final release) is due on 2026-10-23;
  until then you rehearse with 2.2.0-RC1, never in production. Operaton supports only these pairs, and `migrate.sh`
  never downgrades Spring Boot.
- **Step 0** brings the code **and** the database to Camunda 7.24 (EE 7.24.3-ee or later on Spring Boot 4) and Java 17
  before any code conversion. Operaton also starts on an older database, but then fails later at runtime.
- **The cut-over** stops all Camunda nodes and starts the Operaton 2.x build against the same database. No schema
  migration is needed, because the schema is identical.
- **Six decisions are mandatory before the first start on real data**, because skipping them causes a security hole,
  data problems or a cut-over you cannot undo: the [admin group (D5)](#d5), the [cut-over strategy (D7)](#d7),
  [schema management (D8)](#d8), [rollback (D15)](#d15), the [Camunda EE features (D17)](#d17) and
  [legacy variables (D18)](#d18). The EE features decision is mandatory for every EE team, which includes everyone on
  Spring Boot 4. Record all decisions in the [decision log](../checklists/decision-log-template.md).

<a id="1-the-path-step-0-two-hops-one-cut-over"></a>
<a id="path"></a>

## 1. The path: one code change, one cut-over

The table shows the three stages of the path from any Camunda 7 version to Operaton 2.x in production: Step 0, the
code change and the cut-over. They run across the eight phases of the [phased plan](#3-phased-plan). Step 0 ships a
normal Camunda release. The code change happens on a branch and is tested against copies of the production database.
Only the cut-over switches production to Operaton. Your application already runs on Spring Boot 4, the platform that
Operaton 2.x is built on. The platform therefore stays, and one code change with one green build is enough.

| Stage | From → to | Tool |
|---|---|---|
| Step 0 | any Camunda 7 → **Camunda 7.24 EE** (7.24.3-ee or later), Spring Boot 4, Java 17 | Camunda's upgrade scripts, [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql) |
| Code change | → **Operaton 2.x** on the same Spring Boot minor (one recipe run, one commit) | `scripts/migrate.sh` |
| Cut-over | production DB: Camunda 7.24 → Operaton 2.x, **same DB** | [`cutover-runbook.md`](../checklists/cutover-runbook.md) |

### Step 0 · Reach Camunda 7.24 first

**Goal:** bring the application and its database to Camunda 7.24 and Java 17, and ship that as a normal Camunda
release. On the main path this means Camunda 7.24 EE, patch 7.24.3-ee or later, on Spring Boot 4. The Assess phase
checks whether you still need Step 0; if so, you finish it in the Decide and prepare phase, before any code
conversion. The engine checks almost nothing at startup: only `schema.version = 'fox'`, which every Camunda 7 database
has. So Operaton also starts on an older database and then fails at runtime with SQL errors on missing columns.

**Are you on the main path?** Spring Boot 4 on Camunda 7.24 exists only in EE. From 7.24.3-ee, Camunda ships Spring
Boot 4 starters with a `-4` infix (groupId `org.camunda.bpm.springboot`, for example
`camunda-bpm-spring-boot-starter-4`); 7.24.10-ee and later are based on Spring Boot 4.1. EE versions are named
`7.24.N-ee` and come from the EE repository, because nothing after 7.24.0 is on Maven Central. `assess.sh` names
your path in its *Migration path* row.

Step 0 has three parts:

1. On Camunda 7.23 or older, run Camunda's upgrade scripts up to `*_engine_7.23_to_7.24.sql` and ship a Camunda 7.24
   release. On 7.19 or older (Spring Boot 2.7, `javax`), the move to Spring Boot 3 and Jakarta comes first.
2. Move to **Java 17**, the minimum for Operaton and for Camunda's Spring Boot starter.
3. Run [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql). This pre-flight gate runs read-only
   checks and ends in `GO`, `GO_WITH_WARNINGS` or `NO_GO`. Its schema-level row (P01) must be OK, which means the
   newest `ACT_GE_SCHEMA_LOG` row is `7.24.0`, a `7.24.N` EE patch row or `7.25.0`. An overall NO_GO from the
   admin-group check (P03) is expected at this stage, because nobody is in `operaton-admin` yet.

**Camunda EE patches and the database.** EE patch levels do not change the database schema, and no 7.24.x patch
script is known. If one ever runs, it adds a `7.24.N` row (ID 1301 to 1399) to `ACT_GE_SCHEMA_LOG`. The pre-flight
check accepts such a row, and Operaton never reads that table. The EE license key is stored in the database too;
Operaton ignores it (see the [Camunda EE features decision, D17](#d17)).

### The code change: one recipe run

**Goal:** turn the Camunda code into Operaton 2.x code in one reviewed commit. `scripts/migrate.sh` detects from the
build that the project is on Spring Boot 4: the Spring Boot parent, an imported `spring-boot-dependencies` or the
Gradle plugin `org.springframework.boot` is 4.x, or the build uses a `camunda-bpm-spring-boot-starter-4*` artifact. It
then runs the recipe `starterpack.operaton.MigrateSpringBoot4App` once. This recipe wraps Operaton's official
OpenRewrite recipe (an automated code transformation) and adds what it misses. It maps the `-4` starters, the EE
webapps, the `-jackson3` artifacts and `camunda-bom` to Operaton. It renames packages, types, `camunda.bpm.*` keys,
descriptors and ServiceLoader files, and it fixes script imports, logger names, whitelist values and test
dependencies. All Operaton artifacts get the target version through `operaton-bom`.

```bash
scripts/assess.sh path/to/service > assessment.md   # edition, path, recommended target, next command
scripts/migrate.sh --dry-run path/to/service        # review target/rewrite/rewrite.patch; nothing changes
scripts/migrate.sh --with-infra-env path/to/service                  # Spring Boot 4.0 -> Operaton 2.1.5 (default target)
scripts/migrate.sh --with-infra-env --target 2.2.0 path/to/service   # Spring Boot 4.1 -> Operaton 2.2.0 (once GA, 2026-10-23)
scripts/verify-leftovers.sh path/to/service         # exit 1 on MUST-FIX leftovers
```

- **The dry run only writes the patch.** On Spring Boot 4.1 before the 2.2.0 GA, preview with
  `--dry-run --target 2.2.0-RC1` and rehearse with `--target 2.2.0-RC1` (a release candidate, never for production).
  The recipe writes the target into the `operaton.version` property that `operaton-bom` uses, so after the GA you
  set that property to `2.2.0` (and Spring Boot to the patch that `latest-versions.sh` pairs with it) and test and
  rehearse again before production. `--with-infra-env` also renames `CAMUNDA_BPM_*` variables in Dockerfiles, `.env`,
  compose and k8s/Helm YAML.
- **`verify-leftovers.sh`** finds leftovers: Camunda references that no recipe converted and that Operaton ignores or
  fails on. That includes EE leftovers such as `-4` starters, `-jackson3` artifacts, `-ee` versions,
  `camunda-engine-spring-6`, EE-only settings and calls, the license file and the EE repository.
- **Spring Boot stays where it is.** `migrate.sh` never downgrades Spring Boot. At most it raises the patch version to
  the one the target is built with, for example 4.0.5 to 4.0.8 for Operaton 2.1.5. If your Spring Boot minor differs
  from the target's, it leaves Spring Boot alone and prints a warning with the recommended target.
- **The run needs the Camunda EE repository one last time.** The rewrite plugin resolves all dependencies before the
  recipes run, so it needs the EE repository credentials: server id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or
  `MAVEN_ARGS="-s <settings with the EE credentials>"`. After the conversion the Operaton build no longer needs the
  EE repository. Build and test with `mvn -B clean verify`, remove the repository and its credentials from the build,
  and commit the result as one change. Keep the credentials themselves valid until the rollback window closes, because
  a rebuild of the Camunda build you would roll back to still needs them.
- **`--hop` belongs to the Spring Boot 3.5 path** and is rejected on a Spring Boot 4 project. If the detection is
  wrong, `--source boot4` or `--source boot3` overrides it.

**Exit criteria.** The code change is done when all of these hold:
- The code compiles and the tests are green.
- `verify-leftovers.sh` is clean.
- The build resolves from Maven Central alone, without the EE repository.
- The app boots against a **production DB copy** (a restored copy of the production database, never the live one)
  with the admin-group step applied. That step mirrors `camunda-admin`: it copies the group's members and
  authorizations to `operaton-admin`.
- [`smoke-test.sh`](../scripts/smoke-test.sh), the REST and webapp smoke test that also checks the admin setup page,
  is green.
- The readiness probes follow the [health-probes decision (D13)](#d13).
- Spin JSON variables round-trip, that is, they are written and read back unchanged.
- The EE-only settings are gone, and the mitigation for the missing EE hardening is in place
  ([Camunda EE features, D17](#d17)).

### One production cut-over

Production goes **directly from Camunda 7.24 to Operaton 2.x on the same database**. Target the **latest patch of the
Operaton line that matches your Spring Boot minor** at cut-over time, and pin it. Services that share a database each
make their own code change, but they have **one** joint cut-over, because Camunda and Operaton must never work on the
same database at the same time. With a 2.2.x target, add `<db>_engine_7.24_to_7.25.sql` to the cut-over: it only
writes the `7.25.0` marker row (no DDL). The engine ignores the marker, and the pre-flight checks accept both levels
(details: [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md)). How to switch:
[cut-over strategy (D7)](#d7). The steps are in [Phase 6](#phase-6--cut-over) of the [phased plan](#3-phased-plan),
and the details in [Cut-over, rollback and operations](11-cutover-rollback-and-operations.md).

## 2. Version and compatibility matrix

The matrix shows which platform versions belong to the start and the end of the path. Read one column to see what
your build uses at that point. The two Camunda columns are the Step 0 baselines, the two Operaton columns the
production targets. RC1 is the first release candidate.

| | **Camunda 7.24 EE, Spring Boot 4.0** | **Camunda 7.24 EE, Spring Boot 4.1** | **Operaton 2.1.5** | **Operaton 2.2.x** |
|---|---|---|---|---|
| Role | Step 0 baseline (default of 7.24.3-ee to 7.24.9-ee) | Step 0 baseline (default from 7.24.10-ee) | **Production target for Spring Boot 4.0** | Production target for Spring Boot 4.1, once GA (due 2026-10-23) |
| Spring Boot | 4.0.x | **4.1.x** | **4.0.8** | 4.1.x (2.2.0-RC1: 4.1.1) |
| Spring Boot starters | `-4` infix | `-4` infix | no `-4` infix | no `-4` infix |
| Jakarta EE | 11 (Spring Boot 4) | 11 | 11 | 11 |
| Java (min) | 17 | 17 | 17 | 17 |
| JUnit Jupiter | Spring Boot managed | Spring Boot managed | **6.0.3** | 6.0.3 |
| Jackson | Spring 3; Spin/REST 2 (Jackson 3 opt-in from 7.24.16-ee) | same | Spring 3; Spin/REST **2 only** | same |
| Testcontainers / Liquibase | Spring Boot managed | Spring Boot managed | 2.0.5 / 5.0.3 | same |
| Schema log | 7.24.0 | 7.24.0 | 7.24.0 | **7.25.0** (marker row, no DDL) |
| DB minimums | per Camunda docs | per Camunda docs | PostgreSQL 14, MariaDB 10.11, MySQL 8.4 | same |
| Support | EE maintenance until 13 Apr 2030 | EE maintenance until 13 Apr 2030 | maintained until 2.2 GA | preview (RC1) |

- **Operaton and Spring Boot move together.** Operaton supports only the Spring Boot version each release is built
  with: 2.1.5 with 4.0.8, 2.2.x with 4.1.x. [`scripts/latest-versions.sh`](../scripts/latest-versions.sh) reads the
  pairs from Maven Central. Operaton 2.1.5 on Spring Boot 4.1.1 started and passed a smoke test, but this pairing is
  unsupported. No Operaton line is built with Spring Boot 4.2 yet: migrate on Spring Boot 4.1, or wait for the
  matching Operaton line.
- **The Spring Boot minor of your application decides, not the Camunda patch.** Camunda's patch notes allow 7.24.10-ee
  and later to stay on Spring Boot 4.0 by importing `spring-boot-dependencies` 4.0.7. Such an application targets
  Operaton 2.1.5.
- **2.2.x becomes the target once it is GA**, because 2.1 loses support when 2.2.0 ships (October 2026) and Spring
  Boot 4.0 OSS support ends 2026-12-31. If you go live on 2.1.5, moving to 2.2 after the cut-over is a normal minor
  upgrade together with Spring Boot 4.1
  ([Moving from 2.1.x to 2.2.x](12-operaton-2-and-spring-boot-4.md#moving-from-21x-to-22x)), and the `7.25.0` row does
  not block going back.
- On MySQL 8.0 or PostgreSQL 13, plan a database upgrade as a separate change before the migration.

## 3. Phased plan

The plan splits the migration of one service into eight phases, from the first inventory to the clean-up after
go-live. Run it per service. Services that share a database share the Rehearse and Cut-over phases, because Camunda
and Operaton must never work on the same database at the same time. The phases are gates, not a waterfall: work may
overlap, but a phase is only done when its gate is passed. Review the
[decision log](../checklists/decision-log-template.md) at every gate.

The phases have the same names and order as the eight steps in the [README](../README.md#step-by-step) and the
sections of the [migration checklist](../checklists/migration-checklist.md). Step 0 is not a phase of its own: Assess
checks it, and Decide and prepare finishes it if needed.

Record a choice for every decision in the Decide and prepare phase. The *Decisions* line under each phase names the
decisions that the phase feeds with facts, carries out or closes, so that you know which ones to re-check at its gate.

| Phase | What it achieves |
|---|---|
| [1 · Assess](#phase-1--assess) | You know what you are migrating and how big the change is. |
| [2 · Decide and prepare](#phase-2--decide-and-prepare) | The decisions are recorded, and everything that works on both engines is fixed and shipped on Camunda 7.24. |
| [3 · Convert](#phase-3--convert) | The code is converted to Operaton 2.x. |
| [4 · Verify](#phase-4--verify) | The converted app is proven on a copy of production data. |
| [5 · Rehearse](#phase-5--rehearse) | Cut-over and rollback run cleanly and are timed. |
| [6 · Cut-over](#phase-6--cut-over) | Production runs on Operaton. |
| [7 · Hypercare](#phase-7--hypercare) | Production is watched closely while rollback is still possible. |
| [8 · Clean-up](#phase-8--clean-up) | Migration aids are removed and postponed conversions are done. |

### Phase 1 · Assess

**Goal:** find out what you are migrating before you plan it. The dry run of the code change is the best input for
the effort estimate, because its patch shows how much the recipe changes.

- Take an inventory of every repository that touches the engine.
- Confirm the Camunda version, the edition (CE or EE), the Spring Boot version and the Java version, so that you know
  whether [Step 0](#step-0--reach-camunda-724-first) is still needed and which Operaton target applies. `assess.sh`
  reports the edition, the migration path and the recommended target.
- Run the two read-only SQL scans on a production copy. They show the schema level, the admin group and the variables
  that hold `org.camunda.*` objects; count those variables. The pre-flight scan also lists the stored task filters
  that use expressions (P11), which matter for the missing EE hardening.
- Run a dry run with `migrate.sh --dry-run`.
- If you run EE, list the EE features in daily use: the EE webapp features, Optimize, the license and the EE-only
  engine settings.
- Interview ops, the DBA, security, the process owners and the consumer teams about what no scan sees.

**Tools:** [`assess.sh`](../scripts/assess.sh),
[`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql),
[`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql), `migrate.sh --dry-run`.
Details: [Assessment](02-assessment.md).

**Decisions:** [target version and path (D1)](#d1), [support model (D14)](#d14),
[Camunda EE features (D17)](#d17).

<a id="phase-2--prepare"></a>

### Phase 2 · Decide and prepare

**Goal:** record the migration decisions, then fix on Camunda 7.24 everything that also works on Operaton and ship it
as a normal Camunda release. Every fix you ship before the cut-over is one less risk on cut-over day, and it keeps the
way back open.

- Record a choice, an owner and a date for every decision in the
  [decision log](../checklists/decision-log-template.md). The [decision catalogue](#4-decision-catalogue) recommends
  an option for each.
- Complete [Step 0](#step-0--reach-camunda-724-first) if the Assess phase showed that code or database is older than
  Camunda 7.24.
- Upgrade the database if it is below the minimums in the [version matrix](#2-version-and-compatibility-matrix).
- Pin versions, so that the build cannot resolve a release candidate (see [Watch out](#watch-out)).
- Add safety-net tests for scripts, forms and exporters. They cover behaviour that no compiler checks, so anything the
  conversion breaks shows up as a red test.
- Convert or drain the variables that hold `org.camunda.*` objects. The
  [legacy-variables decision (D18)](#d18) explains both options.
- If you run EE, decide what replaces each EE feature you use and how you mitigate the missing EE hardening
  ([Camunda EE features, D17](#d17)).
- Inform the consumer teams of your exported events, because the payloads will change.

**Tools:** [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql),
[`latest-versions.sh`](../scripts/latest-versions.sh).

**Decisions:** [target version and path (D1)](#d1), [recipe toolchain (D2)](#d2),
[BPMN/DMN namespace (D3)](#d3), [Camunda Forms keys (D4)](#d4), [history exporters (D9)](#d9),
[test stack (D11)](#d11), [modeler (D12)](#d12), [Camunda EE features (D17)](#d17),
[variables with `org.camunda.*` objects (D18)](#d18).

### Phase 3 · Convert

**Goal:** turn the code into an Operaton 2.x build in one commit, and prepare the admin-group migration that must run
before the first start.

- Run `migrate.sh` once, fix what it reports, and commit the result as one change.
- Convert the files around the code too: Docker, Helm, ingress and logback configuration.
- On EE, port code that uses Jackson 3 (`tools.jackson.*`) for Spin, REST or the external task client back to
  Jackson 2, remove the EE-only settings and calls and the license file, and remove the EE repository and its
  credentials from the build ([Camunda EE features, D17](#d17)).
- Prepare the admin-group migration, which mirrors `camunda-admin` to `operaton-admin`.

**Tools:** [`migrate.sh`](../scripts/migrate.sh), [`verify-leftovers.sh`](../scripts/verify-leftovers.sh),
[`10-migrate-admin-group.sql`](../sql/postgresql/10-migrate-admin-group.sql),
[`AdminGroupMigrationPlugin`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java).

**Decisions:** [admin group (D5)](#d5), [webapp path (D6)](#d6), [schema management (D8)](#d8),
[direct database scripts (D10)](#d10), [health probes (D13)](#d13), [webapps (D16)](#d16),
[Camunda EE features (D17)](#d17).

### Phase 4 · Verify

**Goal:** prove that the converted application works on real data before anyone rehearses the cut-over.

- Run the tests.
- Boot the app on a production DB copy with `operaton.bpm.job-execution.enabled=false` and outbound calls stubbed, so
  that the copy runs no jobs and calls no real systems.
- Check that the setup page is closed (see below).
- Check that logs, metrics and alerts work as before (log, metric and alert parity).
- Let the consumer teams test the new event payloads.
- If you switched off expressions in stored queries, open the filters that the pre-flight check P11 listed: they fail
  with "Expressions are forbidden in stored queries" until you rewrite them.

**Tool:** [`smoke-test.sh`](../scripts/smoke-test.sh).

**Decisions:** [history exporters (D9)](#d9), [health probes (D13)](#d13), [Camunda EE features (D17)](#d17).

**How to check that the setup page is closed.** The setup page of the Admin webapp creates an admin user without a
login. With DB identity (users stored in the engine database), it opens when nobody is in `operaton-admin`. It is
closed when `GET <app-path>/app/admin/default/` does not redirect to `…/setup/` (`<app-path>` is your webapp path, for
example `/camunda`); `smoke-test.sh` checks this. A 403 on the setup POST proves nothing, because the CSRF filter
returns 403 even when setup is open. **Never POST to the setup endpoint on production**: if it is open, the POST
creates an admin.

### Phase 5 · Rehearse

**Goal:** practise the cut-over and the rollback until both run cleanly, so that you know the steps and the downtime
before cut-over day.

On a fresh production copy, run the runbook and the rollback, and record the timings. Repeat until you have two clean
rounds, one of them with rollback.

**Tool:** [`cutover-runbook.md`](../checklists/cutover-runbook.md).

**Decisions:** [cut-over strategy (D7)](#d7), [rollback and point of no return (D15)](#d15).

### Phase 6 · Cut-over

**Goal:** switch production to Operaton in one maintenance window, in an order that secures and checks the database
before the first Operaton node starts.

1. Freeze deployments, so that no new model version creates data Camunda cannot run. The runbook starts the freeze
   the day before (step F-01) and keeps it until the rollback window closes.
2. Block `<app-path>/api/admin/setup/` at the ingress, so that nobody can reach the setup page. The block stays after
   go-live.
3. Stop all Camunda nodes, so that Camunda and Operaton never run on the database at the same time (a mixed cluster).
4. Release the job locks of the stopped nodes: wait until they expire (default 5 min) or reset them. The pre-flight
   checks report NO_GO while a job is still locked.
5. Take a backup.
6. If the engine schema is managed by Liquibase, apply the rehearsed Liquibase fix.
7. Run the admin-group SQL (`10-migrate-admin-group.sql`), so that your admins are in `operaton-admin` before
   Operaton starts.
8. Run the pre-flight checks and continue only on GO (or GO_WITH_WARNINGS).
9. Start one Operaton node, without user traffic.
10. Run the parse warm-up and the smoke test, then decide go or no-go. On no-go, roll back before traffic.
11. Scale out and open the traffic.

The [runbook](../checklists/cutover-runbook.md#t0--cut-over) has each step with an owner, a command and a check.

**Tools:** the runbook, the SQL scripts, `smoke-test.sh`.

**Decisions carried out:** [admin group (D5)](#d5), [cut-over strategy (D7)](#d7), [schema management (D8)](#d8),
[rollback and point of no return (D15)](#d15).

### Phase 7 · Hypercare

**Goal:** watch production closely right after the cut-over, while rollback is still possible. The rollback window
ends at whichever comes first: the point of no return (the moment Operaton first writes data that Camunda cannot read
or run) or the end of the agreed time cap (see [rollback and point of no return, D15](#d15)).

- Watch incidents, especially from scripts on old definition versions.
- Watch the job backlog and the exporter lag.
- Check that logging and alerts pick up the new logger names.
- Run the [compatibility checkpoint](../checklists/cutover-runbook.md#compatibility-checkpoint-c1c3) daily, so that
  you notice the point of no return when it happens.

**Tool:** the runbook.

**Decision:** close [rollback and point of no return (D15)](#d15) when the rollback window ends.

### Phase 8 · Clean-up

**Goal:** after the rollback window has closed, remove what you kept only for the migration, and do the conversions
you postponed.

- Drop the `camunda-admin` rows.
- If you decided to move later, move the webapps to `/operaton` with a redirect from the old path, and convert
  `camunda:` → `operaton:` per deployment unit.
- Remove the migration helpers (`AdminGroupMigrationPlugin`, later `LegacyCamundaConfigGuard`). If you came from
  Camunda EE, also remove the license leftovers (the Camunda license files and their secrets) and revoke the EE
  repository credentials.
- If you went live on 2.1.5, plan the move to 2.2.x, because 2.1 loses support when 2.2.0 ships.

Details: [Hypercare and clean-up](11-cutover-rollback-and-operations.md#hypercare-and-clean-up).

**Tools:** the [`migration/`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/)
helpers.

**Decisions:** [BPMN/DMN namespace (D3)](#d3), [webapp path (D6)](#d6), [modeler (D12)](#d12),
[webapps (D16)](#d16).

<a id="decisions"></a>

## 4. Decision catalogue

A migration involves 18 decisions. The table gives an overview, including the role that usually owns each decision.
The sub-sections below give the question, the recommendation, the reason and where to read more. Record your choice,
an owner and a date for each decision in your copy of the [decision log](../checklists/decision-log-template.md).
Six decisions are **mandatory** before the first start on real data. One of them, the Camunda EE features decision
(D17), is mandatory for every team that runs Camunda EE, which includes everyone on Spring Boot 4.

| ID | Decision | Mandatory | Recommendation | Owner |
|---|---|---|---|---|
| [D1](#d1) | Target version and path | no | Spring Boot 4 path: one recipe run, one cut-over; 2.1.5 for Spring Boot 4.0, 2.2.x for 4.1 | tech lead |
| [D2](#d2) | Recipe toolchain | no | `migrate.sh`, which detects the path; dry run first | tech lead |
| [D3](#d3) | BPMN/DMN namespace | no | Keep `camunda:` now, convert later | developers |
| [D4](#d4) | Camunda Forms keys | no | `formRef` for the Operaton Tasklist, keep the key for your own UI | developers, process owners |
| [D5](#d5) | Admin group | **yes** | Mirror `camunda-admin` to `operaton-admin` before the first start | DBA, security |
| [D6](#d6) | Webapp path | no | Keep `/camunda` explicitly, move later | ops |
| [D7](#d7) | Cut-over strategy | **yes** | Big bang on the same database, no mixed cluster | tech lead |
| [D8](#d8) | Schema management | **yes** | `schema-update: false` plus the pre-flight gate | DBA |
| [D9](#d9) | History exporters | no | Publish after commit, dual-read consumers | developers, consumer teams |
| [D10](#d10) | Direct database scripts | no | Replace routine SQL with the API | DBA |
| [D11](#d11) | Test stack | no | Operaton test starter and `operaton.cfg.xml` | developers |
| [D12](#d12) | Modeler | no | Camunda Desktop Modeler while models use `camunda:` | developers |
| [D13](#d13) | Health probes | no | `processEngine` in readiness only | ops |
| [D14](#d14) | Support model | no | Decide before go-live | tech lead, security |
| [D15](#d15) | Rollback and point of no return | **yes** | Event-based point of no return plus a time cap | ops, process owners |
| [D16](#d16) | Webapps | no | Classic webapps | ops |
| [D17](#d17) | Camunda EE features | **yes** (EE) | Replace EE features, mitigate the missing hardening, back to Jackson 2, drop license and EE repository | process owners, security, developers |
| [D18](#d18) | Variables with `org.camunda.*` objects | **yes** | Detect, then convert or drain | developers |

<a id="d1"></a>

### D1 · Target version and path

**Question:** Which Operaton version does production run, and which path does the code take to get there?

**Recommendation:** Take the Spring Boot 4 path. From Camunda 7.24 EE on Spring Boot 4, convert the code with
`migrate.sh` in one recipe run and one commit, and switch production in one cut-over on the same database. Choose the
target by the Spring Boot minor version of your application, and pin it:

- **Spring Boot 4.0:** Operaton 2.1.5, the default target of `migrate.sh`. Plan the move to 2.2 soon after.
- **Spring Boot 4.1:** Operaton 2.2.x (`--target 2.2.0`, GA due 2026-10-23). Until the GA, rehearse with
  `--target 2.2.0-RC1`, never in production.
- **Spring Boot 4.2 or later:** no Operaton line is built with it yet. Migrate on Spring Boot 4.1, or wait for the
  matching Operaton line.
- **Spring Boot 3.5:** the two-hop path via the Operaton 1.1.5 checkpoint, and one combined run (`--hop all`) only for
  small, well-tested services ([When one hop is fine](15-coming-from-spring-boot-3.md#when-one-hop-is-fine)).

**Why:** Your application is already on Spring Boot 4, so the platform around the engine stays and one code change is
enough. Operaton supports only the Spring Boot version each release is built with (2.1.5 with 4.0.8, 2.2 with 4.1.x).
`migrate.sh` never downgrades Spring Boot, so its default target 2.1.5 on a Spring Boot 4.1 project gives an
unsupported pairing; `migrate.sh` warns about it. Operaton 2.1 loses support when 2.2.0 ships in October 2026. A
pre-release such as 2.2.0-RC1 is not intended for production, and unpinned versions can resolve to a release
candidate (see [Watch out](#watch-out)).

**Details:** [The path](#path), [version matrix](#2-version-and-compatibility-matrix),
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md).

<a id="d2"></a>

### D2 · Recipe toolchain

**Question:** Which tool converts the code?

**Recommendation:** Use `scripts/migrate.sh`, and always run a dry run first. It detects the path from the build
(`--source auto`). On Spring Boot 4 it runs `starterpack.operaton.MigrateSpringBoot4App` once, with
`rewrite-maven-plugin` 6.46.1 (Gradle: OpenRewrite Gradle plugin 7.39.0) and the official recipe
`org.operaton:migrate-camunda-recipe` 1.0.1.

**Why:** This composite recipe wraps the official recipe and adds fixes for what it misses. The official recipe alone
maps no `-4` starter and no `-jackson3` artifact, and it always writes Operaton 1.0.x, a Spring Boot 3.5 line that is
end of life. On a Spring Boot 4 project it renames the Java imports but leaves the `-4` starters, and the build
breaks. Never use the generic `MigrateFromCamunda`: it doesn't rename `camunda.bpm.*` keys, so your configuration is
silently ignored. Never use `sed`: it breaks `org.camunda.feel`, the FEEL engine that Operaton still uses.
`migrate.sh` rejects `--hop` on a Spring Boot 4 project, because the recipes of the Spring Boot 3.5 path break such a
project ([Recipes of the Spring Boot 3.5 path](03-openrewrite-recipes.md#recipes-of-the-spring-boot-35-path)).

The dry run shows the whole patch before anything changes. It matters even more here, because the Spring Boot 4 path
was tested end to end against a stub of the EE repository ([`tools/test-boot4-path.sh`](../tools/test-boot4-path.sh)),
not against Camunda's real EE artifacts. On Gradle, the Spring Boot 4 path has not been run end to end, and version
catalogs (`gradle/libs.versions.toml`) are never migrated.

**Details:** [OpenRewrite recipes](03-openrewrite-recipes.md).

<a id="d3"></a>

### D3 · BPMN/DMN namespace

**Question:** Do your BPMN and DMN files keep the `camunda:` namespace during the migration, or do you convert them to
`operaton:`?

**Recommendation:** Keep `camunda:` now and convert later, per deployment unit. Never mix both namespaces in one file.
Fix `org.camunda.*` script imports now, ideally package-free and deployed on 7.24.

**Why:** Operaton reads both namespaces, but Camunda 7.24 silently ignores `operaton:`. Keeping `camunda:` creates no
new versions, and Camunda can still run every deployed model, so rollback stays possible. In a file that mixes both,
`operaton:` wins on each element and the `camunda:` attributes there are silently ignored.

The script imports cannot wait: scripts with `org.camunda.*` imports deploy fine and fail at runtime, also in running
instances. A package-free script references no `org.camunda.*` (or `org.operaton.*`) class, only process variables
and the pre-bound `S(…)` function. It runs on both engines, so you can deploy it on Camunda 7.24 before the cut-over
without losing the option to roll back.

**Details:** [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

<a id="d4"></a>

### D4 · Camunda Forms keys

**Question:** Who renders the task forms that use `camunda-forms:` keys: your own UI or the Operaton Tasklist?

**Recommendation:** If your own UI renders the forms, keep `camunda-forms:` and switch your client from
`camundaFormRef` to `operatonFormRef`. If the Operaton Tasklist renders them, use `formRef` (rollback-safe, deploy on
7.24) rather than `operaton-forms:`, which is a hard stop for [rollback (D15)](#d15).

**Why:** The Operaton Tasklist does not render `camunda-forms:` keys. A client that still reads the REST field
`camundaFormRef` gets `null` and shows no form. `formRef` works on both engines, so you can deploy it on Camunda 7.24
before the cut-over. Camunda 7.24 cannot resolve `operaton-forms:` keys, so once tasks are open on them, they are a
hard stop: a change that only Operaton can handle and that blocks a plain rollback to Camunda.

**Details:** [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

<a id="d5"></a>

### D5 · Admin group (mandatory)

**Question:** How do your administrators become members of `operaton-admin`?

**Recommendation:** With DB identity (users stored in the engine database), mirror `camunda-admin` to `operaton-admin`
before the first start: run `10-migrate-admin-group.sql`, plus `AdminGroupMigrationPlugin` as a safety net. Block
`<app-path>/api/admin/setup/*` at the ingress. With LDAP, Keycloak or OAuth2, map the admin group in the identity
provider (IdP).

**Why:** Camunda's webapps treat members of `camunda-admin` as administrators. Operaton hard-codes `operaton-admin`,
and nothing migrates the group. With DB identity, nobody is then an Operaton admin, so the webapps think this is a
fresh installation and the unauthenticated setup page reopens: anyone who can reach it can create an admin user.

**Details:** [Identity, admin group and security](07-identity-admin-group-and-security.md).

<a id="d6"></a>

### D6 · Webapp path

**Question:** Do the webapps (Cockpit, Tasklist, Admin) stay at `/camunda` for the cut-over, or move to `/operaton`?

**Recommendation:** Keep `/camunda` for the cut-over with an explicit `operaton.bpm.webapp.application-path: /camunda`.
Move later, with a redirect.

**Why:** Operaton's default path is `/operaton`. A lost key silently moves you to `/operaton`, and then ingress rules,
SSO redirect URIs, health checks and bookmarks return 404. Moving with the cut-over would change all of them inside
the cut-over window.

**Details:** [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md).

<a id="d7"></a>

### D7 · Cut-over strategy (mandatory)

**Question:** How do you switch production from Camunda to Operaton?

**Recommendation:** Big bang on the same database: stop all Camunda nodes, then start Operaton. Rehearse it on a
production copy. **No mixed Camunda/Operaton cluster** (Kubernetes: `strategy.type: Recreate`).

**Why:** In a mixed cluster, Camunda and Operaton nodes work on the same database at the same time, and jobs run on
whichever engine picks them up. Camunda cannot run `operaton:` definitions, and neither engine reads the other's
serialized classes. Kubernetes' default `RollingUpdate` creates exactly such a mixed cluster, so the cut-over release
uses `Recreate`.

**Details:** [Cut-over, rollback and operations](11-cutover-rollback-and-operations.md).

<a id="d8"></a>

### D8 · Schema management (mandatory)

**Question:** Who may change the database schema, and what is checked before the first start?

**Recommendation:** Set `schema-update: false` and gate the start with `00-preflight-checks.sql`, in production too.
With Liquibase, apply the [Liquibase fix](08-database-schema-data-and-sql-scripts.md#liquibase) from the database chapter and keep its
reverse, which the rollback build needs.

**Why:** The engine itself checks almost nothing at startup (see [Step 0](#step-0--reach-camunda-724-first)), so it
starts on a database it does not fit and fails later at runtime. `schema-update: true` only creates missing tables; it
never checks versions or runs upgrade scripts. The pre-flight gate closes this gap: on `NO_GO` it ends with exit
code 3. With Liquibase, a naive switch fails on the first start, because Operaton changed the changelog path and
author.

**Details:** [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).

<a id="d9"></a>

### D9 · History exporters

**Question:** How do your history exporters (code that publishes engine history events to other systems, such as
Kafka) publish, and what do their consumers expect?

**Recommendation:** Publish after commit, never inside the engine transaction. The `org.operaton…` class names are a
breaking event-schema change: use a versioned topic or a type field, and dual-read consumers that accept both the old
and the new format.

**Why:** History handlers run inside the engine transaction, so an exporter that publishes there also publishes work
that is later rolled back. Class names in payloads change from `org.camunda…` to `org.operaton…`, and consumers that
route or deserialize on them break without a build error.

**Details:** [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md).

<a id="d10"></a>

### D10 · Direct database scripts

**Question:** What happens to scripts that change the `ACT_*` tables directly with SQL?

**Recommendation:** Replace routine SQL with the Java API or REST. Keep only the emergency SQL for job retries
([`30-emergency-job-retries.sql`](../sql/postgresql/30-emergency-job-retries.sql)) and external-task retries
([`31-emergency-external-task-retries.sql`](../sql/postgresql/31-emergency-external-task-retries.sql)), and run it with
all engine nodes stopped. For the job-retries script, pausing job execution on all nodes
(`operaton.bpm.job-execution.enabled=false`) is enough; see the
[emergency SQL rules](08-database-schema-data-and-sql-scripts.md#emergency-sql-strict-rules-of-use).

**Why:** Direct SQL still runs on Operaton and still corrupts engine state. It skips the `REV_` bump (lost updates),
can leave jobs locked forever, leaves incidents and history open, and writes no operation log.

**Details:** [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).

<a id="d11"></a>

### D11 · Test stack

**Question:** Which test libraries replace the Camunda ones?

**Recommendation:** Use `operaton-bpm-spring-boot-starter-test-junit5` + `operaton-bpm-assert`, never
`operaton-bpm-junit5`. `migrate.sh` maps Camunda's `camunda-bpm-spring-boot-starter-4-test` to the Operaton test
starter. Rename `camunda.cfg.xml` → `operaton.cfg.xml`.

**Why:** `operaton-bpm-junit5` is empty on 1.x. From 1.1 on, a test without `operaton.cfg.xml` silently uses a
default engine without your plugins, so a green test no longer proves that your configuration works.

**Details:** [Testing](10-testing.md).

<a id="d12"></a>

### D12 · Modeler

**Question:** Which modeler do your teams use to edit BPMN and DMN files?

**Recommendation:** Keep Camunda Desktop Modeler while models use `camunda:`, and pilot the Operaton Modeler.

**Why:** The Operaton Modeler has no released binaries, and it offers to convert `camunda:` files when it opens them.
A modeler that writes `operaton:` creates new versions and mixed files. Switch the modeler together with the
conversion of the [BPMN/DMN namespace (D3)](#d3).

**Details:** [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

<a id="d13"></a>

### D13 · Health probes

**Question:** Which health indicators do your liveness and readiness probes include?

**Recommendation:** From 2.1 on, put `processEngine` in the readiness group only, never in liveness.

**Why:** Since 2.1, `processEngine` reports DOWN when the database is unreachable. If liveness includes it, every pod
restarts during a database outage or failover.

**Details:** [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md),
[Cut-over, rollback and operations](11-cutover-rollback-and-operations.md).

<a id="d14"></a>

### D14 · Support model

**Question:** Who supports Operaton for you in production: the community, a commercial provider or your own team?

**Recommendation:** Decide before go-live. For business-critical processes, use a commercial provider or a staffed
in-house team.

**Why:** Operaton has no long-term support (LTS), security fixes come only for the latest minor, and the project
gives no service level agreement (SLA). Without a provider that backports fixes to your line, budget a minor upgrade
every six months.

**Details:** [Ecosystem, support and resources](14-ecosystem-support-and-resources.md).

<a id="d15"></a>

### D15 · Rollback and point of no return (mandatory)

**Question:** Until when can you go back to Camunda, and who decides?

**Recommendation:** Define an event-based point of no return plus a time cap (e.g. 72 h); the rollback window ends
at whichever comes first. Name one decider, and keep deployments frozen until the window closes. Know the hard stops:
versions with `operaton:` attributes, `org.operaton.*` script references or `operaton-forms:` keys that have
instances, and Java-serialized `org.operaton.*` variables.

**Why:** Rollback means redeploying the last Camunda build on the same database. That works without a restore only
until Operaton writes something Camunda 7.24 cannot read or run. This moment is the point of no return, and each hard
stop above is such data. After it, rollback means restoring the backup and losing all work since the cut-over. The
deployment freeze keeps new deployments from creating a hard stop by accident.

**Details:** [Cut-over, rollback and operations](11-cutover-rollback-and-operations.md).

<a id="d16"></a>

### D16 · Webapps

**Question:** Which webapps do your users work with: the classic webapps or webapps-neo?

**Recommendation:** Stay on the classic webapps. Evaluate webapps-neo (2.2 preview, no embedded HTML forms) after
2.2 GA.

**Why:** webapps-neo is a technical preview in 2.2 and off by default. It has its own plugin system and does not
render embedded HTML forms.

**Details:** [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md).

<a id="d17"></a>
<a id="d17--camunda-ee-features"></a>

### D17 · Camunda EE features (mandatory for EE)

**Question:** Which Camunda EE features, settings and artifacts does your application use, and what replaces each of
them on Operaton?

**Recommendation:** Work through all five areas before the first start on real data:

1. **EE webapp features.** Inventory who uses the EE screens in Cockpit (history view, heatmap, instance
   modification, migration UI, batches, reports) and test a REST replacement for each before go-live. Optimize is not
   supported.
2. **EE security hardening.** Remove the EE-only settings and calls before the first Operaton start. Then set the
   generic property `enable-expressions-in-stored-queries: false` unless your stored task filters need expressions
   such as `${currentUser()}`, keep `enable-expressions-in-adhoc-queries` false, and restrict who may create or update
   filters. Keep `spring.datasource.hikari.auto-commit: false`, and validate user and group ids in the code that
   creates authorizations.
3. **Jackson 3 opt-in.** If you use the `-jackson3` artifacts of 7.24.16-ee, go back to Jackson 2: `migrate.sh` maps
   the artifacts, and you port code written against `tools.jackson.*` for Spin, REST or the external task client to
   `com.fasterxml.jackson.*`.
4. **License.** The recipe deletes `camunda.bpm.license-file`. Remove `camunda-license.txt`, license mounts and
   secrets, and calls to `ManagementService#setLicenseKey`. Keep the license key in the database for rollback.
5. **EE repository.** Keep access to the Camunda EE repository while the recipe runs. Then remove the repository, its
   `<server>` credentials and the CI secrets from the Operaton build, and prove that the build resolves from Maven
   Central alone. Revoke the credentials only in the clean-up, after the rollback window has closed.

**Why:** Operaton is a fork of Camunda 7 CE, so none of these EE parts exist there, and most of them disappear without
an error:

- The recipe maps the EE webapp artifacts to the CE webapps, so the EE screens vanish without a build error. The
  engine API behind them was never EE-only, so REST calls can replace each of them.
- Operaton has no query-expression allow-list (7.24.7-ee), no `validateAuthResourceIdExists` and no datasource
  autocommit check (both 7.24.3-ee). It behaves like Camunda before 7.24.7: stored task filters evaluate any
  expression, because `enableExpressionsInStoredQueries` defaults to true. Camunda security notice 157 (2026-04-10)
  describes expression injection via stored task filters and ad-hoc task queries. It affects Camunda 7.24.6 and older
  when `enableExpressionsInStoredQueries` is true and a user may update filters, or when
  `enableExpressionsInAdhocQueries` is true. Operaton has published no advisory. Switching expressions off makes
  filters with expressions fail with "Expressions are forbidden in stored queries"; the pre-flight check P11 lists
  them, and no rows means it is safe to switch them off.
- The EE-only names break the conversion in three ways. As generic properties (`queryExpressionAllowListEnabled`,
  `allowedExpression*InQueries`, `validateAuthResourceIdExists`) they **stop the engine start**, because Operaton does
  not know them and `ignore-unknown-fields` defaults to false. The Java calls (`setQueryExpressionValidator`,
  `setAllowed*InQueries`, `setValidateAuthResourceIdExists`, `ManagementService#setLicenseKey`) do not compile. And
  `operaton.bpm.authorization.validate-auth-resource-id-exists` is **silently ignored**.
- Operaton 2.x has no Jackson 3 artifacts for Spin, the engine REST API or the external task client; it stays on
  Jackson 2. Code against `tools.jackson.*` in these places does not compile, and no recipe rewrites it.
- Operaton needs no license. Camunda stores the key in the database (`ACT_GE_BYTEARRAY` resource
  `camunda-license-key`, `ACT_GE_PROPERTY` `camunda-license-key-id`). Operaton ignores these rows, so keep them for a
  rollback to Camunda.
- The rewrite plugin resolves all dependencies, including test dependencies, before a recipe runs, so the conversion
  of an EE build needs the EE repository. After it, the Operaton build does not. Only a rebuild or hotfix of the
  Camunda build that a rollback would redeploy still needs the EE repository, because its `7.24.N-ee` artifacts exist
  only there.

`assess.sh` and `verify-leftovers.sh` find the EE artifacts, settings, API calls, license files and the EE repository
in your code, and the pre-flight check P11 finds the stored filters with expressions. These tools only report: none of
them replaces the EE hardening.

**Details:** [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md) (EE webapps, license),
[Identity, admin group and security](07-identity-admin-group-and-security.md) (EE hardening),
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md) (Jackson),
[OpenRewrite recipes](03-openrewrite-recipes.md) (EE repository).

<a id="d18"></a>

### D18 · Variables with `org.camunda.*` objects (mandatory)

**Question:** What happens to stored variables that contain `org.camunda.*` objects?

**Recommendation:** Detect them with `20-find-legacy-references.sql`, then convert (on 7.24) or drain before the
cut-over. Never rewrite serialized bytes.

**Why:** Operaton has no `org.camunda.*` classes and no compatibility layer, so it cannot load these variables
(`ClassNotFoundException`) and the affected instances fail. **Converting** means reading each affected variable
through the API in a Camunda 7.24 release and setting it again as JSON, primitives or your own DTO. **Draining** means
letting the affected instances finish on Camunda before the cut-over.

**Details:** [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).

<a id="roles"></a>

## 5. Effort and roles

This section shows where the effort goes and who must be involved, so that you can staff the migration.

- The code conversion is cheap. The effort goes into Step 0, missing tests, `org.camunda.*` variables, replacing the
  Camunda EE features you use, verification and rehearsals.
- The owner role of each decision is in the [decision overview](#4-decision-catalogue): tech lead, developers, ops,
  DBA, security, process owners and consumer teams. The tech lead also owns the go/no-go decision.
- Involve **security** and the **consumer teams** from the start, because no test in your repository catches the
  open setup endpoint ([admin group, D5](#d5)), the loss of the EE security hardening
  ([Camunda EE features, D17](#d17)) or the changed event payload ([history exporters, D9](#d9)).

## Watch out

Each entry names the symptom you see, its cause and the fix.

- **Symptom:** the build resolves `2.2.0-RC1`.
  **Cause:** Maven metadata points to the release candidate (RC).
  **Fix:** pin `org.operaton.bpm:operaton-bom:<v>`, and make Renovate/Dependabot ignore `-RC`/`-M` versions.
- **Symptom:** `migrate.sh` prints
  `WARN: Operaton 2.1.5 is built with Spring Boot 4.0.8 (only that pairing is supported), the project is on Spring Boot 4.1.1.`
  **Cause:** the default target 2.1.5 on a Spring Boot 4.1 project.
  **Fix:** use `--target 2.2.0` once it is GA, and `--target 2.2.0-RC1` for rehearsals only
  ([target version and path, D1](#d1)).
- **Symptom:** the `migrate.sh` run on an EE build fails with dependency resolution errors (401 or 403).
  **Cause:** the run has no access to the Camunda EE repository, but the rewrite plugin resolves all dependencies
  before the recipes run.
  **Fix:** provide the credentials (server id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or
  `MAVEN_ARGS="-s <settings with the EE credentials>"`) for this one run.
- **Symptom:** the first Operaton start fails on an unknown generic property.
  **Cause:** EE-only engine properties such as `queryExpressionAllowListEnabled` or `validateAuthResourceIdExists`
  under `generic-properties`.
  **Fix:** remove them (`verify-leftovers.sh` reports them) and apply the mitigation from the
  [Camunda EE features decision (D17)](#d17).
- **Symptom:** SQL errors on missing `ACT_RU_EXECUTION.PROC_DEF_KEY_` or `ACT_HI_COMMENT.REV_`.
  **Cause:** the database is below 7.23.
  **Fix:** do [Step 0](#step-0--reach-camunda-724-first), and run the pre-flight SQL before every start on real data.
- **Symptom:** Camunda and Operaton pods run side by side.
  **Cause:** Kubernetes `RollingUpdate`.
  **Fix:** use `Recreate` ([cut-over strategy, D7](#d7)).
