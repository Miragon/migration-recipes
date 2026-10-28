-- =====================================================================================================
-- Camunda 7 -> Operaton Migration Starter Pack
-- sql/postgresql/00-preflight-checks.sql  -  cut-over pre-flight checks with a GO / NO-GO verdict
-- =====================================================================================================
--
-- PURPOSE
--   Answers "may the first Operaton node start on this database now?" before the cut-over:
--     P01 schema level (ACT_GE_SCHEMA_LOG must end at 7.24.0 or a 7.24.N EE patch row; 7.25.0 once
--         the Operaton 2.2 scripts ran)
--     P02 engine properties (schema.version = 'fox', historyLevel, installation ids, legacy rows)
--     P03 admin group: camunda-admin vs. operaton-admin members and authorizations (decision D5)
--     P04 job locks held by engine nodes that are still running
--     P05 failed jobs / open incidents (baseline to compare after the cut-over)
--     P06 external tasks currently locked by workers
--     P07 deployments, definitions, running instances, batches
--     P08 schema-management tooling (Liquibase / Flyway tables present?)
--     P09 other database sessions (are the Camunda nodes really gone?)
--     P10 quick count of variables typed with org.camunda.* classes (details: 20-find-legacy-references.sql)
--     P11 stored task filters with expressions (informational: Operaton has no 7.24.7-ee allow-list, D17)
--     P99 one-row summary: verdict GO | GO_WITH_WARNINGS | NO_GO, followed by a gate that raises an
--         error on NO_GO, so `psql -v ON_ERROR_STOP=1` exits with code 3 (usable in a pipeline).
--
-- PHASE
--   Phase 0 (rehearsal on a production copy), Phase 1 (freeze baseline) and Phase 2 (cut-over, after all
--   Camunda nodes are stopped, after the backup and after 10-migrate-admin-group.sql).
--   See checklists/cutover-runbook.md. Running it after the first Operaton start is fine too
--   (P02 then shows the operaton.installation.id row).
--
-- MODE
--   Read-only for all ACT_* tables. The script creates one TEMPORARY view inside a transaction that is
--   ROLLED BACK at the end. Idempotent: run it as often as you like.
--
-- PREREQUISITES
--   - A database user that can read the ACT_* tables (the application user is fine).
--   - Custom schema or table prefix (operaton.bpm.database.schema-name / table-prefix)? Run
--     `set search_path to <schema>;` first, or prefix the table names.
--   - P09 needs no extra rights, but only superusers / pg_read_all_stats members see other users' details.
--
-- DATABASE
--   PostgreSQL 13+ (Operaton itself requires 14+). Tested with PGlite 0.5.8 (= PostgreSQL 18.3) on the
--   real Camunda 7.24.0, Operaton 2.1.5 and Operaton 2.2.0-RC1 PostgreSQL DDL plus seed data, see sql/test/.
--
-- RUN
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/00-preflight-checks.sql
--   (The script manages its own transaction: do not add --single-transaction.)
--   Exit code 0 = GO or GO_WITH_WARNINGS, exit code 3 = NO_GO (the gate statement raised an error).
--   Only want the report? Delete or comment out the gate block "P99b".
--
-- OTHER DATABASES (not tested; adapt and test on a copy)
--   - All queries except P08/P09 and the expressions column of P11 are plain SQL. Temporary view -> replace
--     by a CTE that you repeat.
--   - `x ~ 're'` (P99) is a PostgreSQL regular expression: Oracle / MySQL 8 `regexp_like(x, 're')`.
--     P11 `regexp_matches`: drop the expressions column and read QUERY_ instead.
--   - cast(ID_ as integer): Oracle `to_number(ID_)`, SQL Server `cast(ID_ as int)`, MySQL `cast(ID_ as signed)`.
--   - `limit n` -> Oracle 12c+/DB2/SQL Server 2012+: `fetch first n rows only` (SQL Server also `top n`).
--   - CURRENT_TIMESTAMP works everywhere; Oracle uses SYSTIMESTAMP for timestamp precision.
--   - P08: `information_schema.tables` exists on PostgreSQL, SQL Server, MySQL/MariaDB, H2;
--     Oracle: `all_tables`, DB2: `syscat.tables`.  P09: Oracle `v$session`, SQL Server `sys.dm_exec_sessions`,
--     MySQL `information_schema.processlist`.
--   - Gate block (DO $$ ... $$) is PL/pgSQL: Oracle/DB2 use an anonymous PL/SQL block, SQL Server `THROW`,
--     or simply evaluate the "verdict" column in your pipeline.
--
-- ROLLBACK
--   Nothing to roll back.
--
-- DOCS
--   docs/08-database-schema-data-and-sql-scripts.md (schema, persisted data, this toolkit)
--   docs/07-identity-admin-group-and-security.md   (why the admin group is a NO-GO, decision D5)
--   docs/11-cutover-rollback-and-operations.md     (where this runs in the cut-over), sql/README.md
--
-- License: Apache-2.0. As of 2026-10-11 (Camunda 7.24.0 / 7.24.N-ee -> Operaton 2.1.5 / 2.2.x).
-- =====================================================================================================

