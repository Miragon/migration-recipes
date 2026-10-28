-- =====================================================================================================
-- Seed data for the SQL toolkit tests: a Camunda 7.24 database "as found" before the cut-over.
-- Loaded by test.mjs on top of the real PostgreSQL create scripts (Camunda 7.24.0 / Operaton 2.1.5 / 2.2.0-RC1).
-- Modelled on examples/camunda7-spring-boot-legacy (order-fulfillment, camunda-admin, order-ops, ship-order).
-- Not for production use.
-- =====================================================================================================

-- ---------------------------------------------------------------- schema history of an upgraded database
update ACT_GE_SCHEMA_LOG set VERSION_ = '7.21.0', TIMESTAMP_ = now() - interval '400 days' where ID_ = '0';
insert into ACT_GE_SCHEMA_LOG (ID_, TIMESTAMP_, VERSION_) values
  ('1100', now() - interval '300 days', '7.22.0'),
  ('1200', now() - interval '200 days', '7.23.0'),
  ('1300', now() - interval '100 days', '7.24.0');

-- ---------------------------------------------------------------- properties written by Camunda at runtime
insert into ACT_GE_PROPERTY (NAME_, VALUE_, REV_) values
  ('historyLevel', '3', 1),
  ('camunda.installation.id', '5f1c0b6e-3c2d-4f7a-9e1b-6a7d2c9b0001', 1),
  ('camunda.telemetry.enabled', 'false', 1),
  ('telemetry.lock', '0', 1);

-- ---------------------------------------------------------------- identity
insert into ACT_ID_USER (ID_, REV_, FIRST_, LAST_, EMAIL_, PWD_, SALT_) values
  ('demo',     1, 'Demo', 'Administrator', 'demo@example.com',  '{SHA-512}x', 's1'),
  ('jane.ops', 1, 'Jane', 'Ops',           'jane@example.com',  '{SHA-512}x', 's2'),
  ('john',     1, 'John', 'Worker',        'john@example.com',  '{SHA-512}x', 's3'),
  ('auditor',  1, 'Ann',  'Auditor',       'audit@example.com', '{SHA-512}x', 's4');

insert into ACT_ID_GROUP (ID_, REV_, NAME_, TYPE_) values
  ('camunda-admin', 1, 'camunda BPM Administrators', 'SYSTEM'),
  ('order-ops',     1, 'Order Operations',           'WORKFLOW'),
  ('management',    1, 'Management',                 'WORKFLOW');

insert into ACT_ID_MEMBERSHIP (USER_ID_, GROUP_ID_) values
  ('demo', 'camunda-admin'), ('jane.ops', 'camunda-admin'),
  ('demo', 'order-ops'), ('john', 'order-ops'), ('auditor', 'management');

insert into ACT_ID_TENANT (ID_, REV_, NAME_) values ('acme', 1, 'ACME Corp');
insert into ACT_ID_TENANT_MEMBER (ID_, TENANT_ID_, USER_ID_, GROUP_ID_) values
  ('tm-1', 'acme', null, 'camunda-admin'),
  ('tm-2', 'acme', 'john', null);

