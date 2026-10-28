# SQL toolkit · pre-flight, admin group, legacy references, emergency retries

This folder holds five PostgreSQL scripts (PostgreSQL 13+; Operaton itself needs 14+) for the database side of the
migration. DBAs and operations engineers use them in the rehearsal and on cut-over day, the one production event
where you stop all Camunda nodes and start Operaton on the same database. Developers use the legacy-reference scan
during the assessment.

There is no schema migration: Operaton uses the same tables as Camunda 7.24, and Camunda EE (Enterprise Edition)
patch levels such as 7.24.16-ee do not change the schema either. The scripts exist for two other reasons:

- **The engine checks almost nothing at startup.** It only checks `schema.version = 'fox'`, which every Camunda 7
  database has. A hard GO/NO-GO gate therefore decides whether the first Operaton node may start.
- **Some data still says "Camunda".** The admin group and `org.camunda.*` class names in variables and deployed
  scripts break on Operaton. The automated code conversion (the OpenRewrite recipes) only changes your repository,
  never the data in the database.

One kind of Camunda data needs no script: the **Camunda EE license key**. Camunda stores it in the database
(`ACT_GE_BYTEARRAY` resource `camunda-license-key`, referenced by the `ACT_GE_PROPERTY` row `camunda-license-key-id`).
Operaton ignores these rows, and none of these scripts touches them. Leave them in place, because a rollback to
Camunda EE uses the same database.

