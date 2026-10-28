-- =====================================================================================================
-- Camunda 7 -> Operaton Migration Starter Pack
-- sql/postgresql/30-emergency-job-retries.sql  -  EMERGENCY ONLY: give failed jobs new retries by SQL
-- =====================================================================================================
--
--  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--  !!  DO NOT USE THIS AS YOUR NORMAL RETRY TOOL. Use the API / REST / Cockpit (below). This script is  !!
--  !!  for the situation where the engine API is NOT available (engine does not start, REST down,      !!
--  !!  cut-over window) and failed jobs must be made executable again.                                 !!
--  !!  ALL engine nodes must be stopped, or job execution paused on all of them                        !!
--  !!  (operaton.bpm.job-execution.enabled=false), and the scope below must be as narrow as possible.  !!
--  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--
-- USE THE API INSTEAD WHENEVER THE ENGINE RUNS (all of these exist in Camunda 7.24 and Operaton 1.x/2.x)
--   Java  managementService.setJobRetries(3).jobIds(ids).dueDate(new Date()).execute();
--         managementService.setJobRetriesByJobsAsync(3)
--             .jobQuery(managementService.createJobQuery().noRetriesLeft()).dueDate(new Date()).executeAsync();
--         managementService.setJobRetriesByJobDefinitionId(jobDefinitionId, 3);   // bulk, incident stays open
--   REST  PUT  /engine-rest/job/{id}/retries            {"retries": 3, "dueDate": "2026-10-06T10:00:00.000+0200"}
--         POST /engine-rest/job/retries                 {"jobIds": ["..."], "retries": 3}        (batch)
--         PUT  /engine-rest/job-definition/{id}/retries {"retries": 3}
--   UI    Cockpit: incident -> "Retry", or a batch operation.
--   Code  examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java
--   The API also checks authorizations, writes the user operation log (ACT_HI_OP_LOG "SetJobRetries") and
--   calls your IncidentHandler (e.g. a paging/notification handler) - this script does none of that.
--
-- WHAT IT DOES (mirrors the engine; code paths verified in Operaton v2.1.5)
--   For the jobs in your scope that have RETRIES_ = 0:
--   1. resolve_incidents = true  (like ManagementService#setJobRetries(jobId, n) -> JobEntity#setRetries):
--      - history: ACT_HI_INCIDENT rows of the incident chain get END_TIME_ = now, INCIDENT_STATE_ = 1 (resolved)
--      - runtime: the root `failedJob` incident (CONFIGURATION_ = job id) and all parent incidents created in
--        super process instances via call activities (same ROOT_CAUSE_INCIDENT_ID_, CONFIGURATION_ null)
--        are deleted in ONE statement (PostgreSQL's incident self-FKs do not cascade)
--      resolve_incidents = false (like setJobRetriesByJobDefinitionId / Job.xml updateFailedJobRetriesByParameters):
--      - incidents stay open until the job succeeds; then the engine resolves them itself
--   2. job: REV_ = REV_ + 1 (optimistic locking!), LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null,
--      RETRIES_ = new_retries, DUEDATE_ = now (optional: due_now) - the exact column set of the engine's
--      updateFailedJobRetriesByParameters.
--   Exception message/stack trace stay (the engine keeps them too until the next execution).
--
-- PHASE
--   Emergencies at any time (incl. cut-over / hypercare). Not part of the regular migration.
--
-- IDEMPOTENT
--   Effectively yes: the scope only matches jobs with RETRIES_ = 0. A second run finds nothing and aborts
--   with "no job matched the scope", which rolls back and changes nothing.
--
-- PREREQUISITES
--   - Backup or at least a snapshot; a change ticket that records job ids and this output (no op log!).
--   - All nodes stopped, or job execution paused everywhere. The guard aborts if a scoped job is locked.
--   - Custom schema / table prefix: `set search_path to <schema>;` first.
--
-- DATABASE
--   PostgreSQL 13+. Tested with PGlite 0.5.8 (= PostgreSQL 18.3) on the Camunda 7.24.0 and Operaton 2.1.5 /
--   2.2.0-RC1 DDL: three-level call-activity incident chain, both modes, guards, second run, see sql/test/.
--
-- RUN
--   1. Copy this file, edit the two "EDIT HERE" blocks (scope + options).
--   2. Dry run: replace the final COMMIT by ROLLBACK; run; read the preview (E4) and the result (E8).
--   3. psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f 30-emergency-job-retries.sql
--      (BEGIN/COMMIT are in the script: do not add --single-transaction)
--   4. Start or resume the nodes; check Cockpit and 20-find-legacy-references.sql section L8.
--
-- OTHER DATABASES (not tested; adapt and test on a copy)
--   - Temp tables: Oracle global temporary table, SQL Server #tables, MySQL "create temporary table".
--     Or inline the scope as a subquery in every statement.
--   - DO $$ ... $$ guard: Oracle/DB2 anonymous block, SQL Server IF ... THROW; MySQL: check the preview.
--   - UPDATE ... FROM: Oracle/DB2/MySQL use a correlated subquery or MERGE.
--   - MySQL: ACT_HI_INCIDENT.CREATE_TIME_ is a `timestamp` that may auto-update: add CREATE_TIME_ = CREATE_TIME_
--     to the history update; and wrap self-referencing subqueries in a derived table (select ... ) r.
--     MySQL's incident self-FKs cascade, the single delete statement works there too.
--
-- ROLLBACK
--   Before COMMIT: ROLLBACK. After COMMIT: there is no clean undo (setting RETRIES_ back to 0 does not
--   recreate incidents); restore from backup or let the jobs fail again (they then create new incidents).
--
-- DOCS
--   docs/08-database-schema-data-and-sql-scripts.md (direct SQL vs. API, decision D10)
--   docs/13-tips-tricks-and-troubleshooting.md, sql/README.md
--
-- License: Apache-2.0. As of 2026-10-06 (Camunda 7.24.0 -> Operaton 2.1.5 / 2.2.x).
-- =====================================================================================================

begin;

set local lock_timeout = '5s';          -- fail fast instead of waiting for a node that is still running
set local statement_timeout = '120s';

-- -----------------------------------------------------------------------------------------------------
-- E1 >>> EDIT HERE (1/2): WHICH JOBS?  Keep "j.RETRIES_ = 0"; replace the placeholder line by ONE scope.
-- -----------------------------------------------------------------------------------------------------
create temporary table emergency_job_scope on commit drop as
select j.ID_ as job_id
  from ACT_RU_JOB j
 where j.RETRIES_ = 0
   and j.ID_ in ('REPLACE-WITH-JOB-ID')                                          -- <<< placeholder
   -- alternatives:
   -- and j.JOB_DEF_ID_ = '<job definition id>'
   -- and j.PROCESS_INSTANCE_ID_ = '<process instance id>'
   -- and j.PROCESS_DEF_KEY_ = 'order-fulfillment' and j.FAILED_ACT_ID_ = 'Task_CheckInventory'
   -- and j.EXCEPTION_MSG_ like '%Connection refused%'
;

-- -----------------------------------------------------------------------------------------------------
-- E2 >>> EDIT HERE (2/2): OPTIONS
-- -----------------------------------------------------------------------------------------------------
create temporary table emergency_job_options on commit drop as
select 3     as new_retries,         -- must be > 0
       true  as due_now,             -- true: DUEDATE_ = now (like "dueDate": now); false: keep DUEDATE_
       true  as resolve_incidents,   -- true: like setJobRetries(jobId); false: incident stays open until success
       50    as max_jobs;            -- abort if the scope matches more jobs than this

-- -----------------------------------------------------------------------------------------------------
-- E3 Guards: abort (and roll back) on an empty or oversized scope, on bad options, or if a scoped job is
--    currently locked by a node (= that node is running).
-- -----------------------------------------------------------------------------------------------------
do $$
declare
  v_scope   int;
  v_max     int;
  v_retries int;
  v_locked  int;
  v_active  int;
begin
  select count(*) into v_scope from emergency_job_scope;
  select max_jobs, new_retries into v_max, v_retries from emergency_job_options;

  if v_retries is null or v_retries < 1 then
    raise exception 'new_retries must be >= 1 (is %)', v_retries;
  end if;
  if v_scope = 0 then
    raise exception 'no job matched the scope (wrong id, or retries already > 0?) - nothing changed';
  end if;
  if v_scope > v_max then
    raise exception 'scope matches % jobs, more than max_jobs = % - narrow the scope or raise max_jobs', v_scope, v_max;
  end if;

  select count(*) into v_locked
    from ACT_RU_JOB j join emergency_job_scope s on s.job_id = j.ID_
   where j.LOCK_OWNER_ is not null and j.LOCK_EXP_TIME_ > CURRENT_TIMESTAMP;
  if v_locked > 0 then
    raise exception '% scoped job(s) are locked by a running node - stop the nodes or pause job execution first', v_locked;
  end if;

  select count(*) into v_active from ACT_RU_JOB where LOCK_OWNER_ is not null and LOCK_EXP_TIME_ > CURRENT_TIMESTAMP;
  if v_active > 0 then
    raise warning '% other job(s) are locked right now: a job executor seems to be running. Proceeding only because no scoped job is locked.', v_active;
  end if;

  raise notice '% job(s) in scope', v_scope;
end
$$;

-- -----------------------------------------------------------------------------------------------------
-- E4 Preview + row locks (FOR UPDATE: a node that wakes up now has to wait for this transaction).
-- -----------------------------------------------------------------------------------------------------
select j.ID_                      as job_id,
       j.REV_                     as rev,
       j.RETRIES_                 as retries,
       j.PROCESS_DEF_KEY_         as process_definition_key,
       j.PROCESS_INSTANCE_ID_     as process_instance_id,
       j.FAILED_ACT_ID_           as failed_activity,
       left(j.EXCEPTION_MSG_, 120) as exception_message,
       j.DUEDATE_                 as due_date,
       j.LOCK_OWNER_              as lock_owner,
       j.SUSPENSION_STATE_        as suspension_state
  from ACT_RU_JOB j
  join emergency_job_scope s on s.job_id = j.ID_
 order by j.ID_
   for update of j;

-- Root incidents of the scoped jobs (only when resolve_incidents = true)
create temporary table emergency_job_root_incidents on commit drop as
select i.ID_ as root_incident_id, i.CONFIGURATION_ as job_id
  from ACT_RU_INCIDENT i
  join emergency_job_scope s on s.job_id = i.CONFIGURATION_
 where i.INCIDENT_TYPE_ = 'failedJob'
   and i.ID_ = i.ROOT_CAUSE_INCIDENT_ID_
   and (select resolve_incidents from emergency_job_options);

-- Preview of the incident chains that will be resolved (root + parents in super process instances)
select i.ROOT_CAUSE_INCIDENT_ID_ as root_incident_id,
       i.ID_                     as incident_id,
       i.CAUSE_INCIDENT_ID_      as cause_incident_id,
       i.PROC_INST_ID_           as process_instance_id,
       i.ACTIVITY_ID_            as activity_id,
       i.CONFIGURATION_          as configuration
  from ACT_RU_INCIDENT i
 where i.ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_job_root_incidents)
 order by i.ROOT_CAUSE_INCIDENT_ID_, i.INCIDENT_TIMESTAMP_, i.ID_
   for update;

-- -----------------------------------------------------------------------------------------------------
-- E5 History first: close the open history rows of each chain as "resolved" (INCIDENT_STATE_ 1).
--    (Only rows that exist: with history level < full there are none.)
-- -----------------------------------------------------------------------------------------------------
update ACT_HI_INCIDENT
   set END_TIME_ = CURRENT_TIMESTAMP,
       INCIDENT_STATE_ = 1
 where END_TIME_ is null
   and INCIDENT_TYPE_ = 'failedJob'
   and ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_job_root_incidents);

