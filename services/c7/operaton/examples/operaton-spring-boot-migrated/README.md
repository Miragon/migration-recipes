# operaton-spring-boot-migrated · After

This is the result of the example migration: the [legacy app](../camunda7-spring-boot-legacy/README.md) after
`scripts/migrate.sh` (Hop 1 and Hop 2, see below) and manual fixes. It runs on Operaton 2.1.5, Spring Boot 4.0.8 and
Java 17+. Use it to compare with your own migration result, and to copy the generic migration helpers into your app.
Changes are marked `MIGRATED:` in the code; every step is in [`MIGRATION_REPORT.md`](MIGRATION_REPORT.md).

**This app is the target of both paths.** On the main path, a Camunda 7.24 EE app on Spring Boot 4 reaches this
state in one code change: one run of `scripts/migrate.sh`, one commit.
[`tools/test-boot4-path.sh`](../../tools/test-boot4-path.sh) runs that path on a Spring Boot 4 EE variant of the
legacy app ([Reproduce the Spring Boot 4 path](../README.md#reproduce-the-spring-boot-4-path)). The legacy app itself
is Camunda 7.24.0 CE on Spring Boot 3.5, because Camunda's Spring Boot 4 artifacts are EE-only and not on Maven
Central (details in the [examples overview](../README.md)). Its code therefore took the Spring Boot 3.5 path, in two
steps called hops ([Coming from Spring Boot 3.5](../../docs/15-coming-from-spring-boot-3.md)). Hop 1 (rename)
converted Camunda 7.24 to Operaton 1.1.5 on Spring Boot 3.5. Hop 2 (platform) moved on to Operaton 2.1.5 and Spring
Boot 4.

## What changed

The changes fall into three groups: what the recipes changed, what was fixed by hand, and what was kept on purpose.
The decisions behind them follow at the end.

**Changed by the recipes:** the BOM (`operaton-bom`), the test starter
(`operaton-bpm-spring-boot-starter-test-junit5`), the Java packages, the `operaton.bpm.*` properties and
`OPERATON_BPM_*` environment variables, the logger names, `operaton-admin` in the whitelist pattern, the script
import `org.operaton.spin.Spin`, the `operaton-forms:` form key, and Jackson 3 in `InMemoryEventPublisher`.

**Fixed by hand:**

- **3 test expectations.** The tests expected the Camunda group id, form key and class name, which the recipes
  leave alone.
- **History exporter**, the code that sends engine history events to other systems. It now publishes after commit,
  so that a transaction that rolls back no longer sends "ghost events". It is also registered once instead of twice:
  [`HistoryExportPlugin`](src/main/java/com/example/orders/history/HistoryExportPlugin.java) constructs it, and it is
  no `@Component` any more.
- **Direct SQL.** The `ops/sql/*.sql` scripts changed engine tables behind the engine's back. They are replaced by
  [`IncidentRecoveryService`](src/main/java/com/example/orders/operations/IncidentRecoveryService.java), which uses the
  engine API ([pointers](ops/sql/README.md)).
- **Accepted leftovers.** Camunda references that are intended are listed in
  [`.operaton-migration-ignore`](.operaton-migration-ignore), so that `scripts/verify-leftovers.sh` does not flag
  them.

**Kept on purpose:** the `camunda:` namespace in the models (Operaton still reads it), the webapp path `/camunda`
([webapp path decision, D6](../../docs/01-migration-path-and-decisions.md#d6)), and the Spin configurator on Jackson 2
(Operaton 2.x Spin still uses Jackson 2).

**Not in this example:** the source is Camunda CE, so there were no Camunda EE features to replace. Coming from
Camunda EE, you also work through the
[Camunda EE features decision (D17)](../../docs/01-migration-path-and-decisions.md#d17): the EE webapp features, the
license, the EE repository, the Jackson 3 opt-in and the EE security hardening that Operaton lacks.

**Decisions** ([report, section 2](MIGRATION_REPORT.md#2-decisions)):

- **Two hops**, because the source runs on Spring Boot 3.5. The code went through Operaton 1.1.5 on Spring Boot
  3.5.16 to Operaton 2.1.5, in two commits. Production moves from Camunda 7.24 straight to 2.1.5
  ([target version and path, D1](../../docs/01-migration-path-and-decisions.md#d1)). A source on Spring Boot 4 takes
  one commit instead.
- **`eventClass` kept.** The exported history events still carry the engine class name, which is now
  `org.operaton…`. Consumers must dual-read, i.e. accept both the old and the new names
  ([history exporters, D9](../../docs/01-migration-path-and-decisions.md#d9)).
- **Rollback** to 7.24 is possible until the first instance runs on the Operaton-only BPMN v2, with a cap of 72 h
  ([rollback and point of no return, D15](../../docs/01-migration-path-and-decisions.md#d15)). Version 2 of the
  process contains the `org.operaton.spin.Spin` script and the `operaton-forms:` key, which Camunda 7.24 cannot run.

## Migration helpers (`migration/`)

These classes protect the cut-over, the production switch from Camunda to Operaton on the same database. They are
generic, so you can copy them into your app, and temporary: remove them once the rollback window has closed.

| Class | Purpose | Default |
|---|---|---|
| [`AdminGroupMigrationPlugin`](src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java) | Keeps the Admin setup endpoint closed | on |
| [`LegacyCamundaConfigGuard`](src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java) | Fails the start on leftover Camunda configuration | on |
| [`LegacyWebappPathRedirectFilter`](src/main/java/com/example/orders/migration/LegacyWebappPathRedirectFilter.java) | Redirects old webapp URLs | off (opt-in) |
| [`MigrationHelpersConfiguration`](src/main/java/com/example/orders/migration/MigrationHelpersConfiguration.java) | Registers the plugin and the filter as beans | – |

All switches below live under `orders.migration.*`; the default is in parentheses.

### `AdminGroupMigrationPlugin`

**Why:** Operaton only treats `operaton-admin` as admin group, and on a database that Camunda used, nobody is a
member of it. The webapps then consider the engine "not set up", and the Admin setup endpoint lets an
unauthenticated caller create an administrator.

**What it does:** at engine build, before the web server accepts requests, it mirrors the `camunda-admin` members and
authorizations to `operaton-admin` (named `operaton BPM Administrators`), so the Admin setup endpoint stays closed.

- It is idempotent, so it can run on every start.
- If `camunda-admin` has no members, it only logs a WARN, and the endpoint stays open: add an administrator before
  the webapps are reachable.
- It leaves `camunda-admin` rows alone, because a rollback to Camunda needs them.

**Switches:** `admin-group.enabled` (true), `admin-group.legacy-group-id` (`camunda-admin`).

### `LegacyCamundaConfigGuard`

**Why:** Spring Boot silently ignores leftover Camunda keys, and the engine then starts with defaults. Such leftovers
often hide where the recipes never look: Helm values, Kubernetes ConfigMaps, CI/CD variables, config servers.

**What it does:** it fails the start on leftover `camunda.bpm.*`, `CAMUNDA_BPM_*` and `management.health.camunda.*`.
It names the keys, never the values, because values may be secrets.

**Switches:** `legacy-config-guard.enabled` (true), `legacy-config-guard.fail-on-leftovers` (true; with false, the
guard only logs a warning).

### `LegacyWebappPathRedirectFilter`

**Why:** the release that moves the webapps from `/camunda` to the Operaton path
([webapp path decision, D6](../../docs/01-migration-path-and-decisions.md#d6)) would break bookmarks and links. The
filter keeps them working. It is off until you make that move.

**What it does:** it redirects GET/HEAD requests for `/camunda/**` to `operaton.bpm.webapp.application-path`. The
start fails if both paths are equal, because that would be a redirect loop. Other methods are not redirected and
get a 404: a redirect would silently drop their request bodies, so those clients have to be changed.

**Switches:** `legacy-webapp-redirect.enabled` (false), `.legacy-path` (`/camunda`), `.status` (302).

### `MigrationHelpersConfiguration`

It registers the plugin and the filter as beans. The guard is not a bean: it runs before the application context
exists and is registered in `META-INF/spring.factories`.

### Reuse and remove

To reuse the helpers in your app:

1. Copy the classes. They depend only on the Operaton engine and starter.
2. Copy the guard's entry in [`META-INF/spring.factories`](src/main/resources/META-INF/spring.factories). On Spring
   Boot 3.x, interface and key are `org.springframework.boot.env.EnvironmentPostProcessor`.

**Remove** them, their `.operaton-migration-ignore` entries and the `camunda-admin` rows once the rollback window has
closed ([rollback and point of no return, D15](../../docs/01-migration-path-and-decisions.md#d15)).

## Run and test

```bash
mvn -B verify          # 34 tests, H2 in-memory
mvn spring-boot:run    # http://localhost:8080/camunda/app/ (demo / demo); /engine-rest/version → 2.1.5
../../scripts/smoke-test.sh --base-url http://localhost:8080 --webapp-path /camunda --require-operaton
```

The smoke test checks, read-only, that the engine answers, that the webapps are reachable at `/camunda` and that the
setup page is closed. `--require-operaton` makes it fail if the engine is not Operaton.

**Cut-over simulation.** This shows on your machine what happens at the production cut-over: Operaton starts on a
database that Camunda wrote.

1. Run the legacy app with `--spring.datasource.url=jdbc:h2:file:<dir>/orders`, so that it writes to a file
   database.
2. Stop it.
3. Start this app on the same URL.
4. Check the log for `Admin group migration camunda-admin -> operaton-admin: …`. The setup endpoint stays closed.

To see the hole that the plugin closes, start this app on a fresh copy with
`--orders.migration.admin-group.enabled=false`: an anonymous admin creation then returns 204.
