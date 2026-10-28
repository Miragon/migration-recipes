---
name: migrating-camunda7-to-operaton
description: Migrates Java / Spring Boot applications with an embedded Camunda 7 engine to Operaton 2.x. Main path - Camunda 7.24 Enterprise on Spring Boot 4 (camunda-bpm-spring-boot-starter-4*, 7.24.N-ee) to Operaton 2.1.5 or 2.2.x in one recipe run and one cut-over; Spring Boot 3.5 projects (Camunda 7.24.0 CE) take two hops via the Operaton 1.1.5 checkpoint. Assesses readiness, records migration decisions (incl. Camunda EE features), runs the official Operaton OpenRewrite recipe wrapped by gap-fixing starter-pack recipes, fixes what recipes miss (camunda.bpm properties, CAMUNDA_BPM_ env vars, BPMN script imports, admin group camunda-admin to operaton-admin, webapp path, history exporters, EE-only settings, Jackson 3 opt-ins), prepares cut-over SQL and runbooks, and verifies the result. Use when the user wants to migrate or assess a Camunda 7 project for Operaton, mentions Camunda 7 end of life, org.camunda to org.operaton, migrate-camunda-recipe, operaton-admin, or Operaton problems after such a migration.
license: Apache-2.0
compatibility: Requires git, bash, curl, JDK 17+, Maven (Gradle partially supported) and network access to Maven Central; Camunda EE builds also need the Camunda EE repository credentials while the recipe runs. jq is optional. Written for Claude Code and GitHub Copilot agents (Claude models).
metadata:
  version: "1.1.0"
  verified-against: "Camunda 7.24.x EE on Spring Boot 4 (stubbed EE artifacts) -> Operaton 2.1.5 / 2.2.0-RC1, and 7.24.0 CE -> 1.1.5 -> 2.1.5 (2026-10)"
---

# Migrating an embedded Camunda 7 engine to Operaton

You are guiding the migration of a Spring Boot / Java application that embeds the Camunda 7 engine to Operaton 2.x.
Every instruction here is mandatory unless marked (SHOULD) or (MAY).

Two source flavours, two paths. `assess.sh` reports which one applies (row "Migration path"):

- **Spring Boot 4 path (main path):** Camunda 7.24 Enterprise (7.24.3-ee or later, `-4` starters) on Spring
  Boot 4. One code change (one `migrate.sh` run, one commit) to Operaton 2.x and one cut-over on the same database.
  Spring Boot 4.0 → Operaton 2.1.5; Spring Boot 4.1 → Operaton 2.2.x (GA due 2026-10-23; rehearse with 2.2.0-RC1,
  never production). Spring Boot 4 on Camunda 7.24 always means EE, so decision D17 (Camunda EE features) is mandatory.
- **Spring Boot 3.5 path:** Camunda 7.24 on Spring Boot 3.5 (CE 7.24.0, or EE still on 3.5). Two code
  changes (Hop 1 to the Operaton 1.1.5 checkpoint, Hop 2 to Operaton 2.x on Spring Boot 4) and one cut-over. Step 5
  below; background: [15 · Coming from Spring Boot 3.5](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/15-coming-from-spring-boot-3.md).

## Skill directory and bundled files

`<skill-dir>` = the absolute path of the folder that contains this SKILL.md. Claude Code fills it in here: `${CLAUDE_SKILL_DIR}`. GitHub Copilot shows it as "Base directory for this skill" (or as the path of this SKILL.md).

Resolve `<skill-dir>` once and run every bundled script by its absolute path from the project, e.g.
`bash "<skill-dir>/scripts/assess.sh" <project-dir>`. Use the same resolved path in the commands of `references/*.md`.
Do not rely on an exported shell variable: shell state does not reliably persist between tool calls. Paths in the table
are relative to `<skill-dir>`.

**Skill inside the project** (project-scope install in `.claude/skills/`, `.github/skills/` or `.agents/skills/`; always
the case in the Copilot cloud agent): the skill's scripts, SQL and recipes are full of `camunda` on purpose. Before the
recipe run, commit the skill directory or list it in `.git/info/exclude` (`migrate.sh` counts untracked files as a dirty
tree; it reads `git status`), keep it out of the scans with
`verify-leftovers.sh --exclude '<skill path>/**'` (otherwise dozens of false MUST findings), pass
`MAVEN_ARGS="-Drewrite.exclusions=<skill path>/**"` to `migrate.sh` (Maven), and ignore `assess.sh` findings under that
path. `<skill path>` = `<skill-dir>` relative to the project root.

