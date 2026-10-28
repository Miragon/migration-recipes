# Cut-over, rollback and the point of no return

Reference for `cutover` mode: what to generate for humans, the condensed cut-over and rollback runbooks, and the
D15 hard/soft stops. Sources (read them when tailoring):
[11 · Cut-over, rollback and operations](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/11-cutover-rollback-and-operations.md),
[cut-over runbook](https://github.com/Miragon/migration-recipies/blob/main/services/c7/checklists/cutover-runbook.md)
(the step IDs below are the same), [01 · D7/D15](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#d15).

## Contents

1. Ground rules for the agent
2. What to generate in `migration/`
3. Inputs needed for tailoring
4. Runbook: phases before T0
5. Runbook: T0, strictly sequential
6. Rollback triggers
7. Rollback runbook (R1, R2, R3) and the compatibility checkpoint
8. D15: hard stops, soft stops, point of no return
9. Hypercare, clean-up, who to notify

## 1. Ground rules for the agent

- **You generate; humans execute.** Never run SQL, Liquibase, `kubectl`, ingress changes or REST writes against
  anything but a local throw-away engine. `smoke-test.sh --write` appears in the human runbook (rehearsal copy and T0-12;
  it deploys and deletes a tiny `camunda:` process); you run `--write` only against a local throw-away engine.
- Strategy is **big bang on the same database** (D7 A). Never write a rolling/mixed-cluster plan. Kubernetes:
  `strategy.type: Recreate` (or scale to 0) for the cut-over release; the default `RollingUpdate` creates a mixed cluster.
- Never drop these steps from a tailored runbook: setup-path block, stop **all** Camunda nodes, lock handling, backup,
  admin-group step, pre-flight gate, **one** Operaton node without traffic, non-mutating setup check, rollback kit.
- No schema scripts are needed (identical DDL). The database is touched once, at T0.
- Production goes **directly from Camunda 7.24 to Operaton 2.x** (Spring Boot 4 path: one release; Spring Boot 3.5
  path: the 1.x checkpoint never runs on production data). Target 2.2.x: the runbook also runs
  `<db>_engine_7.24_to_7.25.sql` (one `ACT_GE_SCHEMA_LOG` row `7.25.0`, no DDL) before the first Operaton start.
- Camunda EE sources: keep the EE license rows in the database (rollback needs them) and the last Camunda EE image and
  its license configuration in the rollback kit.
- Mark every generated file `DRAFT, review required by <dba/ops/security>` until the user confirms the review.

## 2. What to generate in `migration/`

```
migration/
  README.md                       index, review status, how to run the SQL (psql conventions below)
  cutover-runbook.md              tailored runbook: T−14d … T+72h, owners, gates, CP evidence slots, R1–R3
  config-changes.md               per environment: every key/env var to rename, ingress/probe/IdP changes (D6, D13)
  downstream-notification.md      teams to notify and what to tell each (section 9)
  sql/<vendor>/00-preflight-checks.sql         copy of assets/sql/postgresql/00-…
  sql/<vendor>/10-migrate-admin-group.sql      if D5 includes SQL (recommended)
  sql/<vendor>/20-find-legacy-references.sql   scans for D3/D18 (run on a replica or copy)
  sql/<vendor>/<db>_engine_7.24_to_7.25.sql    only for a 2.2.x target (from operaton-sql-scripts / the operaton-engine 2.2 jar)
  sql/<vendor>/30-emergency-job-retries.sql    only if D10 keeps emergency SQL
  sql/<vendor>/31-emergency-external-task-retries.sql   idem
  sql/<vendor>/catch-up-burst.sql              F-03 query (section 4)
  sql/<vendor>/rollback-checkpoint.sql         C1–C3 (section 7)
  parse-warmup.sh                              T0-10 loop (section 5)
```

- Minimum at the end of `migrate` mode, even if the user does not want the full pack yet (the D5 and D10 defaults
  refer to these files): `sql/<vendor>/00-…`, `10-…`, `20-…` (plus `30-`/`31-` if D10 keeps emergency SQL) and a
  `cutover-runbook.md` stub (DRAFT; section headings of sections 4–8 with `{{…}}` placeholders, the D15 hard stops,
  open decisions listed). Offer `cutover` mode to tailor it.
- `migrate.sh` ignores `migration/` in its clean-tree check and `verify-leftovers.sh` skips it, so the pack can live in the
  repository from the start (commit it with the user's permission).
- `MIGRATION_REPORT.md` section 7 links `migration/cutover-runbook.md` and `migration/sql/…`; keep those paths.
- Each SQL copy gets a header line: source file, copy date, vendor adaptations, and `NOT TESTED on <vendor>` unless
  it is PostgreSQL (only PostgreSQL is tested). Porting notes: references/database.md.
- psql convention for every script: `psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <file>`, **never**
  `--single-transaction` (the scripts manage their own transactions). Files with `:'t0'`/`:'window_start'` take
  `-v t0="$T0"` etc.; psql does not substitute variables in `-c` strings.
- Pre-flight exit codes: 0 = `GO` / `GO_WITH_WARNINGS`, 3 = `NO_GO`. Before the admin-group step and while Camunda
  runs, NO_GO is expected (job locks, empty `operaton-admin`); only the report rows matter then.

## 3. Inputs needed for tailoring

Collect from the report and decisions; ask for what is missing (one message):
namespace/deployment/replica count; DB vendor and how backups/snapshots are taken; old Camunda image tag (rollback)
and new image tag; Operaton target (2.1.5 or 2.2.x, D1); webapp path (D6); `lockTimeInMillis` if customized;
Liquibase/Flyway (D8); Camunda EE: license, EE webapp features in use, query-expression choice (D17); admin approach and
identity type (D5); whether the release deploys changed models on first start (fixed scripts, form keys: D3/D4);
external-task workers (topics, worker ids, retry budgets); event consumers (D9); services sharing the DB (D7);
PoNR time cap and decision owner (D15); support contact (D14); maintenance window.
Owners in the runbook are placeholders: `{{lead}} {{decider}} {{dba}} {{ops}} {{dev}} {{sec}} {{int}} {{comms}}`.

## 4. Runbook: phases before T0

| ID | When | Step | Evidence |
|---|---|---|---|
| P-01 | T−14d | `00-preflight-checks.sql` on production (read-only) | P01 schema log `7.24.0` (or a `7.24.N` EE patch row), P02 `schema.version = fox`; DB within the 2.1+ minimums; P11 filters with expressions listed (D17) |
| P-02 | | migration commit merged (Spring Boot 3.5 path: Hop 1 + Hop 2), `mvn -B verify` green, `verify-leftovers.sh` exit 0, image with pinned versions; EE sources: build resolves from Maven Central alone, EE repository and credentials removed | `mvn dependency:tree` shows intended versions, no `-RC` (2.2.0-RC1 only on a rehearsal build) |
| P-03 | | D5, D6, D7, D8, D13, D14, D15, D17 (EE sources), D18 accepted (D15 with PoNR events, time cap, triggers with numbers) | decision table |
| P-04 | | config change list per environment (`camunda\.bpm`, `CAMUNDA_BPM_`, `management\.health\.camunda`, `org\.camunda\.bpm` loggers, `/camunda/`, `camunda-admin`, `artifacts\.camunda\.com`, `license-file`, `validate-auth-resource-id-exists`, `queryExpressionAllowList`, `allowedExpression`); PRs prepared, **not merged**; D17 query-expression setting in the production configuration | reviewed list; `LegacyCamundaConfigGuard` enabled |
| P-05 | | cut-over manifests: `Recreate`, `terminationGracePeriodSeconds` ≥ longest job + 30 s, D13 probes, `OPERATON_BPM_DATABASE_SCHEMA_UPDATE=false`, `OPERATON_BPM_WEBAPP_APPLICATION_PATH`; ingress rule blocking `<app-path>/api/admin/setup/*` (403) | `kubectl diff`; the ingress's own 403 on the rehearsal host |
| P-06 | | admin-group approach tested on a copy | smoke test: setup page closed |
| P-07 | | Liquibase Fix E or Fix D + reverse (if applicable) | both directions run on a copy |
| P-08 | | pre-migration release (package-free scripts, `formRef`; SKILL step 3b) live on production Camunda 7.24, old-version instances migrated; `20-find-legacy-references.sql` on a replica: every L1–L5 hit remediated, or recorded as D15 hard stop | report |
| P-09 | | logs/alerts match `^org\.(camunda\|operaton)\.bpm\.` (FEEL stays `org.camunda.feel`), JMX both domains, monitor on `/engine-rest/version` | test alert fired |
| P-10…13 | | integrations inventoried, D9 consumer sign-off recorded; D14 decided; T−4 weeks notice; rollback kit drafted | |
| R-01…06 | T−7d | rehearsal on a fresh production snapshot, isolated, outbound stubbed, `OPERATON_BPM_JOB_EXECUTION_ENABLED=false` first; stopwatch per T0 step; catch-up burst; R1 and R2 rehearsed | downtime budget filled; **go/no-go 1** |
| F-01…07 | T−1d | deployment freeze (optionally deny `POST /engine-rest/deployment/create` except the pipeline); baseline (P05–P07, L9); burst estimate; batches drained (`select count(*) from ACT_RU_BATCH`); read-only smoke snapshot of Camunda; rollback kit verified; roster | **go/no-go 2** |

Burst estimate (`catch-up-burst.sql`, run with `-v window_start=… -v window_end=…`):

```sql
select TYPE_, HANDLER_TYPE_, count(*) from ACT_RU_JOB
 where RETRIES_ > 0 and SUSPENSION_STATE_ = 1
   and DUEDATE_ between :'window_start' and :'window_end'
 group by TYPE_, HANDLER_TYPE_;
```

## 5. Runbook: T0, strictly sequential

| ID | Step | Checkpoint |
|---|---|---|
| T0-01 | maintenance page/503 for webapps and `/engine-rest`; setup-path block active (stays after go-live); pause workers with small retry budgets; record `T0` | |
| T0-02 | `kubectl -n $NS scale deploy/$APP --replicas=0` then `kubectl -n $NS wait --for=delete pod -l app=$APP --timeout=300s` | **CP1** no Camunda process anywhere (other clusters, cron jobs); P09 no app sessions |
| T0-03 | wait `lockTimeInMillis` (default 5 min) **or**, with every engine node down, reset locks | **CP2** lock count = 0 |
| T0-04 | backup/snapshot | **CP3** backup id recorded |
| T0-05 | Liquibase Fix E/D as rehearsed (if applicable); target 2.2.x: `<db>_engine_7.24_to_7.25.sql` (Flyway/DBA) or the Liquibase changeSets `7.24-to-7.25` / `7.25.0-tag` | **CP4** nothing left to run |
| T0-06 | `10-migrate-admin-group.sql` (also when the plugin ships) | S6 all mirrored; exit 0 (exit 3 = rolled back) |
| T0-07 | `00-preflight-checks.sql` | `GO`/`GO_WITH_WARNINGS`; NO_GO = stop. Only waivable reason, in writing by `{{lead}}`: plugin-only D5, "nobody is in operaton-admin" |
| T0-08 | merge config PRs; new image, `replicas: 1`, no user traffic; follow the log | **CP5** banner `Operaton: (v…)` + expected Spring Boot; no `ERROR`; no `historyLevel mismatch`; `ENGINE-14014 Starting up the JobExecutor` (unless off on purpose); guard silent; only expected deployments |
| T0-09 | port-forward; `curl -s $BASE_URL/actuator/health/readiness` | **CP6** UP, `processEngine` UP |
| T0-10 | parse warm-up over all definitions with runtime data | **CP7** zero failures |
| T0-11 | `smoke-test.sh --base-url $BASE_URL --webapp-path $WEBAPP_PATH --user … --password … --require-operaton` | **CP8** "admin setup page" PASS; a former admin opens Admin |
| T0-12 | same with `--write` + business smoke (short timer, external task, one deep link) | **CP9** counts = F-02 baseline + expected burst |
| T0-13 | **go/no-go 3** (`{{lead}}` + `{{decider}}`): go if CP1–CP9 passed, else **R1** | decision + time |
| T0-14 | scale out; ingress from maintenance to service, **setup block kept**; resume workers; smoke test through the ingress | **CP10** edge answers its own 403 on the setup path; smoke "setup page closed" |
| T0-15 | watch 60 min | **CP11** error rate, `job-failed` vs `job-successful`, incidents vs baseline, burst drains |
| T0-16 | "done" notice; rollback window open until PoNR event or T0 + cap | |

```sql
-- lock count (CP2, R1-2): must be 0 before the first Operaton start
select count(*) as jobs_locked_now from ACT_RU_JOB
 where LOCK_OWNER_ is not null and LOCK_EXP_TIME_ > CURRENT_TIMESTAMP;
-- lock reset: ONLY with every engine node (Camunda and Operaton) stopped and P09 clean
update ACT_RU_JOB set REV_ = REV_ + 1, LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null where LOCK_OWNER_ is not null;
```

```bash
# parse-warmup.sh: any non-200 is a NO-GO candidate (same idea for /decision-definition/{id})
psql "$DATABASE_URL" -X -At -c "
  select distinct PROC_DEF_ID_ from ACT_RU_EXECUTION
  union select distinct PROCESS_DEF_ID_ from ACT_RU_JOB where PROCESS_DEF_ID_ is not null" |
while read -r id; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPS_USER:$OPS_PASSWORD" \
         "$BASE_URL/engine-rest/process-definition/$id")
  [ "$code" = 200 ] || echo "FAILED ($code): $id"
done
```

The warm-up catches parse problems (Activiti namespace, broken XML), not `org.camunda.*` in scripts; those come from
L3/L4 of `20-find-legacy-references.sql`. A 403 on the setup path proves only the edge block, never the setup state.

## 6. Rollback triggers

Agree numbers before T0 (examples): Operaton not healthy 30 min after first start; setup page cannot be closed (any
time); parse failures on definitions with running instances not fixed within 30 min; `job-failed` > 5 % of
`job-successful` for 15 min, or incidents > baseline + 20 with `ClassNotFoundException`/`org.camunda` messages; a
critical integration broken 30 min; job backlog still growing 1 h after the burst.
**Not** triggers: one process with a broken script (migrate instances, fix forward), cosmetic webapp differences,
dashboards still on old logger names, incident counts high only because of the expected burst.

## 7. Rollback runbook (R1, R2, R3) and the compatibility checkpoint

RB-0: trigger matched, fix time box expired, `{{decider}}` decides rollback vs. fix forward; path chosen; recorded.

**R1 · before traffic was opened:** R1-1 scale Operaton to 0 (no pod, P09 clean) → R1-2 wait/reset locks (count 0) →
R1-3 Liquibase reverse if Fix D was used (or start the Camunda build with `spring.liquibase.enabled=false`; Fix E
needs no reverse) → R1-4 revert config PRs (`CAMUNDA_BPM_*`, probes, paths), deploy `$CAMUNDA_IMAGE` with 1 replica;
leave `operaton-admin` rows, `operaton.installation.id` and a `7.25.0` schema-log row (Camunda ignores them); Camunda EE
finds its license rows, which Operaton left untouched → CP-R1 smoke test with
`--webapp-path /camunda` passes, reports the Camunda `7.x` version (it WARNs "not Operaton yet", expected), counts = F-05 → R1-5 reopen.

```sql
-- Liquibase Fix D reverse (use YOUR FILENAME value)
update DATABASECHANGELOG set AUTHOR = 'Camunda', MD5SUM = null
 where AUTHOR = 'Operaton' and ID in ('7.23-to-7.24', '7.24.0-tag')
   and FILENAME = 'org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml';
```

**R2 · after traffic, before the PoNR:** R2-1 run `rollback-checkpoint.sql` (`-v t0="$T0"`, read-only).
Clean (C3 empty and no Operaton-only deployment from C1 has instances in C2) → R2-2 as R1-1…R1-3 → R2-3 as R1-4 and
CP-R1 plus incident/failed-job counts ≈ F-02 → R2-4 revert ingress/IdP/probes/alerts, resume workers → R2-5 tell the
business what ran on Operaton. **Not clean** → `{{decider}}` chooses: fix forward (preferred); surgical (while
Operaton runs: migrate instances on Operaton-only versions to a Camunda-compatible version with
`runtimeService.newMigration(plan).processInstanceQuery(…).executeAsync()`, wait for the batch, suspend the
Operaton-only definitions, convert variables, re-run R2-1); or restore the CP3 backup (loses all work since T0,
every external system must be reconciled).

**R3 · after the PoNR:** fix forward only (Cockpit/API, `IncidentRecoveryService`, instance migration, hotfix). A
backup restore is disaster recovery with management approval, not a rollback.

```sql
-- rollback-checkpoint.sql (PostgreSQL; run with -v t0='<T0 timestamp>')
-- C1 deployments since the cut-over, and whether they are Operaton-only
select d.ID_, d.NAME_, d.DEPLOY_TIME_, b.NAME_ as resource,
       position(convert_to('http://operaton.org/schema/1.0/', 'UTF8') in b.BYTES_) > 0 as operaton_namespace,
       position(convert_to('org.operaton.', 'UTF8') in b.BYTES_) > 0                      as operaton_references,
       position(convert_to('operaton-forms:', 'UTF8') in b.BYTES_) > 0                    as operaton_form_keys
  from ACT_RE_DEPLOYMENT d join ACT_GE_BYTEARRAY b on b.DEPLOYMENT_ID_ = d.ID_
 where d.DEPLOY_TIME_ >= :'t0';
-- C2 running instances on definitions deployed since the cut-over
select p.KEY_, p.VERSION_, p.ID_, count(*) as running_instances
  from ACT_RE_PROCDEF p join ACT_RU_EXECUTION e on e.PROC_DEF_ID_ = p.ID_ and e.ID_ = e.PROC_INST_ID_
 where p.DEPLOYMENT_ID_ in (select ID_ from ACT_RE_DEPLOYMENT where DEPLOY_TIME_ >= :'t0')
 group by p.KEY_, p.VERSION_, p.ID_;
-- C3 variables only Operaton can read
select TYPE_, TEXT2_, count(*) from ACT_RU_VARIABLE where TEXT2_ like '%org.operaton.%' group by TYPE_, TEXT2_;
select count(*) as serialized_with_operaton_classes
  from ACT_RU_VARIABLE v join ACT_GE_BYTEARRAY b on b.ID_ = v.BYTEARRAY_ID_
 where v.TYPE_ = 'serializable' and position(convert_to('org.operaton.', 'UTF8') in b.BYTES_) > 0;
```

Rollback kit (verified at T−1d, kept until the window closes): last Camunda image tag (exempt from registry clean-up)
and its full configuration (Helm values, ConfigMaps, Secrets with `CAMUNDA_BPM_*`, old probes and ingress; Camunda EE:
license file/secret and the EE repository access needed to rebuild that image); backup id
with a restore timed in the rehearsal; Liquibase reverse SQL; old alert rules; reachable names for R1/R2.

## 8. D15: hard stops, soft stops, point of no return

Rollback = redeploy the last Camunda build on the same DB, no restore, until Operaton writes something Camunda cannot
read or run. Harmless: `operaton.installation.id`, `operaton-admin` rows, the reconfigured `history-cleanup` job, users
and history rows, the 2.2 `7.25.0` schema-log row, the untouched Camunda EE license rows.

| Hard stop (rollback unsafe unless instances are migrated back / variables converted while Operaton runs) |
|---|
| first `operaton:`-namespaced deployment that gets instances (Camunda ignores `operaton:` attributes) |
| definition versions referencing `org.operaton.*` in scripts or class attributes, with instances that have not passed that step |
| definition versions with `operaton-forms:` keys that have open tasks (Camunda cannot load the form) |
| Java-serialized `org.operaton.*` objects in variables (`ClassNotFoundException` on Camunda) |

Soft stops (rollback still possible after reversing): Liquibase Fix D (reverse SQL), deleted `camunda-admin` rows
(restore them; better: never delete before the window closes), a deleted Camunda EE license (restore it; better: never
delete it before the window closes), webapp path moved to `/operaton` (revert proxy and IdP).

**Your fixed models are the first hard stop.** If the release renames script imports to `org.operaton.*` or switches
to `operaton-forms:`, the first Operaton start deploys a version Camunda cannot run. Avoid it: package-free scripts
(only the pre-bound `S(…)`; `JSON(…)`/`XML(…)` are JUEL-only) and `formRef`, deployed **on Camunda 7.24 before the
cut-over** with running instances migrated there. Otherwise record each Operaton-only version as a hard stop.

PoNR = first hard-stop event that gets instances (C1/C2), first `org.operaton.*` serialized value (C3), any soft stop
you will not reverse, or the time cap (e.g. 72 h after traffic opened), whichever comes first. Keep the window open:
freeze deployments (no Modeler deploys, no `operaton:` conversion, no `org.operaton.*` references, no
`operaton-forms:` keys); with authorization enabled, revoke `CREATE` on `DEPLOYMENT` from humans for the window.

## 9. Hypercare, clean-up, who to notify

Hypercare (daily until the window closes): incidents vs baseline; `select EXCEPTION_MSG_, count(*) from ACT_RU_JOB
where RETRIES_ = 0 group by EXCEPTION_MSG_` (nothing with `org.camunda`, `ClassNotFoundException`, `unable to resolve
class`); first-time parse errors (`org.operaton.bpm.engine.bpmn.parser`); first history-cleanup window; exporter lag;
C1–C3 daily; synthetic monitor `GET <app-path>/app/admin/default/` never redirects to `…/setup/`.
Close the window by recorded decision (D15).

Clean-up (normal releases, after the window): lift the freeze; `RollingUpdate` again; delete `camunda-admin` rows
(API or the commented block of `10-migrate-admin-group.sql`) and its whitelist entry; remove `AdminGroupMigrationPlugin`
and later `LegacyCamundaConfigGuard`; simplify dual-match alerts; keep the setup-path block and monitor (move them
with the path); move to `/operaton` with redirect (D6); convert namespaces per deployment unit (D3); form keys (D4);
delete license files and secrets (keep the license rows in the database as long as a rollback to Camunda EE must stay
possible); remove the Camunda EE repository access from CI and build servers; close D5, D6, D7, D15, D17 in the decision log.

`downstream-notification.md`, one section per audience:

| Audience | Tell them |
|---|---|
| Event/history consumers (D9) | envelope v2 adds `schemaVersion` + `entityType`; `eventClass` keeps the Camunda value until they sign off (then it changes to `org.operaton.*` or is dropped); no events for rolled-back work; counts halve if the old exporter double-registered; sign-off before T0 |
| REST clients, integration owners | `/engine-rest` paths unchanged; calls fail during the window, retry; `GET /version` returns `2.x`; `camundaFormRef` → `operatonFormRef`; catch-up burst after start |
| External-task workers | pause/resume by the cut-over team; same `workerId` can complete tasks locked before the switch |
| Ops, on-call, alerting | logger categories `org.operaton.*` (FEEL stays `org.camunda.feel`), JMX `org.operaton.bpm.platform`, 2.1+ health DOWN on DB failure, rollback triggers and decider |
| IdP/SSO owners | only if the webapp path moves (redirect and post-logout URIs) or admin group mapping changes (D5 E) |
| Users, service desk | window, re-login, URLs (unchanged with D6 A), who is admin now, EE features gone (D17) |
| Security | setup-path block, `operaton-admin` membership, support model (D14); Camunda EE hardening Operaton lacks (D17): query-expression allow-list (security notice 157) and the chosen mitigation, no `validateAuthResourceIdExists` |