begin;

-- -----------------------------------------------------------------------------------------------------
-- P01 Schema level. The engine never reads ACT_GE_SCHEMA_LOG, so this is the only place that tells you
--     whether the database really is on 7.24. The first row (highest ID_) decides. OK are:
--       7.24.0  the Camunda 7.24 create script (ID_ 0) or upgrade script 7.23 -> 7.24 (ID_ 1300);
--       7.24.N  a Camunda 7.24 EE patch row (ID_ 1301-1399). Patch levels do not change the schema
--               ("Between patch levels, the structure of the database schema does not change"); Camunda ships
--               a patch script, which adds such a row, only for a bug in the schema itself. None is known for
--               7.24.x, but a database that ran one has the 7.24 schema and must not get a false NO-GO;
--       7.25.0  the Operaton 2.2 script postgres_engine_7.24_to_7.25.sql (ID_ 1400), which adds only this row.
--     Anything else => NO-GO (D1: ship Camunda 7.24 first). A 7.23 database lacks no DDL, only the 7.24.0
--     marker row (the 7.23 -> 7.24 upgrade script contains nothing else). A 7.22 (or older) database lacks
--     ACT_RU_EXECUTION.PROC_DEF_KEY_ and ACT_HI_COMMENT.REV_ (7.22 -> 7.23 upgrade): Operaton starts, then
--     fails at runtime on the missing columns.
-- -----------------------------------------------------------------------------------------------------
select ID_        as schema_log_id,
       VERSION_   as schema_version,
       TIMESTAMP_ as applied_at
  from ACT_GE_SCHEMA_LOG
 order by cast(ID_ as integer) desc;

-- -----------------------------------------------------------------------------------------------------
-- P02 Engine properties. schema.version must be 'fox' (the only value checked at startup with
--     operaton.bpm.database.schema-update=false). historyLevel must match operaton.bpm.history-level
--     (the Operaton Spring Boot default is "full"); a mismatch stops the engine at startup.
-- -----------------------------------------------------------------------------------------------------
select p.NAME_  as property,
       p.VALUE_ as value,
       case
         when p.NAME_ = 'schema.version' and p.VALUE_ = 'fox'
           then 'OK (compared with ProcessEngine.VERSION = fox at startup)'
         when p.NAME_ = 'schema.version'
           then 'NO-GO: expected fox'
         when p.NAME_ = 'historyLevel'
           then 'history level ' || case p.VALUE_ when '0' then 'none' when '1' then 'activity'
                                                  when '2' then 'audit' when '3' then 'full'
                                                  else 'custom (' || p.VALUE_ || ')' end
                || ': set operaton.bpm.history-level to the same value'
         when p.NAME_ = 'camunda.installation.id'
           then 'legacy row, ignored by Operaton; keep it until the rollback window closes'
         when p.NAME_ = 'operaton.installation.id'
           then 'Operaton has already started on this database'
         when p.NAME_ in ('camunda.telemetry.enabled', 'telemetry.lock')
           then 'legacy telemetry row, ignored by Operaton; keep it until the rollback window closes'
         when p.NAME_ like '%lock'
           then 'engine lock row, shared by Camunda and Operaton: never delete'
         when p.NAME_ = 'next.dbid'
           then 'block counter of the numeric id generator (unused with the default UUID generator)'
         else ''
       end as note
  from ACT_GE_PROPERTY p
 order by p.NAME_;

