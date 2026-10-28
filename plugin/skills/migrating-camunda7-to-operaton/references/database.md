# Database: schema, Liquibase/Flyway, persisted data, direct SQL

Load this for schema checks, Liquibase/Flyway setups, Java-serialized variables, SQL files that touch `ACT_*` tables, and
when preparing the SQL part of the cut-over pack. Guide chapter:
https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/08-database-schema-data-and-sql-scripts.md
SQL toolkit details (when to run what, porting table, pitfalls): `assets/sql/README.md` (bundled).

## Contents

1. Rules for the agent and the psql convention
2. Schema facts and the 7.24 gate
3. Schema management (D8) and pre-flight
4. Liquibase
5. Flyway and DBA-managed scripts
6. Persisted data that still says "camunda" (D18)
7. Direct SQL → Java API / REST (D10)
8. The project's own SQL scripts: what to replace them with
9. Emergency SQL: rules of use
10. Porting the SQL to other databases
11. Data-level rollback checks (D15)
12. Done criteria

## 1. Rules for the agent and the psql convention

- **Never run SQL, Liquibase or write REST calls against a database that is not a throw-away local one.** Copy the scripts
  from `assets/sql/postgresql/` into the project's `migration/sql/<vendor>/` folder, adapt them (vendor, schema, scope), and
  hand them to humans with the exact command and the expected result. `migration/` is ignored by `migrate.sh`'s clean-tree
  check and skipped by `verify-leftovers.sh` (the copies contain `camunda` on purpose).
- All bundled scripts are PostgreSQL and were tested against the real Camunda 7.24 / Operaton create scripts (PGlite).

| File | Phase | Writes? |
|---|---|---|
| `00-preflight-checks.sql` | rehearsal, freeze, cut-over gate, after first start | no (temp objects, `ROLLBACK`) |
| `10-migrate-admin-group.sql` | after Camunda stop + backup, before first Operaton start (D5; see references/identity-and-admin.md) | yes, one transaction, idempotent |
| `20-find-legacy-references.sql` | assessment, rehearsal, freeze, hypercare | no |
| `30-emergency-job-retries.sql`, `31-emergency-external-task-retries.sql` | emergencies only, engine API unavailable | yes, guarded |

