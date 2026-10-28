# 08 · Database: schema, persisted data and SQL scripts

This chapter is for DBAs and for whoever owns the engine database. It explains why the database needs no schema
migration, which checks you run before the first Operaton start, what changes for Liquibase and Flyway, and which
stored data still refers to Camunda, including what Camunda EE (Enterprise Edition) leaves in the database. Read it
when you plan Step 0 (bringing code and database to Camunda 7.24 first), and again before the rehearsal on a
production copy (a restored copy of the production database, never the live one).

**In short**
- **There is no schema migration.** Operaton is a fork of Camunda 7 CE (Community Edition) and kept its database
  schema: Operaton 1.0 to 2.1.x has the **same 49 `ACT_*` tables with the same DDL** as Camunda 7.24.0. Operaton 2.2
  only adds a `7.25.0` row to the schema log. Camunda EE patch levels such as 7.24.16-ee do not change the schema
  either. Database, schema and user names that contain `camunda` are cosmetic, so keep your database and its name.
- **The engine checks almost nothing at startup, so you have to check.** Operaton also starts on an older database;
  on Camunda 7.22 or older it then fails at runtime. Be on **Camunda 7.24 first**, and gate the first start with the
  pre-flight gate [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql), a set of read-only checks
  that ends in `GO`, `GO_WITH_WARNINGS` or `NO_GO`.
