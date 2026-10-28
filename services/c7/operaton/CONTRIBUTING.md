# Contributing

Operaton ships a patch every month and a minor every six months, so this pack goes stale without help. Corrections are welcome.

This guide lives in `services/c7/operaton/` of the repository, and its agent skill in `plugin/skills/`. Run the commands
below from `services/c7/operaton/`; paths in this file are relative to it, except `plugin/…` and `.github/…`, which
are relative to the repository root.

## Rules

- **Every factual change needs a source — link it in the PR description.**
- **Decisions stay consistent:** D1–D18 live in [docs/01](docs/01-migration-path-and-decisions.md); if you change a recommendation, update every place that repeats it (`grep -rn "#d5" README.md docs checklists`).
- **No copied text** from sources with incompatible licenses (for example Camunda's C7 → C8 migration skill, which uses the Camunda License). Link instead.

## Updating versions

Versions are pinned in several places, and the scripts, the docs and the skill must name the same ones. Work through
these steps for every new Operaton, recipe or plugin release:

1. Run `scripts/latest-versions.sh`: latest releases (Operaton lines with their Spring Boot version, recipe, plugins) vs. the pins.
2. Update the pinned defaults in `scripts/migrate.sh` and `rewrite/rewrite.yml`, the version tables in `README.md`, `docs/01` and
   `plugin/skills/migrating-camunda7-to-operaton/references/versions.md`, and every date: `grep -rniE "(as of|checked on) 20" . ../../../plugin`
3. Re-run the example migration as in [`examples/README.md`](examples/README.md#reproduce-the-migration) and update
   `examples/operaton-spring-boot-migrated/MIGRATION_REPORT.md`. Run `tools/test-boot4-path.sh` for both Spring Boot
   lines (see the checks below), because the example covers only the Spring Boot 3.5 path.
4. Run `tools/sync-skill.sh`, so that the skill gets the changed scripts and recipes.

**When Operaton 2.2.0 is GA** (due 2026-10-23), the production target for Spring Boot 4.1 moves from the pre-release
2.2.0-RC1 to 2.2.0. These places still say 2.2.0-RC1 and must switch:

- `.github/workflows/ci.yml`: the step "Spring Boot 4.1.1 -> Operaton 2.2.0-RC1" of the job
  `migration-e2e-boot4` runs `tools/test-boot4-path.sh --spring-boot 4.1.1 --target 2.2.0-RC1`; change it to
  `--target 2.2.0`.
- `scripts/migrate.sh`: add 2.2.0 to `KNOWN_SPRING_BOOT_FOR_TARGET`, the fallback table of the Spring Boot version
  each target is built with (used when Maven Central cannot be read), and update the Spring Boot 4.1 text of
  `recommend_target()`.
- `tools/test-boot4-path.sh`: change the default target for Spring Boot 4.1.x from 2.2.0-RC1 to 2.2.0.
- `scripts/assess.sh` switches its texts by itself on `GA22_DATE` (20261023). If the GA slips, update that date.

Then run `tools/sync-skill.sh` and the checks below.

## Checks before a PR

CI runs all of these checks except `claude plugin validate`, so run them locally first:

```bash
python3 tools/check-links.py ../../..              # relative links and #anchors in the whole repository
for f in scripts/*.sh tools/*.sh; do bash -n "$f"; done   # syntax (as in CI)
shellcheck --severity=error scripts/*.sh tools/*.sh       # as in CI (if you have ShellCheck)
tools/sync-skill.sh --check                        # skill assets in sync with the canonical files, and the skill is portable
(cd examples/camunda7-spring-boot-legacy && mvn -B verify)
(cd examples/operaton-spring-boot-migrated && mvn -B verify)
scripts/verify-leftovers.sh examples/operaton-spring-boot-migrated
tools/test-boot4-path.sh --spring-boot 4.0.8 --target 2.1.5       # Spring Boot 4 path, Spring Boot 4.0 line
tools/test-boot4-path.sh --spring-boot 4.1.1 --target 2.2.0-RC1   # Spring Boot 4.1 line (2.2.0 once GA)
(cd sql/test && npm ci && node test.mjs)            # SQL against the Operaton PostgreSQL DDL (PGlite)
claude plugin validate ../../..                     # marketplace manifest (if you have Claude Code)
claude plugin validate ../../../plugin              # plugin manifest
```

`tools/test-boot4-path.sh` tests the Spring Boot 4 path end to end against a stub Camunda EE repository, so you need
no EE access. It needs git, JDK 17+ (`JAVA_HOME`), Maven and direct access to Maven Central, because it ignores
`~/.m2/settings.xml`; behind a Central-only mirror it cannot run as is. Details:
[How the Spring Boot 4 path is tested](docs/03-openrewrite-recipes.md#how-the-spring-boot-4-path-is-tested).

## The skill

`plugin/skills/migrating-camunda7-to-operaton/` must stay self-contained, because people copy the whole folder into the
skill folders of Claude Code and GitHub Copilot, for example `~/.claude/skills/` (the
[README](README.md#let-claude-drive) lists them all). Its
`scripts/`, `assets/rewrite.yml`, `assets/sql/` and `assets/snippets/` are **copies**: edit the canonical file, then
run `tools/sync-skill.sh` (CI fails on drift). Keep `SKILL.md` under 500 lines; details go into `references/`.

The skill must work in **Claude Code and in GitHub Copilot** (with Claude models). Copilot substitutes neither
`${CLAUDE_SKILL_DIR}` nor `$ARGUMENTS`, so:

- Refer to bundled files as `<skill-dir>/…`. `SKILL.md` defines `<skill-dir>` once; that definition line is the only
  place where `${CLAUDE_SKILL_DIR}` may appear.
- Never use `$ARGUMENTS`. The skill takes its mode from the user's request.
- Keep the frontmatter portable: `name` equals the folder name (at most 64 characters), and `description` stays at
  most 1024 characters.

`tools/sync-skill.sh --check` enforces the first two rules and prints
"skill is portable (one <skill-dir> definition, no $ARGUMENTS)" when they hold.