Command convention to put in every runbook step:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migration/sql/postgresql/00-preflight-checks.sql | tee preflight-$(date +%F-%H%M).txt
# exit 0 = GO / GO_WITH_WARNINGS, exit 3 = NO_GO (or any raised guard/assertion)
```

- `-v ON_ERROR_STOP=1` is required (gates, guards and assertions signal by raising an error). `-X` ignores `~/.psqlrc`.
- **No `--single-transaction`**: the scripts contain their own `BEGIN … COMMIT/ROLLBACK`.
- Custom schema: `PGOPTIONS='-c search_path=<schema>' psql …` (or `set search_path`). A table prefix requires editing names.
- Wide rows: `-P expanded=auto`. GUI clients: run the file **as a script**. Kubernetes without a local psql: see
  `assets/sql/README.md` ("How to run").

## 2. Schema facts and the 7.24 gate

- Operaton 1.x–2.1.x DDL is **identical** to Camunda 7.24.0 (same 49 `ACT_*` tables). No DDL migration. Operaton 2.2 adds
  only a schema-log marker row `7.25.0` (script `<db>_engine_7.24_to_7.25.sql`, an `insert` into `ACT_GE_SCHEMA_LOG`, id
  `1400`); for a 2.2.x target `migrate.sh` reminds you to run it at the cut-over.
- Camunda 7.24 EE patch levels do not change the schema ("Between patch levels, the structure of the database schema is
  not changed"); no 7.24.x patch script is known. If one ever runs, it adds a `7.24.N` row (id 1301–1399) to
  `ACT_GE_SCHEMA_LOG`, which Operaton never reads.
- The Camunda EE license is stored in the database: `ACT_GE_BYTEARRAY` resource `camunda-license-key` and the
  `ACT_GE_PROPERTY` row `camunda-license-key-id`. Operaton ignores both ("The license mechanism has no impact on the
  engine or other runtime components"). **Keep them**: a rollback to Camunda EE needs them (D15, D17).
- Keep database, schema and user names containing "camunda". Table `ACT_RE_CAMFORMDEF` keeps its name.
- Startup checks only `ACT_GE_PROPERTY.schema.version = 'fox'` (with `schema-update=false`) and `historyLevel`.
  `ACT_GE_SCHEMA_LOG` is never read, and `schema-update=true` never runs upgrade scripts.
- **Consequence: a 7.22 or older database boots and then fails at runtime** ("column … does not exist":
  `ACT_RU_EXECUTION.PROC_DEF_KEY_`, `ACT_HI_COMMENT.REV_`; ≤ 7.21 also `TASK_STATE_`, `BATCH_ID_`). A 7.23 database lacks only the
  `7.24.0` schema-log row. **Stop condition: production must be on 7.24** (upgrade the app to Camunda 7.24 first, incl. DB
  upgrade scripts). The pre-flight (P01) looks at the newest `ACT_GE_SCHEMA_LOG` row (highest `ID_`) and accepts
  `7.24.0` (create script id 0, or the 7.23 → 7.24 upgrade id 1300), any `7.24.N` EE patch row (rule `^7[.]24[.][0-9]+$`)
  and `7.25.0` (Operaton 2.2 script, id 1400). Anything else is `NO_GO` with the reason `schema log is <v>, expected
  7.24.0 (or a 7.24.N patch row): upgrade to Camunda 7.24 first` (7.23.x rows get the addition ` (7.23 lacks no DDL, only
  the 7.24.0 marker row, but skips the 7.24 changes)`). A suffix such as `7.24.3-ee` would still be `NO_GO` (no evidence
  that Camunda writes one).
- History level: `historyLevel mismatch: configuration says … and database says …` at startup means an old
  `camunda.bpm.history-level` (env var, Helm value) is ignored; set `operaton.bpm.history-level` / `OPERATON_BPM_HISTORY_LEVEL`.
- First Operaton start writes a new `operaton.installation.id` row; `camunda.installation.id`, telemetry rows and the lock rows
  (`deployment.lock`, `history.cleanup.job.lock`, `startup.lock`, `installationId.lock`) stay. Never delete lock rows.
- Operaton 2.1 raised the PostgreSQL/MySQL/MariaDB minimums (values: references/versions.md). Below them: upgrade the
  database first, as a separate change. MariaDB policy is unresolved ("works, verify").
- H2 file DBs (local dev, cut-over simulation): a file written by H2 2.3.232 (Camunda 7.24 / Spring Boot 3.5.5) opens with
  H2 2.4.240 (Spring Boot 4.0.8): schema, identity, jobs and in-flight instances worked (verified on 2026-10-07 in a
  skill run on a copy of the legacy example and in the example's cut-over simulation). Other H2 version pairs are not verified: if a file does not open,
  recreate the dev DB instead of repairing it.

## 3. Schema management (D8) and pre-flight

Recommendation (D8 option A), for the cut-over and in production:

```yaml
operaton:
  bpm:
    database:
      schema-update: false   # fail fast: "There are no Operaton tables in the database" / "Version mismatch"
      # migrate type / schema-name / table-prefix too if they were set under camunda.bpm.database.*
