# Migration checklist · Camunda 7 (embedded, Spring Boot) → Operaton

This checklist takes one service through the eight migration phases. It follows the main path: Camunda 7.24
Enterprise Edition (EE) on Spring Boot 4, converted to Operaton 2.x in one code change and switched in one production
cut-over on the same database. Keep one copy per service; services that share a database also share *Rehearse* and
*Cut-over*, because they switch together. The sections have the same names and order as the eight steps in the
[README](../README.md#step-by-step) and the [phased plan](../docs/01-migration-path-and-decisions.md#3-phased-plan),
which explains each phase and decision.

**Service:** ________  **Owner:** ________  **Target:** Operaton ______ / Spring Boot ______  **Cut-over date:** ________

**Legend.** *D1–D18* are the 18 migration decisions in the [decision log](decision-log-template.md). *MUST* findings
break the build, the start, runtime behaviour or security if you skip them. A *production copy* is a restored copy of
the production database, never the live one. *PoNR* (point of no return) is the first moment Operaton has written
something Camunda 7.24 cannot read or run; a change that writes such data is a *hard stop*. The *EE repository* is
Camunda's Enterprise repository (`https://artifacts.camunda.com/artifactory/private/`, server id
`camunda-bpm-nexus-ee`), the only place that has the `7.24.N-ee` artifacts.

## 1 · Assess

**Goal:** know what the migration involves before you change code. The results size the work, show which path and
Operaton target apply, and feed the decisions in *Decide and prepare*.

