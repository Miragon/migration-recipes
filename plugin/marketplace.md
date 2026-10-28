# Plugin marketplace

This repository is a plugin marketplace for Claude Code and GitHub Copilot. It offers one plugin, `operaton-migration`,
which lives in this folder. Agents read the marketplace from
[`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json) at the repository root and the plugin from
[`.claude-plugin/plugin.json`](.claude-plugin/plugin.json) here; this page describes both for people.

## Plugins and skills

| Plugin | Skill | What it does |
|---|---|---|
| `operaton-migration` | [`migrating-camunda7-to-operaton`](skills/migrating-camunda7-to-operaton/SKILL.md) | Walks a Spring Boot application with an embedded Camunda 7 engine to Operaton 2.x: assess, decide, migrate, verify and cut over. Runs the scripts, recipes and SQL of the [Camunda 7 → Operaton guide](../services/c7/README.md) |

Each skill is self-contained: `SKILL.md` is the entry point, `references/` holds the details the agent loads on demand,
and `scripts/` and `assets/` hold what the agent runs.

```text
plugin/
├── .claude-plugin/plugin.json          plugin manifest
├── marketplace.md                      this page
└── skills/
    └── migrating-camunda7-to-operaton/
        ├── SKILL.md                    entry point: modes assess, migrate, hop2, verify, cutover
        ├── references/                 decisions, recipes, configuration, database, cut-over, troubleshooting …
        ├── scripts/                    assess.sh, migrate.sh, verify-leftovers.sh, smoke-test.sh, latest-versions.sh
        └── assets/                     rewrite.yml (OpenRewrite recipes), sql/ (PostgreSQL), snippets/ (Java helpers),
                                        copilot/ (Copilot cloud-agent setup), MIGRATION_REPORT.template.md
```

## Install

Open or start the agent in **your application's repository**, not in this one: the skill converts the project it runs
in.

**Claude Code**

```bash
claude plugin marketplace add Miragon/migration-recipies
claude plugin install operaton-migration@migration-recipies
# then in Claude Code:  /operaton-migration:migrating-camunda7-to-operaton assess
```

Inside a Claude Code session, the same in one step: `/plugin install operaton-migration --marketplace Miragon/migration-recipies`.

**GitHub Copilot CLI** (reads the same marketplace; VS Code picks up plugins that the Copilot CLI installed)

```bash
copilot plugin marketplace add Miragon/migration-recipies
copilot plugin install operaton-migration@migration-recipies
```

**Copy only the skill** into a project, for the Copilot cloud agent, Visual Studio or JetBrains:

```bash
gh skill install Miragon/migration-recipies migrating-camunda7-to-operaton
```

The full instructions, with the Claude model to pick per Copilot plan, VS Code settings, the Copilot cloud-agent setup
and the folders each agent reads, are in the guide:
[Use it with Claude Code or GitHub Copilot](../services/c7/README.md#let-claude-drive).

## Maintaining the skills

The skill's `scripts/` and its `assets/rewrite.yml`, `assets/sql/` and `assets/snippets/` are **copies** of the
canonical files in [`services/c7/`](../services/c7/). Edit the canonical file, then run
`services/c7/tools/sync-skill.sh`; CI fails if the copies drift. The rules for the skill (self-contained, portable
between Claude Code and GitHub Copilot) are in the guide's [CONTRIBUTING.md](../services/c7/CONTRIBUTING.md#the-skill).