-- camunda-admin: GRANT ALL on '*' for all 22 resource types (what Camunda's admin-user / setup code creates)
insert into ACT_RU_AUTHORIZATION (ID_, REV_, TYPE_, GROUP_ID_, USER_ID_, RESOURCE_TYPE_, RESOURCE_ID_, PERMS_)
select 'ca-all-' || r, 1, 1, 'camunda-admin', null, r, '*', 2147483647
  from generate_series(0, 21) as r;

insert into ACT_RU_AUTHORIZATION (ID_, REV_, TYPE_, GROUP_ID_, USER_ID_, RESOURCE_TYPE_, RESOURCE_ID_, PERMS_) values
  -- members may READ their own group (DefaultAuthorizationProvider#newGroup)
  ('ca-read-self',   1, 1, 'camunda-admin', null,      2, 'camunda-admin', 2),
  -- a hand-made REVOKE: admins must not delete the payroll definition
  ('ca-revoke-pay',  1, 2, 'camunda-admin', null,      6, 'payroll',       2147483631),
  -- other principals on the camunda-admin group as a resource
  ('aud-read-ca',    1, 1, null,            'auditor', 2, 'camunda-admin', 2),
  ('ops-memb-ca',    1, 1, 'order-ops',     null,      3, 'camunda-admin', 2),
  ('glob-read-ca',   1, 0, null,            '*',       2, 'camunda-admin', 2),
  -- unrelated authorizations (must not be touched)
  ('ops-cockpit',    1, 1, 'order-ops',     null,      0, 'cockpit',       2147483647),
  ('ops-tasklist',   1, 1, 'order-ops',     null,      0, 'tasklist',      2147483647),
  ('demo-own-user',  1, 1, null,            'demo',    1, 'demo',          2147483647);

-- ---------------------------------------------------------------- task filters (Tasklist)
-- QUERY_ as JsonTaskQueryConverter writes it (compact Gson JSON): each expression criterion is a key "<criterion>Expression".
insert into ACT_RU_FILTER (ID_, REV_, RESOURCE_TYPE_, NAME_, OWNER_, QUERY_, PROPERTIES_) values
  -- with expressions: typical Tasklist filters (built-in functions only) ...
  ('flt-my-tasks',       1, 'Task', 'My Tasks',          'demo',
                         '{"taskAssigneeExpression":"${currentUser()}"}',
                         '{"description":"Tasks assigned to me","priority":-10,"refresh":false}'),
  ('flt-group-tasks',    1, 'Task', 'My Group Tasks',    'demo',
                         '{"unassigned":true,"taskCandidateGroupInExpression":"${currentUserGroups()}"}',
                         '{"description":"Unassigned tasks of my groups","priority":-5,"refresh":false}'),
  -- ... expressions only inside an or-query ...
  ('flt-mine-or-groups', 1, 'Task', 'Mine or my groups', 'jane.ops',
                         '{"orQueries":[{"taskAssigneeExpression":"${currentUser()}"},{"taskCandidateGroupInExpression":"${currentUserGroups()}"}]}',
                         '{"priority":0}'),
  -- ... and a bean call with an escaped string literal (the kind the 7.24.7-ee allow-list rejects unless allow-listed)
  ('flt-deputy',         1, 'Task', 'Deputy tasks',      'jane.ops',
                         '{"taskCandidateUserExpression":"${deputyService.deputyOf(currentUser(), \"order-ops\")}","dueBeforeExpression":"${dateTime().plusDays(2).toDate()}"}',
                         '{"priority":5}'),
  -- without expressions; flt-high-risk filters on a VARIABLE named riskExpression (a value, not an expression key)
  ('flt-all-tasks',      1, 'Task', 'All Tasks',         null,
                         '{}',
                         '{"description":"All tasks","priority":10,"refresh":false}'),
  ('flt-shipping',       1, 'Task', 'Shipping',          'jane.ops',
                         '{"unassigned":true,"candidateGroups":["order-ops"]}',
                         '{"priority":1}'),
  ('flt-high-risk',      1, 'Task', 'High risk orders',  'auditor',
                         '{"processVariables":[{"name":"riskExpression","value":"high","operator":"EQUALS"}]}',
                         '{"priority":2}');

-- ---------------------------------------------------------------- deployments and resources
insert into ACT_RE_DEPLOYMENT (ID_, NAME_, DEPLOY_TIME_, SOURCE_, TENANT_ID_) values
  ('dep-1', 'SpringAutoDeployment', now() - interval '90 days',   'process application', null),
  ('dep-2', 'SpringAutoDeployment', now() - interval '30 days',   'process application', null),
  ('dep-3', 'SpringAutoDeployment', now() - interval '1 day',     'process application', null),
  ('dep-4', 'feel-tools',           now() - interval '60 days',   'rest',                null),
  ('dep-5', 'legacy-invoice',       now() - interval '2000 days', 'rest',                null);

insert into ACT_GE_BYTEARRAY (ID_, REV_, NAME_, DEPLOYMENT_ID_, BYTES_, GENERATED_, TYPE_, CREATE_TIME_) values
  ('res-of-1', 1, 'order-fulfillment.bpmn', 'dep-1', convert_to(
'<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" xmlns:modeler="http://camunda.org/schema/modeler/1.0" modeler:executionPlatform="Camunda Platform" id="d1">
  <bpmn:process id="order-fulfillment" isExecutable="true" camunda:historyTimeToLive="180">
    <bpmn:serviceTask id="Task_CheckInventory" camunda:asyncBefore="true" camunda:delegateExpression="${checkInventoryDelegate}"/>
    <bpmn:scriptTask id="Task_BuildSummary" scriptFormat="groovy" camunda:asyncBefore="true"><bpmn:script>import org.camunda.spin.Spin
execution.setVariable("summary", Spin.JSON([orderId: orderId]).toString())</bpmn:script></bpmn:scriptTask>
    <bpmn:userTask id="Task_ApproveOrder" camunda:candidateGroups="order-ops" camunda:formKey="camunda-forms:deployment:approve-order.form"/>
    <bpmn:serviceTask id="Task_ShipOrder" camunda:type="external" camunda:topic="ship-order"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '90 days'),
  ('res-dmn-1', 1, 'order-discount.dmn', 'dep-1', convert_to(
'<definitions xmlns="https://www.omg.org/spec/DMN/20191111/MODEL/" id="d2" name="discount"><decision id="order-discount"><decisionTable><input><inputExpression typeRef="string"><text>customerType</text></inputExpression></input><output name="discount" typeRef="double"/><rule><inputEntry><text>"VIP"</text></inputEntry><outputEntry><text>0.1</text></outputEntry></rule></decisionTable></decision></definitions>',
  'UTF8'), false, 1, now() - interval '90 days'),
  ('res-form-1', 1, 'approve-order.form', 'dep-1', convert_to(
'{"components":[{"key":"approved","label":"Approve?","type":"checkbox"}],"type":"default","id":"approve-order","executionPlatform":"Camunda Platform","exporter":{"name":"Camunda Modeler","version":"5.40.0"}}',
  'UTF8'), false, 1, now() - interval '90 days'),
  ('res-of-2', 1, 'order-fulfillment.bpmn', 'dep-2', convert_to(
'<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" id="d1">
  <bpmn:process id="order-fulfillment" isExecutable="true" camunda:historyTimeToLive="180">
    <bpmn:scriptTask id="Task_BuildSummary" scriptFormat="groovy" camunda:asyncBefore="true"><bpmn:script>import org.camunda.spin.Spin
import static org.camunda.spin.Spin.JSON
execution.setVariable("summary", JSON([orderId: orderId]).toString())</bpmn:script></bpmn:scriptTask>
    <bpmn:callActivity id="CallActivity_Payment" calledElement="payment"/>
    <bpmn:userTask id="Task_ApproveOrder" camunda:formKey="camunda-forms:deployment:approve-order.form"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '30 days'),
  ('res-pay-2', 1, 'payment.bpmn', 'dep-2', convert_to(
'<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" id="d3">
  <bpmn:process id="payment" isExecutable="true" camunda:historyTimeToLive="180">
    <bpmn:scriptTask id="Task_Enrich" scriptFormat="javascript" camunda:resource="deployment://scripts/enrich.js"/>
    <bpmn:serviceTask id="Task_ChargeCard" camunda:type="external" camunda:topic="charge-card"/>
    <bpmn:callActivity id="CallActivity_Notify" calledElement="notify"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '30 days'),
  ('res-js-2', 1, 'scripts/enrich.js', 'dep-2', convert_to(
'var Variables = Java.type("org.camunda.bpm.engine.variable.Variables");
execution.setVariable("enriched", Variables.booleanValue(true));', 'UTF8'), false, 1, now() - interval '30 days'),
  ('res-of-3', 1, 'order-fulfillment.bpmn', 'dep-3', convert_to(
'<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" id="d1">
  <bpmn:process id="order-fulfillment" isExecutable="true" camunda:historyTimeToLive="180">
    <bpmn:scriptTask id="Task_BuildSummary" scriptFormat="groovy" camunda:asyncBefore="true"><bpmn:script>import org.operaton.spin.Spin
execution.setVariable("summary", Spin.JSON([orderId: orderId]).toString())</bpmn:script></bpmn:scriptTask>
    <bpmn:serviceTask id="Task_CheckInventory" camunda:asyncBefore="true" camunda:delegateExpression="${checkInventoryDelegate}"/>
    <bpmn:userTask id="Task_ApproveOrder" camunda:formKey="camunda-forms:deployment:approve-order.form"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '1 day'),
  ('res-notify-3', 1, 'notify.bpmn', 'dep-3', convert_to(
'<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" id="d4">
  <bpmn:process id="notify" isExecutable="true" camunda:historyTimeToLive="30">
    <bpmn:serviceTask id="Task_SendMail" camunda:asyncBefore="true" camunda:delegateExpression="${mailDelegate}"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '1 day'),
  ('res-rules-4', 1, 'rules.bpmn', 'dep-4', convert_to(
'<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:camunda="http://camunda.org/schema/1.0/bpmn" id="d5">
  <bpmn:process id="rules" isExecutable="true" camunda:historyTimeToLive="30">
    <bpmn:scriptTask id="Task_Feel" scriptFormat="groovy" camunda:resource="deployment://scripts/feel-helper.groovy"/>
  </bpmn:process>
</bpmn:definitions>', 'UTF8'), false, 1, now() - interval '60 days'),
  ('res-feel-4', 1, 'scripts/feel-helper.groovy', 'dep-4', convert_to(
'import org.camunda.feel.api.FeelEngineBuilder
def engine = FeelEngineBuilder.create().build()', 'UTF8'), false, 1, now() - interval '60 days'),
  ('res-inv-5', 1, 'legacy-invoice.bpmn', 'dep-5', convert_to(
'<definitions xmlns="http://www.omg.org/spec/BPMN/20100524/MODEL" xmlns:activiti="http://activiti.org/bpmn" id="d6">
  <process id="legacy-invoice" isExecutable="true">
    <serviceTask id="Task_Book" activiti:expression="${booking.book(execution)}"/>
  </process>
</definitions>', 'UTF8'), false, 1, now() - interval '2000 days');

insert into ACT_RE_PROCDEF (ID_, REV_, KEY_, VERSION_, DEPLOYMENT_ID_, RESOURCE_NAME_, SUSPENSION_STATE_, HAS_START_FORM_KEY_, STARTABLE_, HISTORY_TTL_) values
  ('order-fulfillment:1:pd-of-1', 1, 'order-fulfillment', 1, 'dep-1', 'order-fulfillment.bpmn', 1, false, true, 180),
  ('order-fulfillment:2:pd-of-2', 1, 'order-fulfillment', 2, 'dep-2', 'order-fulfillment.bpmn', 1, false, true, 180),
  ('payment:1:pd-pay-1',          1, 'payment',           1, 'dep-2', 'payment.bpmn',           1, false, true, 180),
  ('order-fulfillment:3:pd-of-3', 1, 'order-fulfillment', 3, 'dep-3', 'order-fulfillment.bpmn', 1, false, true, 180),
  ('notify:1:pd-notify-1',        1, 'notify',            1, 'dep-3', 'notify.bpmn',            1, false, true, 30),
  ('rules:1:pd-rules-1',          1, 'rules',             1, 'dep-4', 'rules.bpmn',             1, false, true, 30),
  ('legacy-invoice:1:pd-inv-1',   1, 'legacy-invoice',    1, 'dep-5', 'legacy-invoice.bpmn',    1, false, true, null);

insert into ACT_RE_DECISION_DEF (ID_, REV_, KEY_, VERSION_, DEPLOYMENT_ID_, RESOURCE_NAME_, NAME_) values
  ('order-discount:1:dd-1', 1, 'order-discount', 1, 'dep-1', 'order-discount.dmn', 'Order discount');

insert into ACT_RU_JOBDEF (ID_, REV_, PROC_DEF_ID_, PROC_DEF_KEY_, ACT_ID_, JOB_TYPE_, JOB_CONFIGURATION_, SUSPENSION_STATE_, DEPLOYMENT_ID_) values
  ('jd-of2-summary', 1, 'order-fulfillment:2:pd-of-2', 'order-fulfillment', 'Task_BuildSummary',   'async-continuation', 'async-before', 1, 'dep-2'),
  ('jd-of3-check',   1, 'order-fulfillment:3:pd-of-3', 'order-fulfillment', 'Task_CheckInventory', 'async-continuation', 'async-before', 1, 'dep-3'),
  ('jd-notify-mail', 1, 'notify:1:pd-notify-1',        'notify',            'Task_SendMail',       'async-continuation', 'async-before', 1, 'dep-3');

-- ---------------------------------------------------------------- running process instances
-- helper columns: IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_
insert into ACT_RU_EXECUTION (ID_, REV_, ROOT_PROC_INST_ID_, PROC_INST_ID_, BUSINESS_KEY_, PARENT_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, SUPER_EXEC_, ACT_ID_, IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_) values
  -- v1: waiting at the user task / at the external task
  ('pi-of1-a', 1, 'pi-of1-a', 'pi-of1-a', 'A-1001', null, 'order-fulfillment:1:pd-of-1', 'order-fulfillment', null, 'Task_ApproveOrder', true, false, true, false, 1, 0, 5),
  ('pi-of1-b', 1, 'pi-of1-b', 'pi-of1-b', 'A-1002', null, 'order-fulfillment:1:pd-of-1', 'order-fulfillment', null, 'Task_ShipOrder',    true, false, true, false, 1, 0, 7),
  -- v2: one waits at the async job before the Groovy script, two are inside call activities
  ('pi-of2-a', 1, 'pi-of2-a', 'pi-of2-a', 'A-2001', null, 'order-fulfillment:2:pd-of-2', 'order-fulfillment', null, 'Task_BuildSummary', true, false, true, false, 1, 0, 3),
  ('pi-of2-b', 1, 'pi-of2-b', 'pi-of2-b', 'A-2002', null, 'order-fulfillment:2:pd-of-2', 'order-fulfillment', null, null,                 false, false, true, false, 1, 0, 4),
  ('pi-of2-c', 1, 'pi-of2-c', 'pi-of2-c', 'A-2003', null, 'order-fulfillment:2:pd-of-2', 'order-fulfillment', null, null,                 false, false, true, false, 1, 0, 4),
  -- v3 (fixed version)
  ('pi-of3-a', 1, 'pi-of3-a', 'pi-of3-a', 'A-3001', null, 'order-fulfillment:3:pd-of-3', 'order-fulfillment', null, 'Task_CheckInventory', true, false, true, false, 1, 0, 2),
  ('pi-of3-b', 1, 'pi-of3-b', 'pi-of3-b', 'A-3002', null, 'order-fulfillment:3:pd-of-3', 'order-fulfillment', null, 'Task_CheckInventory', true, false, true, false, 1, 0, 2),
  ('pi-of3-c', 1, 'pi-of3-c', 'pi-of3-c', 'A-3003', null, 'order-fulfillment:3:pd-of-3', 'order-fulfillment', null, 'Task_ShipOrder',      true, false, true, false, 1, 0, 6),
  ('pi-rules-1', 1, 'pi-rules-1', 'pi-rules-1', 'R-1', null, 'rules:1:pd-rules-1',       'rules',             null, 'Task_Feel',           true, false, true, false, 1, 0, 2),
  ('pi-inv-1', 1, 'pi-inv-1', 'pi-inv-1', 'INV-7',  null, 'legacy-invoice:1:pd-inv-1',   'legacy-invoice',    null, 'Task_Book',           true, false, true, false, 1, 0, 2);

-- call-activity executions in the super instances
insert into ACT_RU_EXECUTION (ID_, REV_, ROOT_PROC_INST_ID_, PROC_INST_ID_, PARENT_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, ACT_ID_, IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_) values
  ('ex-of2-b-ca', 1, 'pi-of2-b', 'pi-of2-b', 'pi-of2-b', 'order-fulfillment:2:pd-of-2', 'order-fulfillment', 'CallActivity_Payment', true, false, false, false, 1, 0, 5),
  ('ex-of2-c-ca', 1, 'pi-of2-c', 'pi-of2-c', 'pi-of2-c', 'order-fulfillment:2:pd-of-2', 'order-fulfillment', 'CallActivity_Payment', true, false, false, false, 1, 0, 5);

-- payment sub-instances (pi-pay-1 calls notify; pi-pay-2 waits at an external task)
insert into ACT_RU_EXECUTION (ID_, REV_, ROOT_PROC_INST_ID_, PROC_INST_ID_, PARENT_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, SUPER_EXEC_, ACT_ID_, IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_) values
  ('pi-pay-1', 1, 'pi-of2-b', 'pi-pay-1', null, 'payment:1:pd-pay-1', 'payment', 'ex-of2-b-ca', null,              false, false, true, false, 1, 0, 3),
  ('pi-pay-2', 1, 'pi-of2-c', 'pi-pay-2', null, 'payment:1:pd-pay-1', 'payment', 'ex-of2-c-ca', 'Task_ChargeCard', true,  false, true, false, 1, 0, 3);
insert into ACT_RU_EXECUTION (ID_, REV_, ROOT_PROC_INST_ID_, PROC_INST_ID_, PARENT_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, ACT_ID_, IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_) values
  ('ex-pay-1-ca', 1, 'pi-of2-b', 'pi-pay-1', 'pi-pay-1', 'payment:1:pd-pay-1', 'payment', 'CallActivity_Notify', true, false, false, false, 1, 0, 4);
-- notify sub-sub-instance with the failing job (three-level call hierarchy)
insert into ACT_RU_EXECUTION (ID_, REV_, ROOT_PROC_INST_ID_, PROC_INST_ID_, PARENT_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, SUPER_EXEC_, ACT_ID_, IS_ACTIVE_, IS_CONCURRENT_, IS_SCOPE_, IS_EVENT_SCOPE_, SUSPENSION_STATE_, CACHED_ENT_STATE_, SEQUENCE_COUNTER_) values
  ('pi-notify-1', 1, 'pi-of2-b', 'pi-notify-1', null, 'notify:1:pd-notify-1', 'notify', 'ex-pay-1-ca', 'Task_SendMail', true, false, true, false, 1, 0, 2);

insert into ACT_RU_TASK (ID_, REV_, EXECUTION_ID_, PROC_INST_ID_, PROC_DEF_ID_, NAME_, TASK_DEF_KEY_, PRIORITY_, CREATE_TIME_, LAST_UPDATED_, SUSPENSION_STATE_, TASK_STATE_) values
  ('task-of1-a', 1, 'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'Approve order', 'Task_ApproveOrder', 50, now() - interval '2 days', now() - interval '2 days', 1, 'Created');

-- ---------------------------------------------------------------- byte arrays (variables, stack traces)
-- Java serialization stream header: ac ed 00 05 73 72 <len> <class name> ...
insert into ACT_GE_BYTEARRAY (ID_, REV_, NAME_, DEPLOYMENT_ID_, BYTES_, GENERATED_, TYPE_, CREATE_TIME_, ROOT_PROC_INST_ID_) values
  ('ba-v-varmap', 1, null, null, decode('aced000573720034', 'hex') || convert_to('org.camunda.bpm.engine.variable.impl.VariableMapImpl', 'UTF8')
                                 || decode('6c3a5b7c2f8e6a0d0200014c00097661726961626c65737400', 'hex'), null, 2, now(), 'pi-of1-a'),
  ('ba-v-order',  1, null, null, decode('aced00057372000e', 'hex') || convert_to('com.acme.Order', 'UTF8')
                                 || decode('00000000000000010200024c0006616d6f756e74', 'hex')
                                 || convert_to('org.camunda.bpm.engine.variable.value.impl.PrimitiveTypeValueImpl$StringValueImpl', 'UTF8'), null, 2, now(), 'pi-of1-a'),
  ('ba-v-feel',   1, null, null, decode('aced00057372000d', 'hex') || convert_to('com.acme.Rule', 'UTF8')
                                 || decode('0000000000000001020001', 'hex') || convert_to('org.camunda.feel.syntaxtree.ValString', 'UTF8'), null, 2, now(), 'pi-of1-a'),
  ('ba-v-feelval',1, null, null, decode('aced000573720025', 'hex') || convert_to('org.camunda.feel.syntaxtree.ValString', 'UTF8'), null, 2, now(), 'pi-of1-a'),
  ('ba-v-clean',  1, null, null, decode('aced000573720011', 'hex') || convert_to('com.acme.Customer', 'UTF8')
                                 || decode('000000000000000102', 'hex') || convert_to('java.lang.String', 'UTF8'), null, 2, now(), 'pi-of1-a'),
  ('ba-v-dto',    1, null, null, convert_to('[{"type":"String","value":"x","valueInfo":{}}]', 'UTF8'), null, 2, now(), 'pi-of2-a'),
  ('ba-hv-old',   1, null, null, decode('aced0005737200', 'hex') || convert_to('com.acme.LegacyHolder', 'UTF8')
                                 || convert_to('Lorg/camunda/bpm/engine/variable/VariableMap;', 'UTF8'), null, 3, now() - interval '50 days', 'pi-old-1'),
  ('ba-stack-1',  1, 'job.exceptionByteArray', null, convert_to('org.camunda.bpm.engine.ProcessEngineException: Mail server unreachable
	at org.camunda.bpm.engine.impl.bpmn.behavior.ServiceTaskDelegateExpressionActivityBehavior.execute(...)', 'UTF8'), null, 2, now(), 'pi-of2-b'),
  ('ba-stack-of3',1, 'job.exceptionByteArray', null, convert_to('java.net.SocketTimeoutException: Inventory service timeout', 'UTF8'), null, 2, now(), 'pi-of3-a'),
  ('ba-joblog-1', 1, 'job.exceptionByteArray', null, convert_to('org.camunda.bpm.engine.ProcessEngineException: Mail server unreachable (attempt 1)', 'UTF8'), null, 3, now(), 'pi-of2-b'),
  ('ba-ext-err-1',1, 'ExternalTaskEntity.errorDetailsByteArray', null, convert_to('java.io.IOException: HTTP 503 from carrier API', 'UTF8'), null, 2, now(), 'pi-of1-b');

insert into ACT_RU_VARIABLE (ID_, REV_, TYPE_, NAME_, EXECUTION_ID_, PROC_INST_ID_, PROC_DEF_ID_, BYTEARRAY_ID_, TEXT_, TEXT2_, VAR_SCOPE_, SEQUENCE_COUNTER_, IS_CONCURRENT_LOCAL_) values
  ('v-varmap',  1, 'serializable', 'vars',      'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'ba-v-varmap',  null, 'org.camunda.bpm.engine.variable.impl.VariableMapImpl', 'pi-of1-a', 1, false),
  ('v-order',   1, 'serializable', 'order',     'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'ba-v-order',   null, 'com.acme.Order',                                         'pi-of1-a', 1, false),
  ('v-feel',    1, 'serializable', 'rule',      'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'ba-v-feel',    null, 'com.acme.Rule',                                          'pi-of1-a', 1, false),
  ('v-feelval', 1, 'serializable', 'feelValue', 'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'ba-v-feelval', null, 'org.camunda.feel.syntaxtree.ValString',                  'pi-of1-a', 1, false),
  ('v-clean',   1, 'serializable', 'customer',  'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'ba-v-clean',   null, 'com.acme.Customer',                                      'pi-of1-a', 1, false),
  ('v-json',    1, 'json',         'payload',   'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', null,           '{"orderId":"A-1001"}', null,                                  'pi-of1-a', 1, false),
  ('v-dto',     1, 'spin://application/json', 'dtos', 'pi-of2-a', 'pi-of2-a', 'order-fulfillment:2:pd-of-2', 'ba-v-dto', null,
                'java.util.ArrayList<org.camunda.bpm.engine.rest.dto.VariableValueDto>', 'pi-of2-a', 1, false),
  ('v-amount',  1, 'long',         'amount',    'pi-of2-a', 'pi-of2-a', 'order-fulfillment:2:pd-of-2', null,           null, null,                                                   'pi-of2-a', 1, false);

-- ---------------------------------------------------------------- history (variables, decisions, job log)
insert into ACT_HI_VARINST (ID_, PROC_DEF_KEY_, PROC_DEF_ID_, ROOT_PROC_INST_ID_, PROC_INST_ID_, EXECUTION_ID_, NAME_, VAR_TYPE_, CREATE_TIME_, REV_, BYTEARRAY_ID_, TEXT2_, STATE_) values
  ('v-varmap', 'order-fulfillment', 'order-fulfillment:1:pd-of-1', 'pi-of1-a', 'pi-of1-a', 'pi-of1-a', 'vars', 'serializable', now(), 1, null,
               'org.camunda.bpm.engine.variable.impl.VariableMapImpl', 'CREATED'),
  ('v-dto',    'order-fulfillment', 'order-fulfillment:2:pd-of-2', 'pi-of2-a', 'pi-of2-a', 'pi-of2-a', 'dtos', 'spin://application/json', now(), 1, null,
               'java.util.ArrayList<org.camunda.bpm.engine.rest.dto.VariableValueDto>', 'CREATED'),
  ('hv-old',   'order-fulfillment', 'order-fulfillment:1:pd-of-1', 'pi-old-1', 'pi-old-1', 'pi-old-1', 'holder', 'serializable', now() - interval '50 days', 1, 'ba-hv-old',
               'com.acme.LegacyHolder', 'CREATED');

insert into ACT_HI_DETAIL (ID_, TYPE_, PROC_DEF_KEY_, PROC_DEF_ID_, ROOT_PROC_INST_ID_, PROC_INST_ID_, EXECUTION_ID_, NAME_, VAR_TYPE_, REV_, TIME_, TEXT2_, SEQUENCE_COUNTER_) values
  ('hd-1', 'VariableUpdate', 'order-fulfillment', 'order-fulfillment:1:pd-of-1', 'pi-of1-a', 'pi-of1-a', 'pi-of1-a', 'node', 'spin://application/json', 1, now(),
           'org.camunda.spin.impl.json.jackson.JacksonJsonNode', 1);

insert into ACT_HI_DEC_OUT (ID_, DEC_INST_ID_, CLAUSE_ID_, RULE_ID_, VAR_NAME_, VAR_TYPE_, TEXT2_, CREATE_TIME_) values
  ('hdo-1', 'hdi-1', 'Output_1', 'Rule_1', 'result', 'serializable', 'org.camunda.bpm.dmn.engine.impl.DmnDecisionResultImpl', now() - interval '10 days');

insert into ACT_HI_JOB_LOG (ID_, TIMESTAMP_, JOB_ID_, JOB_DUEDATE_, JOB_RETRIES_, JOB_PRIORITY_, JOB_EXCEPTION_MSG_, JOB_EXCEPTION_STACK_ID_, JOB_STATE_, JOB_DEF_ID_, JOB_DEF_TYPE_, ACT_ID_, FAILED_ACT_ID_, EXECUTION_ID_, ROOT_PROC_INST_ID_, PROCESS_INSTANCE_ID_, PROCESS_DEF_ID_, PROCESS_DEF_KEY_, DEPLOYMENT_ID_, SEQUENCE_COUNTER_) values
  ('jl-1', now() - interval '1 hour', 'job-notify-1', null, 3, 0, 'Mail server unreachable', 'ba-joblog-1', 2, 'jd-notify-mail', 'async-continuation', 'Task_SendMail', 'Task_SendMail',
           'pi-notify-1', 'pi-of2-b', 'pi-notify-1', 'notify:1:pd-notify-1', 'notify', 'dep-3', 2);

-- ---------------------------------------------------------------- jobs
insert into ACT_RU_JOB (ID_, REV_, TYPE_, LOCK_EXP_TIME_, LOCK_OWNER_, EXCLUSIVE_, EXECUTION_ID_, ROOT_PROC_INST_ID_, PROCESS_INSTANCE_ID_, PROCESS_DEF_ID_, PROCESS_DEF_KEY_, RETRIES_, EXCEPTION_STACK_ID_, EXCEPTION_MSG_, FAILED_ACT_ID_, DUEDATE_, HANDLER_TYPE_, HANDLER_CFG_, DEPLOYMENT_ID_, SUSPENSION_STATE_, JOB_DEF_ID_, PRIORITY_, SEQUENCE_COUNTER_, CREATE_TIME_) values
  -- currently executed by a node that is still running (lock not expired): pre-flight must say NO_GO
  ('job-of2-live', 2, 'message', now() + interval '4 minutes', 'node-a', true, 'pi-of2-a', 'pi-of2-a', 'pi-of2-a', 'order-fulfillment:2:pd-of-2', 'order-fulfillment', 3,
                   null, null, null, null, 'async-continuation', 'transition-create-scope', 'dep-2', 1, 'jd-of2-summary', 0, 1, now() - interval '1 minute'),
  -- failed in the deepest sub-process of a three-level call hierarchy
  ('job-notify-1', 4, 'message', null, null, true, 'pi-notify-1', 'pi-of2-b', 'pi-notify-1', 'notify:1:pd-notify-1', 'notify', 0,
                   'ba-stack-1', 'Mail server unreachable', 'Task_SendMail', now() - interval '30 minutes', 'async-continuation', 'transition-create-scope', 'dep-3', 1, 'jd-notify-mail', 0, 3, now() - interval '2 hours'),
  -- failed, simple incident (target for resolve_incidents = false)
  ('job-of3',      4, 'message', null, null, true, 'pi-of3-a', 'pi-of3-a', 'pi-of3-a', 'order-fulfillment:3:pd-of-3', 'order-fulfillment', 0,
                   'ba-stack-of3', 'Inventory service timeout', 'Task_CheckInventory', now() - interval '20 minutes', 'async-continuation', 'transition-create-scope', 'dep-3', 1, 'jd-of3-check', 0, 3, now() - interval '3 hours'),
  -- failed without incident (createIncidentOnFailedJobEnabled=false or an old manual SQL fix)
  ('job-of3-noinc',4, 'message', null, null, true, 'pi-of3-b', 'pi-of3-b', 'pi-of3-b', 'order-fulfillment:3:pd-of-3', 'order-fulfillment', 0,
                   null, 'Inventory service timeout', 'Task_CheckInventory', null, 'async-continuation', 'transition-create-scope', 'dep-3', 1, 'jd-of3-check', 0, 3, now() - interval '3 hours'),
  -- lock owner without expiry: inconsistent lock state, never acquired again
  ('job-incons',   2, 'message', null, 'node-b', true, 'pi-of3-c', 'pi-of3-c', 'pi-of3-c', 'order-fulfillment:3:pd-of-3', 'order-fulfillment', 3,
                   null, null, null, null, 'async-continuation', 'transition-create-scope', 'dep-3', 1, 'jd-of3-check', 0, 1, now() - interval '5 hours'),
  -- boundary reminder timer on the user task
  ('job-timer-1',  1, 'timer', null, null, false, 'pi-of1-a', 'pi-of1-a', 'pi-of1-a', 'order-fulfillment:1:pd-of-1', 'order-fulfillment', 3,
                   null, null, null, now() + interval '1 day', 'timer-transition', 'Timer_Reminder', 'dep-1', 1, null, 0, 1, now() - interval '2 days');

-- ---------------------------------------------------------------- external tasks
insert into ACT_RU_EXT_TASK (ID_, REV_, WORKER_ID_, TOPIC_NAME_, RETRIES_, ERROR_MSG_, ERROR_DETAILS_ID_, LOCK_EXP_TIME_, CREATE_TIME_, SUSPENSION_STATE_, EXECUTION_ID_, PROC_INST_ID_, PROC_DEF_ID_, PROC_DEF_KEY_, ACT_ID_, ACT_INST_ID_, PRIORITY_) values
  -- handleFailure(retries = 0, retryTimeout = 10 min): still locked by the worker, no retries left
  ('ext-ship-1',   5, 'worker-7', 'ship-order',  0, 'HTTP 503 from carrier API', 'ba-ext-err-1', now() + interval '10 minutes', now() - interval '1 day',
                   1, 'pi-of1-b', 'pi-of1-b', 'order-fulfillment:1:pd-of-1', 'order-fulfillment', 'Task_ShipOrder', 'Task_ShipOrder:ai-1', 0),
  -- failed inside a called sub-process (incident chain of two)
  ('ext-charge-1', 3, 'worker-3', 'charge-card', 0, 'card declined: gateway timeout', null, now() - interval '5 minutes', now() - interval '1 day',
                   1, 'pi-pay-2', 'pi-pay-2', 'payment:1:pd-pay-1', 'payment', 'Task_ChargeCard', 'Task_ChargeCard:ai-2', 0),
  -- healthy task currently locked by an active worker
  ('ext-locked-1', 2, 'worker-9', 'ship-order', null, null, null, now() + interval '3 minutes', now() - interval '10 minutes',
                   1, 'pi-of3-c', 'pi-of3-c', 'order-fulfillment:3:pd-of-3', 'order-fulfillment', 'Task_ShipOrder', 'Task_ShipOrder:ai-3', 0);

-- ---------------------------------------------------------------- incidents (runtime + history)
insert into ACT_RU_INCIDENT (ID_, REV_, INCIDENT_TIMESTAMP_, INCIDENT_MSG_, INCIDENT_TYPE_, EXECUTION_ID_, ACTIVITY_ID_, FAILED_ACTIVITY_ID_, PROC_INST_ID_, PROC_DEF_ID_, CAUSE_INCIDENT_ID_, ROOT_CAUSE_INCIDENT_ID_, CONFIGURATION_, JOB_DEF_ID_) values
  -- failedJob chain: root in notify, parents in payment and order-fulfillment (CONFIGURATION_ null, like IncidentEntity#createRecursiveIncidents)
  ('inc-n-root', 1, now() - interval '30 minutes', 'Mail server unreachable', 'failedJob', 'pi-notify-1', 'Task_SendMail', 'Task_SendMail', 'pi-notify-1', 'notify:1:pd-notify-1', 'inc-n-root', 'inc-n-root', 'job-notify-1', 'jd-notify-mail'),
  ('inc-n-p1',   1, now() - interval '30 minutes', null, 'failedJob', 'ex-pay-1-ca', 'CallActivity_Notify', 'CallActivity_Notify', 'pi-pay-1', 'payment:1:pd-pay-1', 'inc-n-root', 'inc-n-root', null, null),
  ('inc-n-p2',   1, now() - interval '30 minutes', null, 'failedJob', 'ex-of2-b-ca', 'CallActivity_Payment', 'CallActivity_Payment', 'pi-of2-b', 'order-fulfillment:2:pd-of-2', 'inc-n-p1', 'inc-n-root', null, null),
  -- simple failedJob incident
  ('inc-of3',    1, now() - interval '20 minutes', 'Inventory service timeout', 'failedJob', 'pi-of3-a', 'Task_CheckInventory', 'Task_CheckInventory', 'pi-of3-a', 'order-fulfillment:3:pd-of-3', 'inc-of3', 'inc-of3', 'job-of3', 'jd-of3-check'),
  -- failedExternalTask: simple, and a chain of two
  ('inc-x-ship', 1, now() - interval '1 hour', 'HTTP 503 from carrier API', 'failedExternalTask', 'pi-of1-b', 'Task_ShipOrder', 'Task_ShipOrder', 'pi-of1-b', 'order-fulfillment:1:pd-of-1', 'inc-x-ship', 'inc-x-ship', 'ext-ship-1', null),
  ('inc-x-root', 1, now() - interval '2 hours', 'card declined: gateway timeout', 'failedExternalTask', 'pi-pay-2', 'Task_ChargeCard', 'Task_ChargeCard', 'pi-pay-2', 'payment:1:pd-pay-1', 'inc-x-root', 'inc-x-root', 'ext-charge-1', null),
  ('inc-x-p1',   1, now() - interval '2 hours', null, 'failedExternalTask', 'ex-of2-c-ca', 'CallActivity_Payment', 'CallActivity_Payment', 'pi-of2-c', 'order-fulfillment:2:pd-of-2', 'inc-x-root', 'inc-x-root', null, null);

insert into ACT_HI_INCIDENT (ID_, PROC_DEF_KEY_, PROC_DEF_ID_, ROOT_PROC_INST_ID_, PROC_INST_ID_, EXECUTION_ID_, CREATE_TIME_, END_TIME_, INCIDENT_MSG_, INCIDENT_TYPE_, ACTIVITY_ID_, FAILED_ACTIVITY_ID_, CAUSE_INCIDENT_ID_, ROOT_CAUSE_INCIDENT_ID_, CONFIGURATION_, HISTORY_CONFIGURATION_, INCIDENT_STATE_, JOB_DEF_ID_) values
  ('inc-n-root', 'notify',            'notify:1:pd-notify-1',        'pi-of2-b', 'pi-notify-1', 'pi-notify-1', now() - interval '30 minutes', null, 'Mail server unreachable', 'failedJob', 'Task_SendMail', 'Task_SendMail', 'inc-n-root', 'inc-n-root', 'job-notify-1', 'jl-1', 0, 'jd-notify-mail'),
  ('inc-n-p1',   'payment',           'payment:1:pd-pay-1',          'pi-of2-b', 'pi-pay-1',    'ex-pay-1-ca', now() - interval '30 minutes', null, null, 'failedJob', 'CallActivity_Notify',  'CallActivity_Notify',  'inc-n-root', 'inc-n-root', null, null, 0, null),
  ('inc-n-p2',   'order-fulfillment', 'order-fulfillment:2:pd-of-2', 'pi-of2-b', 'pi-of2-b',    'ex-of2-b-ca', now() - interval '30 minutes', null, null, 'failedJob', 'CallActivity_Payment', 'CallActivity_Payment', 'inc-n-p1',   'inc-n-root', null, null, 0, null),
  ('inc-of3',    'order-fulfillment', 'order-fulfillment:3:pd-of-3', 'pi-of3-a', 'pi-of3-a',    'pi-of3-a',    now() - interval '20 minutes', null, 'Inventory service timeout', 'failedJob', 'Task_CheckInventory', 'Task_CheckInventory', 'inc-of3', 'inc-of3', 'job-of3', null, 0, 'jd-of3-check'),
  ('inc-x-ship', 'order-fulfillment', 'order-fulfillment:1:pd-of-1', 'pi-of1-b', 'pi-of1-b',    'pi-of1-b',    now() - interval '1 hour', null, 'HTTP 503 from carrier API', 'failedExternalTask', 'Task_ShipOrder', 'Task_ShipOrder', 'inc-x-ship', 'inc-x-ship', 'ext-ship-1', null, 0, null),
  ('inc-x-root', 'payment',           'payment:1:pd-pay-1',          'pi-of2-c', 'pi-pay-2',    'pi-pay-2',    now() - interval '2 hours', null, 'card declined: gateway timeout', 'failedExternalTask', 'Task_ChargeCard', 'Task_ChargeCard', 'inc-x-root', 'inc-x-root', 'ext-charge-1', null, 0, null),
  ('inc-x-p1',   'order-fulfillment', 'order-fulfillment:2:pd-of-2', 'pi-of2-c', 'pi-of2-c',    'ex-of2-c-ca', now() - interval '2 hours', null, null, 'failedExternalTask', 'CallActivity_Payment', 'CallActivity_Payment', 'inc-x-root', 'inc-x-root', null, null, 0, null),
  -- an older incident of the same job that was already resolved: must stay untouched
  ('inc-old-resolved', 'notify', 'notify:1:pd-notify-1', 'pi-of2-b', 'pi-notify-1', 'pi-notify-1', now() - interval '5 days', now() - interval '4 days', 'Mail server unreachable', 'failedJob', 'Task_SendMail', 'Task_SendMail', 'inc-old-resolved', 'inc-old-resolved', 'job-notify-1', null, 1, 'jd-notify-mail');
