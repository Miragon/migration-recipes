# rewrite/ · Starter-pack OpenRewrite recipes

This folder holds the OpenRewrite recipes that convert the code of a Camunda 7.24 Spring Boot application to
Operaton. A recipe is an automated code transformation, for example "rename this package".
[`rewrite.yml`](rewrite.yml) wraps the official Operaton recipe (`org.operaton:migrate-camunda-recipe:1.0.1`) with
the fixes it is missing. Its main entry point, `starterpack.operaton.MigrateSpringBoot4App`, converts a Camunda 7.24
EE application on Spring Boot 4 to Operaton 2.x in one run. The file also holds the two hops of the
[Spring Boot 3.5 path](../docs/15-coming-from-spring-boot-3.md) for teams that are not on Spring Boot 4 yet.

You normally do not call these recipes yourself: [`scripts/migrate.sh`](../scripts/migrate.sh) detects your Spring
Boot version (`--source auto`) and runs them with the right versions and settings. Read this page if you want to run
the recipes by hand or in your own pipeline, or if you want to change `rewrite.yml`. What each recipe fixes, the gap
list (what stays manual) and troubleshooting are in [OpenRewrite recipes](../docs/03-openrewrite-recipes.md).

## Recipes

The table lists every recipe in `rewrite.yml`. Per run, you activate one entry point, plus the optional recipes if
you need them. The other recipes are steps of an entry point. The *Path* column says where a recipe is used: the
Spring Boot 4 path (one run), or Hop 1 and Hop 2 of the Spring Boot 3.5 path.

| Recipe ID | Path | Role |
|---|---|---|
| `starterpack.operaton.MigrateSpringBoot4App` | Spring Boot 4 | **Entry point:** Camunda 7.24 on Spring Boot 4 → Operaton 2.x in one run |
| `starterpack.operaton.Boot4PreFixes` | Spring Boot 4 | `operaton-bom` first, then the `-4` starters (including `-4-webapp-ee`), the classic `-webapp-core` and the `-jackson3` artifacts straight to Operaton 2.x; deletes `camunda.bpm.license-file` |
| `starterpack.operaton.PreFixes` | Spring Boot 4, Hop 1 | Fixes that must still see `org.camunda` types |
| `starterpack.operaton.PostFixes` | Spring Boot 4, Hop 1 | Gaps after the official recipe; text fixes last |
| `starterpack.operaton.ScriptImports` | Spring Boot 4, Hop 1 | `org.camunda.{bpm,spin,connect,commons,templateengines}.` → `org.operaton.…` in models and script files |
| `starterpack.operaton.AlignVersionsOperaton2` | Spring Boot 4 | Removes duplicate dependencies, Operaton 2.x target, `operaton.version` property, Spring Boot patch within its minor |
| `starterpack.operaton.InfraEnvVars` | Spring Boot 4, Hop 1; optional | `CAMUNDA_BPM_` → `OPERATON_BPM_` in container and k8s files |
| `starterpack.operaton.FormKeys` | Spring Boot 4, Hop 1; optional | `camunda-forms:` → `operaton-forms:` |
| `starterpack.operaton.MigrateSpringBootApp` | Hop 1 | **Entry point** of Hop 1: Camunda 7.24 → Operaton 1.1.x |
| `starterpack.operaton.AlignVersions` | Hop 1 | Operaton 1.1.x, Spring Boot 3.5.16, `operaton.version` property |
| `starterpack.operaton.UpgradeToOperaton2` | Hop 2 | **Entry point** of Hop 2: Spring Boot 4 + Operaton 2.1.x, Jackson 2 kept for Operaton code |
| `starterpack.operaton.internal.*` | Spring Boot 4, Hop 2 | Building blocks of `AlignVersionsOperaton2` and `UpgradeToOperaton2`; do not run directly |

**How the Spring Boot 4 entry point works.** `MigrateSpringBoot4App` runs six recipes in a fixed order, and each one
sees the result of the one before:

