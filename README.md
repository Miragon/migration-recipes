# migration-recipies

Recipes and pitfalls for migrating process engines: guides, scripts and agent skills that take a team from one engine
to the next, with the decisions, checks and cut-over steps that a real migration needs.

## What's inside

| Folder | What it holds |
|---|---|
| [`services/c7/`](services/c7/README.md) | **Camunda 7 → Operaton.** Guide in 16 chapters, OpenRewrite recipes, assess / migrate / verify scripts, PostgreSQL scripts, a before/after example app, checklists and a cut-over runbook |
| [`services/c8/`](services/c8/README.md) | **Camunda 8.** Reserved for Camunda 8 migration recipes; empty so far |
| [`plugin/`](plugin/marketplace.md) | **Agent plugin** for Claude Code and GitHub Copilot: [`marketplace.md`](plugin/marketplace.md) describes it, [`skills/`](plugin/skills/) holds the skills with their scripts |

```text
.
├── README.md
├── services/
│   ├── c7/                  Camunda 7 → Operaton: guide, recipes, scripts, SQL, examples
│   └── c8/                  Camunda 8 (planned)
├── plugin/
│   ├── marketplace.md       the plugin, its skills and how to install them
│   └── skills/
│       └── migrating-camunda7-to-operaton/   skill + scripts, recipes and SQL it runs
└── .claude-plugin/
    └── marketplace.json     marketplace manifest, read by Claude Code and GitHub Copilot
```

## Quick start

- **Migrating a Camunda 7 application to Operaton by hand:** start with the
  [eight steps of the Camunda 7 → Operaton guide](services/c7/README.md#step-by-step).
- **Letting an AI coding agent do it:** install the plugin in Claude Code and run the skill in your application's
  repository. Other agents (GitHub Copilot CLI, VS Code, `gh skill`) are covered in
  [`plugin/marketplace.md`](plugin/marketplace.md).

```bash
claude plugin marketplace add Miragon/migration-recipies
claude plugin install operaton-migration@migration-recipies
# then in Claude Code:  /operaton-migration:migrating-camunda7-to-operaton assess
```

Inside a Claude Code session, the same in one step: `/plugin install operaton-migration --marketplace Miragon/migration-recipies`.

## License

[Apache License 2.0](LICENSE).
