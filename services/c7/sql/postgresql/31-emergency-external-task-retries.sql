-- =====================================================================================================
-- Camunda 7 -> Operaton Migration Starter Pack
-- sql/postgresql/31-emergency-external-task-retries.sql  -  EMERGENCY ONLY: new retries for external tasks
-- =====================================================================================================
--
--  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--  !!  DO NOT USE THIS AS YOUR NORMAL RETRY TOOL. Use the API / REST / Cockpit (below). This script is  !!
--  !!  for the situation where the engine API is NOT available (engine does not start, REST down,      !!
--  !!  cut-over window) and failed external tasks must become fetchable again.                         !!
--  !!  ALL engine nodes must be stopped (no fetchAndLock is answered then), and the scope below must    !!
--  !!  be as narrow as possible.                                                                       !!
--  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
--
-- USE THE API INSTEAD WHENEVER THE ENGINE RUNS (all of these exist in Camunda 7.24 and Operaton 1.x/2.x)
--   Java  externalTaskService.setRetries(externalTaskId, 3);
--         externalTaskService.updateRetries().externalTaskIds(ids).set(3);            // or .setAsync(3)
--         externalTaskService.updateRetries()
--             .externalTaskQuery(externalTaskService.createExternalTaskQuery().noRetriesLeft()).set(3);
--         externalTaskService.unlock(externalTaskId);
--   REST  PUT  /engine-rest/external-task/{id}/retries   {"retries": 3}
--         PUT  /engine-rest/external-task/retries        {"externalTaskIds": ["..."], "retries": 3}
--         POST /engine-rest/external-task/retries-async  {"externalTaskIds": ["..."], "retries": 3}   (batch)
--         POST /engine-rest/external-task/{id}/unlock
--   UI    Cockpit: incident -> "Retry".
--   Code  examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java
--   The API also checks authorizations, writes the user operation log and calls your IncidentHandler.
--
-- WHAT IT DOES (mirrors ExternalTaskEntity#setRetriesAndManageIncidents + #unlock, Operaton v2.1.5)
--   For the external tasks in your scope that have no retries left (RETRIES_ <= 0):
--   1. history: ACT_HI_INCIDENT rows of the `failedExternalTask` incident chain get END_TIME_ = now,
--      INCIDENT_STATE_ = 1 (resolved)
--   2. runtime: root incident (CONFIGURATION_ = external task id) + parent incidents in super process
--      instances (call activities) are deleted in ONE statement
--   3. task: REV_ = REV_ + 1, RETRIES_ = new_retries; with unlock = true also WORKER_ID_ = null and
--      LOCK_EXP_TIME_ = null, so the next fetchAndLock gets it immediately. (handleFailure() leaves the task
--      locked until now + retryTimeout; with unlock = false that lock expires on its own.)
--   ERROR_MSG_ / ERROR_DETAILS_ID_ stay, as with the API.
--   Fetch condition (ExternalTask.xml): (LOCK_EXP_TIME_ is null or <= now) and (SUSPENSION_STATE_ is null
--   or = 1) and (RETRIES_ is null or > 0).
--
-- PHASE
--   Emergencies at any time (incl. cut-over / hypercare). Not part of the regular migration.
--
-- IDEMPOTENT
--   Effectively yes: the scope only matches tasks without retries. A second run finds nothing and aborts with
--   "no external task matched the scope", which rolls back and changes nothing.
--
-- PREREQUISITES
--   - Backup or snapshot; a change ticket that records the task ids and this output (no op log!).
--   - All nodes stopped. Workers may keep polling; they get nothing while no engine node runs.
--   - Custom schema / table prefix: `set search_path to <schema>;` first.
--
-- DATABASE
--   PostgreSQL 13+. Tested with PGlite 0.5.8 (= PostgreSQL 18.3) on the Camunda 7.24.0 and Operaton 2.1.5 /
--   2.2.0-RC1 DDL, incl. a call-activity incident chain and a second run, see sql/test/.
--
-- RUN
--   1. Copy this file, edit the two "EDIT HERE" blocks (scope + options).
--   2. Dry run: replace the final COMMIT by ROLLBACK; run; read the preview (X4) and the result (X8).
--   3. psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f 31-emergency-external-task-retries.sql
--      (BEGIN/COMMIT are in the script: do not add --single-transaction)
--
-- OTHER DATABASES (not tested; adapt and test on a copy)
--   Same notes as 30-emergency-job-retries.sql: temp tables, DO-block guard, UPDATE ... FROM, MySQL
--   CREATE_TIME_ = CREATE_TIME_ in the ACT_HI_INCIDENT update and the derived-table wrapper.
--
-- ROLLBACK
--   Before COMMIT: ROLLBACK. After COMMIT: no clean undo; restore from backup or let the worker fail again
--   (handleFailure with retries 0 creates a new incident).
--
-- DOCS
--   docs/08-database-schema-data-and-sql-scripts.md (direct SQL vs. API, decision D10)
--   docs/13-tips-tricks-and-troubleshooting.md, sql/README.md
--
-- License: Apache-2.0. As of 2026-10-06 (Camunda 7.24.0 -> Operaton 2.1.5 / 2.2.x).
-- =====================================================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '120s';

-- -----------------------------------------------------------------------------------------------------
-- X1 >>> EDIT HERE (1/2): WHICH EXTERNAL TASKS?  Keep the RETRIES_ condition; replace the placeholder line.
-- -----------------------------------------------------------------------------------------------------
create temporary table emergency_ext_task_scope on commit drop as
select e.ID_ as ext_task_id
  from ACT_RU_EXT_TASK e
 where e.RETRIES_ is not null and e.RETRIES_ <= 0
   and e.ID_ in ('REPLACE-WITH-EXTERNAL-TASK-ID')                                -- <<< placeholder
   -- alternatives:
   -- and e.TOPIC_NAME_ = 'ship-order'
   -- and e.PROC_INST_ID_ = '<process instance id>'
   -- and e.PROC_DEF_KEY_ = 'order-fulfillment' and e.ACT_ID_ = 'Task_ShipOrder'
   -- and e.ERROR_MSG_ like '%503%'
;

-- -----------------------------------------------------------------------------------------------------
-- X2 >>> EDIT HERE (2/2): OPTIONS
-- -----------------------------------------------------------------------------------------------------
create temporary table emergency_ext_task_options on commit drop as
select 3     as new_retries,     -- must be > 0
       true  as unlock,          -- true: fetchable immediately (like ExternalTaskService#unlock)
       50    as max_tasks;       -- abort if the scope matches more tasks than this

-- -----------------------------------------------------------------------------------------------------
-- X3 Guards
-- -----------------------------------------------------------------------------------------------------
do $$
declare
  v_scope   int;
  v_max     int;
  v_retries int;
begin
  select count(*) into v_scope from emergency_ext_task_scope;
  select max_tasks, new_retries into v_max, v_retries from emergency_ext_task_options;

  if v_retries is null or v_retries < 1 then
    raise exception 'new_retries must be >= 1 (is %)', v_retries;
  end if;
  if v_scope = 0 then
    raise exception 'no external task matched the scope (wrong id, or retries already > 0?) - nothing changed';
  end if;
  if v_scope > v_max then
    raise exception 'scope matches % external tasks, more than max_tasks = % - narrow the scope or raise max_tasks', v_scope, v_max;
  end if;
  raise notice '% external task(s) in scope', v_scope;
end
$$;

-- -----------------------------------------------------------------------------------------------------
-- X4 Preview + row locks
-- -----------------------------------------------------------------------------------------------------
select e.ID_                   as ext_task_id,
       e.REV_                  as rev,
       e.RETRIES_              as retries,
       e.TOPIC_NAME_           as topic,
       e.WORKER_ID_            as worker_id,
       e.LOCK_EXP_TIME_        as lock_expiration,
       e.PROC_DEF_KEY_         as process_definition_key,
       e.PROC_INST_ID_         as process_instance_id,
       e.ACT_ID_               as activity_id,
       left(e.ERROR_MSG_, 120) as error_message,
       e.SUSPENSION_STATE_     as suspension_state
  from ACT_RU_EXT_TASK e
  join emergency_ext_task_scope s on s.ext_task_id = e.ID_
 order by e.ID_
   for update of e;

create temporary table emergency_ext_task_root_incidents on commit drop as
select i.ID_ as root_incident_id, i.CONFIGURATION_ as ext_task_id
  from ACT_RU_INCIDENT i
  join emergency_ext_task_scope s on s.ext_task_id = i.CONFIGURATION_
 where i.INCIDENT_TYPE_ = 'failedExternalTask'
   and i.ID_ = i.ROOT_CAUSE_INCIDENT_ID_;

select i.ROOT_CAUSE_INCIDENT_ID_ as root_incident_id,
       i.ID_                     as incident_id,
       i.CAUSE_INCIDENT_ID_      as cause_incident_id,
       i.PROC_INST_ID_           as process_instance_id,
       i.ACTIVITY_ID_            as activity_id,
       i.CONFIGURATION_          as configuration
  from ACT_RU_INCIDENT i
 where i.ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_ext_task_root_incidents)
 order by i.ROOT_CAUSE_INCIDENT_ID_, i.INCIDENT_TIMESTAMP_, i.ID_
   for update;

-- -----------------------------------------------------------------------------------------------------
-- X5 History first: resolve the open history rows of each chain
-- -----------------------------------------------------------------------------------------------------
update ACT_HI_INCIDENT
   set END_TIME_ = CURRENT_TIMESTAMP,
       INCIDENT_STATE_ = 1
 where END_TIME_ is null
   and INCIDENT_TYPE_ = 'failedExternalTask'
   and ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_ext_task_root_incidents);