| Path | Purpose |
|---|---|
| `scripts/assess.sh` | Read-only inventory of a project → Markdown: edition (CE/EE), Spring Boot line, migration path, recommended target, MUST / SHOULD / INFO findings, the next `migrate.sh` command |
| `scripts/migrate.sh` | Runs the OpenRewrite recipes. `--source auto` (default) detects the path: Spring Boot 4 → one run to Operaton 2.x (`--target`, default 2.1.5); Spring Boot 3.5 → `--hop 1` / `--hop 2` / `--hop all`. `--dry-run` previews |
| `scripts/verify-leftovers.sh` | Post-migration scan; exit code 1 on MUST-FIX leftovers (incl. `-4` starters, `-jackson3`, `-ee` versions, EE-only settings) |
| `scripts/smoke-test.sh` | REST smoke test against a running engine (read-only by default) |
| `scripts/latest-versions.sh` | Current Operaton / recipe / plugin versions from Maven Central, Spring Boot minor → Operaton line |
| `assets/rewrite.yml` | Starter-pack composite recipes (`starterpack.operaton.*`) |
| `assets/sql/postgresql/*.sql` | Pre-flight checks, admin-group migration, legacy-reference detection, emergency SQL (guide: `assets/sql/README.md`) |
| `assets/snippets/*.java` | Helpers from the migrated example (package `com.example.orders.*`, Operaton 2.x / Spring Boot 4): `AdminGroupMigrationPlugin` + `MigrationHelpersConfiguration` (does not compile without `LegacyWebappPathRedirectFilter`: copy both, or delete the filter `@Bean`), `LegacyCamundaConfigGuard` (Spring Boot 4 SPI; Spring Boot 3.5 edit in `references/configuration.md` §10), after-commit exporter `HistoryExportPlugin` + `ExportingHistoryEventHandler` + `EventPublisher` + `ExportedHistoryEvent` (v1 envelope; D9 extension in `references/plugins-and-exporters.md` §6), `IncidentRecoveryService` |
| `assets/snippets/test/*.java` | Tests for the helpers: `AdminGroupMigrationPluginTest`, `ExportingHistoryEventHandlerTest`, `LegacyCamundaConfigGuardTest` (how to adapt: `references/testing.md` §8) |
| `assets/copilot/copilot-setup-steps.yml`, `assets/copilot/settings-camunda-ee.xml` | Copilot cloud agent environment (JDK 21, Maven cache, optional Camunda EE credentials); see "Running in the Copilot cloud agent" |
| `assets/MIGRATION_REPORT.template.md` | Report template, the single source of truth of a migration |
| `references/*.md` | Deep knowledge per topic: decisions, versions, recipes, fix-catalog, troubleshooting, configuration, models-and-scripts, plugins-and-exporters, identity-and-admin, database, testing, cutover. Load only what the current step needs |

Run from this skill, the scripts link the guide chapters on GitHub and print SQL paths as `assets/sql/postgresql/<file>`
(relative to `<skill-dir>`).
Migration-only helpers carry the line `// operaton-migration-helper: remove after the rollback window (D15)`: keep it when
you copy them. `verify-leftovers.sh` skips files containing that marker (they hold `camunda` literals on purpose) and the
project's `migration/` folder, reported as one INFO line `skipped N helper files / migration/ pack`; `--strict` scans them too.

## Long-running commands

Maven builds and recipe runs take minutes and print far more than a tool result can hold. For every build:

```bash
mkdir -p /tmp/opmig-logs && (cd <project-dir> && mvn -B clean verify) > /tmp/opmig-logs/<step>.log 2>&1; echo "exit=$?"
```

- Use `./mvnw` instead of `mvn` if the project has a wrapper. Keep the user's Maven arguments (e.g. `-s <settings>`).
- If the tool returns before `exit=` is printed (timeout, command moved to the background), wait and poll
  (`tail -n 5 /tmp/opmig-logs/<step>.log`) until it has finished. Never judge a build from partial output.
- Then read `tail -n 80` of the log and `grep -nE '\[ERROR\]|FAIL|Tests run:' /tmp/opmig-logs/<step>.log | head -50`.
- `assess.sh` output is long: redirect it too (`> /tmp/opmig-logs/assessment.md`) and read the file.
  `migrate.sh` keeps its console output short and writes the Maven output to its own log (`==>   log …/boot4.log`,
  Spring Boot 3.5 path `…/hop<N>.log`): read that log when it fails.