```

Why: with the default `true`, a missed rename of `camunda.bpm.database.schema-name`/`table-prefix` (or
`CAMUNDA_BPM_DATABASE_*`) makes Operaton create an **empty schema** and run against it (Cockpit shows nothing).

`00-preflight-checks.sql` sections: P01 schema level, P02 engine properties, P03 admin group (D5), P04 job locks of running
nodes, P05 failed jobs/incidents (store as baseline), P06 locked external tasks, P07 deployments/running work, P08
Liquibase/Flyway tables, P09 other DB sessions, P10 `org.camunda.*`-typed variables, P11 stored task filters with
expressions (informational, D17), P99 verdict. On an untouched Camunda DB it is expected to say `NO_GO` (nobody in
`operaton-admin`) until `10-…` ran; locks expire after `lockTimeInMillis` (5 min default).

P11 (Camunda EE sources, D17): lists stored Tasklist/REST filters whose query contains expressions
(`ACT_RU_FILTER.QUERY_ like '%Expression":%'`, keys `<criterion>Expression`, or-queries included), columns `filter_id,
filter_name, filter_owner, expressions`; P99 repeats the count as its last column `filters_with_expressions`. It changes
neither the verdict nor the warnings (GO / GO_WITH_WARNINGS / NO_GO and the psql exit 3 of the gate are unchanged; the
script stays read-only, `begin … rollback`). Why: Operaton has no 7.24.7-ee query-expression allow-list; if the team sets
`enable-expressions-in-stored-queries: false`, these filters fail with "Expressions are forbidden in stored queries". No
rows = safe to switch expressions off. Otherwise rewrite the filters, or keep the switch on and restrict filter
create/update (authorization resource type 5 = Filter). Details: references/identity-and-admin.md §10. Tests: the SQL
ran on PGlite (PostgreSQL 18.3) only, not on a real PostgreSQL 13.

## 4. Liquibase

Detect: `DATABASECHANGELOG` table, `spring.liquibase.change-log`, references to `camunda-changelog.xml`. A naive switch to
`org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml` **fails on the first start** (Liquibase identifies changesets
by id + author + file path; the path changed, `7.23-to-7.24`/`7.24.0-tag` are now `author="Operaton"`, checksums differ):
`create table ACT_GE_PROPERTY` already exists, checksum validation errors, or duplicate key `ACT_GE_SCHEMA_LOG ('1300')`
(Oracle `ORA-00001`).

First have a human read the real `FILENAME` values:

```sql
select FILENAME, AUTHOR, count(*) as cnt, max(DATEEXECUTED) as last_run
  from DATABASECHANGELOG where FILENAME like '%camunda%' or FILENAME like '%operaton%' group by FILENAME, AUTHOR;
```

**Fix E** (Liquibase run by CLI/pipeline; rollback-friendly):

```bash
CL=org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml   # or sql/liquibase/operaton-changelog.xml from operaton-sql-scripts
liquibase changelog-sync-to-tag-sql --tag=7.24.0 --changelog-file=$CL   # review the generated INSERTs
liquibase changelog-sync-to-tag --tag=7.24.0 --changelog-file=$CL
liquibase status --verbose --changelog-file=$CL                          # must show nothing to run (2.2+: only 7.24-to-7.25, 7.25.0-tag)
```

**Fix D** (`spring.liquibase` in the app owns the schema, one path kept): wrapper changelog with `logicalFilePath` = the old
`FILENAME` value, plus an author update **run once, separately, before the first Operaton start** (DBA step or init job, never a
changeset in the same run), plus `clear-checksums: true` for the first deployment only:

```xml
<!-- src/main/resources/db/operaton-wrapper-changelog.xml -->
<databaseChangeLog
    xmlns="http://www.liquibase.org/xml/ns/dbchangelog"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
    xsi:schemaLocation="http://www.liquibase.org/xml/ns/dbchangelog
                        http://www.liquibase.org/xml/ns/dbchangelog/dbchangelog-latest.xsd">
  <include file="org/operaton/bpm/engine/db/liquibase/operaton-changelog.xml" relativeToChangelogFile="false"
           logicalFilePath="org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml"/>  <!-- = YOUR FILENAME value -->
</databaseChangeLog>
```

```sql
update DATABASECHANGELOG set AUTHOR = 'Operaton', MD5SUM = null
 where AUTHOR = 'Camunda' and ID in ('7.23-to-7.24', '7.24.0-tag')
   and FILENAME = 'org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml';   -- YOUR FILENAME value