1. `Boot4PreFixes` runs first. It switches `camunda-bom` to `operaton-bom` with the target version before anything
   else, so that every Operaton artifact is managed and the build model stays resolvable; otherwise later Maven
   recipes write explicit versions. Then it maps the Camunda artifacts that the official recipe does not know (the
   `-4` starters, `-4-webapp-ee`, `-webapp-core`, the `-jackson3` artifacts) without versions.
2. `PreFixes` runs while the code still uses `org.camunda` types. After the official recipe, these types no longer
   exist and the fixes would find nothing.
3. `org.operaton.rewrite.spring.MigrateSpringBootApplication`, the official recipe, does the bulk of the renaming.
4. `PostFixes` closes the gaps that the official recipe leaves. Its text fixes run last.
5. `ScriptImports` rewrites the package names in BPMN, DMN and CMMN models and in script files. Scripts reference
   these packages as plain text, so they deploy fine and fail only at runtime.
6. `AlignVersionsOperaton2` replaces the 1.0.x versions of the official recipe (an ended Spring Boot 3.5 line) with
   the Operaton 2.x target. It first removes duplicate dependencies, because two Camunda artifacts can map to one
   Operaton artifact and Maven 3.10 refuses a pom with a duplicate. It never downgrades Spring Boot; its last step,
   `internal.SpringBootPatchForOperaton2`, raises Spring Boot at most to the patch the target is built with.

None of the Spring Boot 4 or Jackson 3 upgrade recipes of Hop 2 run here, because the project is on Spring Boot 4
already.