-- -----------------------------------------------------------------------------------------------------
-- P03 Admin group (decision D5). Operaton only treats `operaton-admin` as admin group. If the database
--     identity has users but nobody is in operaton-admin, the webapps re-open the unauthenticated
--     "create initial admin user" setup page. Fix: 10-migrate-admin-group.sql BEFORE the first start.
--     LDAP / SSO (read-only identity): ACT_ID_* is usually empty; handle the group in the IdP instead.
-- -----------------------------------------------------------------------------------------------------
select g.group_id,
       coalesce(grp.NAME_, '(group row missing)')                                       as group_name,
       (select count(*) from ACT_ID_MEMBERSHIP m where m.GROUP_ID_ = g.group_id)          as members,
       (select count(*) from ACT_RU_AUTHORIZATION a where a.GROUP_ID_ = g.group_id)       as authorizations_held,
       (select count(*) from ACT_RU_AUTHORIZATION a
         where a.RESOURCE_TYPE_ in (2, 3) and a.RESOURCE_ID_ = g.group_id)                as authorizations_on_group
  from (select 'camunda-admin' as group_id union all select 'operaton-admin') g
  left join ACT_ID_GROUP grp on grp.ID_ = g.group_id
 order by g.group_id;

-- P03b camunda-admin members that are NOT yet in operaton-admin (expect: no rows)
select m.USER_ID_ as user_missing_in_operaton_admin
  from ACT_ID_MEMBERSHIP m
 where m.GROUP_ID_ = 'camunda-admin'
   and not exists (select 1 from ACT_ID_MEMBERSHIP x
                    where x.USER_ID_ = m.USER_ID_ and x.GROUP_ID_ = 'operaton-admin')
 order by m.USER_ID_;

-- P03c camunda-admin authorizations without an operaton-admin mirror (expect: no rows)
select a.TYPE_ as auth_type, a.RESOURCE_TYPE_ as resource_type, a.RESOURCE_ID_ as resource_id, a.PERMS_ as perms
  from ACT_RU_AUTHORIZATION a
 where a.GROUP_ID_ = 'camunda-admin'
   and not exists (select 1 from ACT_RU_AUTHORIZATION x
                    where x.GROUP_ID_ = 'operaton-admin'
                      and x.TYPE_ = a.TYPE_
                      and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                      and x.RESOURCE_ID_ = case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
                                                then 'operaton-admin' else a.RESOURCE_ID_ end)
 order by a.RESOURCE_TYPE_, a.RESOURCE_ID_;

-- -----------------------------------------------------------------------------------------------------
-- P04 Job locks. Acquisition needs (LOCK_OWNER_ is null or LOCK_EXP_TIME_ < now). A lock that has not
--     expired means a node acquired the job recently: is a Camunda node still running? Wait at least
--     lockTimeInMillis (default 5 min) after the last node stopped. Expect locked_now = 0.
--     inconsistent_locks = owner set but no expiry: never acquired again until unlocked (setJobRetries does).
-- -----------------------------------------------------------------------------------------------------
select LOCK_OWNER_                                                              as lock_owner,
       count(*)                                                                 as locked_jobs,
       sum(case when LOCK_EXP_TIME_ > CURRENT_TIMESTAMP then 1 else 0 end)      as locked_now,
       sum(case when LOCK_EXP_TIME_ is null then 1 else 0 end)                  as inconsistent_locks,
       max(LOCK_EXP_TIME_)                                                      as latest_lock_expiry
  from ACT_RU_JOB
 where LOCK_OWNER_ is not null
 group by LOCK_OWNER_
 order by locked_now desc, lock_owner;

