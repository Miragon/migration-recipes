# Decisions D1–D18

Catalogue of the 18 migration decisions with the question to ask, the options, the recommended default and the
consequence. IDs and recommendations match the guide:
[01 · Decision catalogue](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/01-migration-path-and-decisions.md#4-decision-catalogue)
(each decision has an anchor, e.g. `…/01-migration-path-and-decisions.md#d5`). Versions: see references/versions.md.
Spring Boot 3.5 path: [15 · Coming from Spring Boot 3.5](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/15-coming-from-spring-boot-3.md).

## Contents

1. How to run the decision step
2. D1–D18
3. Batched interview block (copy, fill, send)
4. Recording the answers

## 1. How to run the decision step

- Run it after the assessment. **Pre-fill every answer from evidence** (`assess.sh` findings, code, config) and ask
  only what you cannot infer. Ask **once, in one message** (section 3), never decision by decision.
- Always ask: D1, D3, D5, D6, and D17 for every Camunda EE source (every Spring Boot 4 project is EE: `-4` starters,
  `7.24.N-ee`; also EE on Spring Boot 3.5: `-ee` artifacts, license, EE repository). Ask when the trigger exists: D4
  (`camunda-forms:` keys), D8 (Liquibase/Flyway manage the engine schema), D9 (`HistoryEventHandler`s or other exporters).
- In the same message, ask **once** for commit permission (one local commit per step on the migration branch, never
  pushed; recommended: yes). The answer goes into the report header ("Commit policy"); SKILL step 3 says what to do without it.
- The report has two gates. **Branch gate** (code migration): needs D1, D3, D5, D6 recorded, plus D17 for EE sources
  and D4/D9 when triggered. **Cut-over gate** (production): needs D5, D6, D7, D8, D13, D14, D15, D17 (EE sources), D18
  accepted and D9 consumer sign-off. Mandatory before the first Operaton start on real data: **D5, D7, D8, D15, D17, D18**
  (D17 for every EE source, which includes everyone on Spring Boot 4).
- "Use the defaults" is a valid answer: record each default as accepted, but still state the D5 consequence, the D17
  losses (EE webapp features, EE hardening) and the D15 hard stops in your reply.
- **No human to ask** (Copilot cloud agent): apply every default, record it as `accepted (default, assumed)`, add one
  "confirm in PR review" line per assumed decision to the report's open items, and never assume a deviation. Commit
  permission is implied by the platform (the agent's branch and pull request).
- A deviation is fine if the user gives a reason. These are not options, whatever the user says: the generic recipe or
  `sed` (D2 C/D), the Spring Boot 3.5 path forced on a Spring Boot 4 project (D2), a pre-release such as 2.2.0-RC1 in
  production (D1), mixing `camunda:` and `operaton:` in one file (D3), "do nothing" for the admin group (D5), a mixed
  Camunda/Operaton cluster as the plan (D7 B), byte-rewriting serialized data (D18 option 3). If the user insists,
  record it as an accepted risk, mark it MUST in the report, and do not implement it yourself.

## 2. D1–D18

**D1 · Target version and path** (always ask)
- Ask: Which Operaton version should production run? The path follows from the Spring Boot line `assess.sh` reports
  (rows "Migration path", "Recommended Operaton target").
- **Spring Boot 4 sources** (Camunda 7.24 EE, 7.24.3-ee or later; the main path): the Spring Boot 4 path, one code
  change (one `migrate.sh` run, recipe `starterpack.operaton.MigrateSpringBoot4App`, one commit) and one cut-over on the
  same database. Target by Spring Boot minor: **4.0 → Operaton 2.1.5** (plan 2.2 soon after: 2.1 support ends Oct 2026,
  and 2.2 needs Spring Boot 4.1); **4.1 → Operaton 2.2.x** (GA due 2026-10-23; rehearse with `--target 2.2.0-RC1`, never
  production; go live with `--target 2.2.0`); **4.2+ → no Operaton line yet**: migrate on 4.1 or wait. The recipe never
  downgrades Spring Boot; a target built with another minor is an unsupported pairing (2.1.5 on Spring Boot 4.1.1
  started and passed a smoke test, but Operaton supports only the default pairs). Switching a 4.0 project to 2.2: upgrade
  it to Spring Boot 4.1 first (own commit), then migrate with the 2.2 target.
- **Spring Boot 3.5 sources** (CE 7.24.0, or EE still on 3.5; details in guide chapter 15): options A final 1.x as
  target (EOL) · B two code hops (1.x checkpoint → 2.x), one production cut-over · C one run straight to 2.x
  (`migrate.sh --hop all`) · D two production cut-overs (1.x live, 2.x later). Default **B**: Hop 1 = final 1.1.x on
  Spring Boot 3.5; Hop 2 = 2.x on Spring Boot 4; production target = latest 2.x GA patch at cut-over. C is fine for
  small, well-tested services (no engine plugins, no Liquibase, few scripts).
- Default: the Spring Boot 4 path for Spring Boot 4 sources; **B** for Spring Boot 3.5 sources. Prerequisite: Camunda
  7.24 (schema log `7.24.0`, or a `7.24.N` EE patch row).
- Consequence: Spring Boot 4 path: one commit with a green build, one release. Spring Boot 3.5 path: two commits with
  their own green builds; the 1.x checkpoint must never be released (1.x and Spring Boot 3.5 are out of support). A/D
  put EOL software in production: only with a dated exit plan. Camunda below 7.24 is a stop condition (Step 0 first).

**D2 · Recipe toolchain** (inform; ask only if the user objects)
- Options: A official `MigrateSpringBootApplication` alone · B starter-pack composites via `scripts/migrate.sh`, which
  detects the source (`--source auto`): Spring Boot 4 → `starterpack.operaton.MigrateSpringBoot4App` (one run);
  Spring Boot 3.5 → `starterpack.operaton.MigrateSpringBootApp` (Hop 1) + `starterpack.operaton.UpgradeToOperaton2`
  (Hop 2) · C generic `org.operaton.rewrite.MigrateFromCamunda` · D `sed`/IDE.
- Default: **B**, pinned plugin versions, always `--dry-run` first on a clean branch.
- Consequence: B fixes the official recipe's defects (JUnit 5 deps never added, Mocks relocation, version pinned to
  `1.0.x`) and gaps (BPMN scripts, logger names, whitelist values; on Spring Boot 4: the `-4` starters, `-jackson3`
  artifacts, `-webapp-core`, the `camunda-bom`). A on a Spring Boot 4 project renames the Java imports but leaves the
  `-4` starters, writes Operaton 1.0.x (a Spring Boot 3.5 line, EOL) and maps the EE webapps to CE: a broken build. C
  leaves `camunda.bpm.*` keys unrenamed (silently ignored). D renames `org.camunda.feel` and breaks DMN. Never force
  the Spring Boot 3.5 path on a Spring Boot 4 project (`--source boot3`): Hop 1 leaves an unbuildable POM, Hop 2 alone
  renames nothing, rewrites the Spin configurator to Jackson 3 and downgrades Spring Boot 4.1 → 4.0.8.

**D3 · BPMN/DMN namespace** (always ask)
- Ask: Keep the `camunda:` namespace in your models for the migration, or convert to `operaton:` now? And for scripts
  that import `org.camunda.*`: package-free fix deployed on Camunda 7.24 first, or rename to `org.operaton.*`?
- Options: A keep `camunda:` · B convert everything in the migration release · C convert later per deployment unit.
  Never mix both in one file (`operaton:` wins, `camunda:` listeners are silently ignored).
- Default: **A now, C later** (when a team adopts the Operaton Modeler). Scripts: **package-free** (only the pre-bound
  `S(…)`, plain Groovy/JS), done in the pre-migration release on Camunda 7.24 (SKILL step 3b, before the recipe run),
  deployed before the cut-over, running instances migrated there. Then the recipe's `ScriptImports` finds nothing.
- Consequence: A = no new versions, no timer resets, Camunda Modeler keeps working, rollback stays possible.
  B = new version of every model, timer start events rescheduled, first `operaton:` deployment with instances is a
  rollback hard stop. Script imports are not optional: `org.camunda.*` imports deploy fine and fail at runtime, also
  in in-flight instances. `ScriptImports` (`org.operaton.*`) is Operaton-only and becomes a D15 hard stop.

**D4 · Camunda Forms keys** (ask if `camunda-forms:` keys exist)
- Ask: Who renders these task forms: your own UI, or the Operaton Tasklist?
- Options: A keep `camunda-forms:` · B `operaton-forms:` (`migrate.sh --with-form-keys`, recipe
  `starterpack.operaton.FormKeys`) · C `formRef` (`camunda:formRef` + `camunda:formRefBinding`).
- Default: own UI → **A** (clients reading REST field `camundaFormRef` switch to `operatonFormRef`).
  Operaton Tasklist → **C** (works on Camunda 7.24 too: part of the pre-migration release, SKILL step 3b; deploy and
  migrate instances before the cut-over); B only if the user accepts it as a D15 hard stop.
- Evidence rule: webapp starter (`camunda-bpm-spring-boot-starter-webapp*` or `-4-webapp*`) on the classpath **and** `camunda-forms:`
  keys / `.form` (form-js) files → assume the Operaton Tasklist renders them and pre-fill **C**, unless the user says
  otherwise (`assess.sh` prints this suggestion). No webapp starter → pre-fill **A**.
- Consequence: according to the source, the Operaton Tasklist only recognizes `operaton-forms:`, so `camunda-forms:`
  tasks likely show an external-form link (verify one task per form on staging). B/C create new versions; running
  instances keep the old key until migrated. webapps-neo only renders form-js via `formRef`.

**D5 · Admin group** (always ask; mandatory) — details in references/identity-and-admin.md
- Ask: Which identity do you use (DB identity, LDAP, Keycloak, OAuth2)? With DB identity: mirror `camunda-admin` to
  `operaton-admin` with the SQL script in the runbook, the startup plugin in the app, or both?
- Options: A `10-migrate-admin-group.sql` before the first start · B `AdminGroupMigrationPlugin` · C
  `AdministratorAuthorizationPlugin(operaton-admin)` (complement only) · D also declare `camunda-admin` an admin group
  (time-boxed transition aid) · E external identity: map the group in LDAP/Keycloak/IdP.
- Default: DB identity → **A + B**, plus C if authorization is enabled; LDAP/Keycloak/OAuth2 → **E**. Always: block
  `<app-path>/api/admin/setup/*` at the ingress during and after the cut-over; keep `camunda-admin` rows until the
  rollback window closes.
- Consequence: without it, nobody is in `operaton-admin` and the webapp setup endpoint lets **anyone create an
  administrator** (release blocker). `operaton.bpm.admin-user` does not add an existing user. C and D alone do not
  close the endpoint.

**D6 · Webapp path** (always ask)
- Ask: Keep the webapps at `/camunda` for the cut-over, or move to `/operaton` now?
- Options: A keep `/camunda` explicitly · B move with the cut-over · C move later with a redirect
  (`LegacyWebappPathRedirectFilter` snippet or a proxy 301).
- Default: **A, then C**. Set `operaton.bpm.webapp.application-path: /camunda` explicitly even when keeping it.
- Consequence: the Operaton default is `/operaton`; a lost key silently moves the webapps and breaks ingress rules,
  SSO redirect URIs, health checks and bookmarks (404). B changes all of them in the cut-over window.
  `/engine-rest` never changes.

**D7 · Cut-over strategy** (mandatory before the cut-over)
- Ask: Can you take a maintenance window (stop all Camunda nodes, start Operaton on the same database)? How many
  services share the engine database?
- Options: A big bang on the same DB, rehearsed · B rolling / mixed cluster · C app by app on a shared DB
  (`deployment-aware`) · D blue/green with a DB copy (rehearsal only).
- Default: **A**, rehearsed twice with D (once including the rollback). Kubernetes: `strategy.type: Recreate` or
  scale to 0 first.
- Consequence: downtime = graceful stop + job-lock expiry (up to `lockTimeInMillis`, default 5 min, or reset) + backup
  + start + smoke test. B is untested upstream (jobs run on either engine). C needs a `camunda:` namespace freeze,
  package-free scripts and both admin groups populated.

**D8 · Schema management** (mandatory; ask details if Liquibase/Flyway manage the engine schema)
- Ask: Who manages the engine schema: the engine (`schema-update`), Liquibase (engine changelog included), Flyway, or a DBA?
- Options: A `schema-update: false` + pre-flight SQL · B keep `schema-update: true` · C Liquibase-managed ·
  D Flyway/DBA scripts.
- Default: **A**, combined with C or D where they exist: Liquibase gets the verified fix (Fix E for CLI/pipeline,
  Fix D for `spring.liquibase`) plus its reverse for the rollback build; Flyway takes scripts from
  `org.operaton.bpm.distro:operaton-sql-scripts`. Details: references/database.md.
- Consequence: B never upgrades anything and, with a lost schema-name/table-prefix key, creates an empty schema next to
  the real one. Untreated Liquibase fails at startup (changed changelog path and author).

**D9 · History exporters** (ask if exporters exist)
- Ask: Who consumes the exported events, and do they route or deserialize on Java class names? Is at-most-once
  acceptable (observability) or do you need at-least-once (audit, SIEM, billing)?
- Options: A keep publishing inside the engine transaction (never) · B after-commit hand-off of an immutable DTO ·
  C transactional outbox + relay · D CDC/polling of `ACT_HI_*`.
- Default: **C** for business streams, **B** for observability; own versioned DTO, versioned topic, dual-read
  consumers, in the same release as the migration. Details: references/plugins-and-exporters.md §5–§6.
- Default for the payload when consumers are unknown or have not signed off (the usual case at migration time): **keep
  the contract stable**. Envelope v2 = the existing fields plus `schemaVersion` and a logical `entityType`, with
  `eventClass` frozen to the Camunda value
  (`event.getClass().getName().replaceFirst("^org\\.operaton\\.", "org.camunda.")`); the consumer canary test stays
  unchanged. Flip or drop `eventClass` only after every consumer owner signed off (cut-over gate).
- Consequence: class names become `org.operaton.bpm.engine.impl.history.event.…`: a breaking event-schema change that
  no build catches. The frozen field defers it; additive fields still need a schema update where consumers validate
  strictly (Avro/JSON Schema registries, `FAIL_ON_UNKNOWN_PROPERTIES`).

**D10 · Direct DB scripts** (ask if SQL on `ACT_*` exists)
- Ask: Which scripts write `ACT_*` tables (ops runbooks, cron jobs, DBA folders)? Can ops call the REST API?
- Options: A keep · B replace with Java API/REST, keep only tested emergency SQL · C ban SQL completely.
- Default: **B** (`IncidentRecoveryService` snippet; `30-…`/`31-…` emergency SQL only with all engine nodes stopped).
- Consequence: kept scripts bypass engine semantics (incidents stay open, no history) and scripts writing
  `camunda-admin` now grant the wrong group.

**D11 · Test stack** (inform; ask only about community test libraries)
- Options: A `operaton-bpm-spring-boot-starter-test-junit5` + `operaton-bpm-assert` · B `operaton-engine:<v>:junit5`
  (`junit6` on 2.x) · C `operaton-bpm-junit5` · D implicit default engine.
- Default: **A** for Spring Boot modules, **B** for plain engine modules, never C or D; `camunda.cfg.xml` →
  `operaton.cfg.xml`; process-test-coverage via the pinned `io.github.ronalders` fork. Details: references/testing.md.
- Consequence: without `operaton.cfg.xml`, 1.1+ silently tests a default engine without your plugins.

**D12 · Modeler** (inform)
- Options: A Camunda Desktop Modeler · B Operaton Modeler (no released binaries) · C other bpmn.io-based modelers.
- Default: **A** while models use `camunda:`; pilot B and switch together with the D3 conversion.
- Consequence: a modeler that writes `operaton:` creates new versions and namespace mixes.

**D13 · Health probes** (ask which endpoints the probes call)
- Options: A `processEngine` in the group used by liveness · B readiness group only · C disable the indicator.
- Default: **B**: `liveness.include: livenessState`, `readiness.include: readinessState,db,processEngine`; probes on
  `/actuator/health/liveness` and `/actuator/health/readiness`, never the aggregate `/actuator/health`.
- Consequence: since 2.1 `processEngine` reports DOWN when the DB is unreachable, so liveness on it restarts every pod
  during a DB outage. Rename `management.health.camunda.enabled` → `management.health.operaton.enabled`.

**D14 · Support model** (ask; decide before go-live)
- Options: A community only · B commercial provider ([operaton.org/service-providers](https://operaton.org/service-providers/)) · C in-house.
- Default: **B** (or a staffed C) for business-critical processes; with A budget two minor upgrades a year
  (April, October) and a monthly patch slot.
- Consequence: no LTS, security fixes only for the latest line, no SLA from the project.

**D15 · Rollback and point of no return** (mandatory before the cut-over) — details in references/cutover.md
- Ask: How long must a rollback to Camunda 7.24 stay possible (time cap), and who decides rollback vs. fix forward?
- Options: A time window only · B event-based PoNR · C events + time cap · D no rollback.
- Default: **C**, e.g. 72 h, one named decision owner, deployment freeze until the window closes, rollback rehearsed once.
- Consequence: hard stops = first `operaton:` deployment with instances; versions referencing `org.operaton.*` with
  instances before that step; `operaton-forms:` versions with open tasks; Java-serialized `org.operaton.*` variables.

**D16 · Webapps** (inform)
- Options: A classic Cockpit/Tasklist/Admin · B webapps-neo (2.2 technical preview) · C third-party plugins · D headless.
- Default: **A**; evaluate B separately after its GA.
- Consequence: webapps-neo renders no embedded HTML forms (only form-js via `formRef` and generated forms) and has its
  own setup screen, also gated on `operaton-admin`.

**D17 · Camunda EE features** (mandatory for every EE source, which includes everyone on Spring Boot 4; stop condition without a plan)
- Ask: Which EE Cockpit features do operators use in incidents (history view/heatmap, instance modification UI, batch
  UI, restart, reports, cleanup page, auditing, search)? Do you use Optimize? Do your stored Tasklist filters use
  expressions such as `${currentUser()}`? Did you opt into the Jackson 3 artifacts (`-jackson3`, 7.24.16-ee)?
- Options: A inventory and plan replacements · B accept the loss · C keep those apps on Camunda 7 EE.
- Default: **A** before go-live, with these parts:
  - **EE webapp features:** inventory and test a replacement for each; Operaton has the CE webapps only.
  - **Optimize:** EE, not supported by Operaton: plan a replacement.
  - **License:** remove license files, mounts and secrets (the recipe deletes `camunda.bpm.license-file`); keep the
    license stored in the database (`ACT_GE_BYTEARRAY` resource `camunda-license-key`, `ACT_GE_PROPERTY`
    `camunda-license-key-id`): Operaton ignores it, a rollback to Camunda EE needs it.
  - **EE repository and credentials:** needed while the recipe runs (Maven resolves all dependencies first), then
    remove the repository, its credentials and CI secrets from the Operaton build; the build resolves from Maven
    Central. Revoke the credentials only after the rollback window closes (the Camunda rollback build needs them).
  - **Jackson 3 opt-in:** Operaton 2.x Spin, REST and external task client are Jackson 2 only (no `-jackson3`
    artifacts): the recipe maps the artifacts back; rewrite `tools.jackson.*` code there to `com.fasterxml.jackson.*`.
  - **EE hardening Operaton lacks:** the query-API expression allow-list (7.24.7-ee): default
    `enable-expressions-in-stored-queries: false` (generic property) when P11 of the pre-flight finds no filters with
    expressions; otherwise rewrite those filters, or keep expressions on and restrict who may create/update filters.
    Keep ad-hoc query expressions off. `validateAuthResourceIdExists` (7.24.3-ee): validate user and group ids in the
    code that creates authorizations. Datasource autocommit check (7.24.3-ee): keep
    `spring.datasource.hikari.auto-commit: false`. Details: references/identity-and-admin.md §10.
- Consequence: the recipe maps `-ee` artifacts to CE silently, so EE Cockpit features disappear without a build error.
  Engine API/REST for modification, restart, batch, migration and history cleanup stay available. EE-only engine
  settings left as generic properties **fail the Operaton start**, Java calls to them do not compile, and
  `operaton.bpm.authorization.validate-auth-resource-id-exists` is ignored silently. With the Operaton defaults, stored
  filters evaluate any expression (`enableExpressionsInStoredQueries` defaults to true): the behaviour of Camunda
  before 7.24.7 (Camunda security notice 157).

**D18 · Variables with `org.camunda.*` objects** (mandatory before the cut-over)
- Ask: Can a DBA run `20-find-legacy-references.sql` on a production copy? For hits: convert or drain?
- Options: 1 detect + convert on Camunda 7.24 (read via API, set again as JSON/primitives/own DTO) · 2 detect + drain ·
  3 rewrite serialized bytes (never) · 4 history rows: accept or clean up via API.
- Default: detect, then **1 or 2** before the cut-over.
- Consequence: Operaton cannot deserialize `org.camunda.*` engine classes (`ClassNotFoundException`); no compatibility
  layer exists. Your own classes (`com.example…`) are unaffected.

## 3. Batched interview block (copy, fill, send)

Fill the `<…>` from the assessment, delete lines whose trigger is absent, and send it as one message.

```text
The read-only assessment is in MIGRATION_REPORT.md. Before I change code I need these decisions.
Reply "defaults" to accept every recommendation, or answer only the numbers you want to change.

Needed now
1. D1 Target: <Spring Boot 4 path: Camunda 7.24.N-ee on Spring Boot <4.0|4.1> -> Operaton <2.1.5|2.2.x> in one
   recipe run, one cut-over<; Spring Boot 4.1: rehearse with 2.2.0-RC1 until 2.2.0 is GA (2026-10-23)> |
   Spring Boot 3.5 path: two code hops (Camunda 7.24 -> Operaton 1.1.x checkpoint -> Operaton 2.x on Spring Boot 4),
   one production cut-over to the latest 2.x patch (<version, see versions>); one hop instead?>
   [default: <Spring Boot 4 path, target from assess | two hops>]
2. D3 Keep the camunda: namespace in BPMN/DMN for now (no new versions, rollback stays possible). <n> scripts import
   org.camunda.*: fix them package-free in a pre-migration release on Camunda 7.24 (rollback-safe), or rename to
   org.operaton.* (Operaton-only, blocks rollback once instances use them)? [default: keep camunda:, package-free]
3. D4 <n> user tasks use camunda-forms: keys<, and the webapp starter is on the classpath>. Who renders them: your own
   UI (keep) or the Operaton Tasklist (switch to formRef in the same pre-migration release)? [default: <A or C from evidence>]
4. D5 Identity: <DB identity | LDAP | Keycloak | OAuth2>. Operaton's admin group is operaton-admin; nobody is in it on
   your database, so the webapp setup page would let anyone create an admin. Plan: SQL script in the runbook + startup
   plugin in the app + block <app-path>/api/admin/setup/* at the ingress. [default: SQL + plugin + block]
5. D6 Keep the webapps at /camunda for the cut-over (explicit property), move to /operaton later? [default: keep]
6. D8 The engine schema is managed by <Liquibase | Flyway>: set schema-update false and apply the documented
   <Liquibase fix | Operaton SQL scripts>, with a reverse step for rollback? [default: yes]
7. D9 <n> history/event exporters found (<classes>). Who consumes them, do they parse Java class names, and is
   at-most-once OK? [default: outbox for business streams, after-commit DTO for observability; payload stays
   compatible (adds schemaVersion + entityType, eventClass keeps the Camunda value) until each consumer signs off]
8. D17 Camunda EE found (<evidence: 7.24.N-ee, -4 starters, -webapp-ee, -jackson3, license, EE repository>). I need EE
   repository access for the recipe run (your settings file, never in the repository) and remove it afterwards.
   Which EE Cockpit features do operators use, is Optimize in use? <n> stored filters use expressions (P11, if known):
   switch stored-query expressions off, or keep them and restrict filter editing? EE-only settings (<list>) are removed
   because Operaton fails to start with them. [default: inventory + replace; expressions off if no filter needs them;
   tools.jackson code rewritten to Jackson 2]
9. Commits: may I commit each step locally on the migration branch (nothing is pushed)? Without it I work in a
   throw-away clone and hand back uncommitted changes. [default: yes, local commits]

Needed before the cut-over (answer now if you know)
10. D7 Is a maintenance window possible (stop all Camunda nodes, then start Operaton on the same DB)?
    Which other services share this engine database? [default: big bang, rehearsed twice]
11. D15 How long must rollback to Camunda 7.24 stay possible, and who decides? [default: 72 h, named owner]
12. D13 Which endpoints do your liveness/readiness probes call? [default: processEngine in readiness only]
13. D14 Support: community only, a provider, or in-house? [decide before go-live]
14. D18 Can a DBA run 20-find-legacy-references.sql on a production copy? Hits: convert or drain? [default: detect, then decide]

Defaults I will apply unless you object: D2 starter-pack recipes via migrate.sh (path detected), dry run first · D10 replace SQL on ACT_* tables
with API calls, keep emergency SQL only · D11 Operaton test starter + operaton.cfg.xml · D12 Camunda Modeler stays ·
D16 classic webapps.
```

## 4. Recording the answers

- Write every decision into the report's decision table (columns ID, Decision, Choice, Rationale, Owner, Gate, Status;
  the template has a row for each of D1–D18). Status: `open` → `accepted` (or `accepted (default)`; without a human to
  ask `accepted (default, assumed)`), `rejected`, `n/a` with a reason (e.g. "D8 n/a: engine manages the schema, no
  Liquibase"; "D17 n/a: Camunda CE 7.24.0, no EE artifact, license or EE repository").
- Rationale = the user's reason or "recommended default". Owner = a named person if the user gives one.
- Deviations from a default: one line on the accepted risk, plus a MUST item in "Open items" if it touches D5, D7,
  D15, D17 or D18.
- For humans who keep a separate decision log, point to the template:
  [checklists/decision-log-template.md](https://github.com/Miragon/migration-recipies/blob/main/services/c7/checklists/decision-log-template.md)
  (it contains a fully worked D5 entry).
- Re-check decisions at each mode switch (`migrate` → `cutover`; Spring Boot 3.5 path: `migrate` → `hop2` → `cutover`).
  A runbook stub with placeholders is fine at any time; the tailored runbook must not leave DRAFT while D5, D7, D8, D15,
  D17 (EE sources) or D18 is still open.
