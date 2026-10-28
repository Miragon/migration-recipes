# Recipes: IDs, order, `migrate.sh`, review and troubleshooting

Guide chapter: https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/03-openrewrite-recipes.md
Operaton 2.x details: [12 · Operaton 2 and Spring Boot 4](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/12-operaton-2-and-spring-boot-4.md).
Spring Boot 3.5 path: [15 · Coming from Spring Boot 3.5](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/15-coming-from-spring-boot-3.md).
Tool and Operaton versions: see references/versions.md (the `migrate.sh --help` defaults are the pinned values).

## Contents

1. Rules
2. Recipe IDs
3. What each starter-pack recipe does, in order
4. Running `migrate.sh` (Maven, Gradle, flags, environment, Camunda EE)
5. Reviewing the dry run
6. Official-recipe bugs and how the composite fixes them
7. What no recipe does (manual work after the run)
8. Combining with other OpenRewrite recipes
9. Troubleshooting recipe runs

## 1. Rules

- MUST run the starter-pack composites through `scripts/migrate.sh`. Never run the bare official recipe and never
  `org.operaton.rewrite.MigrateFromCamunda` on a Spring Boot app: only `MigrateSpringBootApplication` renames
  `camunda.bpm.*` keys, and leftover keys are silently ignored at runtime. On a Spring Boot 4 project the official
  recipe alone also leaves the `-4` starters and writes Operaton 1.0.x: a broken build.
- MUST let `migrate.sh` pick the path (`--source auto`, default) and check the `==> Source:` line of every run.
  Spring Boot 4 projects migrate in **one run** (`MigrateSpringBoot4App`, no `--hop`). Spring Boot 3.5 projects take
  Hop 1, then Hop 2. MUST NOT force `--source boot3` (or any `--hop`) on a Spring Boot 4 project: Hop 1 leaves an
  unbuildable POM, Hop 2 alone renames nothing, rewrites the Spin configurator to Jackson 3 and downgrades Spring Boot
  4.1 → 4.0.8. Use `--source` only when the detection is demonstrably wrong.
- MUST dry-run first, on a clean git tree, on a dedicated branch. `migrate.sh` refuses a dirty tree or a non-git
  directory; it ignores `MIGRATION_REPORT.md`, `.operaton-migration-ignore` and `migration/` (untracked or modified), so
  the report and the cut-over pack never block a run. Never pass `--force` on the user's real repository (only on
  throw-away copies) and never `git stash` the user's work to get a clean tree.
- MUST build after the run (`mvn -B clean verify`; `clean` matters, incremental builds hide the generics errors; log
  and wait, SKILL "Long-running commands"). Commits: with the permission asked once in the decision step, commit locally
  per step (the unmodified recipe output, then the manual fixes; never push). Spring Boot 3.5 path: the same per hop,
  each hop separately. Without permission, run in a throw-away clone (`git clone <project-dir> /tmp/opmig-<name>`),
  commit there, and hand the result back as uncommitted changes or a patch.
- MUST have Camunda EE repository access for EE builds while the recipe runs (section 4); never write credentials
  into the project.
- MUST NOT rename `org.camunda.feel` or the `camunda:` namespace URI (`http://camunda.org/schema/1.0/…`). The recipes
  never touch them; neither may your manual fixes or custom recipes.
- MUST NOT use the stock `org.openrewrite.java.spring.boot4.UpgradeSpringBoot_4_0` (Spring Boot 3.5 path, Hop 2): it moves
  Spin code to Jackson 3 and breaks it. Use `starterpack.operaton.UpgradeToOperaton2`.
- A finished recipe run is not a finished migration: continue with `scripts/verify-leftovers.sh` and references/fix-catalog.md.

## 2. Recipe IDs

| ID | Source | Use |
|---|---|---|
| `org.operaton.rewrite.spring.MigrateSpringBootApplication` | official `org.operaton:migrate-camunda-recipe` | wrapped by the composites; never alone |
| `org.operaton.rewrite.MigrateFromCamunda` | official | plain Java only; never for Spring Boot |
| `org.operaton.rewrite.quarkus.MigrateQuarkusApplication` | official | Quarkus (out of scope) |
| `org.operaton.rewrite.deprecation.ReplaceGetExecutionContext` | official, not wired upstream | run by `PreFixes` |
| `ResolveDeprecations` | named in the upstream README/docs | **does not exist**; do not reference it |
| `starterpack.operaton.MigrateSpringBoot4App` | `assets/rewrite.yml` | **Spring Boot 4 path**, all-in, one run |
| `starterpack.operaton.Boot4PreFixes` / `AlignVersionsOperaton2` / `internal.SpringBootPatchForOperaton2` | `assets/rewrite.yml` | parts of `MigrateSpringBoot4App` (do not run alone) |
| `starterpack.operaton.MigrateSpringBootApp` | `assets/rewrite.yml` | Spring Boot 3.5 path, **Hop 1**, all-in |
| `starterpack.operaton.PreFixes` / `PostFixes` / `ScriptImports` / `AlignVersions` | `assets/rewrite.yml` | parts of the runs above (`AlignVersions`: Hop 1 only; do not run alone) |
| `starterpack.operaton.InfraEnvVars` | `assets/rewrite.yml` | optional (`--with-infra-env`; Spring Boot 4 path or Hop 1) |
| `starterpack.operaton.FormKeys` | `assets/rewrite.yml` | optional, only if decision D4 says so (`--with-form-keys`; Spring Boot 4 path or Hop 1) |
| `starterpack.operaton.UpgradeToOperaton2` | `assets/rewrite.yml` | Spring Boot 3.5 path, **Hop 2** (Operaton 2.x + Spring Boot 4) |