- **Camunda EE data stays where it is.** Operaton ignores the EE license key that Camunda stores in the database, and
  a possible EE patch row in the schema log. Keep both, because a rollback to Camunda EE uses the same database. The
  pre-flight gate also lists stored task filters with expressions (check P11), which matter for the
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17).
- **If Liquibase manages your engine schema, a naive switch fails on the first start**, because Operaton ships the
  changelog under a new file name, with new authors and new checksums. Before the first start, apply one of the two
  [Liquibase fixes](#liquibase): re-sync the changelog under its new name (Fix E) or keep the old file path with a
  wrapper (Fix D).
- **Some stored data still says `camunda`, and Operaton cannot use it:** the admin group, `org.camunda.*` objects in
  variables, and `org.camunda.*` references in deployed scripts. The pre-flight gate checks the admin group;
  [`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql) finds the variables and scripts.
- **Direct SQL ops scripts still run on Operaton and still corrupt engine state.** Nothing in the migration flags
  them. Replace them with the engine API.

How to run the SQL scripts (flags, order, exit codes, porting to other databases): [`sql/README.md`](../sql/README.md).

## What to do

1. **Confirm that the database is on Camunda 7.24** (the highest version in `ACT_GE_SCHEMA_LOG` is `7.24.0`, or a
   `7.24.N` row on Camunda EE) and that your database server meets the [minimums](#supported-databases). Operaton
   starts on older databases too, and fails only later.
2. **Set `schema-update: false`, and migrate all `camunda.bpm.database.*` keys and environment variables** to
   `operaton.bpm.database.*`, so that Operaton finds the existing schema (see
   [Schema management at the cut-over](#schema-management-at-the-cut-over)).
3. **Gate the cut-over on `00-preflight-checks.sql`**, so that Operaton only starts after a `GO`. Exit code 3 means
   `NO_GO`.
4. **If you use Liquibase, rehearse Fix E or Fix D on a production copy**, because the unfixed changelog fails on the
   first start.
5. **Run `20-find-legacy-references.sql` on a production copy.** Convert the variables it finds, or drain them (let
   the affected instances finish on Camunda), and fix the models it lists
   ([BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md)). Then no running instance meets an
   `org.camunda.*` class after the cut-over.
6. **Replace your direct SQL scripts (such as the example's `ops/sql`) with API calls**, and adopt the
   [emergency SQL rules](#emergency-sql-strict-rules-of-use) for the rare case in which the API is not available.
7. **On Camunda EE, keep the license rows for a rollback, and hand the stored-filter list (P11) to the owner of the
   EE features decision**, because that list shows whether expressions in stored filters can be switched off
   ([Camunda EE databases](#camunda-ee-databases)).
8. **Prepare the [rollback checkpoint](#rollback-on-the-same-database-d15)**, so that you know until when you can go
   back to Camunda without restoring the backup.

## Version markers and what the engine checks at startup

At startup the engine decides whether it may use a database. Its schema checks are so weak that they pass on every
Camunda 7 database, whatever its version, so you have to check the schema level yourself.

- With `schema-update: true` (the default), the engine only creates **missing** tables. It never checks versions and
  never runs upgrade scripts.
- With `schema-update: false`, the engine fails only if tables are missing or if `ACT_GE_PROPERTY.schema.version` is
  not `fox`. Every Camunda 7 database says `fox`, so this check passes on every version.
- The engine **never reads** `ACT_GE_SCHEMA_LOG`, the table in which every upgrade script records its version.
  The pre-flight gate reads it for you (check P01). It accepts `7.24.0`, a Camunda EE patch row `7.24.N` and
  `7.25.0`; anything else is `NO_GO`.
- The history level stored as `historyLevel` must match the configured one on every start, or the engine does not
  start. The Operaton default is `full`.
- If you target Operaton 2.2 or later, run `*_engine_7.24_to_7.25.sql`. It only inserts the `7.25.0` row (`ID_`
  1400), with no DDL. With a 2.2.x target, `scripts/migrate.sh` reminds you of it in its next steps:
  `Operaton 2.2.0-RC1 records schema version 7.25.0: run <db>_engine_7.24_to_7.25.sql (no DDL) at the cut-over.`

## Camunda EE databases

If you run Camunda 7.24 EE, which every team on Spring Boot 4 does, your database holds a few things a Camunda CE
database does not. None of them needs a migration step, but two of them matter for a rollback and for security.

- **EE patch levels do not change the schema.** Camunda's patch-level guide says: "Between patch levels, the
  structure of the database schema is not changed." Camunda ships a patch script only for a bug in the schema
  itself, and no such script is known for 7.24.x. If one ever runs, it adds a `7.24.N` row (`ID_` 1301 to 1399) to
  `ACT_GE_SCHEMA_LOG`. The pre-flight gate accepts it, and Operaton never reads that table. A version with a suffix
  such as `7.24.3-ee` would still be `NO_GO`, because there is no evidence that Camunda writes one.
- **The license key stays in the database.** Camunda EE stores one license key per database: the key in
  `ACT_GE_BYTEARRAY` (resource `camunda-license-key`), and a reference to it in `ACT_GE_PROPERTY`
  (`camunda-license-key-id`). Operaton has no license mechanism and ignores both rows. Keep them until the rollback
  window closes, so that the Camunda EE build finds its license after a rollback. Camunda documents that "the license
  mechanism has no impact on the engine or other runtime components". The license file, mounts and secrets of the
  application are covered by the [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17).
- **Stored task filters may contain expressions.** Camunda 7.24.7-ee restricts expressions in task queries with an
  allow-list. Operaton has no allow-list and evaluates any expression in a stored filter, as Camunda 7.24.6 and older
  did. The mitigation, setting the generic property `enable-expressions-in-stored-queries` to `false`, breaks every
  filter that uses an expression such as `${currentUser()}`. The pre-flight gate lists these filters (check P11), so
  that you can decide before the cut-over. Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).

## Coming from Camunda 7.22 or 7.23

This section shows what goes wrong if you skip Step 0. On the main path, Camunda 7.24 EE on Spring Boot 4, your
application is already on 7.24; check that the database is, too. Operaton starts on any Camunda 7 schema, so the
damage shows only at runtime. The table lists what each older database lacks compared with 7.24:

| Database level | What is missing | Effect on Operaton |
|---|---|---|
| 7.23 | Only the `7.24.0` log row, no DDL | Runs, but the pre-flight gate says `NO_GO` |
| 7.22 | `ACT_RU_EXECUTION.PROC_DEF_KEY_` and `ACT_HI_COMMENT.REV_` | Process starts fail with "column … does not exist" |
| 7.21 or older | Also `TASK_STATE_` and `BATCH_ID_` | The same, also for tasks and jobs |

**Do Step 0 first ([Migration path and decisions](01-migration-path-and-decisions.md#step-0--reach-camunda-724-first)):**
upgrade the application to Camunda 7.24 and run it in production. Upgrading the application, not only running the
scripts, also covers the API and behaviour changes of 7.23 and 7.24.

## Schema management at the cut-over

The **schema-management decision** ([D8](01-migration-path-and-decisions.md#d8)) is mandatory. It settles who may
change the engine schema and what is checked before the first start. Its recommendation: `schema-update: false` plus
the pre-flight gate, also when Liquibase or Flyway manages the schema.

With `false`, the engine needs no DDL rights and fails loudly if tables are missing. With the default `true`, a
schema name or table prefix that you forgot to rename makes Operaton silently create a fresh, empty schema and run
against it (see [Watch out](#watch-out)).

```yaml
operaton.bpm.database.schema-update: false
```

### The pre-flight gate

The pre-flight gate is the only place that tells you whether this database is ready for Operaton. It is read-only
and idempotent, so you can run it as often as you like: in the rehearsal, at the freeze (the deployment freeze
before the cut-over), as the cut-over gate and after the first start.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/00-preflight-checks.sql
```

Its checks P01 to P10 cover the schema level, engine properties, admin groups, job locks, failed jobs and open
incidents, locked external tasks, running work, Liquibase or Flyway tables, other database sessions and
`org.camunda.*` variables. P11 lists stored task filters with expressions, for information only (full list in
[`sql/README.md`](../sql/README.md)). It ends with one verdict:

- `NO_GO` (exit code 3): do not start Operaton. Typical reasons are a schema level other than `7.24.0`, a `7.24.N`
  EE patch row or `7.25.0`, nobody in `operaton-admin`, or jobs still locked by a running node.
- `GO` or `GO_WITH_WARNINGS` (exit code 0): Operaton may start. Read the warnings, for example about Liquibase
  tables or `org.camunda.*` variables. The P11 count (`filters_with_expressions`) never changes the verdict.

## Liquibase

Skip this section if Liquibase never managed your engine schema. If it did, through `spring.liquibase.change-log`
or a pipeline step, a naive switch **fails on the first start**, and you need one of two fixes.

Liquibase identifies changesets by id, author and file. Operaton changed the file
(`…/camunda-changelog.xml` → `org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml`), the author of
`7.23-to-7.24` and `7.24.0-tag` (`Operaton`) and the checksums. Liquibase therefore treats changesets it has
already run as new and tries to run them again. The table shows what the obvious attempts do, so that you recognize
the errors:

| What you try | Result |
|---|---|
| Point Liquibase at `operaton-changelog.xml` | `create table ACT_GE_PROPERTY` fails (table exists) |
| Include it with `logicalFilePath` = old path | Validation fails: 8 changeset checksums changed |
| … plus `clear-checksums` | Duplicate key on `ACT_GE_SCHEMA_LOG` `'1300'` (Oracle: `ORA-00001`) |

Find your real `FILENAME` values first, because they depend on how Liquibase was invoked (for example with a
`classpath:` prefix): `select FILENAME, AUTHOR, count(*) from DATABASECHANGELOG group by FILENAME, AUTHOR;`

### Which fix to pick

Both fixes make Liquibase accept the existing schema as up to date. Pick the one that matches who runs Liquibase:

| | Fix E | Fix D |
|---|---|---|
| Use it when | Liquibase runs from the CLI or a pipeline | `spring.liquibase` in the application owns the schema under one file path |
| What it does | Marks all changesets up to `7.24.0` as executed under the new file name | Keeps the old file path with a wrapper and rewrites two authors |

**Fix E (recommended; Liquibase from CLI or pipeline).** The old `camunda-changelog.xml` rows stay in
`DATABASECHANGELOG` and are ignored, so a Camunda rollback still works (untested).

```bash
CL=org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml
liquibase changelog-sync-to-tag-sql --tag=7.24.0 --changelog-file=$CL   # dry run
liquibase changelog-sync-to-tag --tag=7.24.0 --changelog-file=$CL
liquibase status --verbose --changelog-file=$CL                          # nothing to run (2.2+: the 7.25 changesets)
```

**Fix D (`spring.liquibase` owns the schema under one file path).** A wrapper changelog keeps the old path:

```xml
<include file="org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml" relativeToChangelogFile="false"
         logicalFilePath="org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml"/>  <!-- YOUR FILENAME -->
```

Run the author fix **once, before the first Operaton start, as a separate step** (not in the same Liquibase run). If
it runs as a changeset inside the run that needs it, that run has already started without it.

```sql
update DATABASECHANGELOG set AUTHOR = 'Operaton', MD5SUM = null
 where AUTHOR = 'Camunda' and ID in ('7.23-to-7.24', '7.24.0-tag')
   and FILENAME = 'org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml';   -- YOUR FILENAME
```

Then point `spring.liquibase.change-log` at the wrapper, with `clear-checksums: true` for the first deployment only.

After Fix D, a Camunda 7.24 build that runs Liquibase sees `7.23-to-7.24` as not executed and fails. To roll back,
reverse the update or start Camunda with `spring.liquibase.enabled=false`.

Both fixes are untested with Liquibase 5.x, the version that Spring Boot 4 manages (5.0.3 with Operaton 2.1.5).
Your Spring Boot 4 application uses it unless you pinned Liquibase 4.x, so rehearse the fix with exactly the
Liquibase version your build resolves.

## Flyway and DBA-managed SQL

If Flyway or your DBAs apply the engine scripts, the identical schema leaves little to do. Operaton ≤ 2.1 needs
**no new migration**. 2.2+ needs one with the content of `postgres_engine_7.24_to_7.25.sql`, which inserts the
`7.25.0` schema-log row. Never edit applied scripts, because Flyway's checksums would break.

Source scripts from `org.operaton.bpm.distro:operaton-sql-scripts`. That artifact is versioned by **schema level**
(`7.24.0`), not by Operaton version.

## Supported databases

Operaton raised the minimum database versions to **PostgreSQL 14, MySQL 8.4 and MariaDB 10.11**. Support for
Oracle 21, SQL Server 2022 and DB2 is unchanged. Upgrade an older database **before** the engine migration, as a
separate change. MariaDB has no clear support policy: verify on your version.

## Persisted data that still says "camunda"

The schema is the same, but some values stored in it refer to Camunda classes or to the Camunda admin group. The
engine does no `org.camunda` → `org.operaton` mapping on read, so these values break on Operaton. The table lists
what to look for, what happens on Operaton and where the fix is described:

| Data | Impact on Operaton | Action |
|---|---|---|
| `camunda-admin` memberships, grants | Your admins are not admins; the setup page opens | Mirror the admin group ([admin-group decision, D5](01-migration-path-and-decisions.md#d5)) |
| Variables holding `org.camunda.*` objects (also nested) | `Cannot deserialize object in variable '<name>'` | Convert or drain ([below](#variables-holding-orgcamunda-objects)) |
| Deployed scripts/classes with `org.camunda.*` | Fail when executed, also on old versions | Fix, redeploy, migrate instances ([Scripts](05-bpmn-dmn-forms-and-scripts.md)) |
| Models in the `activiti:` namespace | Fail on first parse | Redeploy |

The first row is a security issue. Operaton treats only `operaton-admin` as the admin group, so with users stored
in the engine database nobody is an admin after the switch. The webapps then open the **setup page**, which lets
anyone who reaches it create an admin user without logging in. Mirroring the admin group (copying the members and
authorizations of `camunda-admin` to `operaton-admin`) before the first start prevents this. Details:
[Identity, admin group and security](07-identity-admin-group-and-security.md).

> [!WARNING]
> Do not "rebrand" persisted values. A blanket `camunda → operaton` replace over SQL, configs or custom
> `JobHandler`/`IncidentHandler`/serializer names orphans existing jobs, incidents and variables. Stored job handler
> types, incident types and serializer names are the same in Camunda and Operaton, so they need no change.

## Variables holding `org.camunda.*` objects

Process variables can hold Java objects. The engine stores them Java-serialized (type `serializable`) or as Spin
JSON/XML, together with the class name. If that class comes from `org.camunda.*`, for example a `VariableMap`
stored as a variable, or your own class with an `org.camunda.*` object in a field, Operaton cannot load it, because
it has no such class. It fails with `ClassNotFoundException`, shown as
`Cannot deserialize object in variable '<name>'`. This guide calls these **legacy variables**.

No compatibility layer exists that maps the old class names. `org.camunda.feel.*` is the real FEEL artifact, which
Operaton still uses: exclude it from your searches.

The **decision on variables with `org.camunda.*` objects** ([D18](01-migration-path-and-decisions.md#d18)) is
mandatory. Its recommendation: convert or drain them before the cut-over.

- **Convert:** in a **Camunda 7.24** release, read each affected variable via the API and set it again as JSON,
  primitives or your own DTO, **locally on its original scope** (`setVariableLocal`). Only Camunda can still read the
  old objects, which is why this runs before the switch. Setting the variable on another scope would create a second
  variable with the same name. Fix the producer code too, or new instances create new legacy variables.
- **Drain:** let short-lived instances finish on Camunda before the cut-over, instead of changing them.

History rows with such variables: accept them, or clean them up via the API. Do not rewrite the stored bytes: Java
serialization length-prefixes strings and checks `serialVersionUID`, so renaming class names in the bytes is not safe.

## The detection SQL pack

`20-find-legacy-references.sql` shows which stored data and which deployed model versions still reference
`org.camunda.*`, and which running instances are affected. Run it early, because its findings decide how much
conversion and instance migration you need.

It is read-only. Run it on a production copy at assessment, at the freeze and in hypercare (the watch period right
after the cut-over).

Its one-row summary (L9) must show 0 blockers: runtime `org.camunda.*` variables (L1/L2), running instances (L4) on
definitions with `org.camunda.*` references (L3) or in the Activiti namespace (L5). The other sections are for
information. The job and incident section (L8) checks that jobs and incidents are consistent.

A fixed new version does not help instances on the old one. Every running instance keeps the model version it
started on, and the engine reloads that version from the database. Move such instances to the fixed version with the
Migration API (instance migration), or drain them. How: [In-flight instances on old definition versions](05-bpmn-dmn-forms-and-scripts.md#in-flight-instances-on-old-definition-versions).

## Direct SQL operations: retries, incidents, locks, timers

Many teams keep SQL scripts that retry jobs, delete incidents or move timers directly in the database (the legacy
example keeps them in `ops/sql`). They run unchanged on Operaton, because the tables are identical, and no OpenRewrite
recipe or startup check flags them. They were risky on Camunda and stay risky on Operaton.

The **decision on direct database scripts** ([D10](01-migration-path-and-decisions.md#d10)) recommends: replace them
with the Java API or REST, and keep only the two emergency scripts `30-` and `31-`
([below](#emergency-sql-strict-rules-of-use)).

Raw SQL bypasses what the engine does on every change:

- **It skips the `REV_` bump.** The engine uses `REV_` for optimistic locking, so an engine transaction that read the
  row earlier silently overwrites the script's change (lost updates).
- **It can leave jobs locked forever.** A job with `LOCK_OWNER_` set but no `LOCK_EXP_TIME_` is never acquired
  again.
- **It leaves incidents and history open**, and it writes no operation log, so nobody can see later who changed
  what.
- **Deleted incidents hide instances that are still stuck.** The job keeps 0 retries, and nothing shows it any more.

The table maps the usual script tasks to the engine API that replaces them:

| Task | Java API | REST (`/engine-rest`) |
|---|---|---|
| Retry one job | `managementService.setJobRetries(3).jobId(id).execute()` | `PUT /job/{id}/retries` |
| Retry failed jobs by query | `setJobRetriesByJobsAsync(3).jobQuery(q).executeAsync()` | `POST /job/retries` |
| External task retries | `externalTaskService.updateRetries().externalTaskQuery(q).set(3)` | `PUT /external-task/retries` |
| Move a timer | `setJobDuedate(jobId, date)` | `PUT /job/{id}/duedate` |
| Document an incident | `runtimeService.setAnnotationForIncidentById(id, text)` | `PUT /incident/{id}/annotation` |
| Delete a stuck instance | `runtimeService.deleteProcessInstance(…)` | `DELETE /process-instance/{id}` |

Retries by job id or query resolve the incident. The example's
[`IncidentRecoveryService`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java)
wraps these calls as a replacement for legacy scripts.

## Emergency SQL: strict rules of use

Sometimes the engine API is not available, for example in the cut-over window or when no node can start, and failed
work must become executable again. For that case only, the pack ships
[`30-emergency-job-retries.sql`](../sql/postgresql/30-emergency-job-retries.sql) and
[`31-emergency-external-task-retries.sql`](../sql/postgresql/31-emergency-external-task-retries.sql). They change
the same rows the engine would, including the incident chain and history. Follow all of these rules, every time:

1. **Use them only when the engine API is unavailable** and waiting is worse than the risk.
2. **Make sure no engine is writing.** Stop all nodes. For `30-`, pausing job execution on **all** nodes
   (`operaton.bpm.job-execution.enabled=false`) is enough. Otherwise you race the engine for the same rows.
3. **Take a backup first**, open a ticket and get a four-eyes review.
4. **Use one transaction with a narrow scope** and a row limit. Check the row count before `COMMIT`.
5. **Always** set `REV_ = REV_ + 1`, and clear `LOCK_OWNER_` **and** `LOCK_EXP_TIME_` together.
6. **Never delete** runtime rows by SQL. Delete them with the API once the engine is back.
7. **Afterwards**, sections L8c–L8e of `20-find-legacy-references.sql` must be empty (except intended
   `resolve_incidents = false` rows). These sections list jobs and incidents that no longer match each other.
8. **Record what you did** in the ticket, because the SQL writes no operation log and has no clean undo.
9. **Remember that they are tested on PostgreSQL only.** To port them, follow [sql/README](../sql/README.md).

Stopped nodes keep their job locks until `lockTimeInMillis` (default 5 min), because shutting down does not unlock
acquired jobs. With **all** nodes (Camunda and Operaton) down, reset every lock without an expiry predicate (the
lock step T0-03 of the [runbook](../checklists/cutover-runbook.md)). The locks you want to release are the ones that
are still valid, so with an expiry predicate the first Operaton node would idle until they expire. Never use that
reset while a node may run. For one dead node, release only its expired or inconsistent locks, because a valid lock
may belong to a node that is still alive:

```sql
update ACT_RU_JOB set REV_ = REV_ + 1, LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null
 where LOCK_OWNER_ = :deadNode and (LOCK_EXP_TIME_ is null or LOCK_EXP_TIME_ < CURRENT_TIMESTAMP);
```

## `ACT_GE_PROPERTY`

This table holds engine properties and a few lock rows that Camunda and Operaton share. Never delete
`deployment.lock`, `history.cleanup.job.lock`, `startup.lock` or `installationId.lock`. Nothing needs resetting
after a crash, because these rows are only locked inside a transaction and keep no state. Operaton ignores
`camunda.installation.id` and writes its own `operaton.installation.id`. Keep `camunda.installation.id` until the
rollback window closes. On Camunda EE, the table also holds `camunda-license-key-id`, the reference to the license
key; keep it as well ([Camunda EE databases](#camunda-ee-databases)).

## No mixed clusters

A mixed cluster means Camunda and Operaton nodes working on the same database at the same time. Never allow it. The
**cut-over strategy decision** ([D7](01-migration-path-and-decisions.md#d7)) is mandatory and recommends a big bang on
the same database: stop all Camunda nodes, then start Operaton.

Both engines acquire jobs from the same table, so a job runs on whichever engine picks it up. Camunda cannot run
`operaton:` definitions, and neither engine reads the other's serialized classes. Kubernetes `RollingUpdate` creates
a mixed cluster: use `strategy: Recreate` or scale to 0.

A "dry start" of one Operaton pod against production while Camunda runs (job execution off, no traffic) is already a
mixed window: auto-deploying changed models creates versions Camunda cannot run.

## Rollback on the same database (D15)

Because the schema is identical, you can roll back to Camunda 7.24 **without a restore**, by starting the last
Camunda build (on the main path, the last Camunda EE build) on the same database. Operaton ignores the EE license
rows, so the rollback build still finds its license there. That works until Operaton writes something Camunda cannot
read. That moment is the point of no return; after it, rollback means restoring the backup and losing the work since
the cut-over. The **decision on rollback and point of no return** ([D15](01-migration-path-and-decisions.md#d15)) is mandatory: it
fixes until when you may go back and who decides.

- **Hard stops** create such Operaton-only data:
  - `operaton:`-namespace deployments with running instances
  - versions with `org.operaton.*` script/class references whose instances have not passed that step
  - `operaton-forms:` versions with open tasks
  - `serializable` variables with `org.operaton.*` classes
- **Soft stops** still allow a rollback, but you must reverse them first: Liquibase Fix D, deleted `camunda-admin`
  rows.
- **Harmless:** `operaton.installation.id`, `operaton-admin` rows, history, the `7.25.0` row.

Check whether a rollback is still possible with the read-only C1–C3 queries of the compatibility checkpoint: are
there Operaton-only deployments, instances on them, or variables only Operaton can read? They are PostgreSQL only
and not in the test harness; you find them in the
[cut-over runbook](../checklists/cutover-runbook.md#compatibility-checkpoint-c1c3), step R2-1.
Operaton-only deployments without running instances do not block, nor do scripts that every instance has passed.

- **If the checkpoint is clean:** stop Operaton, release the locks, revert Liquibase Fix D if you used it, and start
  the Camunda build.
- **Otherwise:** migrate the instances back while Operaton runs (runbook R2-1), fix forward, or restore the backup
  and lose all work since the cut-over.

Deploy engine-neutral script and form fixes **on Camunda 7.24 before the cut-over** to avoid hard stops. Details:
[Cut-over, rollback and operations](11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return).

## Watch out

Each item names what you see, its cause and the fix.

- **Symptom:** Cockpit is empty after the cut-over, or the start fails with `There are no Operaton tables in the database`.
  **Cause:** `schema-name`/`table-prefix` were not migrated. With `true`, Operaton created an empty schema and runs
  against it; with `false`, the start fails.
  **Fix:** migrate the keys and set `false`. Check the empty schema for new work before dropping it.
- **Symptom:** `historyLevel mismatch: configuration says … and database says …`.
  **Cause:** the `camunda.bpm.history-level` env var is ignored, so the Operaton default applies.
  **Fix:** set `OPERATON_BPM_HISTORY_LEVEL`.
- **Symptom:** `unable to resolve class org.camunda…` although the BPMN is fixed.
  **Cause:** the instance runs on the old version.
  **Fix:** migrate or drain it.
- **Symptom:** `DELETE FROM ACT_RU_INCIDENT` fails on `ACT_FK_INC_CAUSE`.
  **Cause:** call-activity parent incidents reference the root incident.
  **Fix:** don't delete incidents by SQL.