- Never write logs into `target/` (`mvn clean` deletes it) or into the project (they would end up in a commit).

## Safety rules

1. **Never touch a real database.** Do not run SQL, Liquibase or write REST calls against any database or engine
   that is not a throw-away local one. Generate scripts (from `assets/sql/`) for humans to review and run.
2. **Never push, tag or open PRs yourself.** Commit only with the user's permission, asked once in step 2 (recommended:
   one local commit per step on the migration branch). Without it, follow "Commits and a clean tree" in step 3. In the
   Copilot cloud agent the platform commits to the agent's branch and opens the pull request: that PR is the review gate.
3. Recipes need a clean git tree (`migrate.sh` ignores `MIGRATION_REPORT.md`, `.operaton-migration-ignore` and `migration/`).
   Never `git stash` the user's work; pass `--force` only on a throw-away copy, never on the user's repository.
4. **Never rename `org.camunda.feel`** (packages, artifacts, loggers, SPI files). Operaton still uses the Camunda FEEL engine.
5. **Do not convert the `camunda:` BPMN/DMN namespace** unless the user chose to (decision D3). Operaton accepts it.
6. **Do not delete `camunda-admin` data** (group, memberships, authorizations) or the Camunda EE license rows: rollback needs them.
7. Production uses released versions only (no `-M`/`-RC`), even though Maven metadata `<release>` may point to an RC.
   Only exception: `--target 2.2.0-RC1` on a rehearsal branch of a Spring Boot 4.1 project until Operaton 2.2.0 is GA
   (due 2026-10-23); mark it in the report as "rehearsal only".
8. **Camunda EE credentials stay out of the repository.** Never write them into files, the report, logs or commits, and
   never edit `~/.m2/settings.xml`. Use the user's existing settings or `MAVEN_ARGS="-s <settings with the EE credentials>"`.
9. Evidence before claims: every "done" item in the report cites the command you ran and its result.
10. A finished recipe run is not a finished migration: every recipe warning, compile error, failing test and
    leftover must be resolved or explicitly accepted in the report.

## Modes

Determine the mode from the words after the skill command or from the request: `assess`, `migrate`, `hop2`,
`verify`, `cutover`. If unclear, start with **assess**: it is read-only and always safe.

| Mode | Does | Writes |
|---|---|---|
| `assess` | Steps 1–2 | `MIGRATION_REPORT.md` only |
| `migrate` | Steps 1–4 and 6 (3b if needed), then offer step 7. Spring Boot 3.5 path: step 5 (Hop 1, and Hop 2 if D1 targets 2.x) instead of step 4 | code, config, tests, report; at least `migration/sql/` copies + runbook stub |
| `hop2` | Spring Boot 3.5 path only: step 5b on a project already committed at the Operaton 1.1.x checkpoint | code, config, tests, report |
| `verify` | Step 6 | report |
| `cutover` | Step 7 | runbook + SQL files for review, report |

## Workflow

Copy this checklist into your task list and keep it updated:

```
- [ ] 1 Orient & assess (read-only): edition, Spring Boot line, path, target
- [ ] 2 Decisions recorded (D1–D18; mandatory D5, D7, D8, D15, D17, D18), commit permission asked
- [ ] 3 Pre-flight: branch, clean tree, EE repository access, Camunda 7.24 baseline green
- [ ] 3b Pre-migration release on Camunda 7.24 (D3 package-free scripts, D4 formRef): green, committed separately
- [ ] 4 Spring Boot 4 path: one migrate.sh run + fix catalogue + EE clean-up + leftovers clean + tests green, one commit
- [ ] 5 Spring Boot 3.5 path only (instead of 4): Hop 1, then Hop 2, each green and committed
- [ ] 6 Verify: Central-only build, boot, smoke test, admin setup endpoint closed, branch gate set
- [ ] 7 Cut-over pack: tailored runbook + reviewed SQL + rollback plan (at least SQL copies + runbook stub)
```

### 1. Orient & assess (read-only)

1. Find the project root(s) and build tool (`pom.xml`, `build.gradle[.kts]`, `gradle/libs.versions.toml`).
   Record Camunda version (`7.24.N-ee` = Enterprise), Spring Boot version, Java release, modules, packaging (jar/war),
   DB vendor, schema management (engine / Liquibase / Flyway).