```

Then `spring.liquibase.change-log: classpath:db/operaton-wrapper-changelog.xml` and `spring.liquibase.clear-checksums: true`
(first Operaton deployment only, then remove). Fix D is a D15 **soft stop**: the rollback runbook must reverse the update (`set AUTHOR = 'Camunda'` for the same two ids) or
start the Camunda build with `spring.liquibase.enabled=false`. Spring Boot 4 manages Liquibase 5; the fixes were verified with
Liquibase 4.x only: rehearse with the version the build resolves, or pin `liquibase.version`. Always keep `schema-update: false`.

## 5. Flyway and DBA-managed scripts

- Operaton ≤ 2.1: **no new migration**. Operaton 2.2+: add one migration with the content of `<db>_engine_7.24_to_7.25.sql`.
  Never edit applied scripts (checksums). Keep `schema-update: false`.
- Source scripts from `org.operaton.bpm.distro:operaton-sql-scripts`, which is **versioned by schema level** (`7.24.0` = schema
  of Operaton 1.x–2.1), not by Operaton version (no `operaton-sql-scripts:2.1.x`). Content: `sql/create/`, `sql/upgrade/`,
  `sql/liquibase/`. Unpack it with `maven-dependency-plugin:unpack` (`<includes>sql/upgrade/postgres_*.sql</includes>`).

## 6. Persisted data that still says "camunda" (D18)

The engine maps nothing from `org.camunda` to `org.operaton` on read (no compat layer; PR #3106 was rejected).

| Where | Impact | Action |
|---|---|---|
| `camunda-admin` in `ACT_ID_GROUP`, `ACT_ID_MEMBERSHIP`, `ACT_RU_AUTHORIZATION` | **security**: setup endpoint reopens | D5 (references/identity-and-admin.md); keep the rows for rollback |
| `TEXT2_` = `org.camunda.…` in `ACT_RU_VARIABLE`, `ACT_HI_VARINST`, `ACT_HI_DETAIL`, `ACT_HI_DEC_IN/OUT` | `Cannot deserialize object in variable '<name>'` | D18 |
| `ACT_GE_BYTEARRAY` bytes of `serializable` variables containing `org.camunda.*` (nested, e.g. `VariableMapImpl`) | `ClassNotFoundException` | D18 |
| Deployed resources containing `org.camunda.` (scripts, `camunda:class`) | fail when executed, also in-flight | references/models-and-scripts.md |
| `activiti:` namespace in deployed resources | parse failure | redeploy converted model, migrate instances |
| `camunda:` namespace, stack-trace text, filter JSON, `camunda.installation.id` | none | keep |
| Filter JSON with expressions (`ACT_RU_FILTER.QUERY_`, `…Expression` keys) | none at start; evaluated without an allow-list on Operaton; fails if stored-query expressions are switched off | D17 (P11) |
| EE license (`ACT_GE_BYTEARRAY` `camunda-license-key`, `ACT_GE_PROPERTY` `camunda-license-key-id`) | none (Operaton ignores it) | keep for rollback (D17) |

**Unchanged, never rebrand:** serializer names (`serializable`, `spin://application/json`, `json`, …), job handler types,
batch types, incident types (`failedJob`, `failedExternalTask`), metric names, `Resources`/`Permissions` ints, password hashes.

Detection: `20-find-legacy-references.sql` (run on a replica/restored copy; large `BYTEA` scans). Sections: L1 typed variables
(L1b runtime details), L2 byte arrays containing renamed classes (L2b runtime = blocker), L3–L7 deployed resources, definitions
and running work, Activiti, `camunda-forms:`, DMN/CMMN; L8 job/incident consistency; L9 one-row summary of blockers.
`org.camunda.feel` is never reported. Java serialization writes field types with slashes: search `org/camunda/` too for
null-valued Camunda-typed fields.

**D18 recommendation: convert before the cut-over (option 1) or drain (option 2). No byte rewriting, no waiting for a compat
layer.** 2.x removed `Serializable` from engine entity classes, so serialized engine entities cannot be revived at all.
Conversion runner, **runs on the Camunda 7.24 build** in the release before the cut-over (Camunda imports on purpose):

```java
for (VariableInstance vi : runtimeService.createVariableInstanceQuery().variableName("orderContext").list()) {
  Object legacy = vi.getValue();                          // deserializes with Camunda classes
  if (legacy instanceof Map<?, ?> map) {                  // e.g. VariableMapImpl
    Map<String, Object> plain = new HashMap<>();
    map.forEach((k, v) -> plain.put(String.valueOf(k), v));
    ObjectValue converted = Variables.objectValue(plain)
        .serializationDataFormat(Variables.SerializationDataFormats.JSON).create();   // needs the Spin JSON plugin
    if (vi.getTaskId() != null) taskService.setVariableLocal(vi.getTaskId(), vi.getName(), converted);
    else runtimeService.setVariableLocal(vi.getExecutionId(), vi.getName(), converted);   // keep the original scope
  }
}
```

Fix the producer code in the same release. Target configuration (as in the migrated example):
`operaton.bpm.default-serialization-format: application/json` and the generic property
`javaSerializationFormatEnabled: false`. History rows: accept the Cockpit deserialization error or clean up via the API.