There is no released Operaton 1.x → 2.x recipe (`operaton/operaton-rewrite` is an unreleased snapshot). Do not look for one.

## 3. What each starter-pack recipe does, in order

Spring Boot 4 path = `Boot4PreFixes` → `PreFixes` → official `MigrateSpringBootApplication` → `PostFixes` →
`ScriptImports` → `AlignVersionsOperaton2`, then (same run, if requested) `InfraEnvVars`, `FormKeys`.
Spring Boot 3.5 path, Hop 1 = `PreFixes` → official `MigrateSpringBootApplication` → `PostFixes` → `ScriptImports` →
`AlignVersions`, then (same run, if requested) `InfraEnvVars`, `FormKeys`; Hop 2 = `UpgradeToOperaton2`.
Order is semantics: recipes that match `org.camunda` types run before the official recipe; text recipes
(`FindAndReplace`) run last because a file they change becomes plain text for the rest of the run.

| Step | Changes |
|---|---|
| `Boot4PreFixes` (Spring Boot 4 path) | `camunda-bom` → `org.operaton.bpm:operaton-bom` at the target version **first** (changes the managed dependency); `camunda.version` / `version.camunda` values → target; the 8 `-4` starters (incl. `-4-webapp-ee` → `operaton-bpm-spring-boot-starter-webapp`, `-4-webapp-core`, `-4-test` → `-test`, which `PostFixes` turns into `-test-junit5`), the classic `-webapp-core`, the six `-jackson3` artifacts → their Jackson 2 Operaton artifacts, all without `<version>` (managed by `operaton-bom`); deletes `camunda.bpm.license-file` |
| `PreFixes` | `Context.getExecutionContext()` → `getBpmnExecutionContext()` · shaded EL API `org.camunda.bpm.impl.juel.jakarta.el` → `jakarta.el` · `org.camunda.bpm.engine.test.mock.{Mocks,MockExpressionManager,MockElResolver,MocksResolverFactory}` → `org.operaton.bpm.engine.impl.mock.*` · whole string literals `"camundaBpmDataSource"`, `"camundaBpmTransactionManager"`, `"camundaBpmJdbcTemplate"`, `"camundaTaskExecutor"`, `"camunda.cfg.xml"` → `operaton…` · `camunda.bpm` prefixes inside string literals (`@ConditionalOnProperty(prefix=…)`, `@ConfigurationProperties(…)`) → `operaton.bpm`, but not `"org.camunda.bpm…"` class-name literals |
| official recipe | all Camunda 7.24 coordinates → `org.operaton.*` (pinned to `1.0.x`, fixed by `AlignVersionsOperaton2` / `AlignVersions`) · 1075 method renames · 157 constants incl. `Groups.CAMUNDA_ADMIN` → `Groups.OPERATON_ADMIN` (**changes a runtime value**, written fully qualified inline) · type renames (`CamundaBpmProperties` → `OperatonBpmProperties`, …) · `ChangePackage` for `org.camunda.{bpm,spin,commons,connect}` (also YAML `logging.level` keys, Spring XML `class=`) · `processes.xml`/`bpm-platform.xml` namespace · `META-INF/services/org.camunda.*` file names · deletes `camunda.bpm.license-file` · `camunda.bpm.*` → `operaton.bpm.*` in Spring config. Maps `-webapp-ee` and `camunda-webapp-webjar-ee` to CE; leaves `<repositories>` (the EE repository) alone |
| `PostFixes` (LST) | `management.health.camunda` → `management.health.operaton` · `.properties` logging keys `logging.level.org.camunda.{bpm,spin,commons,connect}` · logback `<logger name>`, log4j2 `<Logger>`/`<AsyncLogger>` names (FEEL logger untouched) · `org.camunda.templateengines` package · renames `**/camunda.cfg.xml` → `operaton.cfg.xml` · adds `operaton-bpm-spring-boot-starter-test-junit5` (test) when `org.junit.jupiter.api.*` is used · removes `operaton-bpm-spring-boot-starter-test` unless `org.junit.Test` is used · removes the empty `operaton-bpm-junit5` · maps `camunda-engine-rest-openapi` → `org.operaton.bpm:operaton-engine-rest-openapi` and `camunda-sql-scripts` → `org.operaton.bpm.distro:operaton-sql-scripts` (versioned by schema, `7.24.0`) |
| `PostFixes` (text) | `camunda-admin` → `operaton-admin` **only inside `*WhitelistPattern` / `*-whitelist-pattern` values** of `application*` / `bootstrap*` files · `disable-strict-camunda-form-parsing` (any spelling) → `disableStrictOperatonFormParsing` (also `*.cfg.xml`) · descriptor `xsi:schemaLocation` · `org.camunda.{bpm,spin,connect,commons,templateengines}.` → `org.operaton.…` in `META-INF/services/*` contents, `META-INF/spring.factories`, `META-INF/spring/*.imports` |
| `ScriptImports` (text) | same regex in `*.bpmn`, `*.bpmn20.xml`, `*.dmn`, `*.dmn11.xml`, `*.cmmn`, `*.cmmn11.xml`, `*.groovy`, `*.gvy`, `*.js`, `*.mjs`, `*.py`, `*.rb`, `*.ftl` (also comments and `camunda:class` values of your own relocated classes). Never matches `org.camunda.feel`, `org.camunda.community` or the namespace URI. **Output is Operaton-only** (rollback hard stop, D15) and every changed model is a new definition version on next start. Keep its changes only if the user accepted `org.operaton.*` scripts (D3); the default is the package-free pre-migration release on Camunda 7.24 (SKILL step 3b), after which it finds nothing |
| `AlignVersionsOperaton2` (Spring Boot 4 path) | **removes duplicate dependencies** (`-4-rest` + `-4-rest-jackson3` map to one `operaton-bpm-spring-boot-starter-rest`; `camunda-spin-dataformat-json-jackson` + `-json-jackson3` to one `operaton-spin-dataformat-json-jackson`) · every `org.operaton*` artifact → the target · removes versions equal to the BOM's · `camunda.version` → `operaton.version`, `version.camunda` → `version.operaton` · then `internal.SpringBootPatchForOperaton2`: parent / imported `spring-boot-dependencies` / `spring-boot-maven-plugin` / Gradle plugin → the target's Spring Boot, **upgrade only** within the same minor (dropped by `migrate.sh` when the minor differs). No Jackson 3 step: the Spin configurator stays on Jackson 2 |
| `AlignVersions` (Hop 1) | every `org.operaton*` artifact → 1.1.x · Spring Boot parent / `spring-boot-dependencies` / Gradle plugin → the version Operaton 1.1.x is built with · property `camunda.version` → `operaton.version` (also `version.camunda` → `version.operaton`). Never downgrades |
| `InfraEnvVars` (text) | `CAMUNDA_BPM_` → `OPERATON_BPM_` in `Dockerfile*`, `Containerfile*`, `*.env`, `.env*`, compose files, YAML under `k8s/`, `kubernetes/`, `helm/`, `charts/`, `deploy/`, `ops/`. Skips CI pipeline files on purpose (secret references). Does **not** rename `MANAGEMENT_HEALTH_CAMUNDA_*` or `LOGGING_LEVEL_ORG_CAMUNDA_*` (do those by hand, see references/configuration.md) |
| `FormKeys` (text) | `camunda-forms:` → `operaton-forms:` in `*.bpmn`, `*.bpmn20.xml`. Test expectations are not changed. Camunda 7.24 cannot resolve `operaton-forms:`; treat versions with open tasks as a rollback hard stop (D15). Rollback-safe alternative `camunda:formRef` is a manual model edit |
| `UpgradeToOperaton2` (Hop 2) | rewrite-spring's `UpgradeSpringBoot_4_0` list copied 1:1 (Spring Framework 7, Security 7, `SpringBootProperties_4_0`, `ReplaceMockBeanAndSpyBean`, Hibernate 7.1, `Testcontainers2Migration`, `MigrateToModularStarters`, `AddAutoConfigureMockMvc`, JUnit 5 → 6 …) except: the Jackson 2 → 3 step only runs on `*.java`/`*.kt` files that use **no** `org.operaton` type, and never on build files (so `jackson-datatype-jsr310` stays for Spin) · then every `org.operaton*` artifact → `--target` · then `ChangeParentPom` to the Spring Boot version the target is built with (may downgrade). Only safe on Hop 1 output: on un-renamed code the Jackson guard does not apply |