2. Run `mkdir -p /tmp/opmig-logs && bash "<skill-dir>/scripts/assess.sh" <project-dir> > /tmp/opmig-logs/assessment.md 2>&1`
   and read the file: the rows **Edition**, **Spring Boot**, **Spring Boot 4 artifacts**, **Migration path** and
   **Recommended Operaton target**, every MUST and SHOULD finding, and next step 2 (the `migrate.sh` command for this project).
3. Inspect the hotspots the script can only hint at (read the code, don't guess):
   process engine plugins, `HistoryEventHandler`s and other exporters, custom `IncidentHandler` / `JobHandler` / identity providers,
   `META-INF/services` and `spring.factories`, scripts inside BPMN/DMN, SQL files touching `ACT_*` tables,
   infra files (Dockerfile, compose, Helm, k8s, CI), downstream consumers of events or REST.
   EE sources also: `-jackson3` artifacts and `tools.jackson.*` code next to Spin / engine REST / the external task client,
   EE-only engine settings and calls (`queryExpressionAllowListEnabled`, `allowedExpression*InQueries`,
   `setQueryExpressionValidator`, `validate-auth-resource-id-exists`, `setLicenseKey`), license files and mounts, the EE
   repository (`artifacts.camunda.com`, server id `camunda-bpm-nexus-ee`) in POMs, settings files and CI.
4. Create `MIGRATION_REPORT.md` in the project root from `assets/MIGRATION_REPORT.template.md` and fill the
   inventory and findings sections. What each finding means: `references/fix-catalog.md` and `references/troubleshooting.md`.

**Stop conditions** (report them prominently, do not continue the code migration):
- Camunda older than 7.24 → first upgrade to 7.24 (code *and* database upgrade scripts). See `references/versions.md`.
- Spring Boot 4.2 or newer → no Operaton line is built with it yet (2.1 = Spring Boot 4.0, 2.2 = 4.1): migrate on 4.1 or wait (D1).
- Camunda EE build without access to the Camunda EE repository → the recipe cannot run (Maven resolves all dependencies
  first). Ask the user to provide credentials in their own settings (safety rule 8).
- Camunda 7 EE features in use (EE Cockpit features, Optimize, license) without an agreed replacement → decision D17.
- Unsupported ecosystem pieces without a plan (e.g. Polyflow/taskpool) → see `references/plugins-and-exporters.md`.

### 2. Decisions

Load `references/decisions.md`. Present the open decisions **in one batch** (its section 3) with the recommended default
for each and a one-line consequence, pre-filled from evidence (e.g. D4: webapp starter on the classpath plus
`camunda-forms:` keys → Operaton Tasklist → `formRef`). At minimum ask for D1 (target version & path), D3 (BPMN namespace,
script fixes), D4 (Camunda Forms keys), D5 (admin group), D6 (webapp path), D17 (Camunda EE features: every Spring Boot 4
or EE source), D9 (history exporters, only if exporters exist), D8 (schema management, only if Liquibase/Flyway manage
the engine schema). Mandatory before the first Operaton start on real data: D5, D7, D8, D15, D17, D18.
In the same message ask **once** for commit permission: "May I commit each step locally on the migration branch?
Nothing is pushed." (recommended: yes). Record every answer in the report's decision table and the commit policy in its
header. In `assess` mode, stop after this step.

### 3. Pre-flight for code changes

- Create a branch such as `migration/operaton` (ask before creating it if unsure); `git status` must be clean.
- **EE builds:** confirm access to the Camunda EE repository (server id `camunda-bpm-nexus-ee` in the user's
  `~/.m2/settings.xml`, or `MAVEN_ARGS="-s <settings with the EE credentials>"`). The baseline build and the recipe run
  need it; the converted Operaton build does not.
- Build and test the **unchanged** project once and record the result as the baseline (`mvn -B verify`, log and wait).
  If the baseline is red, report it and agree with the user how to proceed — never "fix" by deleting tests.
- If Maven downloads fail with `Premature end of Content-Length` or similar mirror errors, suggest running with a
  Maven Central–only settings file via `MAVEN_ARGS="-s <file>"`; never edit the user's `~/.m2/settings.xml`. EE builds
  need the EE repository credentials in that file too.
- **Commits and a clean tree.** `migrate.sh` needs a clean tree. With permission: one local commit per step (3b, the
  unmodified recipe output, the fixes; Spring Boot 3.5 path: the same per hop, Hop 2 builds on a committed Hop 1).
  Without permission: run the migration in a throw-away clone (`git clone <project-dir> /tmp/opmig-<name>`) and commit
  there, then hand the final result back as uncommitted changes (or a patch) in the user's tree. Never `git stash`;
  `--force` only on a throw-away copy.

### 3b. Pre-migration release on Camunda 7.24

Needed when models contain scripts referencing `org.camunda.*` (D3 default: package-free) or `camunda-forms:` keys that
D4 moves to `formRef`. Skip it if neither exists. Done **before the recipe run, on the unchanged Camunda 7.24 code**:
1. Edit the models: package-free scripts (only the pre-bound `S(…)`, e.g. `S(map, 'application/json')`) and
   `camunda:formRef` + `camunda:formRefBinding`; keep the `camunda:` namespace; add a TTL where it is missing
   (`references/models-and-scripts.md` §4, §6, §11).
2. Update the tests that assert the old behaviour (form-key expectations) and make sure each changed script is executed by a test.
3. `mvn -B verify` on Camunda 7.24 must be green; record it and commit it separately (with permission). Tell the user it
   should ship as its own release on Camunda 7.24 before the cut-over, with running instances on old versions migrated
   there (a runbook item for humans; `references/models-and-scripts.md` §5).
4. Result: the recipe's `ScriptImports` finds nothing, and the cut-over deploys no Operaton-only model version (D15).

### 4. Migrate: Spring Boot 4 path (one recipe run)

Only when `assess.sh` reports the Spring Boot 4 path. Spring Boot 3.5 projects: step 5.
1. Dry run: `bash "<skill-dir>/scripts/migrate.sh" --dry-run [--target <version>] <project-dir>`. Check the header:
   `==> Source: Spring Boot 4 (boot4; detected: …)` and `==> Path: Camunda 7.24 -> Operaton <target> in one step`.
   Target: default `2.1.5` for Spring Boot 4.0; Spring Boot 4.1 → `--target 2.2.0` once GA (2026-10-23), before that
   `--target 2.2.0-RC1` for rehearsals only. A pairing `WARN` means the Spring Boot minor does not match the target:
   follow its recommendation (the recipe never downgrades Spring Boot). Summarize the patch
   (`target/rewrite/rewrite.patch`), files touched per category, and work through `references/recipes.md` §5.
2. Apply: same command without `--dry-run`, plus `--with-infra-env` (renames `CAMUNDA_BPM_*` in container files) and
   `--with-form-keys` only if D4 chose `operaton-forms:`. Never pass `--hop` (rejected on Spring Boot 4) and never force
   `--source boot3` on a Spring Boot 4 project. `ScriptImports` (`org.camunda.*` → `org.operaton.*` in model scripts) is
   the right path **only if the user accepted Operaton-only scripts** (D3, a D15 hard stop); otherwise step 3b removed
   those references, and a model hunk from it means: revert it and go back to 3b. Recipe IDs, flags and run problems:
   `references/recipes.md`. Commit the unmodified recipe output (with permission).
3. Build with `mvn -B clean verify` (log and wait). Fix compile errors and test failures with `references/fix-catalog.md`;
   startup and runtime messages are in `references/troubleshooting.md`. Typical manual work: string literals
   (`"camunda-admin"`, `"org.camunda..."` class-name strings), whitelist regex values, `spring.factories` keys, custom
   `ExpressionManager`/EL resolvers, raw-typed job handler lists, `AbstractCamundaConfiguration` subclasses.
4. **Camunda EE clean-up** (D17; `references/fix-catalog.md` §8):
   - Remove EE-only engine settings and calls: as generic properties they **fail the Operaton start**, the Java calls do
     not compile, and `operaton.bpm.authorization.validate-auth-resource-id-exists` is ignored silently. Apply the D17
     query-expression mitigation (`references/identity-and-admin.md` §10).
   - Rewrite Spin / engine REST / external task client code from `tools.jackson.*` to `com.fasterxml.jackson.*`: Operaton
     2.x is Jackson 2 only there. The recipe maps the `-jackson3` artifacts back but does not rewrite code.
   - Remove license files, mounts and secrets (the recipe deletes `camunda.bpm.license-file`); keep the license rows in
     the database for rollback. Record the EE webapp features that disappear (the recipe maps them to CE, no build error).
   - Once the build is green: remove the EE repository and its credential references from the project (POM, `.mvn/`,
     CI secrets) and prove that the build resolves from Maven Central alone (step 6). Tell the user not to revoke the
     credentials themselves before the rollback window closes: a rebuild of the Camunda rollback build needs them.
5. Run `bash "<skill-dir>/scripts/verify-leftovers.sh" <project-dir>` until it exits 0. Bundled helpers (with the
   marker) and `migration/` are skipped. Accepted leftovers (e.g. `WEBAPP_PATH` under D6) go into
   `.operaton-migration-ignore`, one line each **with a reason**, and into the report. The Spring Boot 4 / EE rules
   (`STARTER_4`, `JACKSON3_ARTIFACT`, `ENGINE_SPRING_6`, `EE_*`) are fixed, not accepted.
6. Work through the non-code topics — each has a reference; apply what the decisions require:
   - Configuration, env vars, logging, health, bean names, webapp path, `LegacyCamundaConfigGuard` → `references/configuration.md`
   - BPMN/DMN scripts, forms, namespace, in-flight instances on old definition versions → `references/models-and-scripts.md`
   - Engine plugins, history/event exporters (D9 envelope), SPI files, identity providers → `references/plugins-and-exporters.md`
   - Admin group (`camunda-admin` → `operaton-admin`), the **setup-endpoint security issue** and the EE hardening Operaton
     lacks → `references/identity-and-admin.md` (add `AdminGroupMigrationPlugin` + `MigrationHelpersConfiguration` +
     `LegacyWebappPathRedirectFilter`, adapting the package, and/or prepare `assets/sql/postgresql/10-migrate-admin-group.sql`)
   - Database: schema checks, Liquibase/Flyway, Java-serialized variables, direct SQL ops scripts → `references/database.md`
   - Tests (JUnit 5 deps, `operaton.cfg.xml`, assert, mocks, coverage libs, helper tests from `assets/snippets/test/`) → `references/testing.md`
7. `mvn -B clean verify` must be green. Record test counts and remaining warnings in the report; commit the result as
   one change (with permission).

### 5. Spring Boot 3.5 path: Hop 1 and Hop 2 (instead of step 4)

Only when `assess.sh` reports the Spring Boot 3.5 path (`--source` detects `boot3`). Why two hops: chapter 15 (link at
the top). The 1.1.x checkpoint is never released (Operaton 1.x and Spring Boot 3.5 are out of support).
`--hop all` runs both hops back to back (one diff; only small, well-tested services, decision D1).

<a id="4-hop-1--camunda-724--operaton-11x-rename-hop"></a>

#### 5a. Hop 1 — Camunda 7.24 → Operaton 1.1.x (rename hop)

1. Dry run: `bash "<skill-dir>/scripts/migrate.sh" --hop 1 --dry-run <project-dir>`; check `==> Source: Spring Boot 3.5
   (boot3; …)`, summarize the patch and review it (`references/recipes.md` §5).
2. Apply: same command without `--dry-run`, with `--with-infra-env` / `--with-form-keys` and the `ScriptImports` rule as
   in step 4.2. Commit the unmodified recipe output (with permission).
3. Then step 4 items 3, 5 and 6 (build, leftovers, non-code topics); an EE build on Spring Boot 3.5 also does item 4.
   `LegacyCamundaConfigGuard` needs the Spring Boot 3 SPI edit (`references/configuration.md` §10).
4. `mvn -B clean verify` must be green; record test counts; commit (with permission).

<a id="5-hop-2--operaton-11x--2x-with-spring-boot-4-platform-hop"></a>

#### 5b. Hop 2 — Operaton 1.1.x → 2.x with Spring Boot 4 (platform hop)

Only if decision D1 targets 2.x (the recommended production target). Hop 1 must be committed (or live in the throw-away clone).
1. `bash "<skill-dir>/scripts/migrate.sh" --hop 2 [--target <2.x version>] <project-dir>` (dry run first;
   `references/recipes.md` §3–§5 for what `UpgradeToOperaton2` does and how to review it).
2. Keep **Jackson 2** for everything that touches Spin or the engine (`DataFormatConfigurator`s, Spin `ObjectMapper`s);
   Spring Boot 4 application code uses Jackson 3. Revert wrong Jackson-3 rewrites in Spin code.
3. Apply the Spring Boot 4 / JUnit 6 / Testcontainers 2 follow-ups from `references/fix-catalog.md` §6, including the
   `LegacyCamundaConfigGuard` SPI switch (interface and `spring.factories` key `org.springframework.boot.EnvironmentPostProcessor`).
4. `mvn -B clean verify` green; record results; commit (with permission).

### 6. Verify

1. Build + tests green (the migration commit; Spring Boot 3.5 path: Hop 1 and Hop 2 results in the report).
2. EE sources: the build resolves from Maven Central alone, e.g. `printf '<settings/>\n' > /tmp/opmig-central.xml` and
   `mvn -B -s /tmp/opmig-central.xml -Dmaven.repo.local=/tmp/opmig-m2 clean verify` (log and wait); no `EE_REPOSITORY` finding.
3. Boot the application locally (H2 or a local throw-away DB) and run
   `bash "<skill-dir>/scripts/smoke-test.sh" --base-url http://localhost:8080 --webapp-path <path> --user <u> --password <p> --require-operaton`.
   You run `--write` only against a local throw-away engine; humans may run it where the runbook says so (T0-12).
4. Prove the admin setup endpoint is closed on a **migrated** database (simulate: start the old app on a file DB,
   then the migrated app on a copy of the file) — see `references/identity-and-admin.md` §7.
5. `verify-leftovers.sh` exit 0 (marked helpers and `migration/` skipped; every remaining accepted leftover in
   `.operaton-migration-ignore` with a reason, copied to the report). Fill the "Verification evidence" section and set
   the **branch gate** (code migration) by its criteria in the report template. The **cut-over gate** (production)
   stays NOT READY until humans close its items (D18 detection on a production copy, D9 consumer sign-off,
   `camunda-admin` member check P03, D17 filter review P11, configuration outside the repo, rehearsal incl. rollback);
   list each as an open item with an owner.

### 7. Cut-over pack

Load `references/cutover.md`. Produce, for human review, in a `migration/` folder of the project:
a tailored cut-over runbook (timeline, owners, go/no-go checks, rollback triggers and point of no return — D15),
copies of the needed SQL from `assets/sql/postgresql/` adapted to the user's DB vendor (see `references/database.md`
for porting notes), and the list of downstream teams to notify (event consumers, REST clients, ops/alerting).
Never execute these scripts yourself. `migration/` is skipped by `verify-leftovers.sh` and ignored by `migrate.sh`'s
clean-tree check (the SQL copies contain `camunda` on purpose). Target 2.2.x: the runbook also runs
`<db>_engine_7.24_to_7.25.sql` (a schema-log row, no DDL) at the cut-over.
At the end of `migrate` mode, offer this step. If the user declines, still generate the minimum the defaults rely on
(D5 SQL, D10 emergency SQL): `migration/sql/<vendor>/` copies of `00-`, `10-` and `20-…sql` (plus `30-`/`31-` if D10 keeps
emergency SQL) and a `migration/cutover-runbook.md` stub marked DRAFT with placeholders.