-- -----------------------------------------------------------------------------------------------------
-- X6 Runtime incidents: root + parents in ONE statement
-- -----------------------------------------------------------------------------------------------------
delete from ACT_RU_INCIDENT
 where ROOT_CAUSE_INCIDENT_ID_ in (select root_incident_id from emergency_ext_task_root_incidents);

-- -----------------------------------------------------------------------------------------------------
-- X7 External tasks
-- -----------------------------------------------------------------------------------------------------
update ACT_RU_EXT_TASK e
   set REV_           = e.REV_ + 1,
       RETRIES_       = o.new_retries,
       WORKER_ID_     = case when o.unlock then null else e.WORKER_ID_ end,
       LOCK_EXP_TIME_ = case when o.unlock then null else e.LOCK_EXP_TIME_ end
  from emergency_ext_task_options o
 where e.ID_ in (select ext_task_id from emergency_ext_task_scope)
   and e.RETRIES_ is not null and e.RETRIES_ <= 0;

-- -----------------------------------------------------------------------------------------------------
-- X8 Result (open_root_incidents must be 0)
-- -----------------------------------------------------------------------------------------------------
select e.ID_ as ext_task_id, e.REV_ as rev, e.RETRIES_ as retries, e.WORKER_ID_ as worker_id,
       e.LOCK_EXP_TIME_ as lock_expiration,
       (select count(*) from ACT_RU_INCIDENT i
         where i.INCIDENT_TYPE_ = 'failedExternalTask' and i.CONFIGURATION_ = e.ID_) as open_root_incidents
  from ACT_RU_EXT_TASK e
  join emergency_ext_task_scope s on s.ext_task_id = e.ID_
 order by e.ID_;

commit;   -- dry run: replace by ROLLBACK
