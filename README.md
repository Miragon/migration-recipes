# migration-recipies

Recipes and pitfalls for migrating process engines: guides, scripts and agent skills that take a team from one engine
to the next, with the decisions, checks and cut-over steps that a real migration needs.

## What's inside

The guides are sorted by migration path: `services/<source engine>/<target engine>/`.

| Migration path | Folder | Status |
|---|---|---|
| Camunda 7 → Operaton | [`services/c7/operaton/`](services/c7/operaton/README.md) | Guide in 16 chapters, OpenRewrite recipes, assess / migrate / verify scripts, PostgreSQL scripts, a before/after example app, checklists, cut-over runbook and agent skill |
| Camunda 7 → Camunda 8 | [`services/c7/c8/`](services/c7/c8/README.md) | Planned |
| Camunda 7 → CIB seven | [`services/c7/cib-seven/`](services/c7/cib-seven/README.md) | Planned |

The [`plugin/`](plugin/marketplace.md) folder holds the agent plugin for Claude Code and GitHub Copilot:
[`marketplace.md`](plugin/marketplace.md) describes it, and [`skills/`](plugin/skills/) holds one skill per migration
path, with the scripts it runs.

```text
.
├── README.md
├── services/
│   └── c7/                          migrations away from Camunda 7
│       ├── operaton/                Camunda 7 → Operaton: guide, recipes, scripts, SQL, examples
│       ├── c8/                      Camunda 7 → Camunda 8 (planned)
│       └── cib-seven/               Camunda 7 → CIB seven (planned)
├── plugin/
│   ├── marketplace.md               the plugin, its skills and how to install them
│   └── skills/
│       └── migrating-camunda7-to-operaton/   skill + scripts, recipes and SQL it runs
└── .claude-plugin/
    └── marketplace.json             marketplace manifest, read by Claude Code and GitHub Copilot
```

## Quick start

- **Migrating a Camunda 7 application to Operaton by hand:** start with the
  [eight steps of the Camunda 7 → Operaton guide](services/c7/operaton/README.md#step-by-step).
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