-- -----------------------------------------------------------------------------------------------------
-- P05 Failed jobs and open incidents: the baseline. Store this output; compare it after the cut-over.
-- -----------------------------------------------------------------------------------------------------
select count(*)                                                                  as jobs_total,
       sum(case when RETRIES_ = 0 then 1 else 0 end)                             as jobs_without_retries,
       sum(case when SUSPENSION_STATE_ = 2 then 1 else 0 end)                    as jobs_suspended,
       sum(case when RETRIES_ > 0 and SUSPENSION_STATE_ = 1
                 and (DUEDATE_ is null or DUEDATE_ <= CURRENT_TIMESTAMP) then 1 else 0 end) as jobs_due_now,
       sum(case when TYPE_ = 'timer' then 1 else 0 end)                          as timer_jobs
  from ACT_RU_JOB;

select INCIDENT_TYPE_                                                    as incident_type,
       count(*)                                                          as open_incidents,
       sum(case when ID_ = ROOT_CAUSE_INCIDENT_ID_ then 1 else 0 end)    as root_cause_incidents
  from ACT_RU_INCIDENT
 group by INCIDENT_TYPE_
 order by INCIDENT_TYPE_;

-- -----------------------------------------------------------------------------------------------------
-- P06 External tasks. Locked tasks belong to workers that are still running; they keep working against
--     the same REST API after the cut-over, but pause or inform them if their retry budget is small.
-- -----------------------------------------------------------------------------------------------------
select TOPIC_NAME_                                                                as topic,
       count(*)                                                                   as external_tasks,
       sum(case when LOCK_EXP_TIME_ > CURRENT_TIMESTAMP then 1 else 0 end)        as locked_now,
       sum(case when RETRIES_ is not null and RETRIES_ <= 0 then 1 else 0 end)    as without_retries,
       string_agg(distinct case when LOCK_EXP_TIME_ > CURRENT_TIMESTAMP then WORKER_ID_ end, ', ') as active_workers
  from ACT_RU_EXT_TASK
 group by TOPIC_NAME_
 order by TOPIC_NAME_;

-- -----------------------------------------------------------------------------------------------------
-- P07 Deployments, definitions, running work. With unchanged BPMN/DMN resources and duplicate filtering,
--     the first Operaton start should NOT create new deployments: compare deployments/last_deployment
--     after the start. Running batches should be finished (or paused) before the cut-over.
-- -----------------------------------------------------------------------------------------------------
select (select count(*) from ACT_RE_DEPLOYMENT)                              as deployments,
       (select max(DEPLOY_TIME_) from ACT_RE_DEPLOYMENT)                     as last_deployment,
       (select count(*) from ACT_RE_PROCDEF)                                 as process_definitions,
       (select count(*) from ACT_RE_DECISION_DEF)                            as decision_definitions,
       (select count(*) from ACT_RE_CASE_DEF)                                as case_definitions,
       (select count(*) from ACT_RU_EXECUTION where ID_ = PROC_INST_ID_)     as running_process_instances,
       (select count(*) from ACT_RU_TASK)                                    as open_tasks,
       (select count(*) from ACT_RU_BATCH)                                   as running_batches;

select ID_ as deployment_id, NAME_ as deployment_name, SOURCE_ as source, DEPLOY_TIME_ as deployed_at
  from ACT_RE_DEPLOYMENT
 order by DEPLOY_TIME_ desc
 limit 10;