## 7. Direct SQL → Java API / REST (D10)

Raw SQL on `ACT_*` runs unchanged on Operaton and nothing flags it, with the same damage as before: no `REV_` bump (lost
updates), lock columns left inconsistent (`LOCK_OWNER_` set + `LOCK_EXP_TIME_` null = never acquired again), `failedJob`
incidents and history left open or deleted (stuck instances become invisible), call-activity parent incidents orphaned, no
`ACT_HI_OP_LOG`, no authorization checks, custom `IncidentHandler`s and exporters never called.
**D10: replace every routine script with the API/REST; keep only `30-`/`31-` for when the API is unavailable.**

| Task | Java API (`org.operaton.bpm.engine.*`) | REST (`/engine-rest`) |
|---|---|---|
| Retry one failed job (resolves incident, repairs lock, op log) | `managementService.setJobRetries(3).jobId(id).dueDate(d).execute()` | `PUT /job/{id}/retries` |
| Retry failed jobs by query (batch, per-job semantics) | `setJobRetriesByJobsAsync(3).jobQuery(createJobQuery().noRetriesLeft().processDefinitionKey(k)).dueDate(d).executeAsync()` | `POST /job/retries` `{"jobQuery":{…},"retries":3}` |
| Retry by process instances (batch) | `setJobRetriesByProcessAsync(3).processInstanceQuery(q).executeAsync()` | `POST /process-instance/job-retries` |
| Retry all failed jobs of one job definition (bulk; **incidents stay open until success**) | `setJobRetriesByJobDefinitionId(defId, 3)` | `PUT /job-definition/{id}/retries` |
| Execute a job now (debug) | `managementService.executeJob(id)` | `POST /job/{id}/execute` |
| Unlock a job | no API: locks expire after `lockTimeInMillis`; `setJobRetries(jobId, n)` repairs inconsistent locks | wait, or `PUT /job/{id}/retries` |
| Move a timer | `setJobDuedate(id, date[, cascade])`, `recalculateJobDuedate(id, creationDateBased)` | `PUT /job/{id}/duedate`, `POST /job/{id}/duedate/recalculate` |
| External task retries | `externalTaskService.setRetries(id, 3)`; bulk `updateRetries().externalTaskQuery(q).set(3)` / `.setAsync(3)` | `PUT /external-task/{id}/retries`, `PUT /external-task/retries`, `POST /external-task/retries-async` |
| Unlock an external task | `externalTaskService.unlock(id)` | `POST /external-task/{id}/unlock` |
| Resolve a custom incident (refuses `failedJob`/`failedExternalTask`: use retries) | `runtimeService.resolveIncident(id)` | `DELETE /incident/{id}` |
| Document instead of delete | `runtimeService.setAnnotationForIncidentById(id, text)` | `PUT /incident/{id}/annotation` |
| Fix a variable | `runtimeService.setVariable(executionId, name, value)` | `PUT /process-instance/{id}/variables/{name}` |
| Move a token | `createProcessInstanceModification(pid).cancelAllForActivity(a).startBeforeActivity(b).execute()` | `POST /process-instance/{id}/modification` |
| Delete stuck instance(s) | `deleteProcessInstance(id, reason, skipCustomListeners, externallyTerminated, skipIoMappings)`; `deleteProcessInstancesAsync(…)` | `DELETE /process-instance/{id}?skipCustomListeners=true&skipIoMappings=true`; `POST /process-instance/delete` |
| Suspend / activate | `updateProcessInstanceSuspensionState()…suspend()`, `updateJobSuspensionState()…` | `PUT /process-instance/{id}/suspended`, `PUT /job/{id}/suspended` |
| Clean up history | configure TTL + cleanup window; `historyService.cleanUpHistoryAsync(true)` | `POST /history/cleanup?immediatelyDue=true` |

Manual history cleanup is admin-only with authorization enabled (members of `operaton-admin` after the migration). Do not give
technical users `operaton-admin` to "make it work"; grant the specific authorizations.