## Running in the Copilot cloud agent

The GitHub Copilot cloud agent works without a human in the loop and opens a pull request. Adjust as follows:

- **One mode per session.** A session ends after 59 minutes and cannot be extended. Spring Boot 4 path: `assess`,
  `migrate`, then `verify` / `cutover` as separate tasks. Spring Boot 3.5 path: `migrate` stops after Hop 1; Hop 2 is a
  separate `hop2` task.
- **No questions.** Apply the recommended defaults from `references/decisions.md`, record each as
  `accepted (default, assumed)` and list it under "Open items" for confirmation in the PR review. Never assume a
  deviation from a default; leave it open. Commit policy in the report: "Copilot cloud agent branch, PR review".
- **The pull request is the review gate.** Safety rule 2 is met by the platform; do not merge, do not push elsewhere.
- **Environment.** The skill directory must be committed in the application repository (`.github/skills/`,
  `.claude/skills/` or `.agents/skills/`). `assets/copilot/copilot-setup-steps.yml` goes to `.github/workflows/` of the
  application repository on its default branch: JDK 21, Maven cache, optional EE credentials from **Agents** secrets
  (`CAMUNDA_EE_USER`, `CAMUNDA_EE_PASSWORD`), a non-failing dependency warm-up. EE builds: add `artifacts.camunda.com`
  to the custom allowlist (repository Settings > Copilot > Internet access); Maven Central and the Gradle plugin portal
  are on the recommended allowlist. The firewall applies to your shell commands, not to the setup steps.
