# Cut-over runbook · Camunda 7.24 → Operaton 2.x (embedded Spring Boot, same database)

This runbook switches production from Camunda 7.24 to Operaton 2.x on the same database, and takes you back if
needed. It is the executable form of [11 · Cut-over, rollback and operations](../docs/11-cutover-rollback-and-operations.md),
written for PostgreSQL and Kubernetes. On the main path, production runs Camunda 7.24 EE (Enterprise Edition) on
Spring Boot 4. A rollback then redeploys the last Camunda EE build, so the runbook also keeps what that build needs:
its license and access to the Camunda EE repository. Use **one copy** for the rehearsals and for production.

**Legend**

- **Owners:** `{{lead}}` cut-over lead, `{{decider}}` rollback decider (the one person who decides on a rollback),
  `{{dba}}` database, `{{ops}}` operations, `{{dev}}` development, `{{sec}}` security, `{{int}}` integrations.
  Replace the placeholders with names.
- **Step IDs follow the timeline:** `P-` preparation (T−14 days), `R-` rehearsal (T−7 days), `F-` freeze (T−1 day),
  `T0-` cut-over day, `H-` hypercare after go-live. `RB-0` is the rollback decision; `R1`, `R2` and `R3` are the
  three rollback paths (R-01 is a rehearsal step, R1-1 a rollback step).
- **Check:** what must be true before you tick a step. **CP1 … CP11** (checkpoints) and **CP-R1** (the check after a
  rollback) are the evidence for the change ticket: record the value or attach the output.
- **P01 … P11** (no hyphen) are sections of the pre-flight script `00-preflight-checks.sql`; P11 is for information
  only and never changes the verdict. **L1 … L9** are sections of `20-find-legacy-references.sql`.
- **EE repository:** Camunda's Enterprise repository (`https://artifacts.camunda.com/artifactory/private/`, server id
  `camunda-bpm-nexus-ee`), the only place that has the `7.24.N-ee` artifacts. The Operaton build no longer needs it,
  but a rebuild or hotfix of the Camunda EE build does.
- **PoNR (point of no return):** the first moment Operaton has written something Camunda 7.24 cannot read or run. Such
  a write is a **hard stop**, e.g. a version with `operaton:` attributes that has running instances. After the PoNR,
  going back means restoring the backup and losing all work since T0.

