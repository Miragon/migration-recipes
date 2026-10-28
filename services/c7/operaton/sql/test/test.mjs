// Tests for sql/postgresql/*.sql - Camunda 7 -> Operaton Migration Starter Pack (Apache-2.0)
//
// Loads the REAL PostgreSQL create scripts (Camunda 7.24.0, Operaton 2.1.5, Operaton 2.2.0-RC1) into PGlite
// (PostgreSQL 18 compiled to WASM - no Docker, no server), seeds a realistic Camunda 7.24 database
// (seed.sql) and runs every script with assertions, twice where the script claims to be idempotent.
//
//   cd sql/test && npm install && npm test
//   node test.mjs --ddl operaton-2.1.5      # one DDL source only
//   node test.mjs --verbose                 # print every result set
//   node test.mjs --offline                 # use .ddl-cache only
//
// DDL files are downloaded once from raw.githubusercontent.com into .ddl-cache/ (git-ignored).

import { PGlite } from '@electric-sql/pglite';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const sqlDir = path.resolve(here, '../postgresql');
const cacheDir = path.join(here, '.ddl-cache');
const args = process.argv.slice(2);
const verbose = args.includes('--verbose');
const offline = args.includes('--offline');
const onlyDdl = args.includes('--ddl') ? args[args.indexOf('--ddl') + 1] : null;

const COMPONENTS = ['engine', 'history', 'identity', 'case.engine', 'case.history', 'decision.engine', 'decision.history'];
const DDL_SOURCES = {
  'camunda-7.24.0': {
    base: 'https://raw.githubusercontent.com/camunda/camunda-bpm-platform/7.24.0/engine/src/main/resources/org/camunda/bpm/engine/db/',
  },
  'operaton-2.1.5': {
    base: 'https://raw.githubusercontent.com/operaton/operaton/v2.1.5/engine/src/main/resources/org/operaton/bpm/engine/db/',
  },
  'operaton-2.2.0-RC1': {
    base: 'https://raw.githubusercontent.com/operaton/operaton/v2.2.0-RC1/engine/src/main/resources/org/operaton/bpm/engine/db/',
    // what an upgraded production database gets when moving to Operaton 2.2 (no DDL, only the 7.25.0 marker row)
    upgrade: ['upgrade/postgres_engine_7.24_to_7.25.sql'],
  },
};

// ------------------------------------------------------------------------------------------- tiny test kit
let passed = 0;
const failures = [];
function check(name, cond, detail) {
  if (cond) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failures.push(`${currentSuite}: ${name}${detail !== undefined ? ` -> ${JSON.stringify(detail)}` : ''}`);
    console.log(`  FAIL ${name}${detail !== undefined ? `\n       got: ${JSON.stringify(detail)}` : ''}`);
  }
}
let currentSuite = '';
function suite(name) {
  currentSuite = name;
  console.log(`\n# ${name}`);
}
const sameSet = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

// ------------------------------------------------------------------------------------------- DDL + database
async function ddlFile(source, rel) {
  const file = path.join(cacheDir, source, rel.replace(/\//g, '__'));
  if (!fs.existsSync(file)) {
    if (offline) throw new Error(`missing ${file} (offline mode)`);
    const url = DDL_SOURCES[source].base + rel;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`download failed ${res.status} ${url}`);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, await res.text());
  }
  return fs.readFileSync(file, 'utf8');
}

async function newDb(source, { partialMirror = false } = {}) {
  const db = new PGlite();
  for (const c of COMPONENTS) await db.exec(await ddlFile(source, `create/activiti.postgres.create.${c}.sql`));
  await db.exec(fs.readFileSync(path.join(here, 'seed.sql'), 'utf8'));
  for (const u of DDL_SOURCES[source].upgrade ?? []) await db.exec(await ddlFile(source, u));
  if (partialMirror) await db.exec(fs.readFileSync(path.join(here, 'seed-partial-mirror.sql'), 'utf8'));
  return db;
}

// Runs a toolkit script like `psql -v ON_ERROR_STOP=1 -f` would: on error the transaction is rolled back.
async function runScript(db, name, { replace = [], stripGate = false } = {}) {
  let sql = fs.readFileSync(path.join(sqlDir, name), 'utf8');
  for (const [search, repl] of replace) {
    const n = sql.split(search).length - 1;
    if (n !== 1) throw new Error(`test setup: "${search}" found ${n} times in ${name}`);
    sql = sql.replace(search, repl);
  }
  if (stripGate) {
    const before = sql;
    sql = sql.replace(/-- P99b[\s\S]*?\n\$\$;\n/, '');
    if (sql === before) throw new Error('test setup: gate block not found');
  }
  const notices = [];
  try {
    const results = await db.exec(sql, { onNotice: (n) => notices.push(`${n.severity}: ${n.message}`) });
    if (verbose) for (const r of results) if (r.fields.length) console.table(r.rows);
    return { results, notices, error: null };
  } catch (e) {
    await db.exec('rollback');
    return { results: [], notices, error: e.message };
  }
}