- Never use production credentials or production databases from the cloud agent.

## Key facts to keep in mind (details in references)

- Operaton's DB schema equals Camunda **7.24** — no DDL migration, same `ACT_*` tables. Being on 7.24 first is mandatory.
  EE patch levels do not change the schema; Operaton 2.2 only adds a `7.25.0` schema-log row.
- Use `scripts/migrate.sh`: Spring Boot 4 → `starterpack.operaton.MigrateSpringBoot4App` (one run); Spring Boot 3.5 →
  `starterpack.operaton.MigrateSpringBootApp` (Hop 1) + `starterpack.operaton.UpgradeToOperaton2` (Hop 2). The official
  `org.operaton.rewrite.spring.MigrateSpringBootApplication` alone maps no `-4` starter and no `-jackson3` artifact,
  always writes Operaton 1.0.x and maps the EE webapps to CE silently: on a Spring Boot 4 project it renames the imports
  and leaves a broken build. The generic recipe does not rename `camunda.bpm.*` properties, and leftover keys are
  **silently ignored**.
- The official recipe has known bugs (JUnit 5 deps never added, Mocks relocation): the starter-pack recipes fix them.
- `camunda-admin` is no longer the admin group. On an existing DB nobody is in `operaton-admin` → the webapp
  **setup page lets anyone create an admin** until memberships are migrated. Treat this as a release blocker.