## 4. Running `migrate.sh`

Spring Boot 4 path (Camunda 7.24 EE on Spring Boot 4):

```bash
bash "<skill-dir>/scripts/migrate.sh" --dry-run <project-dir>                          # preview, writes rewrite.patch
bash "<skill-dir>/scripts/migrate.sh" --with-infra-env [--with-form-keys] <project-dir>   # Spring Boot 4.0 -> 2.1.5
bash "<skill-dir>/scripts/migrate.sh" --with-infra-env --target 2.2.0 <project-dir>      # Spring Boot 4.1 -> 2.2.0 (once GA, 2026-10-23)
bash "<skill-dir>/scripts/migrate.sh" --dry-run --target 2.2.0-RC1 <project-dir>         # Spring Boot 4.1 rehearsal before the GA (never production)
bash "<skill-dir>/scripts/verify-leftovers.sh" <project-dir>
(cd <project-dir> && mvn -B clean verify)                                                # log and wait; then remove the EE repository
```

Spring Boot 3.5 path (chapter 15):

```bash
bash "<skill-dir>/scripts/migrate.sh" --hop 1 --dry-run <project-dir>          # preview, writes rewrite.patch
bash "<skill-dir>/scripts/migrate.sh" --hop 1 [--with-infra-env] [--with-form-keys] <project-dir>
bash "<skill-dir>/scripts/verify-leftovers.sh" <project-dir>
(cd <project-dir> && mvn -B clean verify)
# Hop 2, only after Hop 1 is green and committed (or in the throw-away clone); <2.x GA> from references/versions.md
bash "<skill-dir>/scripts/migrate.sh" --hop 2 --target <2.x GA> --dry-run <project-dir>
bash "<skill-dir>/scripts/migrate.sh" --hop 2 --target <2.x GA> <project-dir>
```

