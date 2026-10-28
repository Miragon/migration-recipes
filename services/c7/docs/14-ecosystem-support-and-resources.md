# 14 · Ecosystem, support and resources

The engine is only part of a Camunda 7 stack: you may also depend on community extensions such as test helpers,
Keycloak integration, clients, Cockpit plugins and history exporters. This chapter maps each common library to its
Operaton counterpart (or says that there is none), then covers the project's resources and AI tooling, the support
model, and the upstream issues that could change a recommendation in this guide. Teams that leave Camunda 7 EE
(Enterprise Edition) also find here what replaces their EE subscription and where the official Operaton tools stop
covering EE. Tech leads need it during the assessment, to estimate the effort and to decide how Operaton is supported
in production.

**In short**
- **Core artifacts map 1:1 to `org.operaton.*`**: engine, starters, REST, webapps, the Java external task client,
  LDAP, Spin, Connect and assert. The official recipe handles the classic artifacts, and `scripts/migrate.sh` adds
  Camunda's Spring Boot 4 starters (`-4` infix), which have no `-4` counterpart in Operaton.
- **Most community extensions were not ported.** [`scripts/assess.sh`](../scripts/assess.sh) flags the community and
  legacy artifacts the recipe does not map; look them up below. For each **None**: fork it and run the recipe, replace
  it, or drop it.
- **Anything that only talks HTTP to `/engine-rest` keeps working**, because the REST API is unchanged. Watch for the
  renamed field `camundaFormRef` → `operatonFormRef`.