- Scripts in BPMN/DMN that import `org.camunda.*` deploy fine and **fail at runtime** — also for running instances
  on older definition versions, which must be migrated to a fixed version. Fix them package-free on Camunda 7.24 (step 3b;
  in scripts only `S(…)` is pre-bound, `JSON(…)`/`XML(…)` are not): `org.operaton.*` references and `operaton-forms:` keys
  with open tasks are rollback hard stops (decision D15).
- Exported events that carry engine class names change silently: by default keep the payload stable (D9, envelope v2
  with `eventClass` frozen to the Camunda value) until consumers sign off.
- Webapps move from `/camunda` to `/operaton` unless `operaton.bpm.webapp.application-path` keeps `/camunda` (D6).
- Operaton 2.x requires Spring Boot 4, paired by minor (2.1.5 = Spring Boot 4.0.8, 2.2.x = 4.1); 1.x is end of life.
  Version table: `references/versions.md` (refresh with `scripts/latest-versions.sh`).
- Camunda EE hardening Operaton does not have (D17): the query-API expression allow-list (7.24.7-ee; security notice
  157), `validateAuthResourceIdExists` and the datasource autocommit check (7.24.3-ee). Operaton 2.x Spin, REST and
  external task client are Jackson 2 only (no `-jackson3` artifacts). The Operaton build needs the EE repository only
  while the recipe runs; the Camunda rollback build needs it until the rollback window closes.