// First result set that has all given columns.
function rs(run, ...columns) {
  const r = run.results.find((x) => columns.every((c) => x.fields.some((f) => f.name === c)));
  return r ? r.rows : undefined;
}

const q = async (db, sql) => (await db.query(sql)).rows;

async function snapshot(db, tables) {
  const out = {};
  for (const t of tables) out[t] = await q(db, `select * from ${t} order by 1`);
  return JSON.stringify(out, (k, v) => (v instanceof Uint8Array ? Buffer.from(v).toString('hex') : v));
}
async function allActTables(db) {
  return (await q(db, `select table_name from information_schema.tables where table_schema = 'public' and table_name like 'act\\_%' order by 1`))
    .map((r) => r.table_name);
}
const IDENTITY_TABLES = ['ACT_ID_GROUP', 'ACT_ID_MEMBERSHIP', 'ACT_ID_TENANT_MEMBER', 'ACT_RU_AUTHORIZATION'];
const OPS_TABLES = ['ACT_RU_JOB', 'ACT_RU_INCIDENT', 'ACT_HI_INCIDENT', 'ACT_RU_EXT_TASK'];
const camundaAdminRows = (db) => snapshot(db, [
  `(select * from ACT_ID_GROUP where ID_ = 'camunda-admin') g`,
  `(select * from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'camunda-admin') m`,
  `(select * from ACT_ID_TENANT_MEMBER where GROUP_ID_ = 'camunda-admin') t`,
  `(select * from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'camunda-admin' or RESOURCE_ID_ = 'camunda-admin') a`,
]);