Set these variables in every shell you use; the commands below rely on them. `BASE_URL` points to a port-forward,
and `WEBAPP_PATH` is the path from your [webapp-path decision (D6)](../docs/01-migration-path-and-decisions.md#d6).
`CAMUNDA_IMAGE` is the last Camunda EE build of the service, the one a rollback redeploys; `OPERATON_IMAGE` is the
Operaton build that goes live.

```bash
export NS=orders APP=order-fulfillment DATABASE_URL='postgresql://ops@db.example.com:5432/orders'
export BASE_URL=http://localhost:8080 WEBAPP_PATH=/camunda    # port-forward; D6
export CAMUNDA_IMAGE=registry.example.com/order-fulfillment:1.42.0
export OPERATON_IMAGE=registry.example.com/order-fulfillment:2.0.0 T0='YYYY-MM-DD HH:MM:SS+HH:MM'
export OPS_USER=ops-smoke OPS_PASSWORD='…'
```

Run every SQL file with `psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f <file>`, **never** with
`--single-transaction`: the scripts manage their own transactions. Snippets that use psql variables
(`:'t0'`/`:'window_start'`) work only when you save them as a file and pass the value with `-v` (`-v t0="$T0"`), not
with `-c`.

## T−14 days · Preparation

**Goal:** prepare every change the cut-over needs (code, configuration, manifests, admin group, decisions, rollback
kit) without switching anything yet. The readiness review at the end confirms it.

- [ ] **P-01 Version gate** `{{dba}}`: run `sql/postgresql/00-preflight-checks.sql` on production. It is read-only.
  NO_GO is expected at this point: nobody is in `operaton-admin` yet, and the running Camunda nodes may hold job
  locks.
  **Check:** P01 shows schema log `7.24.0`. It also accepts a `7.24.N` row, which a Camunda EE patch script would
  write; none is known, because EE patch levels do not change the schema. P02 shows `fox` and the history level; on
  an EE database it also lists the license row `camunda-license-key-id`, which stays. Anything older than 7.24 means
  you first do [Step 0](../docs/01-migration-path-and-decisions.md#step-0--reach-camunda-724-first), the upgrade to
  Camunda 7.24. The database is at least PostgreSQL 14 / MariaDB 10.11 / MySQL 8.4. Attach the P11 list, the stored
  task filters that use expressions, to the [Camunda EE features decision (D17)](../docs/01-migration-path-and-decisions.md#d17):
  it shows which filters break if you switch off expressions in stored queries.
- [ ] **P-02 Code** `{{dev}}`: merge the code conversion, which is one commit. On Spring Boot 3.5 it is two commits
  ([Coming from Spring Boot 3.5](../docs/15-coming-from-spring-boot-3.md)).
  **Check:** `mvn -B verify` is green, `scripts/verify-leftovers.sh .` exits 0, and `mvn dependency:tree` shows no `-RC`
  (`2.2.0-RC1` is for rehearsal builds only). The Operaton build resolves from Maven Central alone, without the EE
  repository.
- [ ] **P-03 Decisions** `{{lead}}`: get these decisions to *Accepted* in the [decision log](decision-log-template.md):
  admin group (D5), webapp path (D6), cut-over strategy (D7), schema management (D8), health probes (D13), support
  model (D14), rollback (D15), Camunda EE features (D17, mandatory on EE) and legacy variables (D18). The rollback
  decision (D15) must name the PoNR events, a time cap and numeric triggers.
- [ ] **P-04 Config PRs** `{{ops}}`: grep deployment repos, Config Server, CI variables and Secrets for `camunda\.bpm`,
  `CAMUNDA_BPM_`, `management\.health\.camunda`, `org\.camunda\.bpm`, `/camunda/`, `camunda-admin`,
  `artifacts\.camunda\.com`, `license-file`, `queryExpressionAllowList`, `allowedExpression`,
  `validate-auth-resource-id-exists`.
  - Open one PR per repo, **not merged**; step T0-08 merges them.
  - Delete the Camunda EE-only engine settings instead of renaming them, because Operaton does not start with them
    ([EE-only engine settings](../docs/04-spring-boot-dependencies-and-configuration.md#ee-only-engine-settings)).
  - Put the mitigation for the missing EE security hardening, as decided in D17, into the production configuration,
    for example the generic property `enable-expressions-in-stored-queries: false`
    ([Security](../docs/07-identity-admin-group-and-security.md#camunda-ee-security-hardening-that-operaton-lacks)).
  - Keep `LegacyCamundaConfigGuard` on, so that a missed `camunda.bpm.*` key fails the start.
- [ ] **P-05 Manifests** `{{ops}}`: prepare the cut-over release.
  - `strategy.type: Recreate`, because the default `RollingUpdate` would run Camunda and Operaton pods side by side.
  - Set the grace period (`terminationGracePeriodSeconds`) to at least the longest job plus 30 s for Spring's
    shutdown phase (`spring.lifecycle.timeout-per-shutdown-phase`), so that Kubernetes does not kill a running job
    ([cut-over strategy](../docs/11-cutover-rollback-and-operations.md#cut-over-strategy-d7)).
  - Configure the probes as decided in [health probes (D13)](../docs/01-migration-path-and-decisions.md#d13).
  - `OPERATON_BPM_DATABASE_SCHEMA_UPDATE=false` ([schema management, D8](../docs/01-migration-path-and-decisions.md#d8)).
  - `OPERATON_BPM_WEBAPP_APPLICATION_PATH=$WEBAPP_PATH`.
  - An ingress rule with its own 403 on `$WEBAPP_PATH/api/admin/setup/*`
    ([Security](../docs/07-identity-admin-group-and-security.md)). It must be its own response: the application's
    CSRF filter also answers 403, even while setup is open.

  **Check:** `kubectl diff` reviewed; block tested on the rehearsal.
- [ ] **P-06 Admin group on a copy** `{{dba}}` `{{sec}}`: test `10-migrate-admin-group.sql` and/or
  `AdminGroupMigrationPlugin`, and the IdP mapping.
  **Check:** `smoke-test.sh` reports the setup page closed; former admins can open Admin.
- [ ] **P-07 Liquibase (if applicable)** `{{dba}}`: run Fix E (sync to the Operaton changelog) or Fix D (keep the old
  changelog path, update the author) and its reverse on a copy
  ([Liquibase fixes](../docs/08-database-schema-data-and-sql-scripts.md#liquibase)).
- [ ] **P-08 Legacy references** `{{dev}}` `{{dba}}`: run `sql/postgresql/20-find-legacy-references.sql` on a replica.
  **Check:** every hit in L1–L5 is either fixed on Camunda 7.24 or recorded as a hard stop in
  [rollback (D15)](../docs/01-migration-path-and-decisions.md#d15). L1–L5 cover variables and byte arrays with
  `org.camunda.*` classes, deployed models and scripts that reference `org.camunda.*` with their running instances,
  and Activiti models. Fixed means: package-free scripts without engine classes, `formRef`, instances migrated, and
  variables handled per [legacy variables (D18)](../docs/01-migration-path-and-decisions.md#d18).
- [ ] **P-09 Observability** `{{ops}}`: make alerts, log filters and JMX rules match both `org.camunda` and
  `org.operaton`; add a synthetic `/engine-rest/version` check. **Check:** a test alert fired.
- [ ] **P-10 Integrations** `{{int}}`: check REST callers, workers, consumers (`org.operaton.*` class names) and
  `/version` gates (clients that expect a `7.` version break on Operaton's `2.x.y`). **Check:** retries confirmed.
- [ ] **P-11 Support model:** decide it ([support model, D14](../docs/01-migration-path-and-decisions.md#d14)).
- [ ] **P-12 T−4 weeks notice:** send it.
- [ ] **P-13 Rollback kit** `{{ops}}` `{{dba}}`: assemble what a rollback needs (details:
  [Rollback and the point of no return](../docs/11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)).
  - Exclude `$CAMUNDA_IMAGE` from registry clean-up; tag the old manifests.
  - Write down the backup procedure; keep the Liquibase reverse SQL and the old alert rules.
  - Keep the license file or secret of the Camunda deployment. Leave the license rows in the database untouched
    (`ACT_GE_BYTEARRAY` resource `camunda-license-key`, `ACT_GE_PROPERTY` `camunda-license-key-id`): Operaton ignores
    them, and the rollback build finds its license there as before.
  - Keep the EE repository reachable with valid credentials until the rollback window closes. A rebuild or hotfix of
    the Camunda EE build fails without them, because its `7.24.N-ee` artifacts exist only there.

**Readiness review** `{{lead}}`: every P-step is done or waived in writing.

## T−7 days · Rehearsal

**Goal:** run the whole cut-over and the rollback on a production copy (a restored snapshot of the production
database, never the live one), with a stopwatch. This proves the steps work and shows whether the downtime fits the
window.

- [ ] **R-01** Restore a fresh production snapshot, isolated, with outbound integrations stubbed. Do the first start
  with `OPERATON_BPM_JOB_EXECUTION_ENABLED=false`.
- [ ] **R-02** Time all T0 steps. **Check:** the maintenance window is at least the total time plus the time of
  rollback path R1.
- [ ] **R-03** Switch job execution on (still stubbed) and time the catch-up burst: timers that fell due during the
  downtime fire together at start. **Check:** no unexpected incidents.
- [ ] **R-04** Rehearse rollback paths R1 and R2 with the last Camunda EE build. **Check:** `smoke-test.sh` passes on
  Camunda and reports the Camunda version (`7.24.N-ee` on EE, `7.24.0` on CE).
- [ ] **R-05** Fix the findings; repeat the rehearsal if code or config changed.
- [ ] **R-06** Send the T−1 week notice.

**Go/no-go 1** `{{lead}}` `{{decider}}`: go only with two clean rehearsals (one with rollback), a downtime that fits,
and no open MUST (a finding that breaks the build, the start, runtime behaviour or security) from
`verify-leftovers.sh`, the pre-flight check or the legacy-reference scan.

## T−1 day · Freeze and baseline

**Goal:** stop all changes to the engine and record the state before the switch. After the cut-over you compare
against this baseline, and a rollback relies on the verified kit.

- [ ] **F-01 Freeze** `{{lead}}`: stop Modeler deploys, releases and batch starts. The freeze holds until the rollback
  window closes, because a new deployment can create a hard stop. To enforce it, deny
  `POST /engine-rest/deployment/create` at the ingress for everyone except the pipeline. This is optional here, but
  [Cut-over, rollback and operations](../docs/11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)
  recommends it.
- [ ] **F-02 Baseline** `{{dba}}`: attach pre-flight P05–P07 (failed work, external tasks, running work) and L9 (the
  summary) of `20-find-legacy-references.sql` to the ticket.
- [ ] **F-03 Burst estimate** `{{dba}}`: count the jobs that fall due during the window, i.e. the catch-up
  burst (`-v window_start=… -v window_end=…`); warn downstream owners if it is large:

  ```sql
  select TYPE_, HANDLER_TYPE_, count(*) from ACT_RU_JOB
   where RETRIES_ > 0 and SUSPENSION_STATE_ = 1
     and DUEDATE_ between :'window_start' and :'window_end'
   group by TYPE_, HANDLER_TYPE_;
  ```

- [ ] **F-04 Batches drained** `{{dev}}`: check that `select count(*) from ACT_RU_BATCH;` is 0, or that every
  remaining batch is known.
- [ ] **F-05 Camunda snapshot** `{{dev}}`: run the read-only `scripts/smoke-test.sh` against production and save the
  output; it reports the Camunda version (`7.24.N-ee` on EE, `7.24.0` on CE). The rollback check CP-R1 compares
  against it.
- [ ] **F-06 Rollback kit verified** `{{ops}}`: check that `$CAMUNDA_IMAGE` is pullable, the manifests are at a Git tag,
  the reverse SQL is at hand, the license file or secret of the Camunda deployment is in place, and the EE
  repository credentials are still valid.
- [ ] **F-07 Roster** `{{lead}}`: name deputies; make sure `{{decider}}` is reachable for the whole window.

**Go/no-go 2** `{{lead}}`: all F-steps are done, and no production incident is in progress.

## T0 · Cut-over

**Goal:** switch production to Operaton without ever running both engines on the database at once, and open traffic
only after the new node has passed every check. Work strictly in sequence and log the time of each step.

- [ ] **T0-01 Maintenance on** `{{ops}}`:
  - Answer 503 at the ingress for the webapps and `/engine-rest`.
  - Put the setup-path block in force (it **stays after go-live**).
  - Scale external-task workers with small retry budgets to 0.
  - Record `T0`.
- [ ] **T0-02 Stop Camunda** `{{ops}}`: scale to 0 and wait until every pod is gone.

  ```bash
  kubectl -n $NS scale deploy/$APP --replicas=0
  kubectl -n $NS wait --for=delete pod -l app=$APP --timeout=300s
  ```

  **CP1:** no Camunda node anywhere (other clusters, cron jobs, batch workers); pre-flight P09 shows no app session.
  Any Camunda node left would form a mixed cluster with Operaton.
- [ ] **T0-03 Job locks** `{{dba}}`: stopped nodes keep their job locks until they expire. Wait `lockTimeInMillis`
  (default 5 min) **or**, only with every engine node down, reset them:

  ```sql
  update ACT_RU_JOB set REV_ = REV_ + 1, LOCK_OWNER_ = null, LOCK_EXP_TIME_ = null
   where LOCK_OWNER_ is not null;
  ```

  **CP2:** `select count(*) from ACT_RU_JOB where LOCK_OWNER_ is not null and LOCK_EXP_TIME_ > CURRENT_TIMESTAMP;` returns 0.
- [ ] **T0-04 Backup** `{{dba}}`: take a snapshot or dump (plus any database sharing the engine's transactions). It is
  the only way back after the PoNR. **CP3:** backup id `__________`.
- [ ] **T0-05 Liquibase or schema marker (if applicable)** `{{dba}}`: with Liquibase, apply Fix E or Fix D, as
  rehearsed. With a 2.2.x target and Flyway or DBA-managed SQL, run `postgres_engine_7.24_to_7.25.sql` (release asset
  `operaton-sql-scripts-7.25.0.tar.gz`) or skip it: it only writes the `7.25.0` marker row to `ACT_GE_SCHEMA_LOG`,
  with no DDL, and the engine ignores that row.
  **CP4:** with Liquibase, `liquibase status` has nothing to run (2.2+: only `7.24-to-7.25`, `7.25.0-tag`).
- [ ] **T0-06 Admin group** `{{dba}}`: run `sql/postgresql/10-migrate-admin-group.sql`. It mirrors `camunda-admin` to
  `operaton-admin`; without it, the setup page lets anyone create an admin user.
  - **Check:** S6 (the script's verification) shows all members and grants mirrored; exit 0. On a mismatch it rolls
    back and exits 3.
  - Run it even if `AdminGroupMigrationPlugin` ships. If you rely on the plugin only, the pre-flight gate (T0-07)
    reports NO_GO with the reason "nobody is in operaton-admin". `{{lead}}` then waives that single reason in
    writing.
- [ ] **T0-07 Pre-flight gate** `{{dba}}`: run `sql/postgresql/00-preflight-checks.sql`, then `echo "exit=$?"`. The
  engine itself checks almost nothing at startup, so this gate decides whether Operaton may start.
  - **Check:** `GO` or `GO_WITH_WARNINGS` (exit 0). The schema check (P01) accepts `7.24.0`, a Camunda EE patch row
    `7.24.N` and, after the 2.2 script of T0-05, `7.25.0` (with a warning). The admin-group check (P03) shows all
    admins mirrored, and the job-lock check (P04) shows no locked job.
  - `NO_GO` (exit 3): stop, fix, repeat.
  - P11 is informational: it lists the stored task filters with expressions and never changes the verdict. If the
    production configuration sets `enable-expressions-in-stored-queries: false` (D17), every filter it lists fails
    with "Expressions are forbidden in stored queries" until it is rewritten.
- [ ] **T0-08 First Operaton node, no traffic** `{{ops}}` `{{dev}}`: merge the config PRs from P-04, then:

  ```bash
  kubectl -n $NS set image deploy/$APP app=$OPERATON_IMAGE
  kubectl -n $NS scale deploy/$APP --replicas=1
  kubectl -n $NS logs -f deploy/$APP | tee t0-first-start.log
  ```

  **CP5:** the log shows the banner `Operaton: (v2.x.y)` and `ENGINE-14014 Starting up the JobExecutor`, with no
  `ERROR` and no `historyLevel mismatch`. `LegacyCamundaConfigGuard` stays silent. `ACT_RE_DEPLOYMENT` has only
  expected rows since `T0` (check any new deployment against the hard stops). If the start fails on an unknown
  generic property such as `queryExpressionAllowListEnabled`, a Camunda EE-only setting is left: delete it, and do not
  set `ignore-unknown-fields: true`, because that hides every other leftover generic property.
- [ ] **T0-09 Health** `{{ops}}`: port-forward and run `curl -s $BASE_URL/actuator/health/readiness`. **CP6:** `UP`,
  including `processEngine`.
- [ ] **T0-10 Parse warm-up** `{{dev}}`: run the loop from
  [the cut-over at a glance](../docs/11-cutover-rollback-and-operations.md#the-cut-over-at-a-glance). The engine parses
  an old version only when something touches it, so the loop parses every definition with runtime data now.
  **CP7:** zero failures.
- [ ] **T0-11 Security** `{{sec}}`: run `scripts/smoke-test.sh --base-url "$BASE_URL" --webapp-path "$WEBAPP_PATH" --user "$OPS_USER" --password "$OPS_PASSWORD" --require-operaton`.
  **CP8:** `admin setup page` PASS (closed); a former admin opens Admin. **Never** POST to the setup endpoint on
  production: if setup is open, the POST creates an admin.
- [ ] **T0-12 Functional smoke** `{{dev}}`: run the same with `--write` (deploys, runs and deletes a tiny `camunda:`
  process), plus a business test process. **CP9:** both are green, and the incidents equal the F-02 baseline plus
  the expected burst.
- [ ] **T0-13 Go/no-go 3** `{{lead}}` `{{decider}}`: **go** if CP1–CP9 passed; otherwise roll back with **R1**
  (rollback before traffic). Record the decision and the time.
- [ ] **T0-14 Open** `{{ops}}` `{{int}}`:
  - Scale out: `kubectl -n $NS scale deploy/$APP --replicas=3`.
  - Point the ingress to the service, **keeping the setup-path block**.
  - Resume the workers.

  **CP10:** the ingress's own 403 on the setup path **and** `smoke-test.sh` via the public URL: setup page closed.
- [ ] **T0-15 First 60 minutes** `{{ops}}` `{{dev}}`: watch the service. **CP11:** error rate, `job-failed` ratio and incidents
  within the agreed rollback triggers; the burst drains.
- [ ] **T0-16 Done:** send the notice. The rollback window is open until the PoNR event or `T0 + 72 h`.

## T+1 h … T+72 h · Hypercare

**Goal:** catch the problems that only real work reveals, and spot the PoNR, while going back without a restore is
still possible.

- [ ] **H-01 T+1 h** `{{dev}}`: confirm that the burst has drained and `noRetriesLeft` jobs are not growing.
- [ ] **H-01b Continuous** `{{ops}}`: keep a synthetic `GET $WEBAPP_PATH/app/admin/default/` that alerts on a
  redirect to `…/setup/`, which means the setup page is open again.
- [ ] **H-02 T+4 h, then daily** `{{dev}}`: group failed jobs (`RETRIES_ = 0`) by `EXCEPTION_MSG_`. **Check:** nothing
  new with `org.camunda`, `ClassNotFoundException`, `unable to resolve class` (legacy references hit at runtime); no
  parser errors logged.
- [ ] **H-03 Daily** `{{dba}}`: run the [compatibility checkpoint C1–C3](#compatibility-checkpoint-c1c3); report the
  first PoNR event to `{{decider}}`.
- [ ] **H-04 T+24 h:** send the summary.
- [ ] **H-05** Confirm the first history-cleanup window ran as before.
- [ ] **H-06 T+72 h or PoNR** `{{decider}}`: close the rollback window in the decision log (rollback decision, D15)
  and lift the freeze. Archive the rollback kit, but keep the backup. Schedule the
  [clean-up](../docs/11-cutover-rollback-and-operations.md#hypercare-and-clean-up); only then delete the license files
  and secrets and revoke the EE repository credentials. The license rows in the database can stay.

## Rollback runbook

**Goal:** go back to Camunda 7.24 on the same database, without a restore, as long as Operaton has written nothing
Camunda cannot run. The path depends on how far you got: **R1** before traffic, **R2** after traffic but before the
PoNR. After the PoNR, **R3** applies: you fix forward instead.

### RB-0 · Decide

- [ ] **Decide** `{{decider}}`:
  1. Match the trigger against the [agreed list](../docs/11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)
     and let the fix time box expire, that is the time the trigger allows for a fix (for example 30 min for a
     checkpoint that still fails).
  2. Decide rollback or fix forward; pick R1, R2 or R3 below.
  3. Record the reason and the time.

### R1 · Before traffic

Use R1 if you roll back before traffic was opened, for example at go/no-go 3. Camunda ignores what Operaton's first
start writes, such as `operaton.installation.id` and the `operaton-admin` rows. It also ignores the `7.25.0`
schema-log row that T0-05 writes for a 2.2.x target. Operaton left the license rows untouched, so the Camunda EE build
finds its license as before.

- [ ] **R1-1** `{{ops}}`: scale Operaton to 0 with `kubectl -n $NS scale deploy/$APP --replicas=0`.
  **Check:** no pod, no app session (P09).
- [ ] **R1-2** `{{dba}}`: release the job locks as in T0-03 (wait or reset). **Check:** lock count 0.
- [ ] **R1-3 Fix D only** `{{dba}}`: reverse the author update (or start Camunda with `spring.liquibase.enabled=false`;
  Fix E needs nothing):

  ```sql
  update DATABASECHANGELOG set AUTHOR = 'Camunda', MD5SUM = null
   where AUTHOR = 'Operaton' and ID in ('7.23-to-7.24', '7.24.0-tag')
     and FILENAME = 'org/camunda/bpm/engine/db/liquibase/camunda-changelog.xml';   -- YOUR FILENAME
  ```

- [ ] **R1-4** `{{ops}}`: revert the config PRs, so that the last Camunda EE build gets its old configuration back,
  including the license file or secret. Run `kubectl -n $NS set image deploy/$APP app=$CAMUNDA_IMAGE` and scale to 1
  (`operaton-admin` rows and setup block can stay).
- [ ] **CP-R1** `{{dev}}`: check the Camunda node: clean log; `smoke-test.sh --webapp-path /camunda` shows no FAIL
  (WARN "not Operaton yet" expected) and reports the Camunda version (`7.24.N-ee` on EE, `7.24.0` on CE); counts
  match F-05.
- [ ] **R1-5** `{{ops}}` `{{int}}`: scale out, open the ingress, resume the workers.

### R2 · After traffic, before the point of no return

Operaton has done real work, so first check that it wrote nothing Camunda cannot run.

- [ ] **R2-1 Compatibility checkpoint** `{{dba}}`: run the read-only SQL below.
  - **Clean:** C3 finds no variables, and no Operaton-only deployment from C1 has running instances in C2. Continue
    with R2-2.
  - **Not clean:** `{{decider}}` chooses one of these:
    - fix forward (preferred);
    - while Operaton runs, migrate the instances on Operaton-only versions back to a Camunda-compatible version
      (Migration API batch), suspend the Operaton-only definitions, convert the variables, and rerun R2-1;
    - restore the backup from T0-04 (CP3), which loses all work since T0.
- [ ] **R2-2** Run R1-1 to R1-3: stop Operaton, release the job locks, reverse Fix D if you used it.
- [ ] **R2-3** Run R1-4 and CP-R1: start the Camunda build and check it. **Check:** counts ≈ F-02; no parse errors in
  the Camunda log.
- [ ] **R2-4** `{{ops}}`: revert ingress/IdP, probes and alerts; resume the workers.
- [ ] **R2-5** `{{decider}}`: tell the business what ran on Operaton.

<a id="compatibility-checkpoint-c1c3"></a>

**Compatibility checkpoint (C1–C3).** Three read-only checks: C1 lists deployments since T0 and whether they are
Operaton-only, C2 counts running instances on them, C3 finds variables only Operaton can read. Run them as a file
with `-v t0="$T0"`.

```sql
-- C1: deployments since T0, Operaton-only?
select d.ID_, d.NAME_, d.DEPLOY_TIME_, b.NAME_,
       position(convert_to('http://operaton.org/schema/1.0/', 'UTF8') in b.BYTES_) > 0 as operaton_namespace,
       position(convert_to('org.operaton.', 'UTF8') in b.BYTES_) > 0                      as operaton_references,
       position(convert_to('operaton-forms:', 'UTF8') in b.BYTES_) > 0                    as operaton_form_keys
  from ACT_RE_DEPLOYMENT d join ACT_GE_BYTEARRAY b on b.DEPLOYMENT_ID_ = d.ID_
 where d.DEPLOY_TIME_ >= :'t0';
-- C2: running instances on them
select p.KEY_, p.VERSION_, p.ID_, count(*)
  from ACT_RE_PROCDEF p join ACT_RU_EXECUTION e on e.PROC_DEF_ID_ = p.ID_ and e.ID_ = e.PROC_INST_ID_
 where p.DEPLOYMENT_ID_ in (select ID_ from ACT_RE_DEPLOYMENT where DEPLOY_TIME_ >= :'t0')
 group by p.KEY_, p.VERSION_, p.ID_;
-- C3: variables only Operaton can read
select TYPE_, TEXT2_, count(*) from ACT_RU_VARIABLE where TEXT2_ like '%org.operaton.%' group by TYPE_, TEXT2_;
select count(*) from ACT_RU_VARIABLE v join ACT_GE_BYTEARRAY b on b.ID_ = v.BYTEARRAY_ID_
 where v.TYPE_ = 'serializable' and position(convert_to('org.operaton.', 'UTF8') in b.BYTES_) > 0;
```

### R3 · After the point of no return

Camunda can no longer run what Operaton wrote, so you fix forward.

- [ ] **Fix forward:** Cockpit/API, instance migration, hotfixes. Use the emergency SQL for job retries
  ([`30-…`](../sql/postgresql/30-emergency-job-retries.sql)) and external-task retries
  ([`31-…`](../sql/postgresql/31-emergency-external-task-retries.sql)) only when the API is down ([emergency SQL rules](../docs/08-database-schema-data-and-sql-scripts.md#emergency-sql-strict-rules-of-use)). Restoring the backup is
  disaster recovery.