**Java service to add:** copy `assets/snippets/IncidentRecoveryService.java` (package `com.example.orders.operations`; adapt).
Methods: `retryJob(jobId, retries)`, `retryJobsOfDefinition(jobDefinitionId, retries)` (bulk, incidents stay open),
`retryFailedJobsAsync(processDefinitionKey, retries, dueDate)` → `Batch`, `retryExternalTask(id, retries)`,
`retryFailedExternalTasksAsync(topicName, retries)` → `Batch`, `annotateIncident(incidentId, text)`,
`openIncidents(processDefinitionKey)`. Rejects `retries <= 0`. Expose it only through an authenticated internal endpoint, or use REST.

## 8. The project's own SQL scripts: what to replace them with

For each SQL file touching `ACT_*` (`assess.sh` lists them): explain the defect in the report, replace with the API/REST,
archive the file or turn it into a pointer (the migrated example's `ops/sql/README.md` does this).

| Pattern | Defects | Replacement |
|---|---|---|
| `UPDATE ACT_RU_JOB SET RETRIES_=3 … WHERE RETRIES_=0` | no `REV_` bump; incidents stay open; `EXCEPTION_STACK_ID_ = NULL` orphans byte arrays; `EXCEPTION_MSG_ = NULL` destroys the diagnosis; all jobs due at once (thundering herd); inconsistent locks not repaired; whole table; `HANDLER_TYPE_ = 'async-continuation'` misses timers | `retryFailedJobsAsync(…)` / `POST /job/retries` with a `jobQuery`; `retryJob` / `PUT /job/{id}/retries`; stagger due dates |
| `DELETE FROM ACT_RU_INCIDENT …` | instance stays stuck but invisible; `ACT_HI_INCIDENT` stays open; call-activity parent incidents (FK violation `act_fk_inc_cause` on PostgreSQL, silent cascade on MySQL/MariaDB) | retry when fixed, delete the instance via API when dead, annotate when waiting |
| `INSERT INTO ACT_ID_MEMBERSHIP … 'camunda-admin'` | wrong admin group on Operaton; bypasses id whitelist and authorization | `identityService.createMembership(user, Groups.OPERATON_ADMIN)`, `PUT /engine-rest/group/operaton-admin/members/{user}`, Admin webapp; one-time: `10-migrate-admin-group.sql` |

## 9. Emergency SQL: rules of use

`30-emergency-job-retries.sql` / `31-emergency-external-task-retries.sql` mirror the engine column for column (resolve the
incident chain incl. call-activity parents in one statement, close history, `REV_ + 1`, clear locks). The user copies the
file, edits **EDIT HERE (1/2)** (one scope predicate: job ids, job definition, process instance, `PROCESS_DEF_KEY_` +
`FAILED_ACT_ID_`, or exception message; keep `RETRIES_ = 0`) and **EDIT HERE (2/2)** (`new_retries`, `due_now`/`unlock`,
`resolve_incidents`, `max_jobs`/`max_tasks`, default 50). Guards abort on an empty scope, too many rows, invalid options, or a
scoped job locked by a live node. Dry run: change the final `commit;` to `rollback;`. No clean undo after `COMMIT`.

Rules (put them verbatim into the on-call runbook):
1. Only when `/engine-rest`, Cockpit and Java runners are unavailable.
2. No engine is writing: all nodes stopped or `operaton.bpm.job-execution.enabled=false` everywhere.
3. Backup/snapshot first, ticket open, four-eyes review.
4. One transaction, narrowest scope, row-count limit; compare the affected rows before `commit`. Never `where RETRIES_ = 0` table-wide.
5. Always `REV_ = REV_ + 1`; clear `LOCK_OWNER_` and `LOCK_EXP_TIME_` together.
6. Never delete runtime rows (instances, executions, variables, jobs, tasks) by SQL.
7. Afterwards: `20-find-legacy-references.sql` L8c–L8e must be empty (except intentional `resolve_incidents = false`).
8. Record what was done in the ticket (no `ACT_HI_OP_LOG` entry).
9. Tested on PostgreSQL only; on MySQL add `CREATE_TIME_ = CREATE_TIME_` to every `ACT_HI_INCIDENT` update.

Job locks after a cut-over: all nodes (Camunda and Operaton) down → release every lock
(`update ACT_RU_JOB set REV_ = REV_ + 1, LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null where LOCK_OWNER_ is not null`), or wait
for expiry. One dead node while others may run → only its expired or inconsistent locks
(`… where LOCK_OWNER_ = :deadNode and (LOCK_EXP_TIME_ is null or LOCK_EXP_TIME_ < CURRENT_TIMESTAMP)`). Never swap the two.

## 10. Porting the SQL to other databases

Table and column names are identical on every database. Replace these constructs (full table incl. DB2 and H2:
`assets/sql/README.md`, section "Porting to other databases"):

| PostgreSQL construct | Oracle | SQL Server | MySQL / MariaDB |
|---|---|---|---|
| bytea search for `org.camunda.` (hex `6f72672e63616d756e64612e`) | `dbms_lob.instr(BYTES_, hextoraw('6F72672E63616D756E64612E')) > 0` | `charindex(0x6F72672E63616D756E64612E, cast(BYTES_ as varbinary(max))) > 0` | `locate(X'6F72672E63616D756E64612E', BYTES_) > 0` |
| `gen_random_uuid()::text` (10) | `rawtohex(sys_guid())` | `cast(newid() as varchar(64))` | `uuid()` |
| `create temporary table … on commit drop` | pre-created global temporary table or subqueries | `select … into #tmp` | `create temporary table … as select` |
| `do $$ … raise exception … $$` guards | anonymous block + `raise_application_error` | `throw 50001, '…', 1` | procedure with `signal sqlstate '45000'`, or check previews by hand |
| `update t … from o` (30, 31) | correlated subquery / `merge` | supported | `update t join o on … set …` |
| `string_agg`, `limit`, `cast(ID_ as integer)` | `listagg`, `fetch first n rows only`, `to_number` | `string_agg`, `top n`, `cast(… as int)` | `group_concat`, as is, `cast(… as signed)` |

DB2: `locate(blob(X'…'), BYTES_)`, `declare global temporary table`, `fetch first n rows only`. H2: `locate(X'…', BYTES_)`.
Incident self-FKs do not cascade on PostgreSQL/Oracle/DB2/SQL Server: delete root and parent incidents in one statement.
MySQL: wrap self-referencing subqueries in a derived table `(select …) r`. Mark every ported script "not tested on <vendor>"
in the cut-over pack and require a run on a restored copy first.

## 11. Data-level rollback checks (D15)

Rollback to Camunda 7.24 on the same database works until Operaton writes something Camunda cannot read. **Hard stops:**
`operaton:`-namespaced deployment with running instances; versions with `org.operaton.*` script/class references whose
instances have not passed that step; `operaton-forms:` versions with open tasks; `serializable` variables with
`org.operaton.*` classes. **Soft stops:** Liquibase Fix D (reverse it), edited/deleted `camunda-admin` rows, a deleted
Camunda EE license (restore it). Harmless: `operaton.installation.id`, `operaton-admin` rows, history rows, the `7.25.0`
schema-log row. Checkpoint queries C1–C3:
[cut-over runbook, R2-1](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/checklists/cutover-runbook.md#compatibility-checkpoint-c1c3);
runbook placement: references/cutover.md. No mixed Camunda/Operaton clusters (D7): Kubernetes `Recreate` or scale to 0.

## 12. Done criteria

- [ ] Schema level 7.24 (pre-flight P01: `7.24.0`, a `7.24.N` EE patch row, or `7.25.0`) and DB version ≥ Operaton
      minimums confirmed, or stop condition reported.
- [ ] Camunda EE sources: P11 reviewed (filters with expressions) and the D17 query-expression decision recorded;
      license rows kept.
- [ ] `operaton.bpm.database.schema-update: false`; `camunda.bpm.database.*` keys and `CAMUNDA_BPM_DATABASE_*` env vars migrated.
- [ ] Liquibase: Fix E or D prepared with the real `FILENAME`, reverse SQL in the rollback plan; Flyway: nothing for ≤ 2.1.
- [ ] `00-`, `10-`, `20-` copied to `migration/sql/<vendor>/` (ported if not PostgreSQL), with commands and expected outputs.
- [ ] D18 decided per finding (convert on Camunda 7.24 or drain); producer code fixed; JSON serialization configured.
- [ ] Every project SQL script on `ACT_*` replaced by API/REST (`IncidentRecoveryService` or curl) and archived.
- [ ] Emergency scripts and their nine rules in the runbook, owned by a named person.
- [ ] Baseline (P05) and rollback checkpoint queries in the cut-over pack.
