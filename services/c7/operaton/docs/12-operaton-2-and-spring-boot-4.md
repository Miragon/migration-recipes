<a id="12--operaton-2-and-spring-boot-4-hop-2"></a>

# 12 · Operaton 2 and Spring Boot 4: versions, Jackson and upgrades

This chapter covers what every team on Operaton 2.x needs to know, whichever path it came from: which 2.x line fits
your Spring Boot version, how Spin keeps Jackson 2 next to Spring's Jackson 3, the platform checks after the recipe
run, and how to keep up after the go-live. Tech leads use it to choose between 2.1.x and 2.2.x before the
conversion; developers use the Jackson rules and the checklist right after it. On Spring Boot 3.5? Read
[Coming from Spring Boot 3.5](15-coming-from-spring-boot-3.md) first: on that path, the Spring Boot 4 upgrade is a
code change of its own.

**In short**
- **Each Operaton 2.x line supports exactly one Spring Boot minor.** Operaton 2.1.5 is built with Spring Boot 4.0.8,
  and Operaton 2.2.x with Spring Boot 4.1.x. Pick the line that matches your application: Spring Boot 4.0 goes to
  2.1.5, Spring Boot 4.1 goes to 2.2.x (GA due 2026-10-23; rehearse with 2.2.0-RC1, never in production). Other
  combinations are unsupported.
- **Operaton 2.1 loses support when 2.2.0 ships (October 2026).** Teams that go live on 2.1.5 plan the move to 2.2
  right after the go-live. That move includes the upgrade to Spring Boot 4.1 and a schema-log row `7.25.0`.
- **Spin, the engine REST API and the external task client stay on Jackson 2**, while Spring Boot 4 gives your code
  **Jackson 3**. Never migrate Spin configurators to Jackson 3: the build breaks, or Spin silently loses its date
  handling. Operaton 2.x has no Jackson 3 variants, so teams that used Camunda's `-jackson3` opt-in go back to Jackson
  2 and port their `tools.jackson` code for Spin and REST by hand.