- [ ] **Confirm that code *and* database are on Camunda 7.24:** the first row of
  `select VERSION_ from ACT_GE_SCHEMA_LOG order by cast(ID_ as integer) desc` is `7.24.0`, and the code runs Camunda
  7.24 EE, patch 7.24.3-ee or later, with the Spring Boot 4 starters (the ones with a `-4` infix). EE patch levels do
  not change the schema, so `7.24.0` is the expected value on every `7.24.N-ee` patch (the pre-flight check also
  accepts a `7.24.N` patch row, which no known patch writes). Otherwise plan
  [Step 0](../docs/01-migration-path-and-decisions.md#step-0--reach-camunda-724-first), the upgrade to Camunda 7.24,
  and ship it in *Decide and prepare* before any code conversion: Operaton also starts on an older database, then
  fails at runtime on missing columns.
- [ ] **Confirm a green build** on Java 17+ and Spring Boot 4 (4.0 or 4.1). An EE build needs the EE repository and
  its credentials for that.
- [ ] **Scan every repository that embeds the engine** with `scripts/assess.sh <project> > assessment.md`, and give
  every MUST finding an owner ([Assessment](../docs/02-assessment.md)). The report names the edition (CE or EE), the
  Spring Boot line, the migration path, the recommended Operaton target and the next command to run.
- [ ] **On Spring Boot 3.5?** If the report says *Spring Boot 3.5 path*, read
  [Coming from Spring Boot 3.5: the two-hop path](../docs/15-coming-from-spring-boot-3.md#what-to-do) first. Its
  Step 0 and its two code changes replace Step 0 and the conversion run (*Run the conversion once*, *Commit the
  result as one change*) here; every other item of this checklist applies to you too.
- [ ] **Dry-run the conversion** with `scripts/migrate.sh --dry-run <project>`. It changes nothing, and the size of
  the patch is your best effort estimate. On Spring Boot 4.1, add `--target 2.2.0-RC1` until Operaton 2.2.0 is GA
  (due 2026-10-23). An EE build needs the EE repository credentials for this run, because the rewrite plugin
  resolves all dependencies before any recipe runs. Rate the service's size class and list its red flags
  ([Sizing and red flags](../docs/02-assessment.md#sizing-and-red-flags)).
- [ ] **Run the read-only SQL scans on a production copy:** `sql/postgresql/00-preflight-checks.sql` and
  `20-find-legacy-references.sql` ([SQL toolkit](../sql/README.md)). NO_GO is expected at this stage: nobody is in
  `operaton-admin` yet. Keep the list of stored task filters that use expressions (pre-flight section P11): the
  EE-hardening part of the [Camunda EE features decision (D17)](../docs/01-migration-path-and-decisions.md#d17)
  needs it.
- [ ] **List what needs special handling:**
  - the Camunda EE features in daily use: EE Cockpit screens, Optimize, the license and EE-only engine settings
    ([Camunda EE features, D17](../docs/01-migration-path-and-decisions.md#d17)), and
    [community extensions](../docs/14-ecosystem-support-and-resources.md)
  - [engine plugins and history exporters](../docs/06-engine-plugins-and-history-exporters.md)
  - [`org.camunda.*` in scripts and form keys](../docs/05-bpmn-dmn-forms-and-scripts.md)
  - [direct SQL on `ACT_*` tables](../docs/08-database-schema-data-and-sql-scripts.md)
  - configuration outside the repository
  - downstream consumers
- [ ] **Interview ops, the DBA, security, the process owners and the consumer teams** about what no scan sees:
  configuration outside the repository, direct SQL scripts, event consumers, the EE features in daily use and who is
  an admin today.
- [ ] **Open the decision log** from the [template](decision-log-template.md).

<a id="2--prepare"></a>

## 2 · Decide and prepare

**Goal:** settle the decisions, and ship on Camunda 7.24 every fix that works on both engines. Each such fix removes a
risk from cut-over day and keeps the way back open.

- [ ] **Make the 18 migration decisions (D1–D18)** and record them in the decision log.
  [Migration path and decisions](../docs/01-migration-path-and-decisions.md) recommends an option for each. Six are
  mandatory before the first start on real data: admin group (D5), cut-over strategy (D7), schema management (D8),
  rollback (D15), Camunda EE features (D17) and legacy variables (D18). The EE features decision is mandatory for
  every EE team, which includes everyone on Spring Boot 4.
- [ ] **Choose the Operaton target by your Spring Boot minor**
  ([target version and path, D1](../docs/01-migration-path-and-decisions.md#d1)). Operaton supports only the Spring
  Boot version each release is built with, and `migrate.sh` never downgrades Spring Boot:
  - Spring Boot 4.0: Operaton 2.1.5, the default target of `migrate.sh`. Plan the move to 2.2 soon after, because
    2.1 loses support when 2.2.0 ships.
  - Spring Boot 4.1: Operaton 2.2.x (`--target 2.2.0`, GA due 2026-10-23). Until the GA, rehearse with
    `--target 2.2.0-RC1`, never in production.
  - Spring Boot 4.2 or later: no Operaton line is built with it yet. Migrate on Spring Boot 4.1, or wait.
- [ ] **Finish [Step 0](../docs/01-migration-path-and-decisions.md#step-0--reach-camunda-724-first)** if *Assess*
  found code or database below Camunda 7.24 EE (7.24.3-ee or later), Java 17 or Spring Boot 4, and ship it as a
  normal Camunda release.
- [ ] **Decide what replaces each Camunda EE feature you use**
  ([Camunda EE features, D17](../docs/01-migration-path-and-decisions.md#d17)). Operaton is a fork of Camunda 7 CE,
  so the EE parts do not exist there. The EE Cockpit screens and the EE security hardening vanish without an error,
  so decide now:
  - For each EE Cockpit screen in use (history view, heatmap, instance modification, migration UI, batches, reports),
    choose a REST replacement and plan its test. Optimize is not supported.
  - Choose the mitigation for the EE security hardening that Operaton lacks (the items are under *Convert*). The P11
    list from *Assess* tells you whether switching off expressions in stored queries breaks any filter.
  - If you use Camunda's Jackson 3 opt-in (the `-jackson3` artifacts of 7.24.16-ee), plan to port the code that uses
    `tools.jackson.*` for Spin, the engine REST API or the external task client back to Jackson 2.
- [ ] **Add safety-net tests on 7.24** for what no compiler checks: scripts, forms, DMN, timers, external tasks,
  exporters. After the conversion, a red test shows what broke ([Testing](../docs/10-testing.md)).
- [ ] **Make scripts and form keys engine-neutral** ([Scripts and forms](../docs/05-bpmn-dmn-forms-and-scripts.md)):
  - Rewrite scripts that import `org.camunda.*` classes so that they are package-free: they use only process
    variables and `S(…)`, the only function pre-bound in scripts. Such scripts run on both engines.
  - Switch form keys to `formRef` if [Camunda Forms keys (D4)](../docs/01-migration-path-and-decisions.md#d4) says so.
  - **Deploy on 7.24** and migrate the running instances, which otherwise keep their old version.
- [ ] **Convert or drain variables holding `org.camunda.*` objects**
  ([legacy variables, D18](../docs/01-migration-path-and-decisions.md#d18)). Operaton fails on them with
  `ClassNotFoundException`. Draining means letting those instances finish on Camunda before the cut-over.
- [ ] **Check the database version:** Operaton 2.1+ needs at least PostgreSQL 14 / MySQL 8.4 / MariaDB 10.11. Upgrade
  an older database separately, never in the cut-over window
  ([Database](../docs/08-database-schema-data-and-sql-scripts.md)).
- [ ] **Pin versions**, no `-RC`/`-M`: Maven metadata can point to a release candidate, and `2.2.0-RC1` is for
  rehearsals only. `scripts/latest-versions.sh` shows the current versions and the Operaton line for each Spring
  Boot minor.

## 3 · Convert

**Goal:** convert the code in one reviewed commit, and fix by hand what no recipe reaches: configuration outside the
repository, the Camunda EE leftovers, the admin group and the exporters.

- [ ] **Start on a clean branch** and record the baseline `mvn -B verify`. `migrate.sh` refuses to run on a dirty
  working tree.
- [ ] **Give Maven the EE repository credentials for the recipe run:** server id `camunda-bpm-nexus-ee` in
  `~/.m2/settings.xml`, or `MAVEN_ARGS="-s <settings with the EE credentials>"`. The rewrite plugin resolves all
  dependencies, including test dependencies, before any recipe runs, so a settings file that points only to Maven
  Central does not work for this run
  ([EE repository](../docs/04-spring-boot-dependencies-and-configuration.md#camunda-ee-repository-and-credentials)).
- [ ] **Run the conversion once** ([Recipes](../docs/03-openrewrite-recipes.md)):
  1. Run `scripts/migrate.sh --dry-run .` and review the patch in `target/rewrite/rewrite.patch`. Check that its
     `Source:` line reports Spring Boot 4 (`boot4`). If the detection is wrong, set `--source boot4` or
     `--source boot3`.
  2. Apply `scripts/migrate.sh --with-infra-env [--with-form-keys] [--target <2.x>] .`. The default target 2.1.5
     fits Spring Boot 4.0; on Spring Boot 4.1, add `--target 2.2.0` once it is GA. Converted before the GA with
     `--target 2.2.0-RC1`? Then set the `operaton.version` property to `2.2.0` after the GA (and Spring Boot to the
     patch that `scripts/latest-versions.sh` pairs with it), and build, test and rehearse again before production.
     If `migrate.sh` warns that your Spring Boot minor differs from the target's, the pairing is unsupported: it
     leaves Spring Boot as it is, so pick the target it recommends. The `operaton-forms:` keys that
     `--with-form-keys` writes are a rollback hard stop
     ([Camunda Forms keys, D4](../docs/01-migration-path-and-decisions.md#d4)).
- [ ] **Run `scripts/verify-leftovers.sh` until it exits 0.** It finds leftovers: Camunda references that no recipe
  converted, including leftover `-4` starters, `-jackson3` artifacts, `-ee` versions, `camunda-engine-spring-6`,
  EE-only settings and calls, the license file and the EE repository. Record the leftovers you keep on purpose in
  `.operaton-migration-ignore`, the allowlist file in the project root that the script reads, each with a reason.
- [ ] **Fix the remaining compile and test errors** and get the tests green
  ([Troubleshooting](../docs/13-tips-tricks-and-troubleshooting.md)). Then work through the
  [manual checklist after the recipe](../docs/12-operaton-2-and-spring-boot-4.md#manual-checklist-after-the-recipe),
  for what the recipe cannot see, such as the new FEEL version and the database health check.
- [ ] **Clear the Camunda EE leftovers**
  ([Camunda EE features, D17](../docs/01-migration-path-and-decisions.md#d17)):
  - [ ] **Remove the EE-only engine settings and calls** before the first Operaton start
    ([Security](../docs/07-identity-admin-group-and-security.md#remove-the-ee-only-settings-before-the-first-start)).
    As generic properties, `queryExpressionAllowListEnabled`, `allowedExpression*InQueries` and
    `validateAuthResourceIdExists` stop the engine start. Java calls such as `setQueryExpressionValidator`,
    `setAllowed*InQueries`, `setValidateAuthResourceIdExists` and `ManagementService#setLicenseKey` do not compile.
    `operaton.bpm.authorization.validate-auth-resource-id-exists` is silently ignored.
  - [ ] **Put the mitigation for the missing EE hardening in place.** Operaton has no query-expression allow-list, no
    `validateAuthResourceIdExists` and no datasource autocommit check, and its stored task filters evaluate any
    expression (Camunda security notice 157 describes expression injection through filters). As decided in D17:
    set the generic property `enable-expressions-in-stored-queries: false` unless your filters need expressions such
    as `${currentUser()}`, keep `enable-expressions-in-adhoc-queries` false, restrict who may create or update
    filters, keep `spring.datasource.hikari.auto-commit: false`, and validate user and group ids in the code that
    creates authorizations
    ([Security](../docs/07-identity-admin-group-and-security.md#camunda-ee-security-hardening-that-operaton-lacks)).
  - [ ] **Port Jackson 3 code back to Jackson 2** if you used the `-jackson3` artifacts. `migrate.sh` maps the
    artifacts back, but code written against `tools.jackson.*` for Spin, the engine REST API or the external task
    client does not compile until you rewrite it to `com.fasterxml.jackson.*`. Keep Spin configurators on Jackson 2
    ([Jackson](../docs/12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in)).
  - [ ] **Remove the license from the Operaton build.** The recipe deletes `camunda.bpm.license-file`. Remove
    `camunda-license.txt` and license mounts. Keep the license key in the database: Operaton ignores it, and a
    rollback needs it. Delete the license secrets themselves in the *Clean-up*.
  - [ ] **Remove the EE repository** `https://artifacts.camunda.com/artifactory/private/` (id `camunda-bpm-nexus-ee`),
    its `<server>` credentials and the CI secrets from the Operaton build; the official recipe leaves
    `<repositories>` alone. Then run `mvn -B clean verify` again to prove that the build resolves from Maven Central
    alone. Do not revoke the credentials yet: a rebuild of the Camunda build you would roll back to needs them until
    the rollback window closes (*Clean-up*).
- [ ] **Commit the result as one change.**
- [ ] **Rename config outside `src/`**, which Operaton otherwise silently ignores: `CAMUNDA_BPM_*` variables, Helm,
  config server, logging, and the health key (`management.health.operaton.enabled`). Remove EE-only engine settings
  there too, because they stop the start. Copy
  [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java)
  from the migrated example and keep it on; it fails the start while old Camunda keys remain
  ([Configuration](../docs/04-spring-boot-dependencies-and-configuration.md)).
- [ ] **Set the webapp path explicitly** ([webapp path, D6](../docs/01-migration-path-and-decisions.md#d6)), because a
  lost key silently moves the webapps to `/operaton`. Move webjar overlays to `webjars/operaton/`
  ([Webapps](../docs/09-webapps-rest-api-and-clients.md)).
- [ ] **Prepare the admin-group mirror** ([admin group, D5](../docs/01-migration-path-and-decisions.md#d5)).
  Operaton only treats members of `operaton-admin` as admins. With users in the engine database, nobody is one after
  the switch, and the setup page then lets anyone create an admin user.
  - `sql/postgresql/10-migrate-admin-group.sql` and/or
    [`AdminGroupMigrationPlugin`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java)
    copy the members and authorizations of `camunda-admin` to `operaton-admin`. With LDAP, Keycloak or OAuth2, map
    the admin group in the identity provider instead.
  - Prepare the ingress block on `<app-path>/api/admin/setup/*`
    ([Security](../docs/07-identity-admin-group-and-security.md)).
- [ ] **Make exporters publish after commit**, never inside the engine transaction. Confirm that consumers accept the
  new `org.operaton.*` class names in the events ([Exporters](../docs/06-engine-plugins-and-history-exporters.md)).
- [ ] **Set `operaton.bpm.database.schema-update: false`** and test your Liquibase/Flyway handling and its reverse
  ([schema management, D8](../docs/01-migration-path-and-decisions.md#d8); [Liquibase fixes](../docs/08-database-schema-data-and-sql-scripts.md)).

## 4 · Verify

**Goal:** prove on real data that the service starts, keeps the setup page closed and fits your operations.

- [ ] **Run the full test suite** until it is green, with no MUST leftovers.
- [ ] **Boot on a production copy** with the admin-group SQL applied, `operaton.bpm.job-execution.enabled=false` and
  outbound calls stubbed. Check that all definitions parse. An EE-only generic property left anywhere in the
  configuration stops this start.
- [ ] **Run `scripts/smoke-test.sh --require-operaton --write`** until green, including "admin setup page closed".
  `--write` deploys, runs and deletes a tiny process; `--require-operaton` fails if Camunda still answers.
  **Never POST to the setup endpoint on production:** if setup is open, the POST creates an admin
  ([Security](../docs/07-identity-admin-group-and-security.md)).
- [ ] **Check the EE replacements:** every EE feature you used has a tested replacement. If you switched off
  expressions in stored queries, open the filters that P11 listed: they fail with
  "Expressions are forbidden in stored queries" until you rewrite them.
- [ ] **Check that Spin JSON variables round-trip**, that is, they are written and read back unchanged.
- [ ] **Check that logs, alerts and dashboards work** with the new `org.operaton.*` names. Set the probes as decided
  in [health probes (D13)](../docs/01-migration-path-and-decisions.md#d13)
  ([Operations](../docs/11-cutover-rollback-and-operations.md)).
- [ ] **Get consumer sign-off** on the new payloads.

## 5 · Rehearse

**Goal:** know the real downtime and prove the way back works before you need it.

- [ ] **Run the [cut-over runbook](cutover-runbook.md) end to end** on a fresh production copy, timed, twice.
- [ ] **Rehearse the rollback once**, with the last Camunda EE build. Record PoNR events, time cap, triggers and
  decision owner in [rollback and point of no return (D15)](../docs/01-migration-path-and-decisions.md#d15)
  ([Rollback](../docs/11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)).
- [ ] **Get the downtime accepted** by the process owners, and agree the go/no-go criteria.

<a id="6--cut-over--runbook-cut-over-day-t0"></a>

## 6 · Cut-over

**Goal:** switch production in one controlled event; the commands are in the
[runbook: cut-over day (T0)](cutover-runbook.md#t0--cut-over).

- [ ] **Freeze and stop:**
  - Freeze deployments (the runbook starts the freeze the day before, step F-01) and block the setup path.
  - Stop **all** Camunda nodes. Never run a mixed cluster, that is Camunda and Operaton nodes on the same database
    at the same time ([cut-over strategy, D7](../docs/01-migration-path-and-decisions.md#d7)).
  - Let the job locks expire or reset them, because the pre-flight gate says NO_GO while a job is still locked. Then
    take a backup.
  - If the engine schema is managed by Liquibase, apply the rehearsed Liquibase fix. With a 2.2.x target and Flyway
    or DBA-managed SQL, run `<db>_engine_7.24_to_7.25.sql` or skip it: it only writes the `7.25.0` marker row (no
    DDL), which the engine ignores.
- [ ] **Run `10-migrate-admin-group.sql`, then `00-preflight-checks.sql`.** The pre-flight script is the read-only
  gate for the first Operaton start and must say `GO`/`GO_WITH_WARNINGS` (exit 0). With users in the engine
  database, the other order gives NO_GO, because nobody is in `operaton-admin` yet.
- [ ] **Start one Operaton node without traffic.** Run the parse warm-up (the engine parses old process versions only
  when something touches them) and the smoke test, and confirm that the setup page is closed. Decide go or no-go; on
  no-go, roll back with path R1 of the runbook. On go, scale out and open the traffic; the setup block stays.

## 7 · Hypercare

**Goal:** watch closely while a rollback is still possible, and end that window on purpose.

- [ ] **Check daily:** incidents, failed jobs, job backlog, exporter lag. The setup-page monitor (a synthetic request
  that alerts when the setup page opens again, runbook step H-01b) stays on.
- [ ] **Run the [compatibility checkpoint (C1–C3)](cutover-runbook.md#compatibility-checkpoint-c1c3) daily.** Its
  three read-only checks answer one question: has Operaton written anything Camunda cannot run? The deployment
  freeze holds.
- [ ] **Close the rollback window** by an explicit decision when the point of no return or the agreed time cap is
  reached, and lift the deployment freeze (runbook step H-06).

## 8 · Clean-up

**Goal:** remove the migration scaffolding in normal releases; the security measures stay.

- [ ] **Remove the `camunda-admin` rows**; the setup-path block and monitor stay
  ([Clean-up](../docs/11-cutover-rollback-and-operations.md#hypercare-and-clean-up)).
- [ ] **Remove the migration helpers** (`AdminGroupMigrationPlugin`, later `LegacyCamundaConfigGuard`) and the
  dual-match alert rules, which match both `org.camunda` and `org.operaton`. Set the Kubernetes strategy back to
  `RollingUpdate`.
- [ ] **Remove what the rollback kit kept for Camunda EE:** delete the license files and their secrets, and revoke
  the EE repository credentials that the old Camunda build needed.
- [ ] **Do now what you decided to do "later"**, if anything:
  - Move the webapp path to `/operaton` with a redirect ([webapp path, D6](../docs/01-migration-path-and-decisions.md#d6)).
  - Convert namespaces to `operaton:` per deployment unit
    ([BPMN/DMN namespace, D3](../docs/01-migration-path-and-decisions.md#d3)).
- [ ] **Schedule a monthly patch slot** and the next minor upgrade; Operaton has no LTS
  ([Upgrades](../docs/12-operaton-2-and-spring-boot-4.md)). If you went live on 2.1.5, plan the move to 2.2.x,
  because 2.1 loses support when 2.2.0 ships.