| Flag / variable | Effect |
|---|---|
| `--source auto\|boot4\|boot3` | default `auto`: `boot4` if the build uses Spring Boot 4.x (parent `spring-boot-starter-parent`, imported `spring-boot-dependencies` with `${property}` resolved, Gradle plugin `org.springframework.boot`, `gradle.properties` / `libs.versions.toml` Spring Boot entries; root build file first, XML comments ignored) or any `camunda-bpm-spring-boot-starter-4*` artifact (even without a readable Spring Boot version); otherwise `boot3`. Printed as `==> Source: …` and `==> Path: …`. An override prints a `WARN` |
| `--dry-run` | changes nothing; Maven: `target/rewrite/rewrite.patch` (reactor root for multi-module); Gradle: `build/reports/rewrite/rewrite.patch` |
| `--target <v>` | Operaton 2.x version (default `2.1.5`; Spring Boot 4 path and Hop 2). The script reads `version.spring-boot` from `org.operaton.bpm:operaton-root:<v>` on Maven Central (offline: built-in table, else `--spring-boot`). Warns for `-M`/`-RC` (`--target 2.2.0-RC1 is a pre-release; use released versions for production (decision D1)`). Spring Boot 4 path: never downgrades Spring Boot; same minor → patch upgrade if lower (4.0.5 → 4.0.8 for 2.1.5); different minor → Spring Boot untouched + pairing `WARN` with the recommended target. Hop 2: warns for targets outside 2.1.x (recipe list written for Spring Boot 4.0) |
| `--spring-boot <v>` | override the Spring Boot version paired with `--target` (Spring Boot 3.5 path: the Spring Boot version of Hop 2) |
| `--with-infra-env`, `--with-form-keys` | add `InfraEnvVars` / `FormKeys`; Spring Boot 4 path or Hop 1 (ignored with a warning in Hop 2) |
| `--hop 1\|2\|all` | Spring Boot 3.5 path only, default `1`. `all` = Hop 1 then Hop 2 on the uncommitted result (one diff; only small, well-tested services, D1). `--hop all --dry-run` previews Hop 1 only. **Rejected on Spring Boot 4** (exit 1, before git and Maven) |
| `--plugin-version`, `--recipe-version`, `--rewrite-spring-version`, `--gradle-plugin-version` | override pinned tools; keep the defaults unless references/versions.md says otherwise |
| `--rewrite-yml <file>` | another composite file (default: `assets/rewrite.yml` of this skill) |
| `--force` | ignore dirty tree / missing git. Throw-away copies only |
| `MAVEN_ARGS="-s /path/central-settings.xml"` | extra Maven args, split on spaces (no quoting, no spaces inside one arg); the script passes them itself and unsets `MAVEN_ARGS` for the child. Use for mirror problems or EE credentials; never edit `~/.m2/settings.xml` |
| `GRADLE_ARGS`, `MVN`, `GRADLE` | extra Gradle args; executables (default `./mvnw` or `mvn`, `./gradlew` or `gradle`) |