-- -----------------------------------------------------------------------------------------------------
-- E6 Runtime incidents: root and all parents in ONE statement (FKs are checked at statement end).
-- -----------------------------------------------------------------------------------------------------
delete from ACT_RU_INCIDENT
 where ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_job_root_incidents);

-- -----------------------------------------------------------------------------------------------------
-- E7 Jobs: same columns as the engine's updateFailedJobRetriesByParameters.
-- -----------------------------------------------------------------------------------------------------
update ACT_RU_JOB j
   set REV_           = j.REV_ + 1,
       LOCK_OWNER_    = null,
       LOCK_EXP_TIME_ = null,
       DUEDATE_       = case when o.due_now then CURRENT_TIMESTAMP else j.DUEDATE_ end,
       RETRIES_       = o.new_retries
  from emergency_job_options o
 where j.ID_ in (select job_id from emergency_job_scope)
   and j.RETRIES_ = 0;

-- -----------------------------------------------------------------------------------------------------
-- E8 Result: retries/rev per job, and how many failedJob incidents are still open for them
--    (0 with resolve_incidents = true; 1 per job with false, until the job succeeds).
-- -----------------------------------------------------------------------------------------------------
select j.ID_ as job_id, j.REV_ as rev, j.RETRIES_ as retries, j.DUEDATE_ as due_date, j.LOCK_OWNER_ as lock_owner,
       (select count(*) from ACT_RU_INCIDENT i
         where i.INCIDENT_TYPE_ = 'failedJob' and i.CONFIGURATION_ = j.ID_) as open_root_incidents
  from ACT_RU_JOB j
  join emergency_job_scope s on s.job_id = j.ID_
 order by j.ID_;

commit;   -- dry run: replace by ROLLBACK
