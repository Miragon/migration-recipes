# 03 · OpenRewrite recipes

This chapter explains how to convert the code of a Camunda 7.24 Spring Boot application to Operaton 2.x
automatically, and what you still have to fix by hand. It is for the developers who run the conversion, after the
[assessment](02-assessment.md). OpenRewrite is a tool that changes source code with **recipes**: a recipe is an
automated code transformation, for example "rename this package". A **composite recipe** runs a list of other
recipes in order, and each one sees the result of the one before. On Spring Boot 3.5? Read
[Coming from Spring Boot 3.5](15-coming-from-spring-boot-3.md) first.

**In short**
- **Run [`scripts/migrate.sh`](../scripts/migrate.sh).** It detects the Spring Boot version of your build. On Spring
  Boot 4, which on Camunda 7.24 means Camunda EE (7.24.3-ee or later), it runs the composite recipe
  `starterpack.operaton.MigrateSpringBoot4App` once and converts Camunda 7.24 to Operaton 2.x in one change
  ([recipe-toolchain decision, D2](01-migration-path-and-decisions.md#d2)). The recipes live in
  [`rewrite/rewrite.yml`](../rewrite/rewrite.yml); they wrap Operaton's official recipe and fix its bugs and gaps.
- **Choose the target that matches your Spring Boot minor.** The default `--target 2.1.5` fits Spring Boot 4.0. For
  Spring Boot 4.1, use `--target 2.2.0` once it is GA (due 2026-10-23), and `2.2.0-RC1` for rehearsals only. The
  recipe never downgrades Spring Boot; if the minors differ, `migrate.sh` warns and recommends the matching target.
- **An EE build needs the Camunda EE repository while the recipe runs**, because the rewrite plugin resolves all
  dependencies before any recipe starts. After the conversion, the Operaton build no longer needs it: remove the
  repository and its credentials from the build. Revoke the credentials only after the rollback window has closed,
  because a rebuild of the Camunda rollback build still needs them.
- **Always run with `--dry-run` first, on a clean branch:** a dry run only writes a patch for you to review. Then
  apply, run `scripts/verify-leftovers.sh`, build, test, and commit the result as one change.
- **Never run Operaton's official recipe alone, and never the generic `org.operaton.rewrite.MigrateFromCamunda`.**
  On a Spring Boot 4 project the official recipe leaves the Camunda `-4` starters in the build, which then fails, and
  it writes Operaton 1.0.x, an ended Spring Boot 3.5 line. `MigrateFromCamunda` does not rename `camunda.bpm.*`
  keys, so Operaton silently ignores your whole YAML configuration.
- **Recipes only change the repository.** Deployed definitions, configuration outside the repository, the admin group
  data and the Camunda EE features stay manual ([gap list](#gap-list-what-stays-manual)).

## What to do

1. **Make sure code and database are on Camunda 7.24**, Java 17+ (Step 0, see [Assessment](02-assessment.md)),
   because the recipes rely on the Camunda 7.24 coordinates and Operaton uses the 7.24 database schema.
2. **Run `scripts/assess.sh`.** It reports the edition (CE or EE), the Spring Boot version, the migration path, the
   recommended Operaton target and the right next command, so that you start with the correct options.
3. **Check the pinned versions** with `scripts/latest-versions.sh`, which compares the newest releases with the
   versions this pack pins and shows which Operaton line matches your Spring Boot minor.
4. **On an EE build, provide the EE repository credentials for the run**: the server id `camunda-bpm-nexus-ee` in
   `~/.m2/settings.xml`, or `MAVEN_ARGS="-s <settings with the EE credentials>"`. Without them the run fails while
   resolving dependencies.
5. **Preview on a clean branch:** `scripts/migrate.sh --dry-run ~/src/order-service`. The dry run changes nothing.
   Read `target/rewrite/rewrite.patch` to see what the recipes would change.
6. **Apply:** `scripts/migrate.sh --with-infra-env ~/src/order-service` (on Spring Boot 4.1, add `--target 2.2.0`
   once it is GA).
   Commit the recipe result as one change, so that your own fixes stay in a separate commit that reviewers can tell
   apart.
7. **Check the result:** run `scripts/verify-leftovers.sh ~/src/order-service` to find
   [leftovers](#check-leftovers-scriptsverify-leftoverssh), the Camunda references that no recipe converted. Then run
   `mvn -B clean verify`. Fix the [gap list](#gap-list-what-stays-manual) by hand.
8. **Remove the Camunda EE repository and its credentials** (including CI secrets) from the Operaton build, and prove
   that the build resolves from Maven Central alone, because Operaton needs nothing from the EE repository. Keep the
   credentials themselves valid until the rollback window closes: a rebuild of the Camunda build you would roll back
   to still needs them ([Cut-over, rollback and operations](11-cutover-rollback-and-operations.md)).

The commands of the Spring Boot 4 path in one place:

```bash
scripts/assess.sh . > assessment.md          # edition, path, recommended target, findings, next command
scripts/migrate.sh --dry-run .               # preview: target/rewrite/rewrite.patch, nothing changed
scripts/migrate.sh --with-infra-env .        # Spring Boot 4.0 -> Operaton 2.1.5 (default target)
scripts/migrate.sh --with-infra-env --target 2.2.0 .   # Spring Boot 4.1 -> Operaton 2.2.0 (once GA, 2026-10-23)
scripts/migrate.sh --dry-run --target 2.2.0-RC1 .       # Spring Boot 4.1 rehearsal before the GA (never production)
scripts/verify-leftovers.sh .                # leftovers; exit 1 on MUST-FIX
mvn -B clean verify                          # then remove the EE repository + credentials from the build, commit once
```

## What the official recipe does

Operaton publishes one official migration recipe. What it covers, and what it gets wrong, explains why this pack
wraps it.

`org.operaton:migrate-camunda-recipe:1.0.1` ([source](https://github.com/operaton/migrate-from-camunda-recipe))
renames artifacts, packages, `Camunda*` types and constants, descriptor namespaces, `META-INF/services` file names
and `camunda.bpm` → `operaton.bpm`. It correctly leaves `org.camunda.feel` alone, because Operaton still uses the
Camunda FEEL engine. 1.0.1 is the latest release, and its main branch has not changed the recipes since.

It also has two silent effects:

- It changes `Groups.CAMUNDA_ADMIN` → `OPERATON_ADMIN`. This changes a runtime value: your code now refers to the
  `operaton-admin` group, and nothing moves the members of `camunda-admin` into it. Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).
- It turns EE webapp artifacts (`camunda-bpm-spring-boot-starter-webapp-ee`, `camunda-webapp-webjar-ee`) into CE
  artifacts, so Camunda Enterprise features disappear without an error
  ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)).

On a Camunda 7.24 EE project on Spring Boot 4, the official recipe alone falls short:

- It maps **none** of the Spring Boot 4 starters with the `-4` infix, none of the `-jackson3` artifacts, and not
  `camunda-bpm-spring-boot-starter-webapp-core`. It renames the Java imports to `org.operaton.*` but leaves these
  Camunda artifacts in the build, which then fails.
- It always writes Operaton **1.0.x** versions, an ended Spring Boot 3.5 line, and leaves a `${camunda.version}`
  property behind.
- It deletes `camunda.bpm.license-file`, but leaves the EE repository in `<repositories>` alone.
- It carries EE-only engine settings such as `queryExpressionAllowListEnabled` over into
  `operaton.bpm.generic-properties`, where they stop the Operaton start. Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).

The pack's composite recipe closes these gaps ([What the composite adds](#what-the-composite-adds)).

## Run `scripts/migrate.sh`

`scripts/migrate.sh` runs the recipes on a Maven or Gradle project with the pinned versions, the right recipe
artifacts and the file masks they need. It picks the path from the Spring Boot version of your build.

```text
scripts/migrate.sh [--source auto|boot4|boot3] [--dry-run] [--target 2.1.5] [--spring-boot <v>] [--with-infra-env]
                   [--with-form-keys] [--hop 1|2|all] [--plugin-version 6.46.1] [--recipe-version 1.0.1]
                   [--rewrite-spring-version 6.37.0] [--gradle-plugin-version 7.39.0] [--rewrite-yml <file>]
                   [--force] [project-dir]
```

The main options:

- **`--source auto|boot4|boot3`** (default `auto`): the migration path. `auto` picks **boot4**, the Spring Boot 4
  path, if the build uses Spring Boot 4 (parent `spring-boot-starter-parent`, imported `spring-boot-dependencies` or
  Gradle plugin `org.springframework.boot` 4.x) or any `camunda-bpm-spring-boot-starter-4*` artifact. Otherwise it
  picks **boot3**, the Spring Boot 3.5 path with two hops. Setting the other value overrides the detection with a
  warning.
- **`--dry-run`**: changes nothing and writes `target/rewrite/rewrite.patch` (Gradle:
  `build/reports/rewrite/rewrite.patch`).
- **`--target <2.x>`**: the Operaton version (default 2.1.5). Spring Boot 4.0 goes to 2.1.5, Spring Boot 4.1 to
  2.2.0 (GA due 2026-10-23; 2.2.0-RC1 for rehearsals only, never production). The script reads the Spring Boot
  version the target is built with from `org.operaton.bpm:operaton-root:<version>` on Maven Central. A pre-release
  target prints `WARN: --target 2.2.0-RC1 is a pre-release; use released versions for production (decision D1)`.
- **`--spring-boot <v>`**: overrides the Spring Boot version paired with `--target`, for example when Maven Central
  is not reachable.
- **`--with-infra-env`**: also renames `CAMUNDA_BPM_*` → `OPERATON_BPM_*` in Dockerfiles, `.env`, compose and
  k8s/Helm YAML, but not in CI files (recipe `InfraEnvVars`).
- **`--with-form-keys`**: rewrites `camunda-forms:` → `operaton-forms:` in BPMN (recipe `FormKeys`).
  Camunda 7.24 cannot resolve these keys. Once versions with these keys have open tasks, you can no longer roll back
  by redeploying the Camunda build (a rollback hard stop). See the
  [Camunda Forms keys decision (D4)](01-migration-path-and-decisions.md#d4) and the warning below.
- **`--hop 1|2|all`**: only for the Spring Boot 3.5 path
  ([Recipes of the Spring Boot 3.5 path](#recipes-of-the-spring-boot-35-path)). On a Spring Boot 4 project,
  `migrate.sh` rejects it before it touches anything, because the Spring Boot 4 path has no hops.
- **`--force`**: runs on a dirty working tree or outside git, so the recipe changes mix with yours. Use it on
  throw-away copies only. `MIGRATION_REPORT.md`, `.operaton-migration-ignore` and
  `migration/` in the project root never count as dirty.

**What the script prints.** Before the recipe runs, `migrate.sh` shows the detected source, the path and the Spring
Boot pairing, so that you can stop a wrong run early. For a Camunda 7.24.16-ee build on Spring Boot 4.0.8:

```text
==> Source: Spring Boot 4 (boot4; detected: Spring Boot 4.0.8, parent spring-boot-starter-parent in pom.xml)
==> Path: Camunda 7.24 -> Operaton 2.1.5 in one step (one commit, one cut-over)
==>   Spring Boot 4.0.8 matches the 4.0 line Operaton 2.1.5 is built with (4.0.8): raised to 4.0.8 if lower, never downgraded
```

After the run it lists the next steps: review the diff, scan for leftovers, build and test, fix the
[gap list](#gap-list-what-stays-manual), and, on an EE build, remove the EE repository and its credentials before
you commit. With a 2.2.x target it also reminds you of the schema-log script `<db>_engine_7.24_to_7.25.sql`
([Moving from 2.1.x to 2.2.x](12-operaton-2-and-spring-boot-4.md#moving-from-21x-to-22x)).

**Spring Boot is never downgraded.** If your Spring Boot minor matches the target's (4.0 for 2.1.5), the recipe raises
Spring Boot at most to the patch the target is built with, for example 4.0.5 to 4.0.8. If the minors differ, it
leaves Spring Boot as it is and warns:

```text
WARN: Operaton 2.1.5 is built with Spring Boot 4.0.8 (only that pairing is supported), the project is on Spring Boot 4.1.1. Spring Boot is left as it is (no downgrade, no minor upgrade by the recipe).
WARN:   Recommended for Spring Boot 4.1: --target 2.2.0 once it is GA (due 2026-10-23); --target 2.2.0-RC1 for rehearsals only, never production.
```

The other way round (Spring Boot 4.0 with `--target 2.2.0-RC1`), the warning recommends `--target 2.1.5`, or
upgrading the project to Spring Boot 4.1 first, in its own commit. Which line to choose:
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#choosing-21x-or-22x).

**Camunda EE builds.** The rewrite plugin resolves all dependencies, including test dependencies, before the recipes
run. So a build with `7.24.N-ee` versions, `-ee` or `-jackson3` artifacts, `-4` starters or the EE repository needs
the Camunda EE repository credentials for the run: the server id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or
`MAVEN_ARGS="-s <settings with the EE credentials>"`. `migrate.sh` prints this hint for every EE build, and again
after a run that failed with resolution, 401 or 403 errors. After the migration the Operaton build no longer needs
the EE repository.

**Build tools.** The script does not change your build files. For Maven, it calls the plugin by its coordinates
(with `./mvnw` if present). For Gradle, it writes a temporary init script. Pass extra arguments in `MAVEN_ARGS`
(split on spaces, so no spaces inside one argument) or `GRADLE_ARGS`. Run multi-module builds from the reactor root.
The raw Maven command is in [`rewrite/README.md`](../rewrite/README.md). On Gradle, three limits apply:

- The Spring Boot 4 path has not been run end to end on a Gradle build; only the detection and the assessment were
  tested there.
- Version catalogs (`gradle/libs.versions.toml`) are never migrated; `migrate.sh` warns about it.
- The Maven-only steps (property values and renames, removing redundant versions and duplicate dependencies) do
  nothing on Gradle builds.

<a id="3-versions-and-plugin-choice"></a>

## Versions and plugin choice

The pack pins every tool version, so that each run is reproducible and avoids known bugs of other versions:

- **`org.openrewrite.maven:rewrite-maven-plugin` 6.46.1** is the newest version on Central. It rewrites the contents
  of `META-INF/services` files and the `${camunda.version}` value. The 6.28.1 named in the upstream README does
  neither.
- **`org.operaton:migrate-camunda-recipe` 1.0.1** is the official recipe.
- **`org.openrewrite.recipe:rewrite-spring` 6.37.0** keeps nested YAML nested. The 6.18.0 that the official recipe
  brings in transitively appends a flattened block instead. 6.37.0 also provides `UpgradeSpringBoot_4_0`.
- **`org.openrewrite:plugin` (Gradle) 7.39.0**: versions 7.40+ need `rewrite-bom` 8.91.0, which is not on Central.
- **Operaton target 2.1.5** is the default of `--target`, built with Spring Boot 4.0.8.

New OpenRewrite releases go to the Code Genome Project repository (login required), so the pack pins the newest
versions on Central. `scripts/latest-versions.sh` compares the releases with the pins. Pin Operaton too: Maven's
`<release>` metadata of `operaton-bom` can point to an RC (release candidate).

## What the composite adds

The entry point of the Spring Boot 4 path is the composite recipe `starterpack.operaton.MigrateSpringBoot4App`. It
runs `Boot4PreFixes`, `PreFixes`, then the official recipe, then `PostFixes`, `ScriptImports` and
`AlignVersionsOperaton2`, in this order. It runs none of the Spring Boot 4 or Jackson 3 upgrade recipes, because the
project is on Spring Boot 4 already. The other recipes in `rewrite/rewrite.yml` are optional or belong to the
[Spring Boot 3.5 path](#recipes-of-the-spring-boot-35-path).

- **`Boot4PreFixes`** runs first and maps what the official recipe does not know, straight to Operaton 2.x:
  - It switches `camunda-bom` to `operaton-bom` with the target version **first**. Once the BOM is imported, every
    Operaton artifact is managed and the build model stays resolvable; otherwise later Maven recipes would write
    explicit versions.
  - It sets the `camunda.version` / `version.camunda` property values to the target. An EE version such as
    `7.24.16-ee` counts as "newer" than any Operaton 2.x version, so no upgrade recipe would ever replace it.
  - It maps the Camunda artifacts below without versions, so that `operaton-bom` manages them, and deletes
    `camunda.bpm.license-file`, because Operaton has no license mechanism.
- **`PreFixes`** runs while the `org.camunda` types are still visible (before the official recipe renames them):
  - `getExecutionContext()` → `getBpmnExecutionContext()`
  - the shaded EL package `org.camunda.bpm.impl.juel.jakarta.el` → `jakarta.el`
  - `Mocks*` → `org.operaton.bpm.engine.impl.mock`
  - bean-name literals (`camundaBpmDataSource` …), `"camunda.cfg.xml"`, and `"camunda.bpm…"` prefixes in
    `@ConditionalOnProperty` / `@ConfigurationProperties`
- **`PostFixes`** closes the gaps of the official recipe:
  - `management.health.camunda`, `logging.level.org.camunda.*` in `.properties`, logback/log4j2 logger names
  - `org.camunda.templateengines`, `camunda.cfg.xml` → `operaton.cfg.xml`
  - adds the JUnit 5 test starter, drops the empty `operaton-bpm-junit5`, maps `camunda-engine-rest-openapi` /
    `camunda-sql-scripts`
  - text fixes, which run last: `camunda-admin` in `*WhitelistPattern`, `disable-strict-camunda-form-parsing`, SPI
    contents, `spring.factories`, `*.imports`
- **`ScriptImports`** rewrites `org.camunda.{bpm,spin,connect,commons,templateengines}.` → `org.operaton.…` in
  BPMN/DMN/CMMN and script files. Scripts reference these packages as text, so they deploy fine and fail only at
  runtime. It never touches `org.camunda.feel` or the `camunda:` namespace.
- **`AlignVersionsOperaton2`** replaces the 1.0.x versions of the official recipe. It only touches build files:
  - It removes duplicate dependencies first. Two Camunda artifacts can map to one Operaton artifact (`-4-rest` and
    `-4-rest-jackson3`, or the Spin `json-jackson` and `json-jackson3` artifacts). Maven 3.10 refuses a pom with a
    duplicate, and the version recipes would see only one of the two copies.
  - It moves every `org.operaton*` artifact to the target and removes explicit versions that equal the ones
    `operaton-bom` manages.
  - It renames `camunda.version` → `operaton.version` and `version.camunda` → `version.operaton`.
  - It raises the Spring Boot parent, an imported `spring-boot-dependencies`, the `spring-boot-maven-plugin` and the
    Gradle plugin to the patch the target is built with (upgrade only). `migrate.sh` drops this step when your Spring
    Boot minor differs from the target's.
- **`InfraEnvVars`** (optional) renames `CAMUNDA_BPM_` → `OPERATON_BPM_` in Dockerfiles, `.env`, compose and YAML
  under `k8s/`, `kubernetes/`, `helm/`, `charts/`, `deploy/`, `ops/`. Spring Boot binds these variables to
  `camunda.bpm.*`, which Operaton ignores silently. It skips CI files, because they hold secret references.
- **`FormKeys`** (optional) rewrites `camunda-forms:` → `operaton-forms:` in BPMN. This is the `operaton-forms:`
  option of the [Camunda Forms keys decision (D4)](01-migration-path-and-decisions.md#d4). The decision advises
  against it: if the Operaton Tasklist renders the forms, use `formRef` instead.

The table shows how `Boot4PreFixes` maps the Camunda EE artifacts. Operaton has no `-4` infix (one set of starters
per line) and no Jackson 3 Spin, REST or client artifacts:

| Camunda 7.24 EE (Spring Boot 4) | Operaton 2.x | Note |
|---|---|---|
| `org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4[-rest\|-webapp\|-webapp-core\|-security\|-external-task-client]` | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[…]` | no version, managed by `operaton-bom` |
| `camunda-bpm-spring-boot-starter-4-webapp-ee` | `operaton-bpm-spring-boot-starter-webapp` | EE webapp features are lost ([D17](01-migration-path-and-decisions.md#d17)) |
| `camunda-bpm-spring-boot-starter-4-test` | `operaton-bpm-spring-boot-starter-test-junit5` | via `-test`; `PostFixes` keeps the JUnit 4 flavour only for JUnit 4 tests ([D11](01-migration-path-and-decisions.md#d11)) |
| `camunda-bpm-spring-boot-starter-webapp-core` (classic name) | `operaton-bpm-spring-boot-starter-webapp-core` | not mapped by the official recipe either |
| six `-jackson3` artifacts (7.24.16-ee) | their Jackson 2 counterparts | [Coming from Camunda's Jackson 3 opt-in](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in) |

**What the result looks like.** On a Camunda 7.24.16-ee test build with target 2.1.5, the pom ends up with
`operaton.version` 2.1.5 (formerly `camunda.version` 7.24.16-ee), `org.operaton.bpm:operaton-bom:${operaton.version}`,
one `operaton-bpm-spring-boot-starter-rest` for `-4-rest` plus `-4-rest-jackson3`,
`operaton-spin-dataformat-json-jackson`, `operaton-bpm-spring-boot-starter-test-junit5`, no explicit Operaton
versions and an unchanged parent. `camunda: bpm:` became `operaton: bpm:`, the license file setting is gone, and the
Java imports are renamed.

> [!WARNING]
> **`ScriptImports` and `FormKeys` produce definition versions that only Operaton can run.** Camunda 7.24 cannot run
> `import org.operaton.spin.Spin` or resolve `operaton-forms:`. Once process instances run on such versions,
> rollback is a hard stop
> ([rollback and point-of-no-return decision, D15](01-migration-path-and-decisions.md#d15)). To keep the way back
> open, make scripts package-free (only process variables and `S(…)`, no class names) or use `formRef`. Deploy them
> on Camunda 7.24 and migrate the running instances to the new versions there, **before** the cut-over (the
> production switch from Camunda to Operaton). Details:
> [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

<a id="how-the-spring-boot-4-path-is-tested"></a>

### How the Spring Boot 4 path is tested: `tools/test-boot4-path.sh`

The Spring Boot 4 path needs Camunda EE artifacts, which are not on Maven Central. So that anyone can check the path
without EE access, [`tools/test-boot4-path.sh`](../tools/test-boot4-path.sh) runs it end to end against a stub EE
repository:

1. It writes stub POMs (with empty jars) for the `-4` starters, `-4-webapp-ee`, the six `-jackson3` artifacts and
   `camunda-bom:7.24.16-ee`. Each stub delegates to its public CE 7.24.0 counterpart on Maven Central.
2. It derives a Spring Boot 4 test project from `examples/camunda7-spring-boot-legacy` (parent 4.x,
   `camunda.version` 7.24.16-ee, `-4-webapp-ee`, `-4-rest` plus `-4-rest-jackson3`, `-4-test`,
   `camunda-spin-dataformat-json-jackson3`, `camunda.bpm.license-file`).
3. It runs `assess.sh` and `migrate.sh` (`--hop` must be rejected, `--dry-run` must change nothing, then the real run
   with `--with-infra-env`), checks the result and runs `verify-leftovers.sh`.
4. It deletes the stubs and builds the result with Maven Central only (`mvn -B -DskipTests verify`).

```bash
tools/test-boot4-path.sh
tools/test-boot4-path.sh --spring-boot 4.1.1 --target 2.2.0-RC1
```

Exit code 0 means all checks passed; a run takes about a minute. It needs git, JDK 17+ (`JAVA_HOME`), Maven (3.9+
recommended) and direct access to Maven Central: it ignores `~/.m2/settings.xml`, so that a mirror cannot hide the
stub repository, and therefore cannot run as is behind a Central-only mirror. `--keep` keeps the work directory,
which is always kept when a check fails. CI runs it in the job
"Recipes end-to-end (Camunda 7.24 EE on Spring Boot 4 -> Operaton 2.x)" for Spring Boot 4.0.8 with target 2.1.5 and
Spring Boot 4.1.1 with target 2.2.0-RC1.

**What the test cannot prove.** It never ran against the real Camunda EE repository. The stubs delegate to CE 7.24.0
jars, the `-jackson3` artifact names come from Camunda's 7.24.16 patch notes, and the package names inside the real
`-4` starters are not verified. Dry-run on your own build first, and review the diff.

### Recipes of the Spring Boot 3.5 path

`rewrite/rewrite.yml` also holds the two hops of the Spring Boot 3.5 path:

- `starterpack.operaton.MigrateSpringBootApp` (Hop 1) converts Camunda 7.24 to the Operaton 1.1.5 checkpoint. Its
  last step, `AlignVersions`, sets Operaton 1.1.x and Spring Boot 3.5.16.
- `starterpack.operaton.UpgradeToOperaton2` (Hop 2) moves Operaton 1.1.x to 2.x with Spring Boot 4.

`PreFixes`, `PostFixes` and `ScriptImports` are shared with the Spring Boot 4 path. How and when to use the hops:
[Coming from Spring Boot 3.5](15-coming-from-spring-boot-3.md).

Never run the hops on a Spring Boot 4 project. Hop 1 there leaves the `-4` starters without a managed version, so
the pom cannot be built. Hop 2 alone renames nothing, rewrites the Spin configurator to Jackson 3, and silently
downgrades Spring Boot 4.1 to 4.0.8. That is why `migrate.sh` rejects `--hop` on Spring Boot 4.

<a id="52-gap-list-what-the-official-recipe-does-not-touch"></a>

## Gap list: what stays manual

Recipes change only the files in your repository, and only the patterns they know. Fix the items below by hand.
Several of them fail silently.

- **`"camunda-admin"` literals and the admin group data.** Admins lose their rights. With users stored in the
  engine database (DB identity), the Admin webapp re-opens its setup page, which lets anyone create an admin user
  without logging in ([admin-group decision, D5](01-migration-path-and-decisions.md#d5),
  [Identity, admin group and security](07-identity-admin-group-and-security.md)).
- **Class names in strings** (`"org.camunda.bpm.engine…"`), for example in consumer contracts, allow-lists and
  `Class.forName`. They stay manual by design, because they are often data contracts of downstream consumers
  ([history-exporters decision, D9](01-migration-path-and-decisions.md#d9)).
- **Configuration outside `src/*/resources`** (Helm, config server, CI variables). Operaton silently ignores it. Add
  a fail-fast guard such as
  [`LegacyCamundaConfigGuard`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyCamundaConfigGuard.java),
  which stops the start while such keys exist. Details:
  [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).
- **Webapp path.** The webapps move to `/operaton` unless you set the path explicitly
  ([webapp-path decision, D6](01-migration-path-and-decisions.md#d6)).
- **Already deployed definitions** and their running instances. The engine never rewrites deployed resources. Find
  them with [`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql). Details:
  [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
- **Camunda EE features** ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)). Operaton has
  no counterpart for them, and the recipes cannot decide what replaces them:
  - The EE webapp features (in Cockpit, for example the history view, heatmaps, instance modification, the migration
    UI, batches and reports) disappear without a build error. Details:
    [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md).
  - Operaton needs no license. Remove `camunda-license.txt`, license mounts and secrets. Keep the license key stored
    in the database: it is inert on Operaton, and a rollback needs it.
  - Operaton lacks the EE security hardening (the query expression allow-list, `validateAuthResourceIdExists`, the
    datasource autocommit check). EE-only settings for it stop the Operaton start, no longer compile, or are
    silently ignored. Details:
    [Identity, admin group and security](07-identity-admin-group-and-security.md).
  - Spin, REST or client code written against Jackson 3 (`tools.jackson.*`) must be ported to Jackson 2. Details:
    [Coming from Camunda's Jackson 3 opt-in](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in).
- **The Camunda EE repository and its credentials.** Of the Operaton build, only the recipe run needs them. Remove
  the repository, its `<server>` credentials and the CI secrets from the Operaton build afterwards, and revoke the
  credentials after the rollback window has closed.
- **`gradle/libs.versions.toml`** is not migrated. The build fails until you edit it.
- **Liquibase include of `camunda-changelog.xml`.** Operaton changed the changelog path and author, so a naive
  switch fails on the first start. Details:
  [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md#liquibase).
- **Distros and community extensions.** The recipes leave them alone; swap them by hand. Details:
  [Ecosystem, support and resources](14-ecosystem-support-and-resources.md).
- **Custom `ELResolver`s on Operaton 2.x:** delete `ELResolver#getFeatureDescriptors` overrides (removed in Jakarta
  EL 6.0).
- **Comments** in models that text recipes touched, and **test expectations** (`camunda-admin`, form keys, class
  names). Review them by hand.

## Check leftovers: `scripts/verify-leftovers.sh`

Operaton ignores leftovers or fails on them, often without an error message. `scripts/verify-leftovers.sh` finds
them after the conversion:

```bash
scripts/verify-leftovers.sh [--strict] [--ignore-file f] [--exclude glob] [--max n] [project-dir] | tee leftovers.md
```

The script exits with **1 if any MUST-FIX finding remains**, so use it as a CI gate. It reports three levels:

- **MUST-FIX** findings must be fixed. They include `org.camunda.{bpm,spin,connect,commons,templateengines}`,
  `camunda.bpm.*`, `CAMUNDA_BPM_*`, `camunda.cfg.xml`, Camunda descriptor namespaces, `webjars/camunda`,
  `camunda-changelog.xml` and `camunda*` bean names. For Camunda EE and Spring Boot 4 builds they also include
  leftover `-4` starters (`STARTER_4`), `-jackson3` artifacts (`JACKSON3_ARTIFACT`), `camunda-engine-spring-6`
  (`ENGINE_SPRING_6`), other `-ee` artifacts (`EE_ARTIFACT`), `7.24.N-ee` versions in build files (`EE_VERSION`),
  the EE-only query expression allow-list settings (`EE_QUERY_EXPRESSION_ALLOWLIST`), `validateAuthResourceIdExists`
  (`EE_AUTH_RESOURCE_VALIDATION`) and calls of the license API (`EE_LICENSE`).
- **WARN** findings do not fail the run, but need a look. They include `camunda-admin`, `/camunda` paths
  ([webapp-path decision, D6](01-migration-path-and-decisions.md#d6)), `camunda-forms:`
  ([Camunda Forms keys decision, D4](01-migration-path-and-decisions.md#d4)), the EE repository
  (`EE_REPOSITORY`), license files and settings (`EE_LICENSE`), and unused `-ee` properties or `-ee` values outside
  the build, such as Docker image tags (`EE_VERSION`).
- **INFO** findings are expected: the `camunda:` namespace, which you keep for now
  ([BPMN/DMN namespace decision, D3](01-migration-path-and-decisions.md#d3)), and `org.camunda.feel`, which is
  correct.

The findings that link to this chapter mean:

- **`STARTER_4`:** Camunda's Spring Boot 4 starters have no Operaton artifact of that name. Use
  `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[-x]` without `<version>` (managed by
  `operaton-bom`); `-4-test` becomes `operaton-bpm-spring-boot-starter-test-junit5`, and `-4-webapp-ee` becomes
  `operaton-bpm-spring-boot-starter-webapp`. Left as is, the build fails.
- **`EE_REPOSITORY`:** only the recipe run needed the Camunda EE repository. Remove it, its `<server>` credentials
  and the CI secrets from the Operaton build, and prove that the build resolves from Maven Central alone. Revoke the
  credentials only after the rollback window has closed.
- **`CAMUNDA_PKG`:** `org.camunda.(bpm|spin|connect|commons|templateengines)` becomes `org.operaton.…` in code,
  logger names, SPI files, models and the build. In build coordinates the artifactId changes too
  (`camunda-*` → `operaton-*`). Class names in strings may be data contracts, so fix their consumers too. In a pom,
  this generic finding is dropped when one of the specific rules above fired for the same dependency.

The scan also covers the top-level `.mvn/*.xml` and `.mvn/maven.config`. By default it skips comment lines, files
that contain the marker `operaton-migration-helper`, and the `migration/` folder, because migration helpers handle
the legacy names on purpose. `--strict` scans them too.

If a leftover is intended, accept it in `.operaton-migration-ignore` in the project root, each entry with a reason:

```text
# <RULE|*>  <path-glob>  [<extended regex the line must match>]
# Decision D6: the webapps stay at /camunda for the cut-over release
WEBAPP_PATH  src/main/resources/application.yaml
CAMUNDA_PKG  src/main/java/**/Consumer.java  "org\.camunda\.bpm\.engine\.impl\.history"  # consumer contract
```

A trailing `# comment` is allowed after the glob or after a quoted regex. After an unquoted regex, it becomes part
of the regex.

## Combining with Java / Spring Boot upgrade recipes

OpenRewrite also has recipes for Java and Spring Boot upgrades. Keep them out of the migration run, so that each
diff has one cause, and run them as separate steps with one commit each:

1. If you want to move from Spring Boot 4.0 to 4.1 (and therefore to Operaton 2.2), upgrade Spring Boot first, in its
   own commit. `migrate.sh` suggests this order when your Spring Boot minor is older than the target's.
2. Run the migration (`scripts/migrate.sh`).
3. Optionally run `org.openrewrite.java.migrate.UpgradeToJava21`.

The recipes rely on the Camunda 7.24 coordinates: the legacy `org.camunda.bpm.extension` / `org.camunda.bpm.assert`
coordinates are not mapped, so move them first ([Assessment](02-assessment.md#prerequisites-step-0)).

<a id="11-troubleshooting"></a>

## Troubleshooting

When a run fails, `migrate.sh` prints the path of its log (Maven builds also get a link to this section). Search
the table for the error text from that log.

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: --hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2). This project is on Spring Boot 4 …` | `--hop` on a Spring Boot 4 project | Run without `--hop`. Add `--source boot3` only if the detection is wrong. |
| `ERROR: --source must be auto, boot4 or boot3 (got 'foo')` | Typo in `--source` | Use one of the three values. |
| Resolution errors with `401`/`403` or `Could not resolve` on an EE build | No EE repository credentials during the run | Add the `camunda-bpm-nexus-ee` server credentials, or pass `MAVEN_ARGS="-s <settings with the EE credentials>"`. |
| `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing` | Hop 1 ran on a Spring Boot 4 project (for example with `--source boot3`): the `-4` starters stay, without a managed version | Discard that result and run `migrate.sh` without `--hop` and `--source boot3` (`MigrateSpringBoot4App`). |
| `'dependencies.dependency.(groupId:artifactId:type:classifier)' must be unique` | Two Camunda artifacts became one Operaton artifact, and the recipe file has no duplicate removal | Use the current `rewrite/rewrite.yml` (`AlignVersionsOperaton2` removes duplicates first). |
| `WARN: Operaton 2.1.5 is built with Spring Boot 4.0.8 (only that pairing is supported), the project is on Spring Boot 4.1.1. …` | Target and Spring Boot minor do not match | `--target 2.2.0` once GA, `2.2.0-RC1` for rehearsals ([Choosing 2.1.x or 2.2.x](12-operaton-2-and-spring-boot-4.md#choosing-21x-or-22x)). |
| `ERROR: cannot determine the Spring Boot version of Operaton <v> (offline?). Pass --spring-boot <version>.` | Maven Central not reachable, and the target is not one of the versions the script knows (it knows 2.0.0, 2.1.0 to 2.1.5 and 2.2.0-RC1) | Pass `--spring-boot <version>`. |
| `Recipe(s) not found: org.operaton.rewrite.spring.MigrateSpringBootApplication` (or `starterpack.operaton.…`) | The recipe artifact, the recipe file path or the recipe ID is wrong | Put recipe 1.0.1 in `recipeArtifactCoordinates`, pass an **absolute** `-Drewrite.configLocation`, and use the correct ID. `mvn …:discover` lists the recipes. |
| `Origin: https://github.com does not match the clone url` | Git provenance with an SSH alias | Use a newer plugin or a normal `origin` URL, or run on a copy. |
| `Could not transfer artifact org.rocksdb:rocksdbjni … Premature end of Content-Length delimited message body` | A mirror truncates large jars | `MAVEN_ARGS="-s /path/central-settings.xml" scripts/migrate.sh …`. On an EE build, these settings must also reach the EE repository. |
| Gradle: `Could not find org.openrewrite:rewrite-bom:8.91.0` | Gradle plugin 7.40+ | Use Gradle plugin 7.39.0 (the default). |
| `Could not transfer metadata … camunda-nexus … 401` | FEEL parent POM | Harmless. |
| BPMN still contains `import org.camunda.spin.Spin` | `.bpmn` is not a plain-text mask, so text recipes skip it | `migrate.sh` passes the masks. In Gradle, `plainTextMask()` replaces the defaults. |
| `operaton.bpm:` as one flattened block at the end of `application.yaml` | The transitive `rewrite-spring` 6.18.0 | Add `rewrite-spring:6.37.0` to the recipe artifacts (`migrate.sh` does). |
| `META-INF/services/…` still lists `org.camunda…` classes | Plugin older than 6.36 | Use plugin 6.46.1, or run `PostFixes`. |
| `operaton-bom` 1.0.3 (on Spring Boot 3.5 also Spring Boot still 3.5.5) | Official recipe alone | Run the composite (`AlignVersionsOperaton2`; Spring Boot 3.5 path: `AlignVersions`). |
| `cannot find symbol … ProcessEngineExtension` / `package org.operaton.bpm.engine.test.mock does not exist` | Official recipe alone | Run the composite, or add `operaton-bpm-spring-boot-starter-test-junit5` and use `org.operaton.bpm.engine.impl.mock.Mocks`. |
| `package org.operaton.bpm.impl.juel.jakarta.el does not exist` | Official recipe alone | Run the composite (`PreFixes`), or import `jakarta.el.*`. |
| `method does not override or implement a method from a supertype` on `getFeatureDescriptors` | Removed in Jakarta EL 6.0 (Operaton 2.x) | Delete the method. |
| `Group has an invalid id: 'operaton-admin' is not a valid resource identifier.` | A `*WhitelistPattern` still allows `camunda-admin` | `PostFixes` fixes `application*`/`bootstrap*` files; elsewhere edit by hand. |
| `cvc-elt.1.a: Cannot find the declaration of element 'process-application'` | `processes.xml` still uses the Camunda namespace | Set the namespace to `http://www.operaton.org/schema/1.0/ProcessApplication`. |
| `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper` | A Jackson 3 recipe (the stock `UpgradeSpringBoot_4_0`, or `--hop 2` on un-renamed code) moved Spin code to Jackson 3 | Restore the Jackson 2 code. `MigrateSpringBoot4App` runs no Jackson 3 step; on the Spring Boot 3.5 path use `--hop 2` after Hop 1. |
| Spin or REST code on `tools.jackson.*` does not compile after the migration | Written for Camunda's `-jackson3` artifacts; Operaton is Jackson 2 only | Port it to `com.fasterxml.jackson.*` ([details](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in)). |
| `ERROR: working tree … is dirty` | Uncommitted or untracked changes in the project | Commit first. Use `--force` only on copies. |
| `OutOfMemoryError` on a large reactor | Not enough heap for the build | Set `MAVEN_OPTS=-Xmx4g`, or pass `-Drewrite.exclusions=**/generated/**` or `-Drewrite.runPerSubmodule=true`. |
