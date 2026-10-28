# examples/ · Before and after

This folder holds one realistic application in two states: before and after the migration from Camunda 7 to
Operaton. Use it to see what the pack's tools change in real code, to try the tools before you run them on your own
service, and to copy the generic migration helpers.

| Folder | What it is |
|---|---|
| [`camunda7-spring-boot-legacy/`](camunda7-spring-boot-legacy/README.md) | **Before:** order-fulfillment app on Camunda 7.24.0 CE / Spring Boot 3.5.5 with 21 marked hotspots, 10 tests |
| [`operaton-spring-boot-migrated/`](operaton-spring-boot-migrated/README.md) | **After:** the same app after the pack's scripts: Operaton 2.1.5 / Spring Boot 4.0.8, 34 tests |

**Why the "before" app runs on Spring Boot 3.5.** The main path of this guide starts from Camunda 7.24 EE (Enterprise
Edition) on Spring Boot 4. That flavour cannot be published as a buildable example: Camunda's
Spring Boot 4 starters (the artifacts with a `-4` infix) and every `7.24.N-ee` version exist only in Camunda's EE
repository, not on Maven Central, and you need EE credentials to download them. The legacy app therefore uses the
public flavour, Camunda 7.24.0 CE (Community Edition) on Spring Boot 3.5, which anyone can build.

**The "after" app is the target of both paths.** Whether your code reaches Operaton in one change from Spring Boot 4
or in two hops from Spring Boot 3.5, the result is the same kind of application: Operaton 2.x on Spring Boot 4, here
Operaton 2.1.5 on Spring Boot 4.0.8. Compare your own result with it on either path.

A **hotspot** is a place that the migration must change, or that breaks without an error if nobody changes it. Each
one is marked with a `MIGRATION HOTSPOT` comment in the legacy app. Every step of the migration, with commands,
results and manual fixes, is recorded in [`MIGRATION_REPORT.md`](operaton-spring-boot-migrated/MIGRATION_REPORT.md).

**Build:** you need JDK 17+ (CI: 21) and Maven with Central access. Run `mvn -B verify` in each folder. The tests use
an H2 in-memory database, so you need no database server.

<a id="reproduce-the-spring-boot-4-path"></a>

## Reproduce the Spring Boot 4 path

Because no Camunda EE app can live in this folder, [`tools/test-boot4-path.sh`](../tools/test-boot4-path.sh) builds
one on the fly and runs the main path on it end to end. You need no EE access for it:

1. It writes a stub EE repository: POMs with empty jars for the `-4` starters, `-4-webapp-ee`, the six `-jackson3`
   artifacts and `camunda-bom:7.24.16-ee`. Each stub delegates to the public CE 7.24.0 artifact on Maven Central.
2. It derives a Spring Boot 4 project from the legacy app: parent 4.x, `camunda.version` 7.24.16-ee, `-4-webapp-ee`,
   `-4-rest` plus `-4-rest-jackson3`, `-4-test`, `camunda-spin-dataformat-json-jackson3` and
   `camunda.bpm.license-file`.
3. It runs `scripts/assess.sh` and `scripts/migrate.sh` on it: `--hop` must be rejected, `--dry-run` must change
   nothing, then the real run with `--with-infra-env`. It checks the result and runs `scripts/verify-leftovers.sh`.
4. It deletes the stubs and builds the result with Maven Central only (`mvn -B -DskipTests verify`).

Run it from the pack root (`services/c7/operaton/`):

```bash
tools/test-boot4-path.sh                                           # Spring Boot 4.0.8 -> Operaton 2.1.5
tools/test-boot4-path.sh --spring-boot 4.1.1 --target 2.2.0-RC1    # Spring Boot 4.1.1 -> Operaton 2.2.0-RC1
```

- **Options:** `--spring-boot <version>` sets the Spring Boot version of the project (default 4.0.8). `--target
  <version>` is passed to `migrate.sh` (default 2.1.5 for Spring Boot 4.0.x, 2.2.0-RC1 for 4.1.x; switch to 2.2.0
  once it is GA, due 2026-10-23). `--keep` keeps the work directory with the project, the stub repository, the local
  Maven repository and the logs; it is always kept when a check fails. `--maven-args "<args>"` adds Maven arguments
  to every Maven call.
- **Needs:** git, JDK 17+ (selected with `JAVA_HOME`), Maven (`MVN`, default `mvn`; 3.9+ recommended) and direct
  access to Maven Central. The script ignores `~/.m2/settings.xml`, so that a mirror cannot hide the stub
  repository; behind a Central-only mirror it cannot run as is.
- **Result:** exit code 0 means all checks passed; a run takes about a minute. CI runs both commands above in the job
  "Recipes end-to-end (Camunda 7.24 EE on Spring Boot 4 -> Operaton 2.x)".
- **Limit:** the stubs delegate to CE 7.24.0 jars, so the test has never run against the real Camunda EE repository.
  On your own EE build, dry-run first and review the diff.

How the main path works on your own service: [OpenRewrite recipes](../docs/03-openrewrite-recipes.md).

<a id="reproduce-the-migration"></a>

## Reproduce the example migration (Spring Boot 3.5 path)

You can repeat the migration of the committed example yourself and compare the result with the committed "after"
app. Because the legacy app runs on Spring Boot 3.5, its code reaches Operaton 2.x in two steps, called hops, as
described in [Coming from Spring Boot 3.5: the two-hop path](../docs/15-coming-from-spring-boot-3.md). Run the
commands from the pack root (`services/c7/operaton/`), on a scratch git copy of the legacy app (`migrate.sh` refuses dirty trees):

