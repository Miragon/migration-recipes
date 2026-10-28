-- Scenario "partially migrated": somebody already created operaton-admin (e.g. bootstrap code after the
-- recipe rewrote Groups.CAMUNDA_ADMIN to Groups.OPERATON_ADMIN), added one admin and two authorizations.
-- 10-migrate-admin-group.sql must complete the mirror without touching these rows.
insert into ACT_ID_GROUP (ID_, REV_, NAME_, TYPE_) values ('operaton-admin', 1, 'Camunda Administrators', 'SYSTEM');
insert into ACT_ID_MEMBERSHIP (USER_ID_, GROUP_ID_) values ('demo', 'operaton-admin');
insert into ACT_RU_AUTHORIZATION (ID_, REV_, TYPE_, GROUP_ID_, USER_ID_, RESOURCE_TYPE_, RESOURCE_ID_, PERMS_) values
  ('oa-app-access', 1, 1, 'operaton-admin', null, 0, '*', 2),               -- ACCESS only (not ALL): must stay as is
  ('oa-read-self',  1, 1, 'operaton-admin', null, 2, 'operaton-admin', 2);
