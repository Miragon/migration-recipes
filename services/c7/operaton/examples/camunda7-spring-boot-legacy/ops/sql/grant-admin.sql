-- =============================================================================================
-- INTENTIONALLY NAIVE LEGACY EXAMPLE - analysed in the Camunda 7 -> Operaton migration guide.
-- Do NOT run this in production. It is the kind of script found in many ops repositories.
--
-- Problems: bypasses IdentityService (no validation, no operation log), assumes the group exists.
--
-- MIGRATION HOTSPOT: the admin group id is DATA. Camunda's admin group is 'camunda-admin',
-- Operaton's is 'operaton-admin' (Groups.OPERATON_ADMIN). After the migration this script
-- still runs fine but grants nothing useful, and existing memberships in ACT_ID_MEMBERSHIP /
-- authorizations in ACT_RU_AUTHORIZATION still reference 'camunda-admin'.
-- =============================================================================================

INSERT INTO ACT_ID_MEMBERSHIP (USER_ID_, GROUP_ID_)
VALUES ('jane.ops', 'camunda-admin');