// ------------------------------------------------------------------------------------------- the tests
async function testSource(source) {
  console.log(`\n========== DDL: ${source} ==========`);
  const expectedSchema = source === 'operaton-2.2.0-RC1' ? '7.25.0' : '7.24.0';

  // ---------------------------------------------------------------- 00 + 10, scenario A (untouched C7 database)
  suite(`${source} / 00-preflight-checks.sql on an untouched Camunda 7.24 database`);
  let db = await newDb(source);
  const tables = await allActTables(db);
  check('DDL created 49 ACT_* tables', tables.length === 49, tables.length);
  let snapBefore = await snapshot(db, tables);
  let run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  check('report runs without error', !run.error, run.error);
  let summary = rs(run, 'verdict')?.[0];
  console.log('       summary:', JSON.stringify(summary));
  check('verdict NO_GO', summary?.verdict === 'NO_GO', summary?.verdict);
  check('reason: nobody in operaton-admin (setup page)', /nobody is in operaton-admin/.test(summary?.no_go_reasons));
  check('reason: job locked by a running node', /1 job\(s\) locked by a running engine node/.test(summary?.no_go_reasons));
  check(`schema_log_version = ${expectedSchema}`, summary?.schema_log_version === expectedSchema, summary?.schema_log_version);
  check('camunda_admin_members = 2, operaton_admin_members = 0',
    Number(summary?.camunda_admin_members) === 2 && Number(summary?.operaton_admin_members) === 0);
  check('legacy_typed_variables = 2 (VariableMapImpl, VariableValueDto; FEEL excluded)', Number(summary?.legacy_typed_variables) === 2,
    summary?.legacy_typed_variables);
  check('P03b lists demo and jane.ops as missing',
    sameSet((rs(run, 'user_missing_in_operaton_admin') ?? []).map((r) => r.user_missing_in_operaton_admin), ['demo', 'jane.ops']));
  check('P04 shows node-a with locked_now = 1, node-b inconsistent',
    (rs(run, 'lock_owner', 'locked_now') ?? []).some((r) => r.lock_owner === 'node-a' && Number(r.locked_now) === 1)
    && (rs(run, 'lock_owner', 'locked_now') ?? []).some((r) => r.lock_owner === 'node-b' && Number(r.inconsistent_locks) === 1));
  const p11 = Object.fromEntries((rs(run, 'filter_id', 'expressions') ?? []).map((r) => [r.filter_id, r.expressions]));
  check('P11 lists the 4 filters with expressions (or-query included; not the riskExpression variable, not {})',
    sameSet(Object.keys(p11), ['flt-my-tasks', 'flt-group-tasks', 'flt-mine-or-groups', 'flt-deputy']), Object.keys(p11));
  check('P11 expressions: criterion = expression, or-query and escaped quotes included',
    p11['flt-my-tasks'] === 'taskAssignee = ${currentUser()}'
    && p11['flt-mine-or-groups'] === 'taskAssignee = ${currentUser()}; taskCandidateGroupIn = ${currentUserGroups()}'
    && p11['flt-deputy'] === 'taskCandidateUser = ${deputyService.deputyOf(currentUser(), \\"order-ops\\")}; dueBefore = ${dateTime().plusDays(2).toDate()}',
  p11);
  check('filters_with_expressions = 4', Number(summary?.filters_with_expressions) === 4, summary?.filters_with_expressions);
  check('P11 adds no NO-GO reason', !/filter|xpression/i.test(summary?.no_go_reasons ?? ''), summary?.no_go_reasons);
  run = await runScript(db, '00-preflight-checks.sql');
  check('gate raises "PREFLIGHT NO_GO" (psql would exit 3)', /^PREFLIGHT NO_GO/.test(run.error ?? ''), run.error);
  check('00 changed nothing in any ACT_* table', (await snapshot(db, tables)) === snapBefore);

  suite(`${source} / 10-migrate-admin-group.sql, first run`);
  const caBefore = await camundaAdminRows(db);
  run = await runScript(db, '10-migrate-admin-group.sql');
  check('runs without error', !run.error, run.error);
  check('notice "OK: operaton-admin has 2 member(s)"', run.notices.some((n) => /OK: operaton-admin has 2 member/.test(n)), run.notices);
  const grp = await q(db, `select NAME_ as name, TYPE_ as type, REV_ as rev from ACT_ID_GROUP where ID_ = 'operaton-admin'`);
  check('group operaton-admin created ("operaton BPM Administrators", SYSTEM)',
    grp.length === 1 && grp[0].name === 'operaton BPM Administrators' && grp[0].type === 'SYSTEM' && grp[0].rev === 1, grp);
  check('members = demo, jane.ops', sameSet((await q(db, `select USER_ID_ as u from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin'`)).map((r) => r.u), ['demo', 'jane.ops']));
  const held = await q(db, `select TYPE_ as t, RESOURCE_TYPE_ as rt, RESOURCE_ID_ as rid, PERMS_ as p, ID_ as id, REV_ as rev
                              from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'operaton-admin'`);
  check('24 authorizations held (22x ALL on *, READ on own group, REVOKE)', held.length === 24, held.length);
  check('ALL on * for all 22 resource types',
    new Set(held.filter((h) => h.t === 1 && h.rid === '*' && h.p === 2147483647).map((h) => h.rt)).size === 22);
  check('READ-on-own-group re-pointed to operaton-admin', held.some((h) => h.rt === 2 && h.rid === 'operaton-admin' && h.p === 2));
  check('REVOKE on payroll mirrored (type 2, perms kept)', held.some((h) => h.t === 2 && h.rt === 6 && h.rid === 'payroll' && h.p === 2147483631));
  check('new IDs are UUIDs, REV_ = 1', held.every((h) => /^[0-9a-f-]{36}$/.test(h.id) && h.rev === 1));
  const onGroup = await q(db, `select TYPE_ as t, USER_ID_ as u, GROUP_ID_ as g, RESOURCE_TYPE_ as rt from ACT_RU_AUTHORIZATION
                                where RESOURCE_ID_ = 'operaton-admin' and (GROUP_ID_ is null or GROUP_ID_ <> 'operaton-admin')`);
  check('authorizations of others on the group mirrored (auditor, order-ops, global *)',
    onGroup.length === 3 && onGroup.some((r) => r.u === 'auditor' && r.rt === 2) && onGroup.some((r) => r.g === 'order-ops' && r.rt === 3)
    && onGroup.some((r) => r.t === 0 && r.u === '*'), onGroup);
  check('tenant membership acme mirrored',
    (await q(db, `select 1 from ACT_ID_TENANT_MEMBER where TENANT_ID_ = 'acme' and GROUP_ID_ = 'operaton-admin'`)).length === 1);
  check('camunda-admin rows untouched (rollback window)', (await camundaAdminRows(db)) === caBefore);
  const after1 = rs(run, 'missing_members');
  check('S6 verification: missing_* = 0',
    after1 && Number(after1[0].missing_members) === 0 && Number(after1[0].missing_authorizations) === 0 && Number(after1[0].missing_tenant_memberships) === 0, after1);

  suite(`${source} / 10-migrate-admin-group.sql, second run (idempotency)`);
  const idBefore = await snapshot(db, IDENTITY_TABLES);
  run = await runScript(db, '10-migrate-admin-group.sql');
  check('runs without error', !run.error, run.error);
  check('identity + authorization tables unchanged', (await snapshot(db, IDENTITY_TABLES)) === idBefore);

  suite(`${source} / 00-preflight-checks.sql after 10, node still running / after nodes stopped`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('still NO_GO, only because of the locked job',
    summary?.verdict === 'NO_GO' && !/operaton-admin/.test(summary?.no_go_reasons) && /locked by a running engine node/.test(summary?.no_go_reasons),
    summary?.no_go_reasons);
  // simulate: all Camunda nodes stopped and lockTimeInMillis elapsed
  await db.exec(`update ACT_RU_JOB set LOCK_EXP_TIME_ = now() - interval '1 minute' where LOCK_OWNER_ = 'node-a'`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  console.log('       summary:', JSON.stringify(summary));
  check('verdict GO_WITH_WARNINGS', summary?.verdict === 'GO_WITH_WARNINGS', summary);
  for (const w of ['3 failed job(s), 7 open incident(s)', 'external task(s) locked by active workers', 'runtime variable(s) typed with org.camunda',
    'lock owner but no lock expiry']) {
    check(`warning mentions "${w}"`, (summary?.warnings ?? '').includes(w), summary?.warnings);
  }
  if (expectedSchema === '7.25.0') check('warning mentions schema log 7.25.0', /schema log 7.25.0/.test(summary?.warnings));
  check('no warning about filters with expressions (P11 is informational)', !/filter|xpression/i.test(summary?.warnings ?? ''), summary?.warnings);
  run = await runScript(db, '00-preflight-checks.sql');
  check('gate passes (no error) and notices "PREFLIGHT GO_WITH_WARNINGS"', !run.error && run.notices.some((n) => /PREFLIGHT GO_WITH_WARNINGS/.test(n)), run.error ?? run.notices);

  // ---------------------------------------------------------------- 20 detection pack
  suite(`${source} / 20-find-legacy-references.sql`);
  snapBefore = await snapshot(db, tables);
  run = await runScript(db, '20-find-legacy-references.sql');
  check('runs without error', !run.error, run.error);
  check('20 changed nothing in any ACT_* table', (await snapshot(db, tables)) === snapBefore);
  const l1b = rs(run, 'variable_id', 'object_type_name', 'process_definition_version') ?? [];
  check('L1b runtime typed variables = v-varmap, v-dto (org.camunda.feel.* excluded)', sameSet(l1b.map((r) => r.variable_id), ['v-varmap', 'v-dto']), l1b);
  const l1a = rs(run, 'source_table', 'var_type', 'object_type_name', 'variables') ?? [];
  check('L1a history: ACT_HI_VARINST (2), ACT_HI_DETAIL (1), ACT_HI_DEC_OUT (1)',
    ['ACT_HI_VARINST:2', 'ACT_HI_DETAIL:1', 'ACT_HI_DEC_OUT:1'].every((k) => {
      const [t, n] = k.split(':');
      return l1a.filter((r) => r.source_table === t).reduce((s, r) => s + Number(r.variables), 0) === Number(n);
    }), l1a);
  const l2a = rs(run, 'owner', 'byte_arrays') ?? [];
  const owners = Object.fromEntries(l2a.map((r) => [r.owner.split(' ')[0] + (r.owner.includes('log') ? '-log' : ''), Number(r.byte_arrays)]));
  check('L2a owners: 2 runtime variables, 1 history variable, job stack trace, job log stack trace',
    owners.ACT_RU_VARIABLE === 2 && owners.ACT_HI_VARINST === 1 && owners.job === 1 && owners['job-log'] === 1 && l2a.length === 4, l2a);
  const l2b = rs(run, 'variable_id', 'matched_patterns', 'class_hint') ?? [];
  check('L2b runtime byte hits = v-varmap (top-level) + v-order (nested); not v-feel/v-feelval/v-clean',
    sameSet(l2b.map((r) => r.variable_id), ['v-varmap', 'v-order']), l2b.map((r) => r.variable_id));
  check('L2b class_hint shows the nested class',
    l2b.some((r) => r.variable_id === 'v-order' && r.class_hint === 'org.camunda.bpm.engine.variable.value.impl.PrimitiveTypeValueImpl$StringValueImpl'),
    l2b.map((r) => r.class_hint));
  const l3 = rs(run, 'deployment_id', 'resource_name', 'kind', 'first_reference') ?? [];
  check('L3 resources = dep-1 order-fulfillment.bpmn, dep-2 order-fulfillment.bpmn, dep-2 scripts/enrich.js',
    sameSet(l3.map((r) => `${r.deployment_id}/${r.resource_name}/${r.kind}`),
      ['dep-1/order-fulfillment.bpmn/bpmn', 'dep-2/order-fulfillment.bpmn/bpmn', 'dep-2/scripts/enrich.js/script']), l3);
  check('L3 first_reference = org.camunda.spin.Spin / org.camunda.bpm.engine.variable.Variables',
    l3.some((r) => r.first_reference === 'org.camunda.spin.Spin') && l3.some((r) => r.first_reference === 'org.camunda.bpm.engine.variable.Variables'),
    l3.map((r) => r.first_reference));
  const l4 = rs(run, 'process_definition_key', 'running_instances', 'fixed_version_available') ?? [];
  const l4m = Object.fromEntries(l4.map((r) => [`${r.process_definition_key}:${r.version}`, r]));
  check('L4 affected definitions = order-fulfillment:1, order-fulfillment:2, payment:1 (not rules:1, not v3)',
    sameSet(Object.keys(l4m), ['order-fulfillment:1', 'order-fulfillment:2', 'payment:1']), Object.keys(l4m));
  check('L4 running instances 2 / 3 / 2', Number(l4m['order-fulfillment:1']?.running_instances) === 2
    && Number(l4m['order-fulfillment:2']?.running_instances) === 3 && Number(l4m['payment:1']?.running_instances) === 2,
  l4.map((r) => [r.process_definition_key, r.version, r.running_instances]));
  check('L4 order-fulfillment v1/v2 -> fixed_version_available = 3; payment none',
    l4m['order-fulfillment:1']?.fixed_version_available === 3 && l4m['order-fulfillment:2']?.fixed_version_available === 3
    && l4m['payment:1']?.fixed_version_available === null);
  check('L4 payment:1 is "possibly, via script scripts/enrich.js"', /possibly, via script scripts\/enrich\.js/.test(l4m['payment:1']?.reason ?? ''), l4m['payment:1']?.reason);
  check('L4 counts jobs/tasks/incidents (v1: 1 task, 1 ext task, 1 incident)', Number(l4m['order-fulfillment:1']?.open_user_tasks) === 1
    && Number(l4m['order-fulfillment:1']?.external_tasks) === 1 && Number(l4m['order-fulfillment:1']?.open_incidents) === 1);
  const l5 = rs(run, 'deployment_id', 'resource_name', 'process_definition_id', 'running_instances') ?? [];
  check('L5 Activiti namespace: legacy-invoice.bpmn with 1 running instance',
    l5.length === 1 && l5[0].resource_name === 'legacy-invoice.bpmn' && Number(l5[0].running_instances) === 1, l5);
  const l6 = rs(run, 'deployment_id', 'resource_name', 'open_user_tasks') ?? [];
  check('L6 camunda-forms: keys in 3 deployed order-fulfillment versions', l6.length === 3, l6);
  check('L7 no decision/case definition affected', (rs(run, 'definition_type', 'definition_key') ?? []).length === 0);
  const l8c = rs(run, 'job_id', 'failed_activity', 'exception_message') ?? [];
  check('L8c job without incident = job-of3-noinc', l8c.length === 1 && l8c[0].job_id === 'job-of3-noinc', l8c);
  check('L8d/L8e no inconsistent incidents yet', (rs(run, 'incident_id', 'job_retries') ?? []).length === 0
    && (rs(run, 'incident_id', 'ext_task_retries') ?? []).length === 0);
  const l9 = rs(run, 'runtime_typed_variables', 'running_instances_on_affected_definitions')?.[0];
  console.log('       L9 summary:', JSON.stringify(l9));
  check('L9 summary', l9 && Number(l9.runtime_typed_variables) === 2 && Number(l9.runtime_variable_byte_hits) === 2
    && Number(l9.deployed_resources_with_refs) === 3 && Number(l9.affected_process_definitions) === 3
    && Number(l9.running_instances_on_affected_definitions) === 7 && Number(l9.activiti_namespace_definitions_running) === 1
    && Number(l9.resources_with_camunda_forms_keys) === 3 && Number(l9.harmless_text_hits) === 2, l9);
  run = await runScript(db, '20-find-legacy-references.sql');
  check('second run: same result, still no error', !run.error && (await snapshot(db, tables)) === snapBefore);
  await db.close();

  // ---------------------------------------------------------------- 30 emergency job retries
  suite(`${source} / 30-emergency-job-retries.sql`);
  db = await newDb(source);
  const PH = "and j.ID_ in ('REPLACE-WITH-JOB-ID')";
  let ops = await snapshot(db, OPS_TABLES);
  run = await runScript(db, '30-emergency-job-retries.sql');
  check('unedited placeholder -> abort "no job matched", nothing changed', /no job matched the scope/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);
  run = await runScript(db, '30-emergency-job-retries.sql', { replace: [[PH, 'and 1 = 1'], ['50    as max_jobs', '2 as max_jobs']] });
  check('scope too broad (3 failed jobs > max_jobs 2) -> abort', /scope matches 3 jobs, more than max_jobs = 2/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);
  await db.exec(`update ACT_RU_JOB set LOCK_OWNER_ = 'node-c', LOCK_EXP_TIME_ = now() + interval '2 minutes' where ID_ = 'job-of3-noinc'`);
  ops = await snapshot(db, OPS_TABLES);
  run = await runScript(db, '30-emergency-job-retries.sql', { replace: [[PH, "and j.ID_ in ('job-of3-noinc')"]] });
  check('scoped job locked by a running node -> abort', /locked by a running node/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);
  await db.exec(`update ACT_RU_JOB set LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null where ID_ = 'job-of3-noinc'`);

  run = await runScript(db, '30-emergency-job-retries.sql', { replace: [[PH, "and j.ID_ in ('job-notify-1')"]] });
  check('job-notify-1 (three-level call-activity chain): runs without error', !run.error, run.error);
  check('warns that another job is locked right now (job executor running?)', run.notices.some((n) => /^WARNING: 1 other job\(s\) are locked/.test(n)), run.notices);
  check('preview lists the 3 incidents of the chain', (rs(run, 'root_incident_id', 'cause_incident_id') ?? []).length === 3);
  let job = (await q(db, `select REV_ as rev, RETRIES_ as retries, LOCK_OWNER_ as lo, LOCK_EXP_TIME_ as le,
                                 DUEDATE_ between localtimestamp - interval '2 minutes' and localtimestamp as due_now,
                                 EXCEPTION_MSG_ as msg from ACT_RU_JOB where ID_ = 'job-notify-1'`))[0];
  check('job: REV_ 4 -> 5, RETRIES_ 3, lock cleared, due now, exception message kept',
    job.rev === 5 && job.retries === 3 && job.lo === null && job.le === null && job.due_now === true && job.msg === 'Mail server unreachable', job);
  check('runtime incidents of the chain deleted (root + 2 parents)',
    (await q(db, `select 1 from ACT_RU_INCIDENT where ROOT_CAUSE_INCIDENT_ID_ = 'inc-n-root'`)).length === 0);
  const hi = await q(db, `select ID_ as id, INCIDENT_STATE_ as s, END_TIME_ as e from ACT_HI_INCIDENT where ROOT_CAUSE_INCIDENT_ID_ = 'inc-n-root'`);
  check('history: 3 rows resolved (INCIDENT_STATE_ 1, END_TIME_ set)', hi.length === 3 && hi.every((r) => r.s === 1 && r.e !== null), hi);
  const old = (await q(db, `select INCIDENT_STATE_ as s, END_TIME_ < localtimestamp - interval '3 days' as old_end
                              from ACT_HI_INCIDENT where ID_ = 'inc-old-resolved'`))[0];
  check('older resolved history row untouched', old.s === 1 && old.old_end === true, old);
  check('other incidents untouched (inc-of3, inc-x-*)', (await q(db, `select ID_ from ACT_RU_INCIDENT`)).length === 4);
  ops = await snapshot(db, OPS_TABLES);
  run = await runScript(db, '30-emergency-job-retries.sql', { replace: [[PH, "and j.ID_ in ('job-notify-1')"]] });
  check('second run -> abort "no job matched", nothing changed', /no job matched the scope/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);

  run = await runScript(db, '30-emergency-job-retries.sql', {
    replace: [[PH, "and j.ID_ in ('job-of3')"], ['true  as resolve_incidents', 'false as resolve_incidents'], ['true  as due_now', 'false as due_now']],
  });
  check('job-of3 with resolve_incidents = false, due_now = false: runs', !run.error, run.error);
  job = (await q(db, `select REV_ as rev, RETRIES_ as retries, DUEDATE_ < localtimestamp - interval '10 minutes' as due_kept
                         from ACT_RU_JOB where ID_ = 'job-of3'`))[0];
  check('job retried, DUEDATE_ kept', job.rev === 5 && job.retries === 3 && job.due_kept === true, job);
  check('incident stays open (runtime + history), like setJobRetriesByJobDefinitionId',
    (await q(db, `select 1 from ACT_RU_INCIDENT where ID_ = 'inc-of3'`)).length === 1
    && (await q(db, `select 1 from ACT_HI_INCIDENT where ID_ = 'inc-of3' and END_TIME_ is null and INCIDENT_STATE_ = 0`)).length === 1);
  run = await runScript(db, '20-find-legacy-references.sql');
  const l8d = rs(run, 'incident_id', 'job_retries') ?? [];
  check('20/L8d now reports inc-of3 "job has retries again"', l8d.length === 1 && l8d[0].incident_id === 'inc-of3' && l8d[0].state === 'job has retries again', l8d);

  // ---------------------------------------------------------------- 31 emergency external task retries
  suite(`${source} / 31-emergency-external-task-retries.sql`);
  const PX = "and e.ID_ in ('REPLACE-WITH-EXTERNAL-TASK-ID')";
  ops = await snapshot(db, OPS_TABLES);
  run = await runScript(db, '31-emergency-external-task-retries.sql');
  check('unedited placeholder -> abort, nothing changed', /no external task matched the scope/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);
  run = await runScript(db, '31-emergency-external-task-retries.sql', { replace: [[PX, "and e.ID_ in ('ext-ship-1')"]] });
  check('ext-ship-1 (unlock = true): runs', !run.error, run.error);
  let ext = (await q(db, `select REV_ as rev, RETRIES_ as r, WORKER_ID_ as w, LOCK_EXP_TIME_ as l, ERROR_MSG_ as m from ACT_RU_EXT_TASK where ID_ = 'ext-ship-1'`))[0];
  check('task: REV_ 5 -> 6, RETRIES_ 3, worker + lock cleared, error message kept', ext.rev === 6 && ext.r === 3 && ext.w === null && ext.l === null && ext.m === 'HTTP 503 from carrier API', ext);
  check('incident resolved (runtime deleted, history state 1)', (await q(db, `select 1 from ACT_RU_INCIDENT where ID_ = 'inc-x-ship'`)).length === 0
    && (await q(db, `select 1 from ACT_HI_INCIDENT where ID_ = 'inc-x-ship' and INCIDENT_STATE_ = 1 and END_TIME_ is not null`)).length === 1);
  run = await runScript(db, '31-emergency-external-task-retries.sql', {
    replace: [[PX, "and e.ID_ in ('ext-charge-1')"], ['true  as unlock', 'false as unlock']],
  });
  check('ext-charge-1 (call-activity chain, unlock = false): runs', !run.error, run.error);
  ext = (await q(db, `select REV_ as rev, RETRIES_ as r, WORKER_ID_ as w, LOCK_EXP_TIME_ as l from ACT_RU_EXT_TASK where ID_ = 'ext-charge-1'`))[0];
  check('task: REV_ 3 -> 4, RETRIES_ 3, worker + lock kept', ext.rev === 4 && ext.r === 3 && ext.w === 'worker-3' && ext.l !== null, ext);
  check('root + parent incident deleted, 2 history rows resolved', (await q(db, `select 1 from ACT_RU_INCIDENT where ROOT_CAUSE_INCIDENT_ID_ = 'inc-x-root'`)).length === 0
    && (await q(db, `select 1 from ACT_HI_INCIDENT where ROOT_CAUSE_INCIDENT_ID_ = 'inc-x-root' and INCIDENT_STATE_ = 1`)).length === 2);
  ops = await snapshot(db, OPS_TABLES);
  run = await runScript(db, '31-emergency-external-task-retries.sql', { replace: [[PX, "and e.ID_ in ('ext-ship-1')"]] });
  check('second run -> abort, nothing changed', /no external task matched the scope/.test(run.error ?? '') && (await snapshot(db, OPS_TABLES)) === ops, run.error);
  run = await runScript(db, '20-find-legacy-references.sql');
  check('20/L8e: no inconsistent external task incidents', (rs(run, 'incident_id', 'ext_task_retries') ?? []).length === 0);
  await db.close();

  // ---------------------------------------------------------------- 00 negative: database still on 7.22
  suite(`${source} / 00-preflight-checks.sql on a 7.22 schema level`);
  db = await newDb(source);
  await db.exec(`delete from ACT_GE_SCHEMA_LOG where ID_ in ('1200', '1300', '1400')`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('NO_GO "schema log is 7.22.0" (missing columns)', summary?.verdict === 'NO_GO' && /schema log is 7\.22\.0/.test(summary?.no_go_reasons)
    && /columns of later upgrade scripts are missing/.test(summary?.no_go_reasons), summary?.no_go_reasons);
  await db.close();

  // ---------------------------------------------------------------- 00 negative: database still on 7.23
  suite(`${source} / 00-preflight-checks.sql on a 7.23 schema level`);
  db = await newDb(source);
  await db.exec(`delete from ACT_GE_SCHEMA_LOG where ID_ in ('1300', '1400')`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('NO_GO "schema log is 7.23.0" (only the marker row missing)', summary?.verdict === 'NO_GO' && /schema log is 7\.23\.0/.test(summary?.no_go_reasons)
    && /7\.23 lacks no DDL/.test(summary?.no_go_reasons), summary?.no_go_reasons);
  await db.close();

  // ---------------------------------------------------------------- 00 negative: an older patch row stays NO_GO
  suite(`${source} / 00-preflight-checks.sql on a 7.23 database with a 7.23.N patch row`);
  db = await newDb(source);
  await db.exec(`delete from ACT_GE_SCHEMA_LOG where ID_ in ('1300', '1400')`);
  await db.exec(`insert into ACT_GE_SCHEMA_LOG (ID_, TIMESTAMP_, VERSION_) values ('1212', now() - interval '150 days', '7.23.12')`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('NO_GO "schema log is 7.23.12" (7.23 lacks no DDL)', summary?.verdict === 'NO_GO' && /schema log is 7\.23\.12, expected 7\.24\.0/.test(summary?.no_go_reasons)
    && /7\.23 lacks no DDL/.test(summary?.no_go_reasons), summary?.no_go_reasons);
  run = await runScript(db, '00-preflight-checks.sql');
  check('gate raises "PREFLIGHT NO_GO"', /^PREFLIGHT NO_GO: schema log is 7\.23\.12/.test(run.error ?? ''), run.error);
  await db.close();

  // ---------------------------------------------------------------- 00 positive: Camunda 7.24 EE patch row, ready for the cut-over
  suite(`${source} / 00-preflight-checks.sql on a 7.24 EE database with a 7.24.N patch row`);
  db = await newDb(source);
  await db.exec(`delete from ACT_GE_SCHEMA_LOG where ID_ = '1400'`);
  await db.exec(`insert into ACT_GE_SCHEMA_LOG (ID_, TIMESTAMP_, VERSION_) values ('1303', now() - interval '20 days', '7.24.3')`);
  // all Camunda nodes stopped, admin group migrated: only the schema level is left to judge
  await db.exec(`update ACT_RU_JOB set LOCK_EXP_TIME_ = now() - interval '1 minute' where LOCK_OWNER_ = 'node-a'`);
  run = await runScript(db, '10-migrate-admin-group.sql');
  check('10-migrate-admin-group.sql runs', !run.error, run.error);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('P01 lists 7.24.3 (ID_ 1303) first', rs(run, 'schema_log_id', 'schema_version')?.[0]?.schema_version === '7.24.3',
    rs(run, 'schema_log_id', 'schema_version')?.[0]);
  check('schema_log_version = 7.24.3', summary?.schema_log_version === '7.24.3', summary?.schema_log_version);
  check('verdict GO_WITH_WARNINGS without any NO-GO reason', summary?.verdict === 'GO_WITH_WARNINGS' && summary?.no_go_reasons === null,
    summary?.no_go_reasons);
  check('no schema-log warning either', !/schema log/.test(summary?.warnings ?? ''), summary?.warnings);
  run = await runScript(db, '00-preflight-checks.sql');
  check('gate passes (psql would exit 0)', !run.error && run.notices.some((n) => /PREFLIGHT GO_WITH_WARNINGS/.test(n)), run.error ?? run.notices);
  // the Operaton 2.2 script on top: ID_ 1400 is newer than 1303
  await db.exec(`insert into ACT_GE_SCHEMA_LOG (ID_, TIMESTAMP_, VERSION_) values ('1400', now(), '7.25.0')`);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('then 7.25.0: GO_WITH_WARNINGS with the "schema log 7.25.0" warning',
    summary?.schema_log_version === '7.25.0' && summary?.verdict === 'GO_WITH_WARNINGS' && /schema log 7\.25\.0/.test(summary?.warnings ?? ''), summary);

  // ---------------------------------------------------------------- P11 is informational: same verdict with and without expression filters
  suite(`${source} / 00-preflight-checks.sql: P11 filters with expressions never change the verdict`);
  const withFilters = summary;
  await db.exec(`delete from ACT_RU_FILTER where QUERY_ like '%Expression":%'`);
  check('3 filters without expressions remain', (await q(db, `select 1 from ACT_RU_FILTER`)).length === 3);
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('filters_with_expressions 4 -> 0, P11 lists no filter',
    Number(withFilters?.filters_with_expressions) === 4 && Number(summary?.filters_with_expressions) === 0
    && (rs(run, 'filter_id', 'expressions') ?? ['missing']).length === 0, [withFilters?.filters_with_expressions, summary?.filters_with_expressions]);
  check('verdict, NO-GO reasons and warnings identical',
    summary?.verdict === withFilters?.verdict && summary?.no_go_reasons === withFilters?.no_go_reasons && summary?.warnings === withFilters?.warnings,
    [withFilters, summary]);
  await db.close();

  suite(`${source} / 00-preflight-checks.sql with standard_conforming_strings = off`);
  db = await newDb(source);
  await db.exec('set standard_conforming_strings = off');
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  check('report runs without error (P11 pattern is an E\'...\' literal)', !run.error, run.error);
  check('P11 expressions unchanged (escaped quotes included)',
    (rs(run, 'filter_id', 'expressions') ?? []).find((r) => r.filter_id === 'flt-deputy')?.expressions
      === 'taskCandidateUser = ${deputyService.deputyOf(currentUser(), \\"order-ops\\")}; dueBefore = ${dateTime().plusDays(2).toDate()}',
    rs(run, 'filter_id', 'expressions'));
  await db.close();

  // ---------------------------------------------------------------- 10, scenario B (partially migrated)
  suite(`${source} / 10-migrate-admin-group.sql on a partially migrated database`);
  db = await newDb(source, { partialMirror: true });
  run = await runScript(db, '00-preflight-checks.sql', { stripGate: true });
  summary = rs(run, 'verdict')?.[0];
  check('00 before: NO_GO "1 camunda-admin member(s) not in operaton-admin" (setup page already closed)',
    /1 camunda-admin member\(s\) not in operaton-admin/.test(summary?.no_go_reasons) && !/nobody is in operaton-admin/.test(summary?.no_go_reasons), summary?.no_go_reasons);
  run = await runScript(db, '10-migrate-admin-group.sql');
  check('runs without error', !run.error, run.error);
  const g2 = await q(db, `select NAME_ as name from ACT_ID_GROUP where ID_ = 'operaton-admin'`);
  check('existing group kept as is (name not overwritten)', g2[0]?.name === 'Camunda Administrators', g2);
  check('members = demo, jane.ops', sameSet((await q(db, `select USER_ID_ as u from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin'`)).map((r) => r.u), ['demo', 'jane.ops']));
  const h2 = await q(db, `select ID_ as id, PERMS_ as p from ACT_RU_AUTHORIZATION where GROUP_ID_ = 'operaton-admin'`);
  check('24 authorizations: 2 pre-existing + 22 new; pre-existing APPLICATION/* row keeps PERMS_ 2',
    h2.length === 24 && h2.find((r) => r.id === 'oa-app-access')?.p === 2, h2.length);
  const idB = await snapshot(db, IDENTITY_TABLES);
  run = await runScript(db, '10-migrate-admin-group.sql');
  check('second run: no change', !run.error && (await snapshot(db, IDENTITY_TABLES)) === idB, run.error);
  await db.close();
}

// ------------------------------------------------------------------------------------------- main
const probe = new PGlite();
const version = (await probe.query('select version()')).rows[0].version;
await probe.close();
console.log(`PGlite: ${version.split(' on ')[0]}`);
for (const source of Object.keys(DDL_SOURCES)) {
  if (onlyDdl && source !== onlyDdl) continue;
  await testSource(source);
}
console.log(`\n${passed} checks passed, ${failures.length} failed`);
if (failures.length) {
  console.log(failures.map((f) => ` - ${f}`).join('\n'));
  process.exit(1);
}