-- -----------------------------------------------------------------------------------------------------
-- P08 Schema-management tooling in the current search_path. Liquibase: Operaton ships
--     operaton-changelog.xml with other author/checksums -> apply the verified fix from docs/08 first.
--     Flyway: nothing to add up to Operaton 2.1.x; add the 7.24_to_7.25 script for 2.2+.
-- -----------------------------------------------------------------------------------------------------
select table_schema, table_name
  from information_schema.tables
 where lower(table_name) in ('databasechangelog', 'databasechangeloglock', 'flyway_schema_history')
   and table_schema = any (current_schemas(false))
 order by table_name;

-- -----------------------------------------------------------------------------------------------------
-- P09 Other sessions on this database (CP1 of the runbook: no sessions of the application user left).
-- -----------------------------------------------------------------------------------------------------
select usename          as db_user,
       application_name,
       client_addr,
       state,
       count(*)         as sessions
  from pg_stat_activity
 where datname = current_database()
   and pid <> pg_backend_pid()
 group by usename, application_name, client_addr, state
 order by sessions desc;

-- -----------------------------------------------------------------------------------------------------
-- P10 Runtime variables whose object type name points to a renamed package (org.camunda.feel is NOT
--     renamed and therefore excluded). Any hit needs a plan (decision D18): run
--     20-find-legacy-references.sql for the full picture (history, byte arrays, nested classes).
-- -----------------------------------------------------------------------------------------------------
select TYPE_ as serializer, TEXT2_ as object_type_name, count(*) as variables
  from ACT_RU_VARIABLE
 where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
    or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
    or TEXT2_ like '%org.camunda.templateengines.%'
 group by TYPE_, TEXT2_
 order by variables desc;

-- -----------------------------------------------------------------------------------------------------
-- P11 Stored task filters (Tasklist, REST /filter) whose query contains expressions. Informational only:
--     changes neither the verdict nor the warnings. The engine stores each expression criterion as a JSON
--     key "<criterion>Expression" in ACT_RU_FILTER.QUERY_ (JsonTaskQueryConverter, same format in Camunda
--     7.24 and Operaton), e.g. the Tasklist filter "My Tasks" {"taskAssigneeExpression":"${currentUser()}"};
--     or-queries are included. A variable called "fooExpression" is a value, not a key, and does not count.
--     Why it matters (decision D17): Camunda 7.24.7-ee added an allow-list for query expressions
--     (queryExpressionAllowListEnabled, on by default; security notice 157, expression injection via stored
--     filters). Operaton has no allow-list, only the all-or-nothing switch enable-expressions-in-stored-queries
--     (generic property, default true), so it evaluates any expression in a stored filter, as Camunda 7.24.6
--     and older did. Mitigation: set the switch to false; then listing or counting every filter below fails
--     with "Expressions are forbidden in stored queries". No rows = you can switch expressions off without
--     breaking a filter. Otherwise rewrite these filters without expressions, or keep the switch on and
--     restrict who may create and update filters (ACT_RU_AUTHORIZATION resource type 5 = Filter).
--     Not in the verdict: the first Operaton start does not depend on it, the filters keep working with the
--     default switch, and typical Tasklist filters such as "My Tasks" use ${currentUser()}, so a warning
--     would rarely clear. P99 repeats the count as filters_with_expressions.
--     The expressions column shows each value as stored (JSON-escaped). E'...' keeps the pattern valid even
--     with standard_conforming_strings = off.
-- -----------------------------------------------------------------------------------------------------
select f.ID_    as filter_id,
       f.NAME_  as filter_name,
       f.OWNER_ as filter_owner,
       (select string_agg(x.m[1] || ' = ' || x.m[2], '; ')
          from regexp_matches(f.QUERY_, E'"([A-Za-z]+)Expression":"((?:[^"\\\\]|\\\\.)*)"', 'g') as x(m)) as expressions
  from ACT_RU_FILTER f
 where f.QUERY_ like '%Expression":%'
 order by f.NAME_, f.ID_;