- **Camunda EE builds** (`7.24.N-ee`, `-ee` / `-jackson3` artifacts, `-4` starters, the EE repository): the rewrite
  plugin resolves all (test) dependencies before a recipe runs, so the run needs the EE repository credentials (server
  id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or `MAVEN_ARGS="-s <settings with the EE credentials>"`). A
  Central-only settings file breaks it. `migrate.sh` prints this hint for every EE build and again after a failed run with
  resolution/401/403 errors. `assets/copilot/settings-camunda-ee.xml` is a minimal settings file that reads the
  credentials from `CAMUNDA_EE_USER` / `CAMUNDA_EE_PASSWORD` (it replaces the user's own settings for that run).
  After the migration the Operaton build no longer needs the EE repository: remove it, its credentials and CI secrets
  from the build. The credentials themselves stay valid until the rollback window closes (the Camunda rollback build
  needs them).
- Maven: the plugin runs by coordinates; nothing is added to the POM. Run on the reactor root (`pom.xml` there).
- Gradle: the script writes a temporary init script with the OpenRewrite Gradle plugin, re-adds the default
  plain-text masks (`plainTextMask()` replaces them) and runs `rewriteDryRun` / `rewriteRun`. It cannot be combined
  with a `rewrite {}` block in the user's build. `gradle/libs.versions.toml` is **not** migrated: edit the catalog by
  hand (assess.sh flags it as MUST, migrate.sh warns), otherwise the migrated sources do not compile. The Spring Boot 4
  path was not run end to end on Gradle (only detection and assess), and the Maven-only steps (`ChangePropertyValue`,
  `RemoveRedundantDependencyVersions`, `RemoveDuplicateDependencies`, property renames) do nothing on Gradle builds.
- Output: header (`==> Source`, `==> Path`, the Spring Boot pairing line, EE hint), log in
  `$TMPDIR/operaton-migrate.*/boot4.log` (Spring Boot 3.5 path: `hop<N>.log`), "Estimate time saved", `git diff --stat`,
  **untracked files** (renamed files such as `operaton.cfg.xml` and `META-INF/services/org.operaton.*` show up there:
  they must be added to git together with the deletions), next steps (Spring Boot 4 path: review, verify-leftovers,
  build, the gap list incl. D17, remove the EE repository, one commit; for a 2.2.x target also
  `<db>_engine_7.24_to_7.25.sql` at the cut-over).
- Large reactors: `MAVEN_OPTS=-Xmx4g`; `MAVEN_ARGS="-Drewrite.exclusions=**/generated/**"`; `-Drewrite.runPerSubmodule=true`
  only as a last resort (loses cross-module type information, review harder). A skill installed inside the project:
  `-Drewrite.exclusions=<skill path>/**` (SKILL "Skill inside the project").

## 5. Reviewing the dry run

```bash
git -C <project-dir> apply --stat target/rewrite/rewrite.patch     # files and line counts
git -C <project-dir> apply --check target/rewrite/rewrite.patch    # applies cleanly?
```

Summarize for the user, files per category: build files · Java main · Java test · Spring config · logging config ·
SPI / `spring.factories` · descriptors · models and scripts · infra files. Then check:

- [ ] The `==> Source:` / `==> Path:` lines match `assess.sh` (Spring Boot 4 path: "in one step"); no pairing `WARN`, or
      the user accepted its recommendation.
- [ ] YAML stayed nested (`operaton:` / `bpm:` in place). A flattened `operaton.bpm…` block appended at the end means
      the wrong rewrite-spring version ran (see §9).
- [ ] `<camunda.version>` became `<operaton.version>` with the target value (Spring Boot 4 path, e.g. `2.1.5`; Hop 1: a
      1.1.x value); `camunda-bom` became `operaton-bom` `${operaton.version}`; Operaton artifacts carry no explicit
      `<version>`.
- [ ] Spring Boot 4 path: no `camunda-bpm-spring-boot-starter-4*`, no `-jackson3` artifact, no `-ee` version left; no
      duplicate dependency; Spring Boot parent unchanged or raised within its minor, never downgraded;
      `camunda.bpm.license-file` deleted; the Spin `DataFormatConfigurator` still on `com.fasterxml.jackson`.
      Hop 1: Spring Boot parent bumped to the 1.1.x pairing.
- [ ] Nothing under `org.camunda.feel`, `org.camunda.community` or `http://camunda.org/schema/…` changed.
- [ ] `"org.camunda.bpm…"` class-name strings are **unchanged** (by design: data contracts; fix manually, fix-catalog).
- [ ] `Groups.CAMUNDA_ADMIN` → `org.operaton.bpm.engine.authorization.Groups.OPERATON_ADMIN`: a runtime value change; the
      admin group data still needs decision D5 (references/identity-and-admin.md).
- [ ] Changed BPMN/DMN files: list them; each becomes a new definition version on the next start (with starter
      auto-deployment and the default `deployChangedOnly: false`, one changed file redeploys **all** resources). `ScriptImports`
      changes are Operaton-only (D15). Prefer package-free scripts (references/models-and-scripts.md); after the
      pre-migration release on Camunda 7.24 (SKILL step 3b) `ScriptImports` finds nothing. Any model hunk you did not
      expect: revert it and go back to step 3b unless the user accepted `org.operaton.*`.
- [ ] `FormKeys` / `InfraEnvVars` changes match decisions D4 / the user's request.
- [ ] Comments and prose: text recipes (`InfraEnvVars`, `ScriptImports`, the `PostFixes` text rules) and the official
      recipe's `ChangeNamespaceValue` on `processes.xml`/`bpm-platform.xml` can also change comments and documentation
      text. Review those hunks; revert or reword comments that now describe the old state wrongly.
- [ ] YAML: the order of blocks inside a changed file may differ from the original. Semantics are the same; re-read every
      changed `application*.yaml` and check that comments still sit next to the keys they describe. EE-only generic
      properties (`queryExpressionAllowListEnabled`, …) are carried over verbatim: remove them (fix-catalog §8).
- [ ] Leftover `camunda*` identifiers the recipe does not rename: variables, fields, parameters and method names such as
      `camundaBpmProperties` (types are renamed, names are not). Rename them in the fix commit.
- [ ] Inline fully qualified names: recipes write some replacements fully qualified (e.g. the
      `org.operaton.bpm.engine.authorization.Groups.OPERATON_ADMIN` above). Replace them with an import and the simple name.

## 6. Official-recipe bugs and how the composite fixes them

| # | Bug in `migrate-camunda-recipe` | Effect without the composite | Composite fix |
|---|---|---|---|
| B1 | `AddDependency … onlyIfUsing: org.junit.jupiter.Test` (type does not exist) | junit5 test starter / `operaton-engine:junit5` never added → `cannot find symbol … ProcessEngineExtension` | `PostFixes` adds the starter with `onlyIfUsing: org.junit.jupiter.api.*` |
| B2 | `Mocks*` `ChangeType` runs before `ChangePackage` | `package org.operaton.bpm.engine.test.mock does not exist` | `PreFixes` maps `org.camunda.bpm.engine.test.mock.*` → `org.operaton.bpm.engine.impl.mock.*` |
| B3 | `ReplaceGetExecutionContext` not wired; `ResolveDeprecations` missing | deprecated `Context.getExecutionContext()` stays | `PreFixes` runs it |
| B4 | `newVersion: 1.0.x` (→ 1.0.3, ended line), parent untouched | wrong Operaton line, unsupported Spring Boot pairing | `AlignVersionsOperaton2` (Spring Boot 4 path), `AlignVersions` (Hop 1) |
| B5 | version property keeps its name (or goes stale with older plugins) | misleading `camunda.version` | `AlignVersionsOperaton2` / `AlignVersions` (`RenamePropertyKey`) |
| B6 | `camunda-bpm-junit5` → `operaton-bpm-junit5` | empty jar, no `ProcessEngineExtension` | `PostFixes` removes it |
| B7 | `ChangePackage org.camunda.bpm` hits the shaded EL API | `package org.operaton.bpm.impl.juel.jakarta.el does not exist` | `PreFixes` maps to `jakarta.el` |
| B8 | no mapping for the `-4` starters, `-jackson3` artifacts, `-webapp-core` | `-4` starters left without a managed version: `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing` | `Boot4PreFixes` |

Plugin-version effects (intrinsic to the fix): `rewrite-maven-plugin` < 6.36.0 renames `META-INF/services` files but
not their **content** and inlines the BOM version (stale `<camunda.version>`); rewrite-spring < 6.36 flattens nested
YAML. The `migrate.sh` defaults avoid both.

## 7. What no recipe does (manual work after the run)

String literals that are data (`"camunda-admin"`, `"org.camunda…"` class names, SpEL `T(org.camunda…)`,
`spring.json.trusted.packages`, `Class.forName`), the admin group **data** (D5), the webapp path (D6), configuration
outside the repo (Helm, Config Server, Vault, CI, `SPRING_APPLICATION_JSON`), Gradle version catalogs, Liquibase
`camunda-changelog.xml` includes (references/database.md), already deployed definitions with old scripts (no recipe
can change `ACT_GE_BYTEARRAY`), `AbstractCamundaConfiguration` constructors, raw `List<JobHandler>` generics,
`getFeatureDescriptors` overrides (Jakarta EL 6.0), Keycloak `use*AsCamunda*` keys, webjar overlays. Camunda EE (D17):
EE-only engine settings and calls, `tools.jackson.*` code next to Spin / REST / the external task client, license files
and mounts, the EE repository and its credentials, the EE webapp features. Every item has an entry in
references/fix-catalog.md.

## 8. Combining with other OpenRewrite recipes

Each step is its own run, build and commit.

Spring Boot 4 path:
1. **On Camunda:** the project is already on Camunda 7.24 EE, Spring Boot 4, Jakarta EE 11, JUnit 6 and Jackson 3 for
   Spring (done as part of the upgrade to Camunda 7.24 EE). Spring Boot 4.1 needs Operaton 2.2; to target 2.2 from a
   Spring Boot 4.0 project, upgrade Spring Boot to 4.1 first (own commit).
2. **Migration:** `starterpack.operaton.MigrateSpringBoot4App` (one run, Spring Boot stays on its minor).
3. Optional later: `org.openrewrite.java.migrate.UpgradeToJava21`. JUnit 4 → 5 conversion
   (`org.openrewrite.java.testing.junit5.JUnit4to5Migration`) is a separate step, never in the same commit as the migration.

Spring Boot 3.5 path:
1. **On Camunda:** reach Camunda 7.24 + Spring Boot 3.5 + Java 17 + Jakarta first
   (`org.openrewrite.java.spring.boot3.UpgradeSpringBoot_3_5` chains Java 17 and Jakarta; it also renames
   `logback.xml` → `logback-spring.xml`). Run Camunda's DB upgrade scripts up to 7.24. Do **not** chain this with Hop 1:
   pre-7.17 coordinates (`org.camunda.bpm.extension:camunda-bpm-junit5`, `org.camunda.bpm.assert`) are not mapped.
2. **Hop 1:** `starterpack.operaton.MigrateSpringBootApp` (Spring Boot stays 3.5).
3. **Hop 2:** `starterpack.operaton.UpgradeToOperaton2`.
4. Optional later: `org.openrewrite.java.migrate.UpgradeToJava21`; for an Operaton 2.2.x target (Spring Boot 4.1)
   additionally `org.openrewrite.java.spring.boot4.SpringBootProperties_4_1` (rewrite-spring has no
   `UpgradeSpringBoot_4_1` composite). JUnit 4 → 5 conversion is a separate step, never in the same commit as a hop.

Adding your own recipe: copy `assets/rewrite.yml` to a temp file, edit, pass `--rewrite-yml <copy>`. Rules:
anything matching `org.camunda` types goes into/before `PreFixes`; anything matching `org.operaton` types or
`operaton.bpm` keys goes after the official recipe; text recipes go last with `caseSensitive: true` (the default is
case-insensitive and rewrites "Camunda" in prose); `filePattern` is `;`-separated globs, character classes such as
`[dD]ockerfile` do not work; models/scripts need plain-text masks (migrate.sh passes them). Keep the marker comments
intact, `migrate.sh` rewrites those lines in a temp copy: `# starterpack:boot4-operaton`, `# starterpack:boot4-spring-boot`,
`# starterpack:boot4-spring-boot-patch` (Spring Boot 4 path), `# starterpack:hop2-operaton`, `# starterpack:hop2-spring-boot` (Hop 2).

## 9. Troubleshooting recipe runs

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: working tree … is dirty` | uncommitted changes (other than `MIGRATION_REPORT.md`, `.operaton-migration-ignore`, `migration/`, which are ignored) | commit the step (with permission) or use a throw-away clone; never `git stash` the user's work, never `--force` on the real repo |
| `ERROR: --hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2). This project is on Spring Boot 4 (detected: …)` | `--hop` on a Spring Boot 4 project | run without `--hop` (one run); add `--source boot3` only if the detection is wrong |
| `ERROR: --hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2); --source boot4 migrates in one step …` | `--source boot4` together with `--hop` | drop one of them |
| `ERROR: --source must be auto, boot4 or boot3 (got '…')` | typo | fix the value |
| `WARN: the project is on Spring Boot <3.5.x>: the Spring Boot 4 path does not upgrade Spring Boot. Use --source boot3 …` | `--source boot4` forced on a Spring Boot 3.5 project | drop `--source boot4` (Hop 1, then Hop 2) |
| `WARN: Operaton <v> is built with Spring Boot <x> (only that pairing is supported), the project is on Spring Boot <y>. …` + `Recommended for Spring Boot …` | target and Spring Boot minor differ (e.g. default 2.1.5 on Spring Boot 4.1) | follow the recommendation (`--target 2.2.0` once GA, `2.2.0-RC1` for rehearsals; or upgrade Spring Boot first, own commit). Never downgrade Spring Boot |
| `Could not transfer artifact org.camunda.bpm…:…-ee …` / `401 Unauthorized` / `403` resolving `7.24.N-ee` or `-4` artifacts | EE build without EE repository credentials (or a Central-only settings file) | provide the credentials (server id `camunda-bpm-nexus-ee` in the user's settings, or `MAVEN_ARGS="-s <settings with the EE credentials>"`); the migrate.sh EE hint repeats this |
| `'dependencies.dependency.version' for org.camunda.bpm.springboot:camunda-bpm-spring-boot-starter-4-webapp-ee:jar is missing` (also `-4-rest`, `-4-test`) | the official recipe alone or Hop 1 ran on a Spring Boot 4 project: the `-4` starters lost their managed version | reset to the pre-run commit, run `migrate.sh` without `--hop` / `--source boot3` |
| `'dependencies.dependency.(groupId:artifactId:type:classifier)' must be unique` | two Camunda artifacts mapped onto one Operaton artifact (`-4-rest` + `-4-rest-jackson3`) and a `rewrite.yml` without `RemoveDuplicateDependencies` | use the bundled `assets/rewrite.yml` (its `AlignVersionsOperaton2` removes duplicates first) |
| `RecipeException: Recipe(s) not found: …MigrateSpringBootApplication` (or `starterpack.operaton.…`) | recipe jar not on the classpath (old/alpha coordinates), `rewrite.yml` not found (relative path), typo | use `migrate.sh` (absolute `configLocation`, release recipe). List recipes: `mvn …:discover -Drewrite.recipeArtifactCoordinates=…` |
| `Could not find org.operaton:migrate-camunda-recipe:…-SNAPSHOT` | snapshots are not published | use the release version |
| `Could not transfer artifact org.rocksdb:rocksdbjni … Premature end of Content-Length delimited message body` (also `kotlin-compiler-embeddable`) | corporate mirror truncates large downloads | `MAVEN_ARGS="-s <file with <settings/>>"` (EE builds: plus the EE server entry); do not edit `~/.m2/settings.xml` |
| `IllegalArgumentException: Origin: https://github.com does not match the clone url: https://<ssh-host-alias>/…` | git provenance detection vs SSH host alias / proxy remote | run on a clone with a plain `origin` URL (or set it temporarily) |
| Gradle: `Could not find org.openrewrite:rewrite-bom:8.91.0` | Gradle plugin 7.40+ needs the Code Genome Project repo | keep the `--gradle-plugin-version` default |
| Gradle: `NoClassDefFoundError: org/openrewrite/shaded/jgit/treewalk/AbstractTreeIterator` | Gradle plugin incompatible with the recipe's rewrite version | keep the default Gradle plugin version |
| `Could not transfer metadata … camunda-nexus (…/artifactory/internal): 401` | repo declared in the FEEL engine's parent POM | harmless; never "fix" by renaming FEEL |
| BPMN still contains `import org.camunda.spin.Spin` | `.bpmn` parsed as Quark (no plain-text mask) | run through `migrate.sh` (passes masks); Gradle: re-add masks |
| `operaton.bpm:` appended as one flattened block | transitive rewrite-spring of the official recipe won | keep `--rewrite-spring-version` default (≥ 6.36); `migrate.sh` puts it on the classpath |
| `META-INF/services/org.operaton.…` still lists `org.camunda…` classes | plugin < 6.36.0 | keep the plugin default, or the `PostFixes` SPI rule |
| `operaton-bom` resolved to 1.0.3, Spring Boot unchanged | official recipe ran alone | rerun with `migrate.sh` (`MigrateSpringBoot4App`, or Hop 1's `MigrateSpringBootApp` / `AlignVersions`) |
| prose/display names containing "Camunda" changed | custom `FindAndReplace` without `caseSensitive: true` | revert those hunks; fix the recipe |
| an LST recipe did nothing on a file a text recipe touched | text recipe ran earlier in the list | move text recipes to the end |
| `OutOfMemoryError` / very slow parsing | whole reactor parsed at once | `MAVEN_OPTS=-Xmx4g`, `rewrite.exclusions`, then `rewrite.runPerSubmodule=true` |
| `incompatible types: com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper` | Spring Boot 3.5 path: stock `UpgradeSpringBoot_4_0` was used, or `--hop 2` ran on un-renamed code | revert to Jackson 2 in Spin code; use `UpgradeToOperaton2` on Hop 1 output (references/fix-catalog.md §6) |
| Hop 2 warning "verified for Operaton 2.1.x / Spring Boot 4.0" | Hop 2 target outside 2.1.x | allowed; review the Spring Boot recipe list, add `SpringBootProperties_4_1` for 4.1 targets |
| `cannot determine the Spring Boot version of Operaton <v> (offline?)` | no Maven Central access | pass `--spring-boot <v>` (pairing: `scripts/latest-versions.sh --operaton <v>`) |

Compile errors and test failures after a successful run are not recipe problems: use references/fix-catalog.md and
references/troubleshooting.md.
