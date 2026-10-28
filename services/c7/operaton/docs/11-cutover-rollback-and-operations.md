# 11 · Cut-over, rollback and operations

This chapter explains how production moves from Camunda 7.24 to Operaton 2.x on the same database, what happens to
work in flight, how far back you can go, and what changes for operations afterwards. On the main path, production
runs Camunda 7.24 EE (Enterprise Edition) on Spring Boot 4, so the chapter also covers what the cut-over means for
the EE features and what a rollback to Camunda EE needs. It is for the cut-over lead, ops, the DBA and whoever makes
the rollback call. The [cut-over runbook](../checklists/cutover-runbook.md) has the steps with owners, commands and
gates; this chapter gives the reasons.

**In short**
- **Switch production in one event on the same database** ([cut-over strategy, D7](01-migration-path-and-decisions.md#d7)):
  stop all Camunda nodes, run the admin-group SQL and the pre-flight gate, then start **one** Operaton node without
  traffic. No schema change is needed, because the schema is identical; with a 2.2.x target you run one script that
  only adds a `7.25.0` marker row. **Never run a mixed Camunda/Operaton cluster**, with both engines on the database
  at once.
- **Work in flight survives, with delays.** Jobs that Camunda had locked stay locked until the lock expires (default
  5 min), and timers that fell due during the downtime fire as a burst when Operaton starts.
- **Rollback means redeploying the last Camunda EE build on the same database**, until Operaton writes something
  Camunda cannot read or run ([rollback and point of no return, D15](01-migration-path-and-decisions.md#d15)). If you
  renamed script imports to `org.operaton.*` or form keys to `operaton-forms:`, the first Operaton start deploys such
  a version. Keep what the rollback build needs until the rollback window closes: its image, its license, and access
  to the Camunda EE repository with valid credentials.
- **The Camunda EE features are gone from the first Operaton start**: the EE screens in Cockpit, Optimize, the license
  and the EE security hardening. Settle the
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17) before the cut-over, because there is
  no transition period.
- **Observability is mostly renames** (logger names, JMX domain). Since 2.1, `processEngine` health goes DOWN when
  the database fails, so use it for readiness only ([health probes, D13](01-migration-path-and-decisions.md#d13)).

## What to do

1. **Record the decisions** on cut-over strategy (D7), health probes (D13), support model (D14), rollback (D15) and
   Camunda EE features (D17) in the [decision log](../checklists/decision-log-template.md), with rollback triggers
   and one rollback decider, so that nobody has to negotiate during the cut-over.
2. **Ship script and form-key fixes engine-neutral on Camunda 7.24 before the cut-over**, as described in
   [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md), and clear the hits of
   [`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql), so that the way back stays
   open.
3. **Rename the configuration outside the repository** ([Infrastructure](#infrastructure)), because Operaton silently
   ignores `camunda.bpm.*` keys. Delete the Camunda EE-only engine settings instead of renaming them, because as
   generic properties they stop the Operaton start. Keep
   [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java)
   on: it stops the start when such a key is left.
4. **Prepare probes, alerts that match both the old and the new names (`org.camunda` and `org.operaton`), and an
   ingress block on `<app-path>/api/admin/setup/*`.** With users in the engine database, nobody is in `operaton-admin`
   after the switch until you mirror the group. Meanwhile the Admin webapp opens a setup page that lets anyone create an
   admin user without logging in. The block keeps it unreachable even if the admin-group step fails. Details:
   [Identity, admin group and security](07-identity-admin-group-and-security.md).
5. **Prepare the users of the EE features for day one** ([Camunda EE features at the cut-over](#camunda-ee-features-at-the-cut-over)):
   the REST replacements for the EE screens in Cockpit, and the mitigation for the missing query-expression
   allow-list. Keep the rollback kit for Camunda EE (image, license, EE repository access) until the window closes.
6. **Rehearse the [runbook](../checklists/cutover-runbook.md) twice on a fresh production copy**, once including the
   rollback, and measure the downtime. A production copy is a restored copy of the production database, never the live
   one.
7. **Cut over**, then go through [hypercare and clean-up](#hypercare-and-clean-up).

## How the switch works

**One switch on the same database.** Camunda 7.24 and Operaton use the same tables and DDL, so the cut-over is mostly
an application deployment, not a data migration. You stop every Camunda node and prepare the database. First you
mirror the admin group: you copy the members and grants of `camunda-admin` to `operaton-admin`, because Operaton's
webapps only treat `operaton-admin` as administrators. Then you run the pre-flight gate, read-only checks that must
end in `GO` or `GO_WITH_WARNINGS`. Only then do you start the Operaton build against the same database. Running
instances, jobs, timers and tasks are rows in that database, and Operaton picks them up.

**No mixed cluster.** A mixed cluster means Camunda and Operaton nodes working on the same database at the same time.
Every node takes jobs from the same job table, so a job runs on whichever engine grabs it. Camunda cannot run
definitions with `operaton:` attributes or scripts that use `org.operaton.*`, and neither engine can read the other's
Java-serialized classes.

**Rollback and the point of no return.** A rollback needs no restore as long as Operaton has written nothing that
Camunda 7.24 cannot read or run. Such a write is a **hard stop**, and the first one is the **point of no return**
(PoNR). After it, going back means restoring the backup and losing all work since the cut-over. **Hypercare** is the
watch period after the cut-over, while rollback is still possible.

## Engine facts

Three properties of both engines decide how the cut-over must work:

- **There is no version gate.** At startup, both engines only check `schema.version = 'fox'`, which every Camunda 7
  database has. Nothing stops Camunda and Operaton nodes from sharing a database. A database on Camunda 7.22 or older
  also starts, but then fails at runtime with SQL errors on missing columns. The schema-level check (P01) of the
  pre-flight gate is therefore your gate.
- **Definitions are parsed lazily.** The engine parses a process definition only the first time something needs it
  after a start. A broken old version therefore fails only when something touches it, for example a timer days later.
- **Namespaces are compatible in one direction only.** Operaton reads both `camunda:` and `operaton:` attributes.
  Camunda 7.24 silently ignores `operaton:` attributes, so it cannot run `operaton:` definitions.

## Cut-over strategy (D7)

The [cut-over strategy decision (D7)](01-migration-path-and-decisions.md#d7) chooses how production moves to
Operaton. There are four options:

- **A · Big bang on the same database: recommended.** Stop every Camunda node, then start Operaton. Rehearse it at
  least twice with option D (blue/green on a database copy, below). The downtime is the time to stop, back up,
  start and smoke-test, plus up to 5 min until Camunda's job locks expire.
- **B · Rolling update or mixed cluster: no.** Nobody has tested it. Jobs run on either engine, and `operaton:`
  deployments and fixed scripts break the Camunda nodes.
- **C · App by app on a shared database (`deployment-aware`): only if joint downtime is impossible**, and only with
  the constraints below. With `deployment-aware` job execution, each engine runs only the jobs of deployments it has
  registered, so one application can move to Operaton while another still runs on Camunda.
- **D · Blue/green on a database copy: rehearsal only.** The copy starts to diverge from production as soon as both
  process work, and two engine databases cannot be merged.

Kubernetes' default `RollingUpdate` starts the new pods while the old ones still run, which creates a mixed cluster.
Use `Recreate` for the cut-over release. Kubernetes kills the container after `terminationGracePeriodSeconds`, so set
it above the longest job duration plus Spring's shutdown-phase timeout:

```yaml
spec:
  strategy:
    type: Recreate          # back to RollingUpdate afterwards
  template:
    spec:
      terminationGracePeriodSeconds: 120   # ≥ longest job + spring.lifecycle.timeout-per-shutdown-phase
```

**Constraints for option C:**
- Keep `camunda:` namespaces and package-free scripts in **all** apps until the last one moves. A package-free script
  references no `org.camunda.*` or `org.operaton.*` class, so it runs on both engines. This matters because cross-app
  calls run the other app's BPMN in your JVM.
- Populate both admin groups, because Camunda's webapps check `camunda-admin` and Operaton's check `operaton-admin`.
- Check that `managementService.getRegisteredDeployments()` covers every deployment that owns jobs. Jobs of a
  deployment that no node has registered never run.

## In-flight work

Nothing in flight is lost, because it all lives in the shared database. You manage the timing, and the few items
that Operaton cannot run:

- **Jobs locked by Camunda.** A shutdown does not unlock them: they stay locked until `LOCK_EXP_TIME_`
  (`lockTimeInMillis`, default 5 min). Wait, or reset the locks with **all** nodes down
  ([runbook step T0-03](../checklists/cutover-runbook.md#t0--cut-over)).
- **A job killed mid-run.** Its transaction rolls back, and the job runs again after its lock expires. Use a graceful
  shutdown. Whether the starter lets a running job finish when the application shuts down was not verified, so also
  make delegates idempotent: running a side effect twice must do no harm.
- **Timers that fall due during the window.** They all fire at the first start, as a **catch-up burst**. Count them at
  the freeze, warn the downstream systems, start one replica first, and size the `operaton.bpm.job-execution.*` pool.
- **External tasks.** The lock is in the database, so a worker that fetched a task from Camunda can complete it on
  Operaton with the same `workerId`. Camunda's clients keep working against Operaton. Pause workers that fail fast
  (`handleFailure`), because their calls fail during the downtime and turn into incidents.
- **Old versions with `org.camunda.*` scripts or in the `activiti:` namespace.** They fail when an instance reaches
  them. Sections L3–L5 of `20-find-legacy-references.sql` find them, and L4 also lists the running work on them.
  Migrate those instances **before** the cut-over.
- **Java-serialized `org.camunda.*` variables.** Operaton cannot load them and fails with `ClassNotFoundException`.
  Convert them on Camunda 7.24 or drain them, that is, let the affected instances finish on Camunda
  ([variables with `org.camunda.*` objects, D18](01-migration-path-and-decisions.md#d18)).

## Camunda EE features at the cut-over

Operaton is a fork of Camunda 7 CE (Community Edition), so the EE parts of your stack stop working at the moment the
first Operaton node starts. There is no period in which both are available, because Camunda and Operaton never run on
the database at the same time. The [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17) is
mandatory for everyone on Spring Boot 4; this section lists what it means for cut-over day.

- **The EE screens in Cockpit are missing from day one**: history view, heatmap, instance modification, migration
  UI, batches and reports. Optimize is not supported. The build gives no warning, because the recipe maps the EE
  webapps to the CE webapps. Tell the users before cut-over day, and have the REST replacement for each screen tested
  ([Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features)).
- **The EE security hardening is gone from the first start.** Operaton has no query-expression allow-list, no
  `validateAuthResourceIdExists` and no datasource autocommit check. Stored task filters evaluate any expression
  again. The mitigation must be in the configuration of the first Operaton node: the generic property
  `enable-expressions-in-stored-queries: false` unless your filters need expressions such as `${currentUser()}` (the
  pre-flight check P11 lists them), `enable-expressions-in-adhoc-queries` kept false, restricted rights to create and
  update filters, and `spring.datasource.hikari.auto-commit: false`. Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).
- **EE-only engine settings stop the start.** As generic properties, `queryExpressionAllowListEnabled`,
  `allowedExpression…InQueries` and `validateAuthResourceIdExists` make the engine fail at startup, because Operaton
  does not know them. Inside the repository, the recipe carries them over unchanged, and `scripts/verify-leftovers.sh`
  reports them as MUST-FIX findings. Outside the repository (Helm values, ConfigMaps, Config Server) the recipe changes
  nothing, so delete them when you rename that configuration by hand. Details:
  [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md#ee-only-engine-settings).
- **The license stays in the database.** Operaton needs no license and ignores the license rows
  (`ACT_GE_BYTEARRAY` resource `camunda-license-key`, `ACT_GE_PROPERTY` `camunda-license-key-id`). Leave them, and
  keep the license file or secret of the Camunda deployment, because the rollback build needs them. Remove the file
  and the secret in the [clean-up](#hypercare-and-clean-up); the rows can stay.

## The cut-over at a glance

Cut-over day follows a fixed order that protects the database: no Operaton node starts before every Camunda node is
gone, the backup exists, the admin group is mirrored and the pre-flight gate says GO. The
[runbook](../checklists/cutover-runbook.md) has each step with an owner, a command and a checkpoint. In outline:

1. Switch on the maintenance page and block the setup path at the ingress.
2. Stop all Camunda nodes.
3. Handle the job locks: wait until they expire, or reset them.
4. Take a backup.
5. If you use Liquibase, apply the Liquibase fix
   ([Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md#liquibase)). With a 2.2.x
   target, run `<db>_engine_7.24_to_7.25.sql` unless Liquibase applies it. The script only writes the `7.25.0` marker
   row (no DDL), and `scripts/migrate.sh` reminds you of it.
6. Mirror the admin group.
7. Run the pre-flight gate, and continue only on `GO` or `GO_WITH_WARNINGS`.
8. Start one Operaton node, without traffic.
9. Check the startup log, run the parse warm-up and the smoke test.
10. Decide go or no-go. On no-go, roll back with path R1, the rollback before traffic (see
    [rollback paths](#rollback-and-the-point-of-no-return)).
11. Scale out, open traffic (**the setup-path block stays**) and resume the workers.

These are the commands for steps 6 to 9 (numbered 1 to 4 in the comments):

```bash
# Scripts manage their own transactions: never --single-transaction.
# 1. Admin group (D5): camunda-admin → operaton-admin; idempotent; rolls back and exits 3 on a mismatch
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/10-migrate-admin-group.sql

# 2. Pre-flight gate, read-only: GO / GO_WITH_WARNINGS = exit 0, NO_GO = exit 3.
#    P03 all admins mirrored, P04 no locked job. With DB identity, a run before step 1 says NO_GO ("nobody is in operaton-admin").
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/00-preflight-checks.sql

# 3. First node (port-forward, no traffic), parse warm-up of every definition with runtime data; non-200 = NO-GO candidate
psql "$DATABASE_URL" -X -At -c "
  select distinct PROC_DEF_ID_ from ACT_RU_EXECUTION
  union select distinct PROCESS_DEF_ID_ from ACT_RU_JOB where PROCESS_DEF_ID_ is not null" |
while read -r id; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -u "$OPS_USER:$OPS_PASSWORD" \
         "http://localhost:8080/engine-rest/process-definition/$id")
  [ "$code" = 200 ] || echo "FAILED ($code): $id"
done   # DMN: /engine-rest/decision-definition/{id}

# 4. Smoke test
scripts/smoke-test.sh --base-url http://localhost:8080 --webapp-path /camunda \
  --user "$OPS_USER" --password "$OPS_PASSWORD" --require-operaton --write
```

The **parse warm-up** counters lazy parsing: it requests every definition that still has running executions or jobs,
which makes the engine parse it now, inside the maintenance window, instead of days later. It does not catch
`org.camunda.*` inside scripts, because the engine compiles a script only when a token reaches it. Sections L3 and L4
of `20-find-legacy-references.sql` find those.

`smoke-test.sh` reports FAIL if the **admin setup page is open**. It only reads and never POSTs to the setup endpoint,
because on an open setup page a POST would create an administrator. With `--require-operaton` it also fails on a `7.x`
version (Camunda EE answers with `7.24.N-ee`), which means Camunda still answers. `--write` deploys, runs and deletes
a tiny `camunda:` process.

**Startup log** (runbook checkpoint CP5): if models changed since 7.24, the first start creates a new deployment.
Check it against the hard stops below, because a new version that Camunda cannot run ends the option to roll back as
soon as it gets instances.

## Rollback and the point of no return

The schema is identical, and Camunda ignores what Operaton's first start writes: `operaton.installation.id`, the
`operaton-admin` rows and the `history-cleanup` job. It also ignores the `7.25.0` schema-log row of a 2.2.x target.
In the other direction, Operaton ignores the Camunda EE license rows, so the rollback build finds its license in the
database as before. That changes once Operaton writes one of the items in the table. Without a backup restore, a
**hard** stop can only be undone by migrating the affected instances back (or converting the variables) while Operaton
still runs. A **soft** stop can be reversed with the step shown.

| Written by Operaton | What Camunda 7.24 does with it | Stop |
|---|---|---|
| `operaton:` deployment with instances | ignores the attributes, so delegates and listeners are missing | **hard** |
| Version with `org.operaton.*` in scripts or class attributes, instances not past that step | the script or class fails | **hard** |
| Version with `operaton-forms:` keys and open tasks | cannot load the form | **hard** |
| `serializable` variables with `org.operaton.*` classes | `ClassNotFoundException` | **hard** |
| Liquibase Fix D (the author update in `DATABASECHANGELOG`) | the rollback build's Liquibase fails | soft: reverse SQL or `spring.liquibase.enabled=false` |
| Deleted `camunda-admin` rows | Camunda admins lose their rights | soft: restore the rows |
| Webapp path moved to `/operaton` | old URLs return 404 on the rollback build | soft: revert ingress and identity provider (IdP) |

> [!WARNING]
> **Your fixed models are the first hard stop.** Renaming script imports to `org.operaton.*` (or keys to
> `operaton-forms:`) makes the first Operaton start deploy a version Camunda cannot run. Ship package-free scripts
> (only `S(…)` is pre-bound on both engines; `JSON(…)`/`XML(…)` are JUEL-only) and `formRef` on Camunda 7.24
> **before** the cut-over, and migrate the running instances there.

**The end of the rollback window** ([rollback decision, D15](01-migration-path-and-decisions.md#d15)) is whichever
comes first: the point of no return (the first hard stop), a soft stop you will not reverse under pressure, or the
**time cap** (e.g. 72 h). The time cap exists because, after a while, so much business work has run on Operaton that a
rollback is riskier than fixing forward. Until the window ends, **freeze deployments**, because a new deployment can
create a hard stop. Enforce the freeze by denying `POST /engine-rest/deployment/create` at the ingress for everyone
except the pipeline.

**Rollback triggers.** Agree on them with numbers before cut-over day (T0), so that nobody has to argue during the
cut-over. Examples to adapt:
- a checkpoint still fails 30 min after the start;
- the setup page cannot be closed;
- warm-up failures on definitions with running instances;
- `job-failed` > 5 % of `job-successful` for 15 min, or incidents > baseline + 20 with
  `ClassNotFoundException`/`org.camunda` in the message;
- a critical integration is broken for 30 min;
- the job backlog is still growing 1 h after the burst.

**Not** triggers: one broken script (fix it forward), cosmetic webapp differences, and the expected burst.

**Rollback paths.** Which way back you take depends on how far the cut-over got. The
[rollback runbook](../checklists/cutover-runbook.md#rollback-runbook) has the commands and the
[compatibility checkpoint C1–C3](../checklists/cutover-runbook.md#compatibility-checkpoint-c1c3): three read-only
queries for Operaton-only deployments since the cut-over (C1), running instances on them (C2) and variables only
Operaton can read (C3).
- **R1 · before traffic:** scale Operaton to 0, release the job locks, reverse Liquibase Fix D if you applied it,
  deploy the last Camunda EE image with its old configuration (including the license file or secret), and run the
  smoke test.
- **R2 · after traffic, before the point of no return:** run checkpoint C1–C3 first.
  - Clean: continue as in R1, then revert ingress, probes and alerts.
  - Not clean: fix forward (preferred), or migrate the instances back to a Camunda-compatible version with a
    Migration API batch while Operaton runs, then continue with R1. Restoring the T0 backup instead loses all work
    since T0.
- **R3 · after the point of no return:** fix forward.

**What the rollback build needs.** On the main path, the rollback build is the last Camunda EE build. Keep everything
it depends on until the rollback window closes. The rollback kit of the runbook (assembled in step P-13, verified in
step F-06) holds these items:

- **The image** in the registry, excluded from clean-up, with the manifests at a Git tag.
- **The license**: the license file or secret of the Camunda deployment, and the license rows in the database (see
  above).
- **The Camunda EE repository and valid credentials.** The Operaton build no longer needs them, but a hotfix or a
  rebuild of the Camunda EE build does, because its `7.24.N-ee` artifacts exist only in that repository. Revoke the
  credentials in the [clean-up](#hypercare-and-clean-up), not before.

After a rollback, the EE features of that build are back.

## Observability

Prepare monitoring before the cut-over, so that alerts and dashboards work for both Camunda and Operaton, also after a
rollback. Most changes are renames:

- **Logs:** `org.camunda.{bpm,spin,connect,commons}` → `org.operaton.…`; **FEEL stays `org.camunda.feel`**.
  - The recipe renames the logger names in `logback*.xml`/`log4j2*.xml`. Rename `LOGGING_LEVEL_ORG_CAMUNDA_BPM_*`
    environment variables yourself.
  - During the transition, let log shipping filters, alerts and APM match `^org\.(camunda|operaton)\.bpm\.`, so that
    they work for both engines.
  - Message codes, MDC keys, metric names and REST payloads are unchanged. Prefer alerts on `ENGINE-…` codes, because
    they survive the rename.
- **`GET /engine-rest/version`** returns `2.x.y`. Use it as a post-deploy check and as a synthetic monitor that shows
  which product serves production. Clients and integrations that expect a version starting with `7.` break.
- **Health probes** ([D13](01-migration-path-and-decisions.md#d13)): since 2.1, `processEngine` reports DOWN when the
  database is unreachable. Keep it out of liveness, or every pod restarts during a database failover:

  ```yaml
  management:
    health.operaton.enabled: true          # management.health.camunda.* is ignored
    endpoint.health.group:
      liveness.include: livenessState
      readiness.include: readinessState,db,processEngine
  ```

  Point liveness at `/actuator/health/liveness` and readiness at `/actuator/health/readiness`, never at the aggregate.
  Naming `jobExecutor` in a group on nodes with job execution off fails the start, because those nodes have no job
  executor to report on. Replace `HEALTHCHECK`s that call webapp pages: they depend on the webapp path and say nothing
  about the engine.
- **JMX:** the domain is now `org.operaton.bpm.platform…`. Match both domains in your exporter rules.
- **History cleanup:** check that the first cleanup window after the cut-over runs as before. Manual cleanup needs
  membership in `operaton-admin`.

## Infrastructure

The recipes convert your code and the configuration files in the repository. These items live mostly outside it, in
deployment tooling, the identity provider and the pipeline, so work through them by hand before the cut-over:

- [ ] **Configuration outside the repo** (Helm, ConfigMaps, Secrets, Config Server, CI): rename every
  `CAMUNDA_BPM_*` → `OPERATON_BPM_*`. A leftover is **silently ignored**, and Operaton's default applies instead. You
  then see jobs running on REST-only nodes, `/camunda` returning 404, `historyLevel mismatch`, or an empty schema
  created because the schema name was ignored. Inside the repo, `scripts/migrate.sh --with-infra-env` covers
  Dockerfiles, `.env`, compose and k8s/Helm YAML. Details:
  [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).
- [ ] **Ingress:** keep the `/camunda` path for the cut-over
  ([webapp path, D6](01-migration-path-and-decisions.md#d6)). Block the setup path from T0; keeping the block
  permanently is fine.
- [ ] **SSO:** update IdP redirect URIs that contain `/camunda/`, rename the `camunda.bpm.oauth2.*` keys, and map the
  IdP admin group to `operaton-admin`.
- [ ] **Image:** use a JDK 17+ base image and `OPERATON_BPM_*` in the `ENV` lines.
- [ ] **CI/CD:**
  - Build the Operaton application from Maven Central only: remove the Camunda EE repository
    (`artifacts.camunda.com`, server id `camunda-bpm-nexus-ee`), its `<server>` credentials and the CI secrets from
    its build. `scripts/verify-leftovers.sh` reports what is left as `EE_REPOSITORY`. Keep the credentials themselves
    until the rollback window closes, because the Camunda EE rollback build may still need them (see
    [What the rollback build needs](#rollback-and-the-point-of-no-return)).
  - **Pin versions**, because Maven's `<release>` metadata can point to a release candidate (RC).
    [`scripts/latest-versions.sh`](../scripts/latest-versions.sh) prints the current versions.
  - Run `smoke-test.sh --require-operaton` after each deployment, so that a pipeline never reports success for an
    environment that still runs Camunda.
  - Block Operaton 1.x in production ([target version and path, D1](01-migration-path-and-decisions.md#d1)).
- [ ] **Scanners:** allow-lists need both `org.operaton` and `org.camunda`, because `org.camunda.feel` remains.

## Support

Operaton has no LTS (long-term support) line. A minor version ships every six months, and monthly patches cover only
the current minor. Plan a monthly patch slot, and choose the version line as described in
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md). Decide between community and commercial support
**before** go-live ([support model, D14](01-migration-path-and-decisions.md#d14)). Coming from Camunda EE, this
decision replaces your EE subscription, under which Camunda maintains 7.24 until 13 Apr 2030. Providers and the
comparison are in [Ecosystem, support and resources](14-ecosystem-support-and-resources.md).

## Hypercare and clean-up

**Hypercare:** work through runbook steps H-01 to H-06 until the rollback window closes; the failed-job check (H-02)
and the compatibility checkpoint (H-03) repeat daily. The steps check that the catch-up burst has drained, that the
setup page stays closed, that no failed jobs point to `org.camunda` leftovers, and whether the point of no return has
been reached. H-06 closes the window and lifts the deployment freeze.

**Clean-up** removes what you kept only for the migration. Do it in normal releases after the rollback window has
closed, because until then a rollback still needs these items:
1. Lift the deployment freeze (if runbook step H-06 has not done so already), and set the Kubernetes strategy back
   to `RollingUpdate`.
2. Remove the `camunda-admin` rows with the commented block in `10-migrate-admin-group.sql`.
3. Remove `AdminGroupMigrationPlugin`, later `LegacyCamundaConfigGuard`, and the alert rules that match both
   `org.camunda` and `org.operaton`. Keep the setup-path block.
4. Optionally move the webapps to `/operaton` with a redirect
   ([webapp path, D6](01-migration-path-and-decisions.md#d6)), and convert namespaces and form keys one deployment
   unit at a time ([BPMN/DMN namespace, D3](01-migration-path-and-decisions.md#d3)).
5. Delete the Camunda EE license files, mounts and secrets, and revoke the EE repository credentials in CI and in
   the Maven settings. The license rows in the database can stay, because Operaton ignores them.
6. In the decision log, record that the follow-up work of the admin-group, webapp-path, cut-over, rollback and EE
   features decisions (D5, D6, D7, D15, D17) is done.

## Watch out

Each entry names the symptom you see, its cause and the fix.

- **Symptom:** a Camunda node logs
  `One of the attributes 'class', 'delegateExpression', 'type', or 'expression' is mandatory on serviceTask`.
  **Cause:** Camunda is parsing an `operaton:` deployment, either in a mixed cluster from `RollingUpdate` or after a
  rollback past a hard stop.
  **Fix:** use `Recreate` or scale to 0. Before a rollback, migrate the instances back.
- **Symptom:** all pods restart during a database failover.
  **Cause:** `processEngine` is in the liveness group.
  **Fix:** move it to readiness ([health probes, D13](01-migration-path-and-decisions.md#d13)).
- **Symptom:** `historyLevel mismatch: configuration says full and database says audit`.
  **Cause:** `CAMUNDA_BPM_HISTORY_LEVEL` was ignored, so the default `full` applies.
  **Fix:** set `OPERATON_BPM_HISTORY_LEVEL`, and look for other leftovers.
- **Symptom:** the first Operaton node does not start because of an unknown generic property such as
  `queryExpressionAllowListEnabled` or `validateAuthResourceIdExists`.
  **Cause:** Camunda EE-only engine settings were carried over: by the recipe inside the repository, or with the rest
  of the configuration outside it. Operaton binds generic properties strictly, so it stops on names it does not know.
  **Fix:** delete these settings, and do not set `ignore-unknown-fields: true` to get past the error, because it would
  hide every other leftover generic property. Put the mitigation for the missing EE hardening in place instead
  ([Camunda EE features at the cut-over](#camunda-ee-features-at-the-cut-over)).
- **Symptom:** after go-live, Cockpit users report that the history view, heatmap, instance modification or migration
  UI is missing.
  **Cause:** Operaton has only the CE webapps; the recipe mapped the EE webapps to them without an error.
  **Fix:** point the users to the REST replacements prepared for the
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17)
  ([Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features)).
- **Symptom:** a hotfix of the Camunda rollback build fails with `401` or `403` from `artifacts.camunda.com`.
  **Cause:** the EE repository credentials were revoked before the rollback window closed.
  **Fix:** restore the credentials, and revoke them only in the [clean-up](#hypercare-and-clean-up).
- **Symptom:** the Admin webapp shows "create initial admin user".
  **Cause:** `operaton-admin` is empty.
  **Fix:** stop before opening traffic, and run `10-migrate-admin-group.sql`
  ([admin group, D5](01-migration-path-and-decisions.md#d5)).
- **Symptom:** the rollback build fails with `unable to resolve class org.operaton.spin.Spin`, or forms fail with
  "does not reference a deployed form".
  **Cause:** Operaton deployed `org.operaton.*` scripts or `operaton-forms:` keys.
  **Fix:** migrate those instances back first.
- **Symptom:** the rollback build fails in Liquibase.
  **Cause:** Liquibase Fix D changed the changeset author.
  **Fix:** reverse the author update (runbook step R1-3).