-- -----------------------------------------------------------------------------------------------------
-- P99 Summary: one row. verdict = NO_GO if any blocking reason exists, GO_WITH_WARNINGS if only
--     warnings exist, GO otherwise. filters_with_expressions (P11) is informational and never changes it.
-- -----------------------------------------------------------------------------------------------------
create temporary view starterpack_preflight as
with m as (
  select
    (select VERSION_ from ACT_GE_SCHEMA_LOG
      where cast(ID_ as integer) = (select max(cast(ID_ as integer)) from ACT_GE_SCHEMA_LOG))        as schema_log_version,
    (select VALUE_ from ACT_GE_PROPERTY where NAME_ = 'schema.version')                              as schema_version_property,
    (select VALUE_ from ACT_GE_PROPERTY where NAME_ = 'historyLevel')                                as history_level,
    (select count(*) from ACT_ID_USER)                                                               as db_users,
    (select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'camunda-admin')                       as camunda_admin_members,
    (select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin')                      as operaton_admin_members,
    (select count(*) from ACT_ID_MEMBERSHIP m
      where m.GROUP_ID_ = 'camunda-admin'
        and not exists (select 1 from ACT_ID_MEMBERSHIP x
                         where x.USER_ID_ = m.USER_ID_ and x.GROUP_ID_ = 'operaton-admin'))          as admins_not_mirrored,
    (select count(*) from ACT_RU_AUTHORIZATION a
      where a.GROUP_ID_ = 'camunda-admin'
        and not exists (select 1 from ACT_RU_AUTHORIZATION x
                         where x.GROUP_ID_ = 'operaton-admin' and x.TYPE_ = a.TYPE_
                           and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                           and x.RESOURCE_ID_ = case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
                                                     then 'operaton-admin' else a.RESOURCE_ID_ end)) as authorizations_not_mirrored,
    (select count(*) from ACT_RU_JOB
      where LOCK_OWNER_ is not null and LOCK_EXP_TIME_ > CURRENT_TIMESTAMP)                          as jobs_locked_now,
    (select count(*) from ACT_RU_JOB where LOCK_OWNER_ is not null and LOCK_EXP_TIME_ is null)       as jobs_inconsistent_lock,
    (select count(*) from ACT_RU_JOB where RETRIES_ = 0)                                             as jobs_without_retries,
    (select count(*) from ACT_RU_INCIDENT)                                                           as open_incidents,
    (select count(*) from ACT_RU_EXT_TASK where LOCK_EXP_TIME_ > CURRENT_TIMESTAMP)                  as external_tasks_locked_now,
    (select count(*) from ACT_RU_BATCH)                                                              as running_batches,
    (select count(*) from ACT_RU_VARIABLE
      where TEXT2_ like '%org.camunda.bpm.%'     or TEXT2_ like '%org.camunda.spin.%'
         or TEXT2_ like '%org.camunda.connect.%' or TEXT2_ like '%org.camunda.commons.%'
         or TEXT2_ like '%org.camunda.templateengines.%')                                            as legacy_typed_variables,
    (select count(*) from information_schema.tables
      where lower(table_name) = 'databasechangelog'
        and table_schema = any (current_schemas(false)))                                             as liquibase_tables,
    (select count(*) from ACT_GE_PROPERTY where NAME_ = 'operaton.installation.id')                  as operaton_started_before,
    (select count(*) from ACT_RU_FILTER where QUERY_ like '%Expression":%')                          as filters_with_expressions
),
r as (
  select m.*,
    concat_ws('; ',
      case when m.schema_log_version is null
             or not (m.schema_log_version ~ '^7[.]24[.][0-9]+$' or m.schema_log_version = '7.25.0')
           then 'schema log is ' || coalesce(m.schema_log_version, '(empty)')
                || ', expected 7.24.0 (or a 7.24.N patch row): upgrade to Camunda 7.24 first'
                || case when m.schema_log_version ~ '^7[.]23[.][0-9]+$'
                        then ' (7.23 lacks no DDL, only the 7.24.0 marker row, but skips the 7.24 changes)'
                        when m.schema_log_version ~ '^7[.](1[1-9]|2[0-2])[.]'
                        then ' (columns of later upgrade scripts are missing: Operaton would fail at runtime)'
                        else '' end end,
      case when m.schema_version_property is distinct from 'fox'
           then 'ACT_GE_PROPERTY schema.version is ' || coalesce(m.schema_version_property, '(missing)')
                || ', expected fox' end,
      case when m.db_users > 0 and m.operaton_admin_members = 0
           then 'nobody is in operaton-admin: the webapp setup page would let anyone create an admin'
                || ' (run 10-migrate-admin-group.sql)' end,
      case when m.admins_not_mirrored > 0 and m.operaton_admin_members > 0
           then m.admins_not_mirrored || ' camunda-admin member(s) not in operaton-admin'
                || ' (run 10-migrate-admin-group.sql)' end,
      case when m.jobs_locked_now > 0
           then m.jobs_locked_now || ' job(s) locked by a running engine node: stop all Camunda nodes and wait'
                || ' for the lock time (default 5 min)' end
    ) as no_go_reasons,
    concat_ws('; ',
      case when m.schema_log_version = '7.25.0'
           then 'schema log 7.25.0: fine for Operaton 2.2+, harmless for older engines' end,
      case when m.authorizations_not_mirrored > 0
           then m.authorizations_not_mirrored || ' camunda-admin authorization(s) without operaton-admin mirror'
                || ' (run 10-migrate-admin-group.sql)' end,
      case when m.history_level is null
           then 'no historyLevel row (engine never started on this database?)' end,
      case when m.jobs_inconsistent_lock > 0
           then m.jobs_inconsistent_lock || ' job(s) with lock owner but no lock expiry (never acquired)' end,
      case when m.jobs_without_retries > 0 or m.open_incidents > 0
           then m.jobs_without_retries || ' failed job(s), ' || m.open_incidents
                || ' open incident(s): keep P05 as baseline' end,
      case when m.external_tasks_locked_now > 0
           then m.external_tasks_locked_now || ' external task(s) locked by active workers' end,
      case when m.running_batches > 0
           then m.running_batches || ' running batch(es): let them finish before the cut-over' end,
      case when m.legacy_typed_variables > 0
           then m.legacy_typed_variables || ' runtime variable(s) typed with org.camunda.* classes'
                || ' (run 20-find-legacy-references.sql, decision D18)' end,
      case when m.liquibase_tables > 0
           then 'Liquibase-managed schema: apply the changelog fix from docs/08 before the first start' end,
      case when m.operaton_started_before > 0
           then 'operaton.installation.id exists: Operaton has started on this database before' end
    ) as warnings
  from m
)
select case when r.no_go_reasons <> '' then 'NO_GO'
            when r.warnings <> ''      then 'GO_WITH_WARNINGS'
            else 'GO' end                       as verdict,
       nullif(r.no_go_reasons, '')              as no_go_reasons,
       nullif(r.warnings, '')                   as warnings,
       r.schema_log_version,
       r.schema_version_property,
       r.history_level,
       r.camunda_admin_members,
       r.operaton_admin_members,
       r.admins_not_mirrored,
       r.authorizations_not_mirrored,
       r.jobs_locked_now,
       r.jobs_without_retries,
       r.open_incidents,
       r.external_tasks_locked_now,
       r.running_batches,
       r.legacy_typed_variables,
       r.filters_with_expressions
  from r;

select * from starterpack_preflight;

-- -----------------------------------------------------------------------------------------------------
-- P99b Gate: raises an error on NO_GO (psql -v ON_ERROR_STOP=1 then exits with code 3).
--      Comment out this block if you only want the report.
-- -----------------------------------------------------------------------------------------------------
do $$
declare
  v_verdict text;
  v_reasons text;
begin
  select verdict, no_go_reasons into v_verdict, v_reasons from starterpack_preflight;
  if v_verdict = 'NO_GO' then
    raise exception 'PREFLIGHT NO_GO: %', v_reasons;
  end if;
  raise notice 'PREFLIGHT %', v_verdict;
end
$$;

rollback;