- **The production target is the latest 2.x patch at cut-over**, pinned
  ([target version and path, D1](01-migration-path-and-decisions.md#d1)). After the go-live, follow Operaton's
  monthly patches and half-yearly minors, because there is no long-term support line.

## What to do

1. **Choose the 2.x line that matches your Spring Boot minor** ([Choosing 2.1.x or 2.2.x](#choosing-21x-or-22x)) and
   record it in the target-version decision, so that `scripts/migrate.sh` gets the right `--target`.
2. **If you used Camunda's Jackson 3 opt-in, plan to port that code**, because Spin, REST and client code written
   against `tools.jackson.*` does not compile against Operaton's Jackson 2 artifacts
   ([Coming from Camunda's Jackson 3 opt-in](#coming-from-camundas-jackson-3-opt-in)).
3. **After the recipe run, work through the [manual checklist](#manual-checklist-after-the-recipe)**, because the
   recipe cannot see behaviour changes such as a new FEEL version or the new database health check.
4. **Boot on a production copy** (a restored copy of the production database, never the live one) with the
   admin-group step applied, then run `scripts/smoke-test.sh --base-url <url> --require-operaton`.
5. **After hypercare, the watch period after the cut-over, plan the next minor** and set up the patch routine
   ([Moving from 2.1.x to 2.2.x](#moving-from-21x-to-22x), [Keeping up afterwards](#keeping-up-afterwards)).

## What 2.0, 2.1 and 2.2 change

The table shows the platform versions that come with each Operaton 2.x version. Read one column to see what your
build uses at that version; bold marks the main changes. The schema marker is the newest row in
`ACT_GE_SCHEMA_LOG`, which names the schema level.

| | 2.0 | 2.1.5 | 2.2 |
|---|---|---|---|
| Spring Boot | 4.0.4 | **4.0.8** | 4.1.x |
| Jakarta EE / JUnit | 11 / 6 | 11 / 6 | 11 / 6 |
| Jackson: Spring / Spin, REST | 3 / 2 | 3 / 2 | 3 / 2 |
| Testcontainers, Liquibase, Groovy (Spring Boot managed) | 2.0, 5.0, 5 | 2.0, 5.0, 5 | 2.0, 5.0, 5 |
| FEEL `org.camunda.feel:feel-engine` | 1.21 | 1.21 | 1.22 **unshaded** |
| `processEngine` health | always UP | **DOWN on DB failure** | same |
| Schema marker | 7.24.0 | 7.24.0 | 7.25.0 (no DDL) |

What else each version changes:

- **2.0** adds the engine test classifier `junit6`. The package stays `org.operaton.bpm.engine.test.junit5`, and
  `operaton-bpm-spring-boot-starter-test-junit5` brings the classifier for you.
- **2.1** raises the database minimums to PostgreSQL 14, MariaDB 10.11 and MySQL 8.4. It adds the opt-in
  `operaton.bpm.webapp.session-cookie-path-enforcement`, which restricts the webapp session cookie to the webapp path.
  It also changes some internal `.impl.` APIs (for example, `HistoryLevelSetupCommand` is now an interface), which
  affects engine plugins that use them.
- **2.2** switches to the unshaded FEEL artifact: FEEL's dependencies are no longer bundled inside its jar, so Scala and
  `jackson-module-scala` land on your classpath. It also records the schema level `7.25.0` (one new row in
  `ACT_GE_SCHEMA_LOG`, no DDL). Its previews (`job-executor-acquire-with-skip-locked` for job acquisition, and
  webapps-neo, a new webapp) stay off for the migration, because previews may still change
  ([webapps, D16](01-migration-path-and-decisions.md#d16)).

<a id="operaton-2x-needs-spring-boot-4"></a>

## Spring Boot pairing: one Spring Boot minor per Operaton line

Operaton supports only the Spring Boot version each release is built with. Other combinations must be tested
thoroughly by you and are not supported, so keep your application on the pair. The table shows which Operaton line
matches which Spring Boot minor (as of 2026-10-11):

| Your Spring Boot | Operaton line | Built with | Status |
|---|---|---|---|
| 4.0 | 2.1.x (2.1.5) | 4.0.8 | GA, supported pairing |
| 4.1 | 2.2.x (2.2.0-RC1 today) | 4.1.1 | GA due 2026-10-23; RC1 for rehearsals only, never production |
| 4.2 | none yet | — | migrate on Spring Boot 4.1, or wait for the matching Operaton line |

- **`scripts/latest-versions.sh`** prints this mapping from Maven Central, and
  `scripts/latest-versions.sh --operaton <version>` adds the Spring Boot version of one release. Use exactly that
  Spring Boot version.
- **2.1.5 on Spring Boot 4.1 is unsupported.** 2.1.5 on Spring Boot 4.1.1 started and passed a smoke test, but that
  is no support statement: Operaton supports 2.1.5 only with 4.0.8.
- **`scripts/migrate.sh` never downgrades Spring Boot.** It raises Spring Boot at most to the patch level of the
  target's pairing within the same minor (for example 4.0.5 to 4.0.8 for 2.1.5). If your minor differs from the
  target's, it leaves Spring Boot alone and warns with the matching target (see [Watch out](#watch-out); the full
  warning is in [OpenRewrite recipes](03-openrewrite-recipes.md#run-scriptsmigratesh)).

## Jackson 2 and Jackson 3

On Operaton 2.x your application contains two Jackson major versions in different packages. They do not conflict,
but every `ObjectMapper` in your code belongs to exactly one of them. The table shows which code uses which:

| Code | Jackson | Package |
|---|---|---|
| Spin (`DataFormatConfigurator`s, `JacksonJsonDataFormat#getObjectMapper()`), engine REST, external task client | **2** | `com.fasterxml.jackson` |
| Your Spring beans, MVC converters, the injected `ObjectMapper` | **3** | `tools.jackson` |

Follow these rules:

1. **Anything that touches a Spin or engine mapper stays on Jackson 2**, because Spin itself still uses Jackson 2.
   Keep the Jackson 2 module `jackson-datatype-jsr310`, which provides the `JavaTimeModule` for Java date types.
2. **Your own beans inject `tools.jackson.databind.ObjectMapper`** and catch `tools.jackson.core.JacksonException`,
   because Spring Boot 4 auto-configures a Jackson 3 mapper.
3. **Never run a blanket Jackson 3 recipe on Spin code.** `starterpack.operaton.MigrateSpringBoot4App`, the recipe
   that `scripts/migrate.sh` runs on a Spring Boot 4 project, renames your Spin configurator and runs no Jackson 3
   step. The stock `UpgradeSpringBoot_4_0` recipe rewrites Spin configurators to `tools.jackson` and drops their
   module registrations.
4. **Stored JSON variables are unaffected**, because Spin keeps writing them with Jackson 2.

### Coming from Camunda's Jackson 3 opt-in

Camunda 7.24.16-ee added opt-in Jackson 3 artifacts; Jackson 2 stayed Camunda's default. Operaton 2.x has no
Jackson 3 Spin, REST or client artifacts: the Operaton project decided to stay on Jackson 2 for 2.x
([operaton#1672](https://github.com/operaton/operaton/issues/1672)). If your build uses one of these artifacts, the
recipe of the Spring Boot 4 path maps it back to the Jackson 2 artifact:

| Camunda (Jackson 3 opt-in) | Operaton (Jackson 2) |
|---|---|
| `camunda-spin-dataformat-json-jackson3` | `org.operaton.spin:operaton-spin-dataformat-json-jackson` |
| `camunda-spin-dataformat-all-jackson3` | `org.operaton.spin:operaton-spin-dataformat-all` |
| `camunda-bpm-spring-boot-starter-4-rest-jackson3` | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-rest` |
| `camunda-engine-rest-core-jakarta-jackson3` / `camunda-engine-rest-jakarta-jackson3` | `org.operaton.bpm:operaton-engine-rest-core` / `operaton-engine-rest` |
| `camunda-external-task-client-jackson3` | `org.operaton.bpm:operaton-external-task-client` |

What stays manual:

- **Code written against `tools.jackson.*` for Spin, the engine REST API or the external task client** (for example
  a `DataFormatConfigurator` or an `ObjectMapper` customizer) does not compile against the Jackson 2 artifacts.
  Rewrite it to `com.fasterxml.jackson.*`. `scripts/assess.sh` reports such code as a MUST finding; no recipe
  rewrites it.
- **Leftover `-jackson3` coordinates** fail the leftover scan: `scripts/verify-leftovers.sh` reports them as
  `JACKSON3_ARTIFACT` (MUST-FIX).
- **The JSON format.** Camunda's patch notes state that the JSON that Spin and the REST API write is the same with
  Jackson 2 and Jackson 3. Keep your REST response snapshots in the tests anyway, so that a difference shows up as a
  red test.

This is part of the [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17).

## Manual checklist after the recipe

These items apply to every team on Operaton 2.x. They need a human look after the recipe run, because the recipe
cannot see behaviour changes or decide licensing questions:

- **Scripts and DMN:** Operaton 2.x brings FEEL 1.21 (1.22 with 2.2) and runs on Groovy 5 (Spring Boot managed). Test
  every script path and decision table. Details: [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
- **Health probes and database:** put `processEngine` in readiness only
  ([health probes, D13](01-migration-path-and-decisions.md#d13)), because since 2.1 it reports DOWN when the database
  fails. Bring the database to the 2.1 minimums (PostgreSQL 14, MariaDB 10.11, MySQL 8.4) in a separate change.
- **Custom `ELResolver`:** delete the `getFeatureDescriptors` override, because Jakarta EL 6.0 (part of Jakarta EE 11)
  removed that method. Otherwise the build fails with "method does not override or implement a method from a
  supertype".
- **Engine plugins on internal APIs:** check plugins that use `.impl.` classes, because 2.1 changed some of them
  (for example `HistoryLevelSetupCommand`). Details:
  [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md).
- **Liquibase 5**, which Spring Boot 4 manages, is licensed under the FSL (Functional Source License), not
  Apache-2.0. Get it reviewed, or pin 4.x deliberately. The changelog fix from
  [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md#liquibase) is untested on
  Liquibase 5.

## Choosing 2.1.x or 2.2.x

Production should run the latest 2.x patch at cut-over, on the Spring Boot minor it is built with. The support
windows are short: 2.1 loses support when 2.2.0 ships (general availability, GA, due 2026-10-23). Spring Boot 4.0
OSS support ends 2026-12-31, and 4.1 OSS support on 2027-07-31. Choose by the Spring Boot minor of your application
(Camunda 7.24.10-ee and later use Spring Boot 4.1 by default):

- **Spring Boot 4.0: target 2.1.5** (`migrate.sh`'s default target).
  - **Go-live before the 2.2.0 GA:** go live on 2.1.5 (or 2.1.6). Plan the 2.2.x move, including Spring Boot 4.1,
    right after hypercare.
  - **Go-live after the 2.2.0 GA:** develop on 2.1.5 and try 2.2.0-RC1 on a branch (never in production) to see the
    differences early. At GA, switch to 2.2.x together with Spring Boot 4.1
    ([Moving from 2.1.x to 2.2.x](#moving-from-21x-to-22x)), or upgrade the Camunda application to Spring Boot 4.1
    first, in its own commit, and run the migration with `--target 2.2.0`. Rehearse on that exact version.
- **Spring Boot 4.1: target 2.2.x.** Rehearse with `--target 2.2.0-RC1` until the GA, and go live with
  `--target 2.2.0`. The default target 2.1.5 would be an unsupported pairing, and the recipe never downgrades
  Spring Boot.
- **Spring Boot 4.2:** no Operaton line is built with it yet. Migrate on Spring Boot 4.1, or wait for the matching
  Operaton line.

**Going straight to 2.2 at the cut-over.** Operaton 2.2 records the schema level `7.25.0`. With a 2.2.x target,
`migrate.sh` reminds you of it in its next steps:
`Operaton 2.2.0-RC1 records schema version 7.25.0: run <db>_engine_7.24_to_7.25.sql (no DDL) at the cut-over.`
How to handle the marker: step 4 of [Moving from 2.1.x to 2.2.x](#moving-from-21x-to-22x).

### Moving from 2.1.x to 2.2.x

This is a minor upgrade within Operaton 2.x, together with the Spring Boot upgrade from 4.0 to 4.1. You can do it
before or after the production cut-over:

1. Bump `operaton.version` and the Spring Boot parent **together**, to the pair that `scripts/latest-versions.sh`
   prints. Do it by hand: `scripts/migrate.sh` converts Camunda code, and it is not tested for upgrades within
   Operaton 2.x.
2. Migrate the Spring Boot 4.1 properties, then read the
   [Spring Boot 4.1 release notes](https://github.com/spring-projects/spring-boot/wiki/Spring-Boot-4.1-Release-Notes):

   ```bash
   mvn -B org.openrewrite.maven:rewrite-maven-plugin:6.46.1:run \
     -Drewrite.recipeArtifactCoordinates=org.openrewrite.recipe:rewrite-spring:6.37.0 \
     -Drewrite.activeRecipes=org.openrewrite.java.spring.boot4.SpringBootProperties_4_1
   ```

3. Check for Scala version clashes, because the unshaded FEEL brings Scala libraries onto your classpath:
   `mvn dependency:tree -Dincludes=org.scala-lang,com.fasterxml.jackson.module`.
4. Handle the schema marker `7.25.0`. The 2.2 upgrade script `*_engine_7.24_to_7.25.sql` contains no DDL: its only
   statement inserts this row into `ACT_GE_SCHEMA_LOG`. Liquibase applies it for you (changeSet `7.24-to-7.25`).
   With Flyway or DBA-managed SQL, add the script (release asset `operaton-sql-scripts-7.25.0.tar.gz`) or skip it:
   the engine ignores the marker, and [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql) accepts
   both levels. Details: [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).
5. Deploy it as a normal rolling update: from 2.1 to 2.2 that is supported, and the marker does not block a rollback.
   This differs from the Camunda-to-Operaton cut-over, where Camunda and Operaton nodes must never run side by side.
   Go one minor at a time, because schema compatibility is promised only between consecutive minors.

<a id="7-keeping-up-afterwards"></a>

## Keeping up afterwards

Operaton ships a patch every month and a minor every April and October, with no LTS (long-term support) line
([roadmap](https://operaton.org/roadmap/)). Staying supported on community terms means following that release train.
For each patch:

1. Bump `operaton.version` and the Spring Boot parent **together** to the pair that `scripts/latest-versions.sh`
   prints, because Operaton supports only its paired Spring Boot version.
2. Run `scripts/smoke-test.sh --base-url <staging-url> --require-operaton` on staging.

Maven Central's `<release>` metadata can point to a release candidate, so pin exact versions. Configure Dependabot to
group `org.operaton*`, and to ignore Spring Boot minor/major updates and any proposed `-M`/`-RC` version, so that the
bot never breaks the pairing or proposes a pre-release.

## Watch out

Each entry names the symptom you see, its cause and the fix.

- **Symptom:** `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper`.
  **Cause:** a blanket Jackson 3 recipe hit a Spin configurator, for example the stock `UpgradeSpringBoot_4_0`.
  **Fix:** restore the Jackson 2 version of the class. The migration needs no Jackson 3 step: `MigrateSpringBoot4App`,
  the recipe that `scripts/migrate.sh` runs on a Spring Boot 4 project, has none.
- **Symptom:** JSON variables serialize dates as numbers.
  **Cause:** a "migrated" Spin configurator lost `JavaTimeModule`.
  **Fix:** the same as above, plus a test that the configurator is active.
- **Symptom:** Spin, REST or client customizations written against `tools.jackson.*` no longer compile.
  **Cause:** they were written for Camunda's `-jackson3` artifacts, and Operaton 2.x Spin, REST and client are
  Jackson 2 only.
  **Fix:** rewrite them to `com.fasterxml.jackson.*` ([Coming from Camunda's Jackson 3 opt-in](#coming-from-camundas-jackson-3-opt-in)).
- **Symptom:** `WARN: Operaton 2.1.5 is built with Spring Boot 4.0.8 (only that pairing is supported), the project is on Spring Boot 4.1.1.`
  **Cause:** the target does not match your Spring Boot minor.
  **Fix:** use `--target 2.2.0` once it is GA, and `--target 2.2.0-RC1` for rehearsals only
  ([Choosing 2.1.x or 2.2.x](#choosing-21x-or-22x)).
- **Symptom:** the build resolves `2.2.0-RC1`.
  **Cause:** Maven metadata points to the release candidate.
  **Fix:** pin `org.operaton.bpm:operaton-bom:<v>`, and make Renovate/Dependabot ignore `-RC`/`-M` versions.
- **Symptom:** `JAXBContext implementation could not be found. WADL feature is disabled.` at startup.
  **Cause:** Jersey on Spring Boot 4.
  **Fix:** none needed; the message is harmless.