- **The project offers no LTS (long-term support) and no SLA (service level agreement).** Decide the support model
  before go-live ([support model, D14](01-migration-path-and-decisions.md#d14)), because it decides how often you must
  upgrade.
- **Leaving Camunda EE means leaving a maintained line.** Camunda maintains 7.24 EE until 13 Apr 2030, with patch
  releases and security fixes for EE customers. Operaton replaces neither the EE features nor that maintenance, so the
  support-model decision replaces your EE subscription.
- **Operaton's own migration tools and docs cover Camunda 7 CE only.** The official recipe maps no Spring Boot 4
  starter of Camunda EE and always writes Operaton 1.0.x. This pack's `scripts/migrate.sh` adds what is missing
  ([The official recipe and Camunda EE](#the-official-recipe-and-camunda-ee)).
- **Forks get published or abandoned within weeks.** Re-check the rows you depend on when your project starts.

## Community extensions and test libraries

The table maps each common Camunda 7 library to its Operaton replacement. The status column tells you how much you
can rely on the replacement:

- **Core:** part of Operaton itself, released with every Operaton version.
- **Maintained:** a maintained Operaton build exists outside core, in the Operaton organization or upstream.
- **Community fork:** someone forked and ported it. Check publication, version alignment and activity yourself.
  "Fork, unpublished" means you have to build it yourself.
- **REST-level:** no port, but it keeps working because it only talks HTTP to `/engine-rest`.
- **None:** no Operaton build exists. Fork it and run the recipe, replace it, or drop it.

| Camunda 7 library | Operaton replacement | Status |
|---|---|---|
| `camunda-bpm-assert` | `org.operaton.bpm:operaton-bpm-assert` | Core |
| `ProcessEngineExtension` (`camunda-bpm-junit5`) | `operaton-engine` classifier `junit5` (2.x also `junit6`), or `operaton-bpm-spring-boot-starter-test-junit5`; **not** `operaton-bpm-junit5` | Core |
| `org.camunda.bpm.extension:camunda-bpm-junit5`, `org.camunda.bpm.assert:*` | Move to the official 7.24 test artifacts **before** the recipe | None |
| camunda-process-test-coverage | `io.github.ronalders:operaton-process-test-coverage-*` 1.0.0 | Community fork |
| camunda-platform-scenario | `io.github.ronalders:operaton-platform-scenario-runner` 1.1.2 | Community fork |
| camunda-platform-7-mockito, camunda-bpm-data | Unpublished `operaton` branches; fallback `Mocks.register(...)` plus Mockito | Fork, unpublished |
| bpmn-to-code | `io.miragon:bpmn-to-code-*` 6.1.1, engine `OPERATON` | Maintained |
| camunda-platform-7-keycloak | `org.operaton.bpm.extension:operaton-keycloak` 1.1.0 / 2.1.0 (per Operaton line) | Maintained |
| viadee external-task-retry-aspect | Same artifact, 1.12.0+ | Maintained |
| Cockpit plugins (datakurre) | `datakurre/operaton-cockpit-plugins` | Maintained |
| camunda-platform-7-reactor | Built-in `operaton.bpm.eventing.*` | Core |
| JS / Python external task clients | Keep them (`operaton-external-task-client-js` does not exist on npm) | REST-level |
| Generated REST clients | Regenerate from `org.operaton.bpm:operaton-engine-rest-openapi` | REST-level |
| camunda-platform-7-mail, Holunda Feign REST client, Polyflow, bpmn-driven-testing, GraphQL API, history exporters | — | None |
| Camunda EE webapps (`-webapp-ee`, `camunda-webapp-webjar-ee`) | The CE webapps (`operaton-bpm-spring-boot-starter-webapp`); the EE screens are missing | Core, CE scope only |
| Camunda Optimize | — | None |
| Jackson 3 opt-in of 7.24.16-ee (`-jackson3` artifacts for Spin, REST and the external task client) | The Jackson 2 artifacts; Operaton 2.x has no Jackson 3 variants | None |

Notes on some rows:

- **Test helpers:** do not use `operaton-bpm-junit5`, because it contains no `ProcessEngineExtension` on 1.x. Move the
  legacy coordinates `org.camunda.bpm.extension:camunda-bpm-junit5` and `org.camunda.bpm.assert:*` to the official
  7.24 artifacts before the recipe runs; otherwise the package rename produces packages that do not exist.
- **Keycloak:** rename the three `use…AsCamunda…Id` properties to `…Operaton…`, because the old keys are silently
  ignored. The recipe maps only the base artifact, not `-jwt`/`-all`/`-run`.
- **Version alignment:** community forks pull `operaton-engine:junit5:1.1.2` at compile scope. Import `operaton-bom`,
  and check with `mvn dependency:tree | grep -E 'org\.operaton'` that only a single Operaton version is left.
- **Camunda EE webapps:** the recipe maps them to the CE webapps without a build error, so the history view, heatmap,
  instance modification, migration UI, batches and reports disappear. REST calls replace each of them
  ([Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features)), and community Cockpit
  plugins exist (`datakurre/operaton-cockpit-plugins`). Decide per feature in the
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17).
- **Jackson 3:** Operaton decided to stay on Jackson 2 for Spin, REST and the client in 2.x
  ([operaton#1672](https://github.com/operaton/operaton/issues/1672)), and no open issue tracks Jackson 3 for them.
  `scripts/migrate.sh` maps the `-jackson3` artifacts back to the Jackson 2 ones; code written against
  `tools.jackson.*` for Spin, REST or the client must be ported by hand
  ([Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in)).

## Operaton project resources

The Operaton project ships more than the engine. Some of it targets new projects or the standalone distribution, so
check what each resource is good for before you use it in a migration:

- [docs.operaton.org](https://docs.operaton.org): the reference documentation and the official migration page. That
  page, "Migration Guide from Camunda 7 CE to Operaton", covers Camunda 7 CE only and says nothing about EE; Operaton
  states API compatibility with Camunda 7 CE 7.24.
- [forum.operaton.org](https://forum.operaton.org): migration questions (most land in **Development**).
- [github.com/operaton](https://github.com/operaton): issues and releases. Report security issues only via private
  advisories.
- [`migrate-from-camunda-recipe`](https://github.com/operaton/migrate-from-camunda-recipe): the official recipe and its
  mapping file. This pack wraps it in [`rewrite/rewrite.yml`](../rewrite/rewrite.yml), because it does not cover
  Camunda EE on Spring Boot 4 ([below](#the-official-recipe-and-camunda-ee)).
- [operaton.org/hub](https://operaton.org/hub): curated community plugins. The entries are not quality-reviewed.
- [start.operaton.org](https://start.operaton.org) and `operaton/operaton-examples`: references for a clean 2.x
  project, useful to compare with your migrated one. Don't copy the generator's test dependency
  (`operaton-bpm-junit5`).

Not for the production path:
- **The Docker images** run the standalone distribution, while an embedded application builds its own image. Use them
  only as a test fixture, with a pinned version tag, never `latest`.
- **The Helm chart** is stale.
- **The Operaton Modeler** has no releases. Keep the Camunda Modeler while your models use `camunda:`.

### The official recipe and Camunda EE

Read this before you compare this pack with the official recipe, or run the official recipe on its own. The official
recipe `org.operaton:migrate-camunda-recipe` was written for Camunda 7 CE. Version 1.0.1 (January 2026) is the
latest release, its recipe sources on the main branch are unchanged since, and as of 2026-10-11 no issue or pull
request in its repository mentions Spring Boot 4, the `-4` starters, Jackson 3, Camunda EE patch versions or
Operaton 2.x. On a Camunda 7.24 EE project on Spring Boot 4 it falls short in these ways:

- **It maps no `-4` starter**, no `-jackson3` artifact and not `-webapp-core`. It renames the Java imports anyway, so
  the code refers to Operaton packages while the build still pulls Camunda EE starters, and the build breaks.
- **It always writes Operaton 1.0.x**, an end-of-life line that is not built for Spring Boot 4, and it leaves a
  `${camunda.version}` property behind.
- **It maps the EE webapps to the CE webapps** (`camunda-bpm-spring-boot-starter-webapp-ee`,
  `camunda-webapp-webjar-ee`), so the EE screens disappear without a build error.
- **It deletes `camunda.bpm.license-file`, but carries EE-only generic properties over unchanged**, such as
  `queryExpressionAllowListEnabled`. Operaton does not start with them.
- **It leaves `<repositories>` alone**, so the Camunda EE repository stays in your build.

This pack's composite recipe `starterpack.operaton.MigrateSpringBoot4App`, which `scripts/migrate.sh` runs on a
Spring Boot 4 project, runs the official recipe and adds the missing mappings, and
[`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh) reports what is left. Details:
[OpenRewrite recipes](03-openrewrite-recipes.md).

## AI and agent tooling

AI tools can help you look at an engine before and after the cut-over. They do not replace the deterministic checks
of this pack.

- This pack's agent skill,
  [`plugin/skills/migrating-camunda7-to-operaton/SKILL.md`](../../../plugin/skills/migrating-camunda7-to-operaton/SKILL.md), drives the
  recipes, scripts and checks. It works with Claude Code, and with GitHub Copilot when you choose a Claude model
  (installation: [Use it with Claude Code or GitHub Copilot](../README.md#let-claude-drive)). It starts
  assessment-only and never runs database-changing SQL itself.
- `operaton-mcp` (npm) is an MCP server that gives AI agents tools for the Operaton REST API. It reads definitions,
  instances, jobs and incidents over `/engine-rest`, which is useful for before/after triage. The evidence stays
  [`scripts/smoke-test.sh`](../scripts/smoke-test.sh).

> [!WARNING]
> `operaton-mcp` 1.1.0 ignores `OPERATON_GUARD=read-only`: it can complete tasks, set retries or delete instances.
> Never point it at production or a shared database. Use a throw-away copy, authorization enabled, and a technical
> user that engine authorizations make read-only.

## Support and service providers

The Operaton project gives you releases and a security process, not a support contract. These facts drive the
support-model decision:

- **Release train:** a minor every April and October, and monthly patches. Each minor is supported for six months,
  until the next one. There is no LTS.
- **Maintained line:** 2.1.x until 2.2.0 replaces it: the roadmap ends 2.1 support with the 2.2 release in
  October 2026 (GA due 2026-10-23). 1.1.x is end of life; its final release is 1.1.5.
- **Security:** fixes come generally only for the latest line. The work is volunteer-driven, with no SLA. As of
  2026-10-11, Operaton has published no security advisory. That includes the expression injection through stored task
  filters that Camunda security notice 157 describes: Operaton behaves like Camunda before 7.24.7 there
  ([Identity, admin group and security](07-identity-admin-group-and-security.md)).
- **Budget a minor upgrade every six months**, or contract a provider that backports fixes to your line.
- **Commercial providers** list themselves at [operaton.org/service-providers](https://operaton.org/service-providers);
  the project does not review or endorse them.

The **support-model decision** ([D14 · Support model](01-migration-path-and-decisions.md#d14)) answers who supports
Operaton for you in production: the community, a commercial provider or your own team. Decide it before go-live,
because it sets your upgrade rhythm: without a provider that backports fixes to your line, you must move to a new
minor version every six months to keep getting security fixes. The three options:

- **Community only** (forum, GitHub): no cost, but no SLA, and you must follow the six-month release train.
- **Commercial provider** from the operaton.org list: an SLA, extended maintenance for older lines and migration
  help, at a cost and after due diligence on the provider.
- **In-house team** that patches and builds Operaton itself: full control, but it needs engine expertise and release
  engineering.

For business-critical processes, use a provider or a staffed in-house team. Record the choice in the
[decision log](../checklists/decision-log-template.md).

### Coming from a Camunda EE subscription

For a team on Camunda 7.24 EE, the support-model decision replaces the EE subscription, so compare what you give up
with what you get:

- **What Camunda EE gives you today:** Camunda maintains 7.24 EE until 13 Apr 2030. Patch-level updates are only
  provided to enterprise customers, and security fixes come as patches to the enterprise platform, together with
  Camunda's security notices. Platform updates came as patches too: the Spring Boot 4 starters in 7.24.3-ee, the
  environment update with Spring 7 and Spring Boot 4.0 in 7.24.6-ee, and Spring Boot 4.1 in 7.24.10-ee.
- **What Operaton gives you instead:** a six-month release train with no LTS, security fixes generally only for the
  latest line, and no SLA from the project. Without a provider that backports fixes, you upgrade to a new minor
  every six months.
- **What you lose regardless of the support model:** the EE screens in Cockpit, Optimize, the EE security hardening
  of the 7.24.x patches and the Jackson 3 opt-in. The
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17) plans a replacement for each.
- **What you still need from Camunda for a while:** access to the EE repository with valid credentials and the
  license, until the rollback window after the cut-over closes, because the rollback build is your last Camunda EE
  build ([Cut-over, rollback and operations](11-cutover-rollback-and-operations.md#rollback-and-the-point-of-no-return)).

## Upstream issues to watch

Each of these upstream items can change a recommendation in this guide. Check their state when your project starts.
The second column says what would change once the item lands.

| Item | What would change |
|---|---|
| [operaton#941](https://github.com/operaton/operaton/issues/941) — persisted `org.camunda` references | An official tool replaces convert-or-drain: converting such variables on Camunda 7.24, or letting their instances finish there ([legacy-variables decision, D18](01-migration-path-and-decisions.md#d18)) |
| Recipe release after `v1.0.1` | It fixes the JUnit 5, `Mocks` and `ReplaceGetExecutionContext` bugs, so `starterpack.operaton.PreFixes`/`PostFixes` shrink |
| A recipe release that maps the `-4` starters and writes Operaton 2.x (no issue tracks it as of 2026-10-11) | `starterpack.operaton.Boot4PreFixes` and `AlignVersionsOperaton2` shrink |
| `operaton-rewrite` release (today 0.1.0-SNAPSHOT, not on Maven Central) | An official 1.x → 2.x recipe replaces `starterpack.operaton.UpgradeToOperaton2`, the platform recipe of [the two-hop path](15-coming-from-spring-boot-3.md) |
| `operaton-mcp` release after 1.1.0 | The guard flags become usable |
| Operaton 2.2.0 GA | The production target moves to 2.2.x (Spring Boot 4.1): Spring Boot 4.1 teams go live with `--target 2.2.0` instead of rehearsing with 2.2.0-RC1. 2.1.x support ends. |
