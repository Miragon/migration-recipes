-- =====================================================================================================
-- Camunda 7 -> Operaton Migration Starter Pack
-- sql/postgresql/20-find-legacy-references.sql  -  find persisted data that still points to Camunda
-- =====================================================================================================
--
-- PURPOSE
--   The schema is identical, but some DATA written by Camunda 7 breaks on Operaton because Operaton renamed
--   the Java packages org.camunda.{bpm,spin,connect,commons,templateengines} -> org.operaton.* and has no
--   compatibility mapping (PR operaton#3106 was closed unmerged; issue #941 is open). This detection pack finds:
--     L1 object variables whose type name (TEXT2_) is an org.camunda.* class - runtime and history
--     L2 byte arrays (Java-serialized variables, nested objects, Spin values) that contain org.camunda.* class
--        names - classified by owner (runtime variable = blocker, history = accept/clean up, stack trace = harmless)
--     L3 deployed resources (BPMN, DMN, scripts, forms) that reference org.camunda.* classes - typical:
--        Groovy `import org.camunda.spin.Spin`, JavaScript `Java.type('org.camunda.bpm...')`
--     L4 the process definitions behind L3 plus their RUNNING work (instances, jobs, tasks, incidents):
--        these instances fail when they reach the script -> migrate them to a fixed version or drain them
--     L5 deployed models in the legacy Activiti namespace (http://activiti.org/bpmn) - not parsed by Operaton
--     L6 `camunda-forms:` form keys (information for decision D4: according to its source the Operaton Tasklist
--        renders only operaton-forms:; formRef is the rollback-safe fix, operaton-forms: is Operaton-only)
--     L7 decision / case definitions behind L3 hits (information)
--     L8 job and incident overview + consistency checks (also the "after" check for 30-/31-emergency scripts)
--     L9 one-row summary
--   org.camunda.feel.* is NOT renamed (Operaton still uses the Camunda FEEL engine) and is never reported.
--
-- PHASE
--   Phase 0 assessment and rehearsal (on a production copy), again at the freeze, and in hypercare (L8 shows
--   failures that mention org.camunda classes). Decisions: D3 (models/scripts), D4 (forms), D18 (variables).
--
-- MODE
--   Read-only for all ACT_* tables: only TEMPORARY tables are created, in a transaction that is ROLLED BACK.
--   Idempotent.
--
-- COST
--   L2/L3 scan ACT_GE_BYTEARRAY contents (bytea). On large databases run it on a replica or a restored copy,
--   or off-peak; statement_timeout below is 15 min.
--
-- DATABASE
--   PostgreSQL 13+. Tested with PGlite 0.5.8 (= PostgreSQL 18.3) on the Camunda 7.24.0 and Operaton 2.1.5 /
--   2.2.0-RC1 DDL with seed data (serialized variables, nested classes, FEEL-only values, Groovy/JS scripts,
--   Activiti model, camunda-forms keys, incident chains), see sql/test/.
--
-- RUN
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/20-find-legacy-references.sql > legacy-references.txt
--   (The script manages its own transaction: do not add --single-transaction.)
--   Custom schema / table prefix: `set search_path to <schema>;` first.
--
-- OTHER DATABASES (not tested unless noted; adapt and test on a copy)
--   Byte search "contains org.camunda." (hex 6f72672e63616d756e64612e) - replace position(... in BYTES_):
--     H2 2.x       LOCATE(X'6f72672e63616d756e64612e', BYTES_) > 0      (tested on H2 2.3)
--                  or UTF8TOSTRING(BYTES_) LIKE '%org.camunda.%'
--     Oracle       DBMS_LOB.INSTR(BYTES_, HEXTORAW('6F72672E63616D756E64612E')) > 0
--     SQL Server   CHARINDEX(0x6F72672E63616D756E64612E, CAST(BYTES_ AS VARBINARY(MAX))) > 0
--     MySQL/MariaDB LOCATE(X'6F72672E63616D756E64612E', BYTES_) > 0
--     DB2          LOCATE(BLOB(X'6F72672E63616D756E64612E'), BYTES_) > 0
--   Temp tables -> CTEs; string_agg -> Oracle/DB2 listagg, MySQL group_concat; encode(..,'escape') and the regex
--   substring -> drop the class_hint column. Portable alternative for L3: REST GET /process-definition/{id}/xml
--   and grep (scripts/assess.sh scans your source repository instead of the database).
--
-- ROLLBACK
--   Nothing to roll back.
--
-- DOCS
--   docs/08-database-schema-data-and-sql-scripts.md (persisted data, decision D18)
--   docs/05-bpmn-dmn-forms-and-scripts.md (scripts, namespaces, forms, redeploy + instance migration)
--   docs/02-assessment.md, sql/README.md
--
-- License: Apache-2.0. As of 2026-10-06 (Camunda 7.24.0 -> Operaton 2.1.5 / 2.2.x).
-- =====================================================================================================

begin;

set local statement_timeout = '15min';

-- Byte patterns of the renamed packages (dotted = class names in Java serialization, JSON type names,
-- script source; slashed = JVM descriptors). org.camunda.feel is deliberately absent.
create temporary table legacy_patterns (label text, pattern bytea) on commit drop;
insert into legacy_patterns (label, pattern) values
  ('org.camunda.bpm',             convert_to('org.camunda.bpm.', 'UTF8')),
  ('org.camunda.spin',            convert_to('org.camunda.spin.', 'UTF8')),
  ('org.camunda.connect',         convert_to('org.camunda.connect.', 'UTF8')),
  ('org.camunda.commons',         convert_to('org.camunda.commons.', 'UTF8')),
  ('org.camunda.templateengines', convert_to('org.camunda.templateengines.', 'UTF8')),
  ('org/camunda/bpm',             convert_to('org/camunda/bpm/', 'UTF8')),
  ('org/camunda/spin',            convert_to('org/camunda/spin/', 'UTF8')),
  ('org/camunda/connect',         convert_to('org/camunda/connect/', 'UTF8')),
  ('org/camunda/commons',         convert_to('org/camunda/commons/', 'UTF8'));

-- -----------------------------------------------------------------------------------------------------
-- L1 Object variables whose declared type name is a renamed class (Java-serialized "serializable" values
--    and Spin JSON/XML values store the type name in TEXT2_). Runtime rows block the cut-over (D18).
-- -----------------------------------------------------------------------------------------------------
create temporary table legacy_typed_variables on commit drop as
select 'ACT_RU_VARIABLE' as source_table, ID_ as id, NAME_ as name, TYPE_ as var_type, TEXT2_ as object_type_name,
       PROC_INST_ID_ as process_instance_id, PROC_DEF_ID_ as process_definition_id
  from ACT_RU_VARIABLE
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%'
union all
select 'ACT_HI_VARINST', ID_, NAME_, VAR_TYPE_, TEXT2_, PROC_INST_ID_, PROC_DEF_ID_
  from ACT_HI_VARINST
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%'
union all
select 'ACT_HI_DETAIL', ID_, NAME_, VAR_TYPE_, TEXT2_, PROC_INST_ID_, PROC_DEF_ID_
  from ACT_HI_DETAIL
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%'
union all
select 'ACT_HI_DEC_IN', ID_, CLAUSE_ID_, VAR_TYPE_, TEXT2_, null, null
  from ACT_HI_DEC_IN
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%'
union all
select 'ACT_HI_DEC_OUT', ID_, VAR_NAME_, VAR_TYPE_, TEXT2_, null, null
  from ACT_HI_DEC_OUT
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%';

-- L1a overview per table and type name
select source_table, var_type, object_type_name, count(*) as variables,
       count(distinct process_instance_id) as process_instances
  from legacy_typed_variables
 group by source_table, var_type, object_type_name
 order by source_table desc, variables desc;

-- L1b runtime details (convert each one before the cut-over, or let the instance finish on Camunda)
select v.id as variable_id, v.name as variable_name, v.var_type, v.object_type_name,
       v.process_instance_id, pd.KEY_ as process_definition_key, pd.VERSION_ as process_definition_version
  from legacy_typed_variables v
  left join ACT_RE_PROCDEF pd on pd.ID_ = v.process_definition_id
 where v.source_table = 'ACT_RU_VARIABLE'
 order by pd.KEY_, v.process_instance_id, v.name;

-- -----------------------------------------------------------------------------------------------------
-- L2 Non-deployment byte arrays that CONTAIN renamed class names. Catches what TEXT2_ cannot see: e.g. a
--    com.acme.Order that holds an org.camunda.* object in a field (ClassNotFoundException on read).
-- -----------------------------------------------------------------------------------------------------
create temporary table legacy_bytearray_hits on commit drop as
select b.ID_ as bytearray_id,
       b.NAME_ as bytearray_name,
       string_agg(p.label, ', ' order by p.label) as matched_patterns
  from ACT_GE_BYTEARRAY b
  join legacy_patterns p on position(p.pattern in b.BYTES_) > 0
 where b.DEPLOYMENT_ID_ is null
   and position(convert_to('camunda', 'UTF8') in b.BYTES_) > 0      -- cheap pre-filter
 group by b.ID_, b.NAME_;

create temporary table legacy_bytearray_owners on commit drop as
select h.*,
       case
         when exists (select 1 from ACT_RU_VARIABLE v where v.BYTEARRAY_ID_ = h.bytearray_id)        then 'ACT_RU_VARIABLE (BLOCKER: running instances)'
         when exists (select 1 from ACT_HI_VARINST v where v.BYTEARRAY_ID_ = h.bytearray_id)         then 'ACT_HI_VARINST (history: accept or clean up)'
         when exists (select 1 from ACT_HI_DETAIL v where v.BYTEARRAY_ID_ = h.bytearray_id)          then 'ACT_HI_DETAIL (history: accept or clean up)'
         when exists (select 1 from ACT_HI_DEC_IN v where v.BYTEARRAY_ID_ = h.bytearray_id)          then 'ACT_HI_DEC_IN (history: accept or clean up)'
         when exists (select 1 from ACT_HI_DEC_OUT v where v.BYTEARRAY_ID_ = h.bytearray_id)         then 'ACT_HI_DEC_OUT (history: accept or clean up)'
         when exists (select 1 from ACT_RU_JOB j where j.EXCEPTION_STACK_ID_ = h.bytearray_id)       then 'job stack trace (harmless text)'
         when exists (select 1 from ACT_HI_JOB_LOG l where l.JOB_EXCEPTION_STACK_ID_ = h.bytearray_id) then 'job log stack trace (harmless text)'
         when exists (select 1 from ACT_RU_EXT_TASK e where e.ERROR_DETAILS_ID_ = h.bytearray_id)    then 'external task error details (harmless text)'
         when exists (select 1 from ACT_HI_EXT_TASK_LOG l where l.ERROR_DETAILS_ID_ = h.bytearray_id) then 'external task log error details (harmless text)'
         when exists (select 1 from ACT_RU_BATCH t where t.CONFIGURATION_ = h.bytearray_id)          then 'batch configuration (check)'
         when exists (select 1 from ACT_HI_ATTACHMENT a where a.CONTENT_ID_ = h.bytearray_id)        then 'task attachment (check)'
         else 'other / orphaned (check)'
       end as owner
  from legacy_bytearray_hits h;

-- L2a overview by owner
select owner, count(*) as byte_arrays
  from legacy_bytearray_owners
 group by owner
 order by owner;

-- L2b runtime variables whose bytes contain renamed classes (convert or drain before the cut-over, D18)
select v.ID_ as variable_id, v.NAME_ as variable_name, v.TYPE_ as var_type, v.TEXT2_ as object_type_name,
       v.PROC_INST_ID_ as process_instance_id, pd.KEY_ as process_definition_key,
       o.matched_patterns,
       substring(encode(b.BYTES_, 'escape')
                 from 'org[./]camunda[./](?:bpm|spin|connect|commons|templateengines)[A-Za-z0-9_./$]*') as class_hint
  from legacy_bytearray_owners o
  join ACT_RU_VARIABLE v on v.BYTEARRAY_ID_ = o.bytearray_id
  join ACT_GE_BYTEARRAY b on b.ID_ = o.bytearray_id
  left join ACT_RE_PROCDEF pd on pd.ID_ = v.PROC_DEF_ID_
 order by pd.KEY_, v.PROC_INST_ID_, v.NAME_;

-- -----------------------------------------------------------------------------------------------------
-- L3 Deployed resources that reference renamed classes. The engine never rewrites deployed resources:
--    fixing the file in Git only helps NEW versions. kind = model (bpmn/dmn/cmmn), script, form, other.
-- -----------------------------------------------------------------------------------------------------
create temporary table legacy_resource_hits on commit drop as
select b.ID_ as bytearray_id,
       b.DEPLOYMENT_ID_ as deployment_id,
       b.NAME_ as resource_name,
       case
         when lower(b.NAME_) like '%.bpmn' or lower(b.NAME_) like '%.bpmn20.xml' then 'bpmn'
         when lower(b.NAME_) like '%.dmn'  or lower(b.NAME_) like '%.dmn11.xml'  then 'dmn'
         when lower(b.NAME_) like '%.cmmn' or lower(b.NAME_) like '%.cmmn11.xml' then 'cmmn'
         when lower(b.NAME_) like '%.form' then 'form'
         when lower(b.NAME_) ~ '\.(groovy|js|py|rb|kts?|java|mvel|juel|ftl|vm)$' then 'script'
         else 'other'
       end as kind,
       string_agg(p.label, ', ' order by p.label) as matched_patterns
  from ACT_GE_BYTEARRAY b
  join legacy_patterns p on position(p.pattern in b.BYTES_) > 0
 where b.DEPLOYMENT_ID_ is not null
   and position(convert_to('camunda', 'UTF8') in b.BYTES_) > 0
 group by b.ID_, b.DEPLOYMENT_ID_, b.NAME_;

select h.deployment_id, d.NAME_ as deployment_name, d.DEPLOY_TIME_ as deployed_at, h.resource_name, h.kind,
       h.matched_patterns,
       substring(encode(b.BYTES_, 'escape')
                 from 'org[./]camunda[./](?:bpm|spin|connect|commons|templateengines)[A-Za-z0-9_./$]*') as first_reference
  from legacy_resource_hits h
  join ACT_RE_DEPLOYMENT d on d.ID_ = h.deployment_id
  join ACT_GE_BYTEARRAY b on b.ID_ = h.bytearray_id
 order by d.DEPLOY_TIME_ desc, h.resource_name;

-- -----------------------------------------------------------------------------------------------------
-- L4 Affected process definitions and their running work. A BPMN hit affects the definitions parsed from
--    that resource; a script/other hit (e.g. camunda:resource="deployment://enrich.js") affects every process
--    definition of the same deployment ("possibly"). running_instances > 0 => process instance migration to a
--    fixed version (fixed_version_available) or drain on Camunda before the cut-over.
-- -----------------------------------------------------------------------------------------------------
create temporary table legacy_affected_definitions on commit drop as
select pd.ID_ as process_definition_id, pd.KEY_ as process_definition_key, pd.VERSION_ as version,
       pd.DEPLOYMENT_ID_ as deployment_id, pd.RESOURCE_NAME_ as resource_name,
       string_agg(distinct case when h.kind = 'bpmn' then 'model: ' || h.matched_patterns
                                else 'possibly, via ' || h.kind || ' ' || h.resource_name end, '; ') as reason
  from ACT_RE_PROCDEF pd
  join legacy_resource_hits h
    on h.deployment_id = pd.DEPLOYMENT_ID_
   and ((h.kind = 'bpmn' and h.resource_name = pd.RESOURCE_NAME_) or h.kind in ('script', 'other'))
 group by pd.ID_, pd.KEY_, pd.VERSION_, pd.DEPLOYMENT_ID_, pd.RESOURCE_NAME_;

select a.process_definition_key, a.version, a.process_definition_id, a.deployment_id, a.reason,
       (select count(*) from ACT_RU_EXECUTION e
         where e.PROC_DEF_ID_ = a.process_definition_id and e.ID_ = e.PROC_INST_ID_)                     as running_instances,
       (select count(*) from ACT_RU_JOB j
         where j.PROCESS_DEF_ID_ = a.process_definition_id and j.RETRIES_ > 0)                          as active_jobs,
       (select count(*) from ACT_RU_JOB j
         where j.PROCESS_DEF_ID_ = a.process_definition_id and j.RETRIES_ = 0)                          as failed_jobs,
       (select count(*) from ACT_RU_TASK t where t.PROC_DEF_ID_ = a.process_definition_id)              as open_user_tasks,
       (select count(*) from ACT_RU_EXT_TASK x where x.PROC_DEF_ID_ = a.process_definition_id)          as external_tasks,
       (select count(*) from ACT_RU_INCIDENT i where i.PROC_DEF_ID_ = a.process_definition_id)          as open_incidents,
       (select max(n.VERSION_) from ACT_RE_PROCDEF n
         where n.KEY_ = a.process_definition_key
           and coalesce(n.TENANT_ID_, '') = coalesce(pd.TENANT_ID_, '')
           and n.VERSION_ > a.version
           and not exists (select 1 from legacy_affected_definitions z where z.process_definition_id = n.ID_)) as fixed_version_available
  from legacy_affected_definitions a
  join ACT_RE_PROCDEF pd on pd.ID_ = a.process_definition_id
 order by a.process_definition_key, a.version;

-- -----------------------------------------------------------------------------------------------------
-- L5 Legacy Activiti namespace (Camunda 7 still accepted it as fallback, Operaton does not): such definitions
--    fail to parse on Operaton - redeploy converted models and migrate the running instances.
-- -----------------------------------------------------------------------------------------------------
select b.DEPLOYMENT_ID_ as deployment_id, b.NAME_ as resource_name, pd.ID_ as process_definition_id,
       pd.KEY_ as process_definition_key, pd.VERSION_ as version,
       (select count(*) from ACT_RU_EXECUTION e where e.PROC_DEF_ID_ = pd.ID_ and e.ID_ = e.PROC_INST_ID_) as running_instances
  from ACT_GE_BYTEARRAY b
  left join ACT_RE_PROCDEF pd on pd.DEPLOYMENT_ID_ = b.DEPLOYMENT_ID_ and pd.RESOURCE_NAME_ = b.NAME_
 where b.DEPLOYMENT_ID_ is not null
   and position(convert_to('http://activiti.org/bpmn', 'UTF8') in b.BYTES_) > 0
 order by b.DEPLOYMENT_ID_, b.NAME_;

-- -----------------------------------------------------------------------------------------------------
-- L6 camunda-forms: form keys (information, decision D4). The engine resolves both camunda-forms: and
--    operaton-forms:, the Operaton Tasklist (according to its source) only renders operaton-forms:.
--    Rollback-safe fix: formRef, deployed on Camunda 7.24 before the cut-over (operaton-forms: versions with
--    open tasks block a rollback, decision D15). webapps-neo (2.2 preview) renders form-js only via formRef.
-- -----------------------------------------------------------------------------------------------------
select b.DEPLOYMENT_ID_ as deployment_id, b.NAME_ as resource_name, pd.KEY_ as process_definition_key,
       pd.VERSION_ as version,
       (select count(*) from ACT_RU_TASK t where t.PROC_DEF_ID_ = pd.ID_) as open_user_tasks
  from ACT_GE_BYTEARRAY b
  left join ACT_RE_PROCDEF pd on pd.DEPLOYMENT_ID_ = b.DEPLOYMENT_ID_ and pd.RESOURCE_NAME_ = b.NAME_
 where b.DEPLOYMENT_ID_ is not null
   and position(convert_to('camunda-forms:', 'UTF8') in b.BYTES_) > 0
 order by pd.KEY_, pd.VERSION_;

-- -----------------------------------------------------------------------------------------------------
-- L7 Decision and case definitions parsed from resources with hits (information).
-- -----------------------------------------------------------------------------------------------------
select 'decision' as definition_type, dd.KEY_ as definition_key, dd.VERSION_ as version, dd.ID_ as definition_id,
       h.resource_name, h.matched_patterns
  from ACT_RE_DECISION_DEF dd
  join legacy_resource_hits h on h.deployment_id = dd.DEPLOYMENT_ID_ and h.resource_name = dd.RESOURCE_NAME_
union all
select 'case', cd.KEY_, cd.VERSION_, cd.ID_, h.resource_name, h.matched_patterns
  from ACT_RE_CASE_DEF cd
  join legacy_resource_hits h on h.deployment_id = cd.DEPLOYMENT_ID_ and h.resource_name = cd.RESOURCE_NAME_
 order by 1, 2, 3;

-- -----------------------------------------------------------------------------------------------------
-- L8 Jobs and incidents: overview + consistency. Run it before and after the cut-over (and after the
--    emergency scripts): L8c, L8d and L8e should return no rows.
-- -----------------------------------------------------------------------------------------------------
-- L8a failed jobs by definition / activity / message (look for org.camunda, ClassNotFoundException,
--     "unable to resolve class" = legacy references hit at runtime)
select j.PROCESS_DEF_KEY_ as process_definition_key, j.FAILED_ACT_ID_ as failed_activity,
       left(j.EXCEPTION_MSG_, 160) as exception_message, count(*) as failed_jobs,
       case when j.EXCEPTION_MSG_ like '%org.camunda%' or j.EXCEPTION_MSG_ like '%org/camunda%'
              or j.EXCEPTION_MSG_ like '%ClassNotFound%' or j.EXCEPTION_MSG_ like '%unable to resolve class%'
            then 'LEGACY REFERENCE?' else '' end as hint
  from ACT_RU_JOB j
 where j.RETRIES_ = 0
 group by j.PROCESS_DEF_KEY_, j.FAILED_ACT_ID_, left(j.EXCEPTION_MSG_, 160), 5
 order by failed_jobs desc;

-- L8b open incidents by type and definition
select i.INCIDENT_TYPE_ as incident_type, pd.KEY_ as process_definition_key,
       count(*) as open_incidents,
       sum(case when i.ID_ = i.ROOT_CAUSE_INCIDENT_ID_ then 1 else 0 end) as root_cause_incidents
  from ACT_RU_INCIDENT i
  left join ACT_RE_PROCDEF pd on pd.ID_ = i.PROC_DEF_ID_
 group by i.INCIDENT_TYPE_, pd.KEY_
 order by open_incidents desc;

-- L8c jobs without retries but without failedJob incident (createIncidentOnFailedJobEnabled=false, or manual SQL)
select j.ID_ as job_id, j.PROCESS_DEF_KEY_ as process_definition_key, j.FAILED_ACT_ID_ as failed_activity,
       left(j.EXCEPTION_MSG_, 120) as exception_message
  from ACT_RU_JOB j
 where j.RETRIES_ = 0
   and not exists (select 1 from ACT_RU_INCIDENT i where i.INCIDENT_TYPE_ = 'failedJob' and i.CONFIGURATION_ = j.ID_)
 order by j.ID_;

-- L8d root failedJob incidents whose job is gone or has retries again (typical after "update ACT_RU_JOB set
--     RETRIES_ = 3" or setJobRetriesByJobDefinitionId: Cockpit shows an incident for a job that is retrying)
select i.ID_ as incident_id, i.CONFIGURATION_ as job_id, j.RETRIES_ as job_retries,
       case when j.ID_ is null then 'job gone' else 'job has retries again' end as state
  from ACT_RU_INCIDENT i
  left join ACT_RU_JOB j on j.ID_ = i.CONFIGURATION_
 where i.INCIDENT_TYPE_ = 'failedJob'
   and i.ID_ = i.ROOT_CAUSE_INCIDENT_ID_
   and (j.ID_ is null or j.RETRIES_ > 0)
 order by i.ID_;

-- L8e the same for external tasks
select i.ID_ as incident_id, i.CONFIGURATION_ as ext_task_id, e.RETRIES_ as ext_task_retries,
       case when e.ID_ is null then 'external task gone' else 'external task has retries again' end as state
  from ACT_RU_INCIDENT i
  left join ACT_RU_EXT_TASK e on e.ID_ = i.CONFIGURATION_
 where i.INCIDENT_TYPE_ = 'failedExternalTask'
   and i.ID_ = i.ROOT_CAUSE_INCIDENT_ID_
   and (e.ID_ is null or e.RETRIES_ is null or e.RETRIES_ > 0)
 order by i.ID_;

-- L8f external tasks without retries, by topic and error
select x.TOPIC_NAME_ as topic, left(x.ERROR_MSG_, 120) as error_message, count(*) as external_tasks
  from ACT_RU_EXT_TASK x
 where x.RETRIES_ is not null and x.RETRIES_ <= 0
 group by x.TOPIC_NAME_, left(x.ERROR_MSG_, 120)
 order by external_tasks desc;

-- -----------------------------------------------------------------------------------------------------
-- L9 Summary (one row). Blockers for the cut-over: runtime_typed_variables, runtime_variable_byte_hits,
--    running_instances_on_affected_definitions, activiti_namespace_definitions_running.
-- -----------------------------------------------------------------------------------------------------
select
  (select count(*) from legacy_typed_variables where source_table = 'ACT_RU_VARIABLE')                 as runtime_typed_variables,
  (select count(*) from legacy_typed_variables where source_table <> 'ACT_RU_VARIABLE')                as history_typed_variables,
  (select count(*) from legacy_bytearray_owners where owner like 'ACT_RU_VARIABLE%')                   as runtime_variable_byte_hits,
  (select count(*) from legacy_bytearray_owners where owner like 'ACT_HI_%')                           as history_variable_byte_hits,
  (select count(*) from legacy_bytearray_owners where owner like '%harmless%')                         as harmless_text_hits,
  (select count(*) from legacy_resource_hits)                                                          as deployed_resources_with_refs,
  (select count(*) from legacy_affected_definitions)                                                   as affected_process_definitions,
  (select count(*) from ACT_RU_EXECUTION e
    where e.ID_ = e.PROC_INST_ID_
      and e.PROC_DEF_ID_ in (select process_definition_id from legacy_affected_definitions))           as running_instances_on_affected_definitions,
  (select count(*) from ACT_RE_PROCDEF pd
    where exists (select 1 from ACT_GE_BYTEARRAY b
                   where b.DEPLOYMENT_ID_ = pd.DEPLOYMENT_ID_ and b.NAME_ = pd.RESOURCE_NAME_
                     and position(convert_to('http://activiti.org/bpmn', 'UTF8') in b.BYTES_) > 0)
      and exists (select 1 from ACT_RU_EXECUTION e where e.PROC_DEF_ID_ = pd.ID_))                     as activiti_namespace_definitions_running,
  (select count(*) from ACT_GE_BYTEARRAY b
    where b.DEPLOYMENT_ID_ is not null
      and position(convert_to('camunda-forms:', 'UTF8') in b.BYTES_) > 0)                              as resources_with_camunda_forms_keys,
  (select count(*) from ACT_RU_JOB where RETRIES_ = 0)                                                 as failed_jobs,
  (select count(*) from ACT_RU_INCIDENT)                                                               as open_incidents;

rollback;
