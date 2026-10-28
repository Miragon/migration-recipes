-- =====================================================================================================
-- Camunda 7 -> Operaton Migration Starter Pack
-- sql/postgresql/10-migrate-admin-group.sql  -  mirror `camunda-admin` to `operaton-admin` (decision D5)
-- =====================================================================================================
--
-- PURPOSE
--   Operaton hard-codes `operaton-admin` (Groups.OPERATON_ADMIN) as its admin group. On an existing Camunda
--   database nobody is a member of it, so after the switch:
--     * the webapps re-open the UNAUTHENTICATED "create initial admin user" setup page
--       (POST <webapp-path>/api/admin/setup/default/user/create returned 204 in the starter pack's trial; Camunda: 403),
--     * former Camunda admins lose admin-only operations (history cleanup, table counts, unlock user, ...),
--     * operaton.bpm.admin-user does NOT help: it skips users that already exist.
--   This script mirrors everything bound to `camunda-admin` onto `operaton-admin`, in ONE transaction:
--     S1 group `operaton-admin` (name "operaton BPM Administrators", type SYSTEM, exactly what Operaton's own
--        setup / admin-user code creates), only if the database identity has a `camunda-admin` group
--     S2 memberships of `camunda-admin`                           -> same users in `operaton-admin`
--     S3 authorizations HELD BY `camunda-admin` (GRANT/REVOKE)    -> same rows for `operaton-admin`
--        (the READ-on-own-group row is re-pointed to resource id `operaton-admin`)
--     S4 authorizations held by OTHER users/groups ON the `camunda-admin` group (resource GROUP /
--        GROUP_MEMBERSHIP)                                        -> same rows on resource `operaton-admin`
--     S5 tenant memberships of `camunda-admin`                    -> same tenants for `operaton-admin`
--     S6 verification (before/after table) and S7 an assertion that rolls everything back on a mismatch.
--   It never deletes or changes a `camunda-admin` row: Camunda 7.24 keeps working on this database during
--   the rollback window (decision D15). Cleanup comes later, see the commented section at the end.
--
-- PHASE
--   Cut-over (Phase 2): after all Camunda nodes are stopped and the backup is taken, BEFORE the first
--   Operaton node starts. Also safe earlier (rehearsal, or even while Camunda 7.24 still runs: Camunda
--   ignores `operaton-admin`). Re-run it right before the first start if admins changed in between.
--   Alternative: the Java plugin examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/
--   migration/AdminGroupMigrationPlugin.java (runs before the web server accepts requests).
--
-- IDEMPOTENT
--   Yes. Every insert is guarded by NOT EXISTS (respecting ACT_UNIQ_AUTH_GROUP / ACT_UNIQ_AUTH_USER /
--   ACT_UNIQ_TENANT_MEMB_GROUP). A second run inserts 0 rows.
--
-- PREREQUISITES
--   - BACKUP FIRST (it is a data change, even if small and reversible).
--   - Database-backed identity (ACT_ID_*). LDAP / Keycloak (read-only identity) and the OAuth2 starter (groups
--     come from the token, login required): the setup page is not exposed; rename or map the group in the IdP
--     or register AdministratorAuthorizationPlugin (docs/07). S3/S4 still copy the authorizations, which is
--     what you need after renaming the IdP group.
--   - Custom schema / table prefix: `set search_path to <schema>;` first.
--   - Webapp sessions cache authorizations: users have to log in again (or wait for the cache TTL).
--
-- DATABASE
--   PostgreSQL 13+ (gen_random_uuid() is built in since 13; Operaton requires 14+).
--   PostgreSQL 12 or older: replace gen_random_uuid()::text by md5(random()::text || clock_timestamp()::text)
--   (any unique varchar(64) is a valid ID_; the default Spring Boot id generator also writes UUIDs).
--   Tested with PGlite 0.5.8 (= PostgreSQL 18.3) on the Camunda 7.24.0 and Operaton 2.1.5 / 2.2.0-RC1 DDL,
--   twice in a row (second run: 0 rows inserted), see sql/test/.
--
-- RUN
--   psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/10-migrate-admin-group.sql
--   (The script contains BEGIN ... COMMIT itself: do not add --single-transaction.)
--   Dry run: replace the final COMMIT by ROLLBACK and read the S6 output.
--
-- OTHER DATABASES (not tested; adapt and test on a copy)
--   - UUID: Oracle rawtohex(sys_guid()), SQL Server cast(newid() as varchar(64)), MySQL/MariaDB uuid(),
--     H2 cast(random_uuid() as varchar(64)), DB2 hex(generate_unique()) - or concat('opadm-', a.ID_).
--   - INSERT ... SELECT ... WHERE NOT EXISTS without FROM: Oracle add "from dual", DB2 "from sysibm.sysdummy1".
--   - DO $$ ... $$ (S7) is PL/pgSQL: Oracle/DB2 anonymous block, SQL Server IF ... THROW; or drop S7 and
--     check the S6 output by hand.
--   - BEGIN/COMMIT: SQL Server "begin transaction", MySQL "start transaction".
--
-- ROLLBACK
--   Before Operaton starts: ROLLBACK instead of COMMIT, or restore the backup. After the commit, the new rows
--   are harmless for Camunda 7.24 (it ignores `operaton-admin`), so a rollback of the cut-over does not need
--   to remove them. To remove them anyway: the "UNDO" block at the end (commented).
--
-- DOCS
--   docs/07-identity-admin-group-and-security.md (decision D5, setup endpoint, LDAP/SSO variants)
--   docs/08-database-schema-data-and-sql-scripts.md, docs/01-migration-path-and-decisions.md#d5, sql/README.md
--
-- License: Apache-2.0. As of 2026-10-06 (Camunda 7.24.0 -> Operaton 2.1.5 / 2.2.x).
-- =====================================================================================================

begin;

-- Do not wait forever if something still holds locks on the identity tables.
set local lock_timeout = '10s';

-- S0 State before the change (for the change ticket)
select 'before'                                                                                     as moment,
       (select count(*) from ACT_ID_GROUP where ID_ = 'operaton-admin')                              as operaton_admin_group,
       (select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'camunda-admin')                    as camunda_admin_members,
       (select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin')                   as operaton_admin_members,
       (select count(*) from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'camunda-admin')                 as camunda_admin_authorizations,
       (select count(*) from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'operaton-admin')                as operaton_admin_authorizations;

-- -----------------------------------------------------------------------------------------------------
-- S1 Group. Same NAME_/TYPE_ as Operaton's SetupResource / CreateAdminUserConfiguration (v2.1.5).
--    Only for database-backed identity that actually has a camunda-admin group.
-- -----------------------------------------------------------------------------------------------------
insert into ACT_ID_GROUP (ID_, REV_, NAME_, TYPE_)
select 'operaton-admin', 1, 'operaton BPM Administrators', 'SYSTEM'
 where exists     (select 1 from ACT_ID_GROUP where ID_ = 'camunda-admin')
   and not exists (select 1 from ACT_ID_GROUP where ID_ = 'operaton-admin');

-- -----------------------------------------------------------------------------------------------------
-- S2 Memberships: every camunda-admin member also becomes an operaton-admin member.
--    (Closes the setup page as soon as at least one member exists.)
-- -----------------------------------------------------------------------------------------------------
insert into ACT_ID_MEMBERSHIP (USER_ID_, GROUP_ID_)
select m.USER_ID_, 'operaton-admin'
  from ACT_ID_MEMBERSHIP m
 where m.GROUP_ID_ = 'camunda-admin'
   and exists (select 1 from ACT_ID_GROUP where ID_ = 'operaton-admin')
   and not exists (select 1 from ACT_ID_MEMBERSHIP x
                    where x.USER_ID_ = m.USER_ID_ and x.GROUP_ID_ = 'operaton-admin');

-- -----------------------------------------------------------------------------------------------------
-- S3 Authorizations held by camunda-admin (typically GRANT ALL on '*' for all 22 resource types, plus
--    READ on the group itself, plus whatever you added: resource-specific GRANTs and REVOKEs).
--    Unique key ACT_UNIQ_AUTH_GROUP (TYPE_, GROUP_ID_, RESOURCE_TYPE_, RESOURCE_ID_) is respected.
--    Existing operaton-admin rows win (they are not overwritten).
-- -----------------------------------------------------------------------------------------------------
insert into ACT_RU_AUTHORIZATION
       (ID_, REV_, TYPE_, GROUP_ID_, USER_ID_, RESOURCE_TYPE_, RESOURCE_ID_, PERMS_, REMOVAL_TIME_, ROOT_PROC_INST_ID_)
select gen_random_uuid()::text, 1, a.TYPE_, 'operaton-admin', null, a.RESOURCE_TYPE_,
       case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
            then 'operaton-admin' else a.RESOURCE_ID_ end,
       a.PERMS_, a.REMOVAL_TIME_, a.ROOT_PROC_INST_ID_
  from ACT_RU_AUTHORIZATION a
 where a.GROUP_ID_ = 'camunda-admin'
   and not exists (select 1 from ACT_RU_AUTHORIZATION x
                    where x.TYPE_ = a.TYPE_
                      and x.GROUP_ID_ = 'operaton-admin'
                      and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                      and x.RESOURCE_ID_ = case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
                                                then 'operaton-admin' else a.RESOURCE_ID_ end);

-- -----------------------------------------------------------------------------------------------------
-- S4 Authorizations of OTHER principals on the camunda-admin group as a resource
--    (RESOURCE_TYPE_ 2 = GROUP, 3 = GROUP_MEMBERSHIP), e.g. "auditor may READ group camunda-admin".
--    Covers user rows (ACT_UNIQ_AUTH_USER), group rows (ACT_UNIQ_AUTH_GROUP) and global rows (USER_ID_ '*').
-- -----------------------------------------------------------------------------------------------------
insert into ACT_RU_AUTHORIZATION
       (ID_, REV_, TYPE_, GROUP_ID_, USER_ID_, RESOURCE_TYPE_, RESOURCE_ID_, PERMS_, REMOVAL_TIME_, ROOT_PROC_INST_ID_)
select gen_random_uuid()::text, 1, a.TYPE_, a.GROUP_ID_, a.USER_ID_, a.RESOURCE_TYPE_, 'operaton-admin',
       a.PERMS_, a.REMOVAL_TIME_, a.ROOT_PROC_INST_ID_
  from ACT_RU_AUTHORIZATION a
 where a.RESOURCE_TYPE_ in (2, 3)
   and a.RESOURCE_ID_ = 'camunda-admin'
   and (a.GROUP_ID_ is null or a.GROUP_ID_ <> 'camunda-admin')
   and not exists (select 1 from ACT_RU_AUTHORIZATION x
                    where x.TYPE_ = a.TYPE_
                      and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                      and x.RESOURCE_ID_ = 'operaton-admin'
                      and ((a.USER_ID_  is not null and x.USER_ID_  = a.USER_ID_)
                        or (a.GROUP_ID_ is not null and x.GROUP_ID_ = a.GROUP_ID_)));

-- -----------------------------------------------------------------------------------------------------
-- S5 Tenant memberships (only relevant with multi-tenancy; admins bypass tenant checks anyway, but the
--    mirror keeps queries such as "groups of tenant X" consistent).
-- -----------------------------------------------------------------------------------------------------
insert into ACT_ID_TENANT_MEMBER (ID_, TENANT_ID_, USER_ID_, GROUP_ID_)
select gen_random_uuid()::text, t.TENANT_ID_, null, 'operaton-admin'
  from ACT_ID_TENANT_MEMBER t
 where t.GROUP_ID_ = 'camunda-admin'
   and exists (select 1 from ACT_ID_GROUP where ID_ = 'operaton-admin')
   and not exists (select 1 from ACT_ID_TENANT_MEMBER x
                    where x.TENANT_ID_ = t.TENANT_ID_ and x.GROUP_ID_ = 'operaton-admin');

-- -----------------------------------------------------------------------------------------------------
-- S6 Verification: both groups side by side, "missing_*" must be 0.
-- -----------------------------------------------------------------------------------------------------
select g.group_id,
       coalesce(grp.NAME_, '(no group row)')                                                    as group_name,
       (select count(*) from ACT_ID_MEMBERSHIP m where m.GROUP_ID_ = g.group_id)                 as members,
       (select count(*) from ACT_RU_AUTHORIZATION a where a.GROUP_ID_ = g.group_id)              as authorizations_held,
       (select count(*) from ACT_RU_AUTHORIZATION a
         where a.RESOURCE_TYPE_ in (2, 3) and a.RESOURCE_ID_ = g.group_id)                       as authorizations_on_group,
       (select count(*) from ACT_ID_TENANT_MEMBER t where t.GROUP_ID_ = g.group_id)              as tenant_memberships
  from (select 'camunda-admin' as group_id union all select 'operaton-admin') g
  left join ACT_ID_GROUP grp on grp.ID_ = g.group_id
 order by g.group_id;

select 'after'                                                                                   as moment,
       (select count(*) from ACT_ID_MEMBERSHIP m
         where m.GROUP_ID_ = 'camunda-admin'
           and not exists (select 1 from ACT_ID_MEMBERSHIP x
                            where x.USER_ID_ = m.USER_ID_ and x.GROUP_ID_ = 'operaton-admin'))   as missing_members,
       (select count(*) from ACT_RU_AUTHORIZATION a
         where a.GROUP_ID_ = 'camunda-admin'
           and not exists (select 1 from ACT_RU_AUTHORIZATION x
                            where x.TYPE_ = a.TYPE_ and x.GROUP_ID_ = 'operaton-admin'
                              and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                              and x.RESOURCE_ID_ = case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
                                                        then 'operaton-admin' else a.RESOURCE_ID_ end)) as missing_authorizations,
       (select count(*) from ACT_ID_TENANT_MEMBER t
         where t.GROUP_ID_ = 'camunda-admin'
           and not exists (select 1 from ACT_ID_TENANT_MEMBER x
                            where x.TENANT_ID_ = t.TENANT_ID_ and x.GROUP_ID_ = 'operaton-admin'))  as missing_tenant_memberships,
       (select string_agg(m.USER_ID_, ', ' order by m.USER_ID_)
          from ACT_ID_MEMBERSHIP m where m.GROUP_ID_ = 'operaton-admin')                         as operaton_admin_members;

-- -----------------------------------------------------------------------------------------------------
-- S7 Assertion: on any mismatch the whole transaction is aborted (psql -v ON_ERROR_STOP=1 exits with 3,
--    nothing is committed). An empty operaton-admin group only produces a notice: 00-preflight-checks.sql
--    reports it as NO_GO, because the setup page would stay open.
-- -----------------------------------------------------------------------------------------------------
do $$
declare
  v_missing_members int;
  v_missing_auth    int;
  v_members         int;
begin
  select count(*) into v_missing_members
    from ACT_ID_MEMBERSHIP m
   where m.GROUP_ID_ = 'camunda-admin'
     and not exists (select 1 from ACT_ID_MEMBERSHIP x where x.USER_ID_ = m.USER_ID_ and x.GROUP_ID_ = 'operaton-admin');

  select count(*) into v_missing_auth
    from ACT_RU_AUTHORIZATION a
   where a.GROUP_ID_ = 'camunda-admin'
     and not exists (select 1 from ACT_RU_AUTHORIZATION x
                      where x.TYPE_ = a.TYPE_ and x.GROUP_ID_ = 'operaton-admin' and x.RESOURCE_TYPE_ = a.RESOURCE_TYPE_
                        and x.RESOURCE_ID_ = case when a.RESOURCE_ID_ = 'camunda-admin' and a.RESOURCE_TYPE_ in (2, 3)
                                                  then 'operaton-admin' else a.RESOURCE_ID_ end);

  select count(*) into v_members from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin';

  if v_missing_members > 0 or v_missing_auth > 0 then
    raise exception 'admin group migration incomplete: % member(s), % authorization(s) not mirrored - rolled back',
      v_missing_members, v_missing_auth;
  end if;

  if not exists (select 1 from ACT_ID_GROUP where ID_ = 'camunda-admin') then
    raise notice 'No camunda-admin group in ACT_ID_GROUP: nothing to mirror (read-only identity provider? see docs/07).';
  elsif v_members = 0 then
    raise notice 'ACTION REQUIRED: operaton-admin has no members (camunda-admin had none). Add an admin before the first start, otherwise the webapp setup page is open.';
  else
    raise notice 'OK: operaton-admin has % member(s); all camunda-admin memberships and authorizations are mirrored.', v_members;
  end if;
end
$$;

commit;   -- dry run: replace by ROLLBACK

-- =====================================================================================================
-- LATER: CLEANUP AFTER THE ROLLBACK WINDOW (do NOT run during the cut-over)
-- =====================================================================================================
-- Only after the point of no return (decision D15), when nobody needs Camunda 7.24 on this database any more.
-- 1) Check that nothing else still uses the group (candidate groups, starter groups, identity links):
--
--   select 'ACT_RU_IDENTITYLINK' as tbl, count(*) from ACT_RU_IDENTITYLINK where GROUP_ID_ = 'camunda-admin'
--   union all
--   select 'ACT_RU_AUTHORIZATION (held)', count(*) from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'camunda-admin'
--   union all
--   select 'ACT_ID_MEMBERSHIP', count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'camunda-admin';
--
-- 2) Preferred: delete through the API, which also writes the operation log:
--      identityService.deleteGroup("camunda-admin")  /  DELETE /engine-rest/group/camunda-admin
--    It removes the group, its memberships and tenant memberships. Authorizations ON the group are removed
--    only for resource type GROUP and only when authorization is enabled (DbIdentityServiceProvider#deleteGroup,
--    v2.1.5); the authorizations HELD BY the group (GRANT ALL on '*' ...) are NOT removed. Delete those too
--    (stale ALL grants are a latent risk if a group with that id is ever recreated):
--      GET /engine-rest/authorization?groupIdIn=camunda-admin, then DELETE /engine-rest/authorization/{id}
--
-- 3) SQL equivalent (application stopped, backup taken):
--
--   begin;
--   delete from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'camunda-admin';
--   delete from ACT_RU_AUTHORIZATION where RESOURCE_TYPE_ in (2, 3) and RESOURCE_ID_ = 'camunda-admin';
--   delete from ACT_ID_TENANT_MEMBER where GROUP_ID_ = 'camunda-admin';
--   delete from ACT_ID_MEMBERSHIP    where GROUP_ID_ = 'camunda-admin';
--   delete from ACT_ID_GROUP         where ID_      = 'camunda-admin';
--   commit;
--
-- 4) Remove "camunda-admin" from groupResourceWhitelistPattern / admin-groups if you configured it.
--
-- =====================================================================================================
-- UNDO (only if you really want to remove the mirror again; Camunda 7.24 does not need this)
-- =====================================================================================================
--   begin;
--   delete from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'operaton-admin';
--   delete from ACT_RU_AUTHORIZATION where RESOURCE_TYPE_ in (2, 3) and RESOURCE_ID_ = 'operaton-admin';
--   delete from ACT_ID_TENANT_MEMBER where GROUP_ID_ = 'operaton-admin';
--   delete from ACT_ID_MEMBERSHIP    where GROUP_ID_ = 'operaton-admin';
--   delete from ACT_ID_GROUP         where ID_      = 'operaton-admin';
--   commit;
-- Careful: this also removes operaton-admin rows that Operaton created itself after the cut-over.