```bash
rsync -a --exclude target examples/camunda7-spring-boot-legacy/ /tmp/orders/
git -C /tmp/orders init -q && git -C /tmp/orders add -A && git -C /tmp/orders commit -qm baseline
scripts/assess.sh /tmp/orders > /tmp/orders-assessment.md                 # 7 MUST · 7 SHOULD · 4 INFO
scripts/migrate.sh --hop 1 --with-infra-env --with-form-keys /tmp/orders  # --dry-run to preview
(cd /tmp/orders && mvn -B clean verify)   # 8/10: test literals fail on purpose
scripts/verify-leftovers.sh /tmp/orders   # fix the test expectations M1-M3 (MIGRATION_REPORT.md section 4), commit
scripts/migrate.sh --hop 2 --target 2.1.5 /tmp/orders
(cd /tmp/orders && mvn -B clean verify)   # 10/10, no manual fix
diff -ru -x target -x .git /tmp/orders examples/operaton-spring-boot-migrated
```

What each step does:

1. **Copy and commit a baseline.** The copy keeps the example untouched. The baseline commit gives `migrate.sh` the
   clean git working tree it requires. It also lets you see with `git diff` what the recipes changed (the OpenRewrite
   recipes are the automated code transformations that `migrate.sh` runs).
2. **Assess.** `scripts/assess.sh` lists everything the migration touches. It reports 7 MUST, 7 SHOULD and 4 INFO
   findings. MUST means the finding blocks the migration or breaks silently unless somebody acts. SHOULD means the
   recipes handle it or it is a decision with a safe default. INFO is planning context, such as counts and versions.
   Its *Migration path* row says "Spring Boot 3.5 path", because the app is Camunda CE on Spring Boot 3.5.
3. **Run Hop 1 (rename).** `migrate.sh --hop 1` is the first hop: it converts Camunda 7.24 to Operaton 1.1.5 and
   keeps Spring Boot 3.5. The two extra flags also rename the `CAMUNDA_BPM_*` environment variables and the
   `camunda-forms:` form keys. Add `--dry-run` first if you want to preview the patch.
4. **Build and test.** 8 of 10 tests pass. The other two fail **on purpose**: the recipes leave test literals alone,
   so the tests still expect the Camunda group id, form key and exported class name.
5. **Scan for leftovers and fix them.** `scripts/verify-leftovers.sh` lists the Camunda references that no recipe
   converted. Fix the three test expectations (M1–M3 in
   [section 4 of the report](operaton-spring-boot-migrated/MIGRATION_REPORT.md#4-manual-fixes-and-accepted-leftovers)),
   then commit.
6. **Run Hop 2 (platform).** `migrate.sh --hop 2 --target 2.1.5`, the second hop, moves to Operaton 2.1.5 and
   Spring Boot 4.0.8.
7. **Build and test again.** All 10 tests pass without a manual fix.
8. **Compare** your result with the committed "after" app. The committed app also contains the manual work recorded
   in the report, such as the migration helpers, the exporter fix and `IncidentRecoveryService`, so expect these
   differences.

## Hotspots and where they are fixed

The table shows the most important hotspots, how the legacy app handles them, what the migrated app does instead,
and which chapter explains the change. Why each hotspot is a trap is listed in the
[legacy README](camunda7-spring-boot-legacy/README.md#migration-hotspots). A Camunda EE app on Spring Boot 4 has
further hotspots that this CE app cannot show, such as the `-4` starters, `-ee` versions, the EE webapps, the
license, the EE repository and EE-only engine settings; the
[Camunda EE features decision (D17)](../docs/01-migration-path-and-decisions.md#d17) covers them.

| Hotspot | Legacy | Migrated | Chapter |
|---|---|---|---|
| Build | `camunda-bom` 7.24.0, Boot 3.5.5 | `operaton-bom` 2.1.5, Boot 4.0.8 | [Spring Boot dependencies and configuration](../docs/04-spring-boot-dependencies-and-configuration.md) |
| Config, env, loggers | `camunda.bpm.*`, `CAMUNDA_BPM_*`, `org.camunda.bpm.*` | `operaton.bpm.*`, `OPERATON_BPM_*`, `org.operaton.bpm.*`, plus `LegacyCamundaConfigGuard` | [Spring Boot dependencies and configuration](../docs/04-spring-boot-dependencies-and-configuration.md) |
| BPMN script, forms | `import org.camunda.spin.Spin`, `camunda-forms:` | `org.operaton.spin.Spin`, `operaton-forms:`; `camunda:` namespace kept | [BPMN, DMN, forms and scripts](../docs/05-bpmn-dmn-forms-and-scripts.md) |
| History exporter | publishes inside the transaction, registered twice | after commit, registered once | [Engine plugins and history exporters](../docs/06-engine-plugins-and-history-exporters.md) |
| Admin group | `Groups.CAMUNDA_ADMIN`, `ops/sql/grant-admin.sql` | `Groups.OPERATON_ADMIN` + `AdminGroupMigrationPlugin` | [Identity, admin group and security](../docs/07-identity-admin-group-and-security.md) |
| Direct SQL | `ops/sql/*.sql` on `ACT_*` | `IncidentRecoveryService` | [Database: schema, data and SQL scripts](../docs/08-database-schema-data-and-sql-scripts.md) |
| Webapp path | `/camunda` | `/camunda` kept; `LegacyWebappPathRedirectFilter` opt-in | [Webapps, REST API and clients](../docs/09-webapps-rest-api-and-clients.md) |
| Spin configurator | Jackson 2 | Jackson 2 (Spin); Spring on Jackson 3 | [Operaton 2 and Spring Boot 4](../docs/12-operaton-2-and-spring-boot-4.md) |

The `migration/` helpers are generic: they mirror the admin group, stop the application from starting with leftover
Camunda configuration, and redirect the old webapp path. Copy them into your app; the [migrated README](operaton-spring-boot-migrated/README.md)
explains how.