Background: [Database: schema, data and SQL scripts](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/08-database-schema-data-and-sql-scripts.md),
[Identity, admin group and security](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/07-identity-admin-group-and-security.md), and the
[cut-over runbook](https://github.com/Miragon/migration-recipies/blob/main/services/c7/checklists/cutover-runbook.md), which calls these scripts step by step.

## Scripts

The table gives an overview. The sections below explain each script: what it is for, when you run it, and what to
look for in its output. "Writes" means the script changes engine tables; read-only scripts roll back everything they
create.

| File | Short name | When | Writes? |
|---|---|---|---|
| [`postgresql/00-preflight-checks.sql`](postgresql/00-preflight-checks.sql) | pre-flight check (00) | rehearsal, freeze, cut-over gate, after first start | **read-only** |
| [`postgresql/10-migrate-admin-group.sql`](postgresql/10-migrate-admin-group.sql) | admin-group script (10) | cut-over, after stop and backup, **before the first Operaton start** | **writes**; one transaction; idempotent |
| [`postgresql/20-find-legacy-references.sql`](postgresql/20-find-legacy-references.sql) | legacy-reference scan (20) | assessment, rehearsal, freeze, hypercare | **read-only** |
| [`postgresql/30-emergency-job-retries.sql`](postgresql/30-emergency-job-retries.sql) | emergency job retries (30) | **emergencies only** (API unavailable) | **writes**; 2nd run aborts |
| [`postgresql/31-emergency-external-task-retries.sql`](postgresql/31-emergency-external-task-retries.sql) | emergency external-task retries (31) | **emergencies only** | **writes**; 2nd run aborts |
| [`test/`](https://github.com/Miragon/migration-recipies/tree/main/services/c7/sql/test/) | test harness | before you adapt a script | – |

### Pre-flight check: `00-preflight-checks.sql`

**Purpose:** answer the question "may the first Operaton node start on this database now?" before the cut-over.
Operaton also starts on a database that does not fit and only fails later at runtime, so you need this check as the
gate. It ends with a verdict: `GO`, `GO_WITH_WARNINGS` or `NO_GO`. On `NO_GO` it raises an error, so psql exits
with code 3 and a pipeline stops.

**When:** in the rehearsal, at the freeze (the stop of all deployments and releases before the cut-over), as the
cut-over gate, and after the first start.

**Writes:** nothing (**read-only**). Run it as often as you like.

**What it checks:**

- the schema level (P01): the newest row of `ACT_GE_SCHEMA_LOG` (highest `ID_`) decides. The engine never reads
  this table, so only this check tells you whether the database really is on Camunda 7.24. These rows are OK:
  - `7.24.0`, written by the Camunda 7.24 create script (`ID_` 0) or by the 7.23 to 7.24 upgrade script
    (`ID_` 1300).
  - `7.24.N`, a Camunda EE patch row (`ID_` 1301 to 1399). EE patch levels do not change the schema, and no 7.24.x
    patch script is known. Camunda ships a patch script only for a bug in the schema itself, and such a script
    would add this row, so a database that ran one gets no false `NO_GO`.
  - `7.25.0`, written by the Operaton 2.2 script `postgres_engine_7.24_to_7.25.sql` (`ID_` 1400), which adds only
    this row. It passes with the warning `schema log 7.25.0: fine for Operaton 2.2+, harmless for older engines`.

  Anything else is `NO_GO` with the reason
  `schema log is <v>, expected 7.24.0 (or a 7.24.N patch row): upgrade to Camunda 7.24 first`. A suffix such as
  `7.24.3-ee` is also `NO_GO`: the rule accepts digits only (`^7[.]24[.][0-9]+$`), because there is no evidence that
  Camunda writes such a suffix.
- the engine properties (P02): `schema.version`, the history level, installation ids and legacy rows. P02 lists every
  `ACT_GE_PROPERTY` row. On a Camunda EE database that includes `camunda-license-key-id` without a note: Operaton
  ignores it, so keep it for a rollback.
- the admin groups (P03): members and authorizations of `camunda-admin` and `operaton-admin`.
- the job locks (P04): jobs locked by a node that may still be running.
- the failed-work baseline (P05): failed jobs and open incidents. Store it and compare after the cut-over.
- the locked external tasks (P06): tasks that workers hold right now.
- the running work (P07): deployments, definitions, running instances and batches.
- Liquibase or Flyway (P08): whether schema-management tables exist.
- other database sessions (P09): whether the Camunda nodes are really gone.
- legacy variables (P10): a quick count of variables typed with `org.camunda.*` classes. The legacy-reference scan
  (20) gives the full picture.
- stored task filters with expressions (P11, for information only): the Tasklist and REST filters whose stored query
  contains an expression, with `filter_id`, `filter_name`, `filter_owner` and the expressions themselves (for
  example `taskAssignee = ${currentUser()}`). Or-queries are included. Read it below.

**Why P11 exists.** It is input for the
[Camunda EE features decision (D17)](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d17). Camunda 7.24.7-ee added an
allow-list for expressions in task queries (`queryExpressionAllowListEnabled`, on by default), after Camunda
security notice 157 described expression injection through stored filters. Operaton has no allow-list. It only has
the all-or-nothing switch `enable-expressions-in-stored-queries` (a generic property, default `true`), so it
evaluates any expression in a stored filter, as Camunda 7.24.6 and older did. The mitigation is to set that switch to
`false`. Then every filter that P11 lists fails when it is listed or counted, with
`Expressions are forbidden in stored queries`.

- **No rows:** you can switch expressions off without breaking a filter.
- **Rows:** rewrite these filters without expressions, or keep the switch on and restrict who may create and update
  filters (authorizations on resource type 5, Filter, in `ACT_RU_AUTHORIZATION`).

P11 changes neither the verdict nor the warnings. The first Operaton start does not depend on it, the filters keep
working with the default switch, and typical Tasklist filters such as "My Tasks" use `${currentUser()}`, so a warning
would rarely clear.

**What to look for:** the one-row summary at the end (P99). `NO_GO` lists its reasons, for example a wrong schema
level, nobody in `operaton-admin`, or jobs still locked by a running node. Fix them and run the check again.
`GO_WITH_WARNINGS` lists items to review; it does not block the start. The last column, `filters_with_expressions`,
repeats the P11 count for information and never changes the verdict.

### Admin-group script: `10-migrate-admin-group.sql`

**Purpose:** Camunda's webapps treat members of `camunda-admin` as administrators. Operaton hard-codes
`operaton-admin`, and nothing migrates the group. With users stored in the engine database ("DB identity"), nobody
is an Operaton admin after the switch. The webapps then think this is a fresh installation and open the **setup
page**, which lets anyone who can reach it create an admin user without logging in. This script closes that hole
([admin-group decision, D5](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d5)).

**What it does:** it creates `operaton-admin` and mirrors the members, the authorizations (held by and on
`camunda-admin`) and the tenant memberships. It rolls back on any mismatch. It never touches `camunda-admin` rows,
so Camunda 7.24 keeps working on this database while a rollback is still possible.

**When:** at the cut-over, after you have stopped all Camunda nodes and taken the backup, and **before the first
Operaton start**. The script is harmless for a running Camunda 7.24, which ignores `operaton-admin`: run it early,
for example in the rehearsal, and re-run it before the start in case admins changed in between.

**Writes:** yes, in **one transaction**. It is **idempotent**: a second run inserts nothing.

**What to look for:** the before/after verification table (S6), in which every `missing_*` count must be 0, and the
final notice. `OK: operaton-admin has … member(s)` means you are done. The other two notices are covered under
[Pitfalls](#pitfalls).

The example application does the same at startup with the Java plugin
[`AdminGroupMigrationPlugin`](https://github.com/Miragon/migration-recipies/blob/main/services/c7/examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java).

### Legacy-reference scan: `20-find-legacy-references.sql`

**Purpose:** find data that Camunda 7 wrote and that breaks on Operaton. Operaton renamed the Java packages
`org.camunda.*` to `org.operaton.*` and has no compatibility mapping. A stored variable or a deployed script that
names an `org.camunda.*` class therefore fails on Operaton, for example with `ClassNotFoundException`.

**When:** at the assessment, in the rehearsal, at the freeze and during hypercare (the watch period right after the
cut-over).

**Writes:** nothing (**read-only**). The scan reads the contents of the byte arrays in `ACT_GE_BYTEARRAY`, so on a
big database run it on a replica or a restored copy.

**What it reports:**

- **Variables and byte arrays with `org.camunda.*`** (L1, L2). Runtime variables block the cut-over. Convert them
  on Camunda 7.24, or **drain** them, which means you let the affected instances finish on Camunda before the
  cut-over ([legacy-variables decision, D18](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d18)). Hits in history
  tables do not block the cut-over: accept them or clean them up. Hits in stack traces are harmless text.
- **Deployed resources that reference such classes, and their running work** (L3, L4). The engine never rewrites
  deployed resources, so a fix in Git only helps new versions. Instances on an old version fail when they reach the
  script: migrate them to a fixed version with the Migration API, or drain them.
- **Models in the old Activiti namespace** (L5). Operaton does not parse them.
- **`camunda-forms:` form keys** (L6), as input for the
  [Camunda Forms keys decision (D4)](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d4).
- **Decision and case definitions** behind the deployed-resource hits (L7), for information.
- **Job and incident consistency** (L8). This is also the check after the emergency scripts (30, 31).
- **A one-row summary** (L9). Its blocker columns must be 0 before the cut-over.

The scan ignores `org.camunda.feel.*`, because Operaton still uses the Camunda FEEL engine and that package is not
renamed.

### Emergency retries: `30-emergency-job-retries.sql` and `31-emergency-external-task-retries.sql`

**Purpose:** make failed work executable again when the engine API is **not** available, for example because the
engine does not start or REST is down. Whenever the engine runs, use the API instead (see the warning under
[Using the emergency scripts](#using-the-emergency-scripts-30-31)).

**What they do:** both scripts mirror what the engine itself does.

- **Jobs (30):** for the scoped jobs with `RETRIES_ = 0`, the script resolves the incident chain including history, sets
  `REV_ + 1`, clears the locks and sets the retries, like `setJobRetries`. The `REV_` bump matters because the engine
  uses it for optimistic locking. With `resolve_incidents = false` it behaves like
  `setJobRetriesByJobDefinitionId`: the incidents stay open until the job succeeds.
- **External tasks (31):** the same for external tasks, with an optional unlock.

**When:** **emergencies only**, also during the cut-over or hypercare. They are not part of the regular migration.

**Writes:** yes. A **2nd run aborts**: the scope only matches work without retries, so a second run finds nothing,
rolls back and changes nothing.

### Test harness: `test/`

**Purpose:** prove that the scripts still do what they should after you change them. The harness uses PGlite
(Node.js 20+) and runs every script twice on a seeded database, which also checks that a second run is harmless:

```bash
cd sql/test && npm install && npm test
```

The harness loads the real PostgreSQL create scripts of Camunda 7.24.0, Operaton 2.1.5 and Operaton 2.2.0-RC1. The
tests also cover Camunda EE patch rows in the schema log and stored filters with and without expressions. PGlite
0.5.8 is PostgreSQL 18.3; the scripts have not been run on a real PostgreSQL 13.

**When:** before you adapt a script, for example for a custom schema or another database.

## How to run

Run every script with psql and the same flags:

```bash
export DATABASE_URL='postgresql://camunda:***@db.example.com:5432/camunda'
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/00-preflight-checks.sql | tee preflight-$(date +%F-%H%M).txt
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/10-migrate-admin-group.sql
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/20-find-legacy-references.sql > legacy-references.txt  # big DB: run on a replica
```

Why each flag matters, and what the exit codes mean:

- **`-v ON_ERROR_STOP=1` is required.** The gate (00), the assertion (10) and the safety checks (guards) of 30 and 31
  signal a problem by raising an error. With this flag psql stops at that error and exits with code 3.
- **Exit codes:** 0 = done (for 00: `GO` or `GO_WITH_WARNINGS`). 3 = `NO_GO`, a failed assertion or a failed
  guard; nothing was committed.
- **`-X`** ignores `~/.psqlrc`. Personal settings such as `AUTOCOMMIT off` or `ON_ERROR_ROLLBACK` then cannot
  interfere with the scripts' transactions.
- **Never use `--single-transaction`.** Each script manages its own transaction. With the flag, psql warns
  `there is already a transaction in progress`, and the inner `COMMIT` ends its transaction early.

Special cases:

- **Custom schema or table prefix.** The symptom is `relation "act_ge_schema_log" does not exist`. Run
  `set search_path to <schema>;` first, and edit the table names if they carry a prefix.
- **GUI clients:** run the file as a script.
- **Kubernetes without psql:** start a temporary psql pod.

  ```bash
  kubectl run psql --rm -i --restart=Never --image=postgres:17 --env=DATABASE_URL="$DATABASE_URL" -- psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f - < sql/postgresql/00-preflight-checks.sql
  ```

### Order: when to run what

The scripts run at six moments of the migration. The [cut-over runbook](https://github.com/Miragon/migration-recipies/blob/main/services/c7/checklists/cutover-runbook.md) contains
the same steps with owners and checkpoints.

1. **Rehearsal on a production copy.** Find every blocker while there is still time to fix it. A production copy is
   a restored copy of the production database, never the live one.
   1. Run the pre-flight check (00) and the legacy-reference scan (20).
   2. Fix the findings. Hand the stored-filter list (P11) to whoever owns the Camunda EE features decision (D17),
      because it shows whether expressions in stored filters can be switched off.
   3. Run the admin-group script (10).
   4. Run the pre-flight check (00) again. It must say `GO` or `GO_WITH_WARNINGS`.
2. **Freeze.** Record the state before the switch. The freeze holds until the rollback window closes.
   1. Run the pre-flight check (00) and store the failed-work baseline (P05) in the ticket.
   2. Run the legacy-reference scan (20) and check that nothing new has appeared since the rehearsal.
3. **Cut-over.** Never let Camunda and Operaton work on the database at the same time, and start Operaton only
   after a passed gate.
   1. Stop all Camunda nodes.
   2. Run the pre-flight check (00) and check that the job locks show `locked_now = 0`.
   3. Take the backup.
   4. Run the admin-group script (10).
   5. Run the pre-flight check (00) as the gate. It must exit with 0.
   6. Start the first Operaton node.
4. **After the first start.** With unchanged models, the pre-flight check (00) shows no new deployments. A new
   deployment may create definition versions that only Operaton can run, which blocks a rollback.
   [`scripts/smoke-test.sh`](https://github.com/Miragon/migration-recipies/blob/main/services/c7/scripts/smoke-test.sh) must find the setup page closed.
5. **Hypercare.** Run the pre-flight check (00) and the job and incident checks (L8) of the legacy-reference scan
   (20), and compare them with the baseline. Failures that mention `org.camunda` classes show legacy references hit
   at runtime. Use the emergency scripts (30, 31) only if the API is down.
6. **After the point of no return** ([rollback and point-of-no-return decision, D15](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d15)).
   This is the first moment Operaton has written data that Camunda 7.24 cannot read or run. After it, a rollback
   means restoring the backup. Only then clean up the `camunda-admin` rows with the commented section at the end of
   the admin-group script (10). Until then, Camunda 7.24 still needs them.

### Using the emergency scripts (30, 31)

> [!WARNING]
> Use the API whenever the engine runs: the API table in
> [Direct SQL operations](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/08-database-schema-data-and-sql-scripts.md#direct-sql-operations-retries-incidents-locks-timers),
> Cockpit, or
> [`IncidentRecoveryService`](https://github.com/Miragon/migration-recipies/blob/main/services/c7/examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java).
> SQL checks no authorizations, writes no operation log and never calls your `IncidentHandler`.

The strict rules behind these steps are in
[Emergency SQL: strict rules of use](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/08-database-schema-data-and-sql-scripts.md#emergency-sql-strict-rules-of-use).

1. **Make sure no engine is writing.** Stop all engine nodes. For the job script (30), setting
   `operaton.bpm.job-execution.enabled=false` on **all** of them is enough. Take a backup, open a ticket and get a second reviewer.
2. **Narrow the scope.** Copy the script. In **EDIT HERE (1/2)**, replace the placeholder with **one** narrow scope;
   the alternatives (job definition, process instance, activity, error message) are listed there. Keep the
   `RETRIES_` condition: it limits the script to failed work and makes a second run harmless.
3. **Set the options.** In **EDIT HERE (2/2)**, set `new_retries`, `due_now` (30) or `unlock` (31),
   `resolve_incidents` (jobs only), and `max_jobs` / `max_tasks` (default 50), the upper limit of the scope.
4. **Dry run.** Change the final `commit;` to `rollback;`, run the script, and read the preview and result rows.
5. **Run it for real** and record the output in the ticket, because the script writes no operation log.
   There is **no clean undo** after `COMMIT`.
6. **Check the result.** Resume the nodes. Run the legacy-reference scan (20): its job and incident consistency
   checks (L8c–L8e) must be empty, apart from intentional `resolve_incidents = false` cases.

The guards abort and roll back on an empty or oversized scope, on invalid options, and (30) on a scoped job that is
locked by a live node. `lock_timeout` is 5 s, so the script fails fast instead of waiting for a node that is still
running.

## Porting to other databases

Only PostgreSQL is tested. Table and column names are identical on every database, so you only replace the
PostgreSQL-specific constructs below and rehearse on a copy. Each row names a construct, the scripts that use it (in
parentheses), and its replacement per database.

| PostgreSQL (script) | Oracle | SQL Server | MySQL / MariaDB | DB2 | H2 2.x |
|---|---|---|---|---|---|
| `gen_random_uuid()::text` (10) | `rawtohex(sys_guid())` | `cast(newid() as varchar(64))` | `uuid()` | `hex(generate_unique())` | `cast(random_uuid() as varchar(64))` |
| `insert … select … where not exists` without `from` (10) | add `from dual` | as is | as is | add `from sysibm.sysdummy1` | as is |
| `position(convert_to('org.camunda.','UTF8') in BYTES_) > 0` (20) | `dbms_lob.instr(BYTES_, hextoraw('6F72672E63616D756E64612E')) > 0` | `charindex(0x6F72672E63616D756E64612E, cast(BYTES_ as varbinary(max))) > 0` | `locate(X'6F72672E63616D756E64612E', BYTES_) > 0` | `locate(blob(X'6F72672E63616D756E64612E'), BYTES_) > 0` | `locate(X'6f72672e63616d756e64612e', BYTES_) > 0` |
| `create temporary table … on commit drop` (00: view; 20, 30, 31) | global temporary table or subqueries | `select … into #tmp` | `create temporary table … as select` | `declare global temporary table` | `create local temporary table` |
| `do $$ … raise exception … $$` (00, 10, 30, 31) | `raise_application_error(-20001, '…')` in a block | `throw 50001, '…', 1` | procedure with `signal sqlstate '45000'`, or check previews | block with `signal sqlstate` | none: check result rows |
| `update t … from o` (30, 31) | subquery or `merge` | supported | `update t join o on … set …` | `merge` | `merge` or subquery |
| `string_agg(x, ', ')` (00, 10, 20) | `listagg … within group` | `string_agg` | `group_concat` | `listagg` | `listagg` |
| `limit n`; `cast(ID_ as integer)` (00) | `fetch first n rows only`; `to_number` | `top n`; `cast(… as int)` | as is; `cast(… as signed)` | `fetch first n rows only`; as is | as is |
| `true`/`false` options (30, 31) | `1`/`0` | `1`/`0` | as is | as is | as is |
| regex `~`, `substring(… from …)` (00, 20) | `regexp_like`, `regexp_substr` | `like`, drop the class hint | `regexp_like`, `regexp_substr` | same as Oracle | same as Oracle |
| `pg_stat_activity`, `information_schema.tables` (00) | `v$session`, `all_tables` | `sys.dm_exec_sessions` | `information_schema.processlist` | `sysibmadm.applications`, `syscat.tables` | `information_schema.sessions` |

The stored-filter check (P11 of 00) uses `regexp_matches` only for its `expressions` column. On other databases,
drop that column and read `QUERY_` instead.

Two database-specific traps in the emergency scripts:

- **MySQL:** `ACT_HI_INCIDENT.CREATE_TIME_` may auto-update. Add `CREATE_TIME_ = CREATE_TIME_` to the history update
  in 30 and 31. Wrap self-referencing subqueries in a derived table `(select …) r`.
- **PostgreSQL, Oracle, DB2, SQL Server:** the incident self-FKs (`ACT_FK_INC_CAUSE`, `ACT_FK_INC_RCAUSE`) do not
  cascade. Delete root and parent incidents **in one statement**, as 30 and 31 do.

## Pitfalls

Each entry starts with what you see, then explains the cause and the fix.

- **Symptom:** the pre-flight check (00) exits with 3 in the rehearsal: `PREFLIGHT NO_GO: nobody is in operaton-admin …`.
  **Cause:** this is expected before the admin-group script (10) has run.
  **Fix:** run the admin-group script, then the pre-flight check again.
- **Symptom:** the pre-flight check (00) still says `NO_GO` after all pods are gone:
  `job(s) locked by a running engine node`.
  **Cause:** stopped nodes keep their job locks until they expire after `lockTimeInMillis` (5 min).
  **Fix:** wait. Check the other database sessions (P09) to make sure no Camunda node is still connected.
- **Symptom:** the admin-group script (10) prints `ACTION REQUIRED: operaton-admin has no members` (exit 0).
  **Cause:** `camunda-admin` had no members, so there was nobody to mirror, and the setup page stays open.
  **Fix:** add an admin before the first start.
- **Symptom:** the admin-group script (10) prints `No camunda-admin group in ACT_ID_GROUP`.
  **Cause:** your groups live in LDAP, Keycloak or OAuth2, not in the engine database.
  **Fix:** map the admin group there
  ([Identity, admin group and security](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/07-identity-admin-group-and-security.md)).
- **Symptom:** former admins still lack admin rights after the admin-group script (10).
  **Cause:** webapp sessions cache the groups.
  **Fix:** log in again.
- **Symptom:** the emergency job script (30) aborts with `no job matched the scope`.
  **Cause:** the placeholder was not replaced, or the jobs have retries > 0.
  **Fix:** replace the placeholder in **EDIT HERE (1/2)**. The script only handles jobs with `RETRIES_ = 0`.