- The Spring Boot 4 path was tested end to end with stub EE artifacts that delegate to the CE 7.24.0 jars, not against
  the real EE repository: always dry-run on the real build first.

## Installing this skill (for humans)

The skill is written for Claude Code and for GitHub Copilot agents with Claude models. The Copilot instructions follow
GitHub's documentation; this project has not run the skill in Copilot yet. Full instructions (VS Code, JetBrains,
models per Copilot plan):
[README · Use it with Claude Code or GitHub Copilot](https://github.com/Miragon/migration-recipies/blob/main/services/c7/README.md#let-claude-drive).

```bash
# Claude Code: plugin from this repository's marketplace
claude plugin marketplace add Miragon/migration-recipies
claude plugin install operaton-migration@migration-recipies     # /operaton-migration:migrating-camunda7-to-operaton assess
# GitHub Copilot CLI: same marketplace and plugin (VS Code picks up plugins installed by the Copilot CLI)
copilot plugin marketplace add Miragon/migration-recipies
copilot plugin install operaton-migration@migration-recipies    # then /migrating-camunda7-to-operaton assess
# Copilot cloud agent, Visual Studio: copy the skill into the project (GitHub CLI 2.90+, preview; lands in .agents/skills/)
gh skill install Miragon/migration-recipies migrating-camunda7-to-operaton
```

Manual copy: project `.claude/skills/` (read by Claude Code, VS Code, Visual Studio, the Copilot CLI and the cloud
agent), `.github/skills/` or `.agents/skills/` (Copilot only; JetBrains: `.github/skills/`); personal `~/.claude/skills/`
(Claude Code, VS Code, Visual Studio), `~/.copilot/skills/` or `~/.agents/skills/` (Copilot CLI, which no longer reads
`~/.claude/skills/`, VS Code, Visual Studio). Copy the whole directory: the scripts and assets are part of the skill.