**Optional recipes.** `InfraEnvVars` renames environment variables in Dockerfiles, `.env`, compose and k8s/Helm
files. Spring Boot binds `CAMUNDA_BPM_*` variables to `camunda.bpm.*`, which Operaton ignores silently. CI
variables, secrets and config servers outside the repository are not covered; `scripts/verify-leftovers.sh` lists
them. `FormKeys` implements one option of the
[Camunda Forms keys decision (D4)](../docs/01-migration-path-and-decisions.md#d4).

> [!WARNING]
> **`ScriptImports` and `FormKeys` produce an Operaton-only result.** The new definition versions reference
> `org.operaton.*` or `operaton-forms:`, and Camunda 7.24 cannot run them. Once process instances run on such
> versions, you can no longer roll back by redeploying the Camunda build
> ([rollback and point-of-no-return decision, D15](../docs/01-migration-path-and-decisions.md#d15)). To keep the way
> back open, remove the class names from scripts or use `formRef` for forms, and deploy these models on Camunda 7.24
> before the cut-over. Details: [OpenRewrite recipes](../docs/03-openrewrite-recipes.md#what-the-composite-adds).

## Run

Use [`scripts/migrate.sh`](../scripts/migrate.sh). Run it on a clean git working tree and preview first: the dry run
changes nothing and only writes a patch for you to review.

```bash
scripts/migrate.sh --dry-run /path/to/app                          # preview: target/rewrite/rewrite.patch
scripts/migrate.sh --with-infra-env /path/to/app                   # Spring Boot 4.0 -> Operaton 2.1.5; then build, test, commit
scripts/migrate.sh --with-infra-env --target 2.2.0 /path/to/app    # Spring Boot 4.1 -> Operaton 2.2.0 (once GA, 2026-10-23)
```

Commit the result as one change. On a Camunda EE build, the run needs the Camunda EE repository and its credentials
(server id `camunda-bpm-nexus-ee`), because the rewrite plugin resolves all dependencies, including test
dependencies, before any recipe runs. After the conversion nothing needs the EE repository any more.

**The raw Maven command.** If you cannot use the script, this is what `--with-infra-env` runs on a Spring Boot 4
project. It makes no change to your `pom.xml`, because it calls the plugin by its coordinates. Use the `:dryRun` goal
instead of `:run` for a preview, and add `FormKeys` to the active recipes for what `--with-form-keys` does.

```bash
mvn -B org.openrewrite.maven:rewrite-maven-plugin:6.46.1:run \
  -Drewrite.configLocation=/abs/path/to/starter-pack/rewrite/rewrite.yml \
  -Drewrite.recipeArtifactCoordinates=org.operaton:migrate-camunda-recipe:1.0.1,org.openrewrite.recipe:rewrite-spring:6.37.0 \
  -Drewrite.activeRecipes=starterpack.operaton.MigrateSpringBoot4App,starterpack.operaton.InfraEnvVars \
  '-Drewrite.additionalPlainTextMasks=**/*.bpmn,**/*.bpmn20.xml,**/*.dmn,**/*.dmn11.xml,**/*.cmmn,**/*.cmmn10.xml,**/*.cmmn11.xml,**/*.form,**/*.groovy,**/*.gvy,**/*.js,**/*.mjs,**/*.py,**/*.rb,**/*.ftl' \
  -Drewrite.exportDatatables=false
```

What the parameters are for:

- **`rewrite.configLocation`** points to `rewrite.yml`. Use an **absolute** path, otherwise the plugin does not find
  the `starterpack.operaton.*` recipes.
- **`rewrite.recipeArtifactCoordinates`** loads the official recipe and `rewrite-spring` 6.37.0. The newer
  `rewrite-spring` replaces the 6.18.0 that the official recipe brings in, which would append a flattened
  `operaton.bpm:` block to `application.yaml` instead of keeping nested YAML nested.
- **`rewrite.additionalPlainTextMasks`** makes BPMN, DMN, CMMN, form and script files readable as plain text.
  Without it, the text recipes skip these files silently.

**Target versions.** The committed file targets Operaton 2.1.5 with Spring Boot 4.0.8, the default of `migrate.sh`.
`migrate.sh --target <v>` rewrites the lines marked `# starterpack:boot4-operaton` and
`# starterpack:boot4-spring-boot` in a temporary copy, so that another Operaton 2.x version gets the Spring Boot
version it is built with. When the Spring Boot minor of your project differs from the target's, it also comments out
the line marked `# starterpack:boot4-spring-boot-patch`, so that Spring Boot stays as it is, and warns with the
target that matches your Spring Boot minor (Spring Boot 4.1: `--target 2.2.0` once it is GA, `2.2.0-RC1` for
rehearsals only). With the raw command and the committed file, the Spring Boot patch step only ever upgrades: a
project on Spring Boot 4.1.x keeps 4.1.x. For another target, edit the marked lines in a copy of the file.

**Gradle:** `migrate.sh` writes an init script (plugin 7.39.0), so your build files stay unchanged here too.
Versions 7.40+ of the Gradle plugin need `rewrite-bom` 8.91.0, which is not on Maven Central. The Spring Boot 4 path
has not been run end to end on Gradle, the recipes never migrate `gradle/libs.versions.toml`, and the Maven-only
steps (property values and renames, redundant versions, duplicate dependencies) do nothing on Gradle builds.

<a id="the-spring-boot-35-path-hop-1-and-hop-2"></a>

## The Spring Boot 3.5 path: Hop 1 and Hop 2

Teams on Spring Boot 3.5 convert in two hops, each as its own commit, through an Operaton 1.1.5 checkpoint that never
goes to production. Why and when: [Coming from Spring Boot 3.5](../docs/15-coming-from-spring-boot-3.md).

- **Hop 1 (rename)** converts Camunda 7.24 to Operaton 1.1.x. It renames Maven coordinates, packages, types and
  `camunda.bpm.*` properties; Spring Boot stays on 3.5. Its entry point `MigrateSpringBootApp` runs `PreFixes`, the
  official recipe, `PostFixes`, `ScriptImports` and `AlignVersions`. `AlignVersions` moves every Operaton artifact
  to 1.1.x (the official recipe pins the ended 1.0.x line) and Spring Boot to 3.5.16, the version Operaton 1.1.5 is
  built with.
- **Hop 2 (platform)** converts Operaton 1.1.x to Operaton 2.x with Spring Boot 4. `UpgradeToOperaton2` runs the
  Spring Boot 4.0 upgrade of `rewrite-spring`, with a Jackson 3 step that skips code using Operaton types. This keeps
  Spin on Jackson 2, because Operaton's Spin, engine and REST API still use Jackson 2.

```bash
scripts/migrate.sh --hop 1 --dry-run --with-infra-env /path/to/app   # preview: target/rewrite/rewrite.patch
scripts/migrate.sh --hop 1 --with-infra-env /path/to/app             # apply; then build, test, commit
scripts/migrate.sh --hop 2 --target 2.1.5 /path/to/app               # second commit
```

Commit each hop separately, so that each hop has its own commit with a green build. `migrate.sh` accepts `--hop` only
on the Spring Boot 3.5 path; on a Spring Boot 4 project it stops with an error.

**Raw Maven commands for the hops.** Hop 1 uses the command above with
`activeRecipes=starterpack.operaton.MigrateSpringBootApp,starterpack.operaton.InfraEnvVars`. Hop 2 uses
`recipeArtifactCoordinates=org.openrewrite.recipe:rewrite-spring:6.37.0` and
`activeRecipes=starterpack.operaton.UpgradeToOperaton2`. The committed file targets Operaton 2.1.x / Spring Boot
4.0.8 for Hop 2. `migrate.sh --target <v>` rewrites the `# starterpack:hop2-*` lines in a temporary copy, so that
another Operaton 2.x version gets the matching Spring Boot version.

## Rules for changing `rewrite.yml`

A recipe list runs top to bottom, and every recipe sees the output of the previous one. A recipe in the wrong place
or with the wrong file pattern can fail without an error: it simply changes nothing. Follow these rules:

1. **Place recipes by the names they match.** Recipes that match `org.camunda` types go into `PreFixes` (Camunda
   artifacts of the Spring Boot 4 path into `Boot4PreFixes`); those matching `org.operaton` types or `operaton.bpm`
   keys into `PostFixes`. The official recipe runs between the two and does the renaming.
2. **Text recipes (`FindAndReplace`) go last, with `caseSensitive: true`.** A text recipe turns every file it changes
   into plain text for the rest of the run, so recipes that understand Java, YAML, XML or Maven can no longer work on
   that file. `FindAndReplace` is case-insensitive by default. Unknown file types need a plain-text mask, or they
   are skipped silently. The only recipes after the text recipes (`AlignVersions`, `AlignVersionsOperaton2`) touch
   build files that no text recipe touches.
3. **`filePattern` takes `;`-separated globs; `[dD]` character classes do not work.** List both spellings instead,
   for example `**/Dockerfile*;**/dockerfile*`.
4. **Never touch `org.camunda.feel` or `http://camunda.org/schema/...`.** Operaton still uses the Camunda FEEL
   engine, and it still reads the `camunda:` model namespace
   ([BPMN/DMN namespace decision, D3](../docs/01-migration-path-and-decisions.md#d3)).
5. **Keep Hop 2 in sync with rewrite-spring.** `UpgradeToOperaton2` copies recipe lists from rewrite-spring 6.37.0,
   with a narrower Jackson 3 step. Compare them again if you raise that version.
6. **Keep the order at the start of the Spring Boot 4 recipes.** The BOM switch stays the first step of
   `Boot4PreFixes`, and the duplicate removal the first step of `AlignVersionsOperaton2`. Otherwise later recipes see
   an unresolvable model or only one copy of a duplicated dependency, and leave explicit or old versions behind.
7. **Keep the `# starterpack:` markers** (`boot4-operaton`, `boot4-spring-boot`, `boot4-spring-boot-patch`,
   `hop2-operaton`, `hop2-spring-boot`). `migrate.sh` rewrites these lines for `--target`. Without the
   `boot4-operaton`, `boot4-spring-boot-patch` or `hop2-operaton` marker it stops with an error; without a Spring
   Boot marker it silently keeps the Spring Boot version of the committed file.
8. **Test and sync after a change.** Run [`tools/test-boot4-path.sh`](../tools/test-boot4-path.sh), the end-to-end test
   of the Spring Boot 4 path ([how it works](../docs/03-openrewrite-recipes.md#how-the-spring-boot-4-path-is-tested)).
   Then run `tools/sync-skill.sh`, because the skill carries a copy of `rewrite.yml`; CI checks it with
   `tools/sync-skill.sh --check`.
