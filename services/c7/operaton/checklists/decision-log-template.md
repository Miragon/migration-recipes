# Decision log · Camunda 7 → Operaton migration

A migration involves 18 design decisions, from the target version to the rollback plan. This log records, for each
one, what you chose, who owns it and when it last changed. Copy this file into your service repository and fill it
in. The IDs match the [decision catalogue](../docs/01-migration-path-and-decisions.md#d1) in the chapter *Migration
path and decisions*, which gives the recommendation for each.

**How to fill it in**

- **Owner:** one named person per decision, not a role. **Date:** the last status change.
- **Status:** a decision starts as `Proposed` and becomes `Accepted` or `Rejected`. An accepted decision can later be
  `Superseded by Dx` or `Revisited`. Use `N/A` only with a reason.
- **When to decide:** record a choice for every decision in the *Decide and prepare* phase of the
  [migration checklist](migration-checklist.md). The six **mandatory** decisions must be made before the first start
  on real data, for example the first boot of the converted app on a production copy: admin group (D5), cut-over
  strategy (D7), schema management (D8), rollback (D15), Camunda EE features (D17) and legacy variables (D18).
  Skipping them causes a security hole, data problems, a failed start or a cut-over you cannot undo.
- **Camunda EE features (D17)** is mandatory for every team on Camunda EE, which includes everyone on Spring Boot 4,
  because Spring Boot 4 on Camunda 7.24 exists only in EE. It covers the EE webapp features, Optimize, the license,
  the EE repository and its credentials, the Jackson 3 opt-in and the EE security hardening that Operaton lacks. Only
  a team on Camunda 7.24.0 CE sets it to `N/A`, with the reason "CE".
- **Several services on one engine database:** keep one shared log for the admin group (D5), the cut-over strategy
  (D7), schema management (D8) and rollback (D15), because these services cut over together.
- **Review the log at every phase gate**, that is, before a service moves on to the next phase of the
  [migration checklist](migration-checklist.md). No **mandatory** decision may still be `Proposed` when the *Rehearse*
  phase starts, because the rehearsal runs the cut-over and the rollback as decided.
- **After the cut-over:** record in the rollback decision (D15) when the rollback window was closed. After the
  [clean-up](../docs/11-cutover-rollback-and-operations.md#hypercare-and-clean-up), note in the rows of the admin group
  (D5), webapp path (D6), cut-over strategy (D7) and rollback (D15) that their follow-up work is done. On EE, note in
  the Camunda EE features row (D17) when the license files and their secrets were deleted and the EE repository
  credentials were revoked.

## Decisions

Each row names the decision and the question it answers. Write your answer in *Our choice*; put longer reasoning in
an [ADR](#adr-template) below.

| ID | Decision | The question | Our choice | Owner | Date | Status |
|---|---|---|---|---|---|---|
| [D1](../docs/01-migration-path-and-decisions.md#d1) | Target version and path | Which Operaton version does production run, and which path does the code take to get there? | | | | Proposed |
| [D2](../docs/01-migration-path-and-decisions.md#d2) | Recipe toolchain | Which tool converts the code? | | | | Proposed |
| [D3](../docs/01-migration-path-and-decisions.md#d3) | BPMN/DMN namespace | Do models keep `camunda:` attributes, and when do they move to `operaton:`? | | | | Proposed |
| [D4](../docs/01-migration-path-and-decisions.md#d4) | Camunda Forms keys | How do user tasks reference Camunda Forms after the switch? | | | | Proposed |
| [D5](../docs/01-migration-path-and-decisions.md#d5) | Admin group **(mandatory)** | How do your admins become members of `operaton-admin`? | | | | Proposed |
| [D6](../docs/01-migration-path-and-decisions.md#d6) | Webapp path | Do Cockpit, Tasklist and Admin keep the `/camunda` URL? | | | | Proposed |
| [D7](../docs/01-migration-path-and-decisions.md#d7) | Cut-over strategy **(mandatory)** | How does production switch from Camunda to Operaton? | | | | Proposed |
| [D8](../docs/01-migration-path-and-decisions.md#d8) | Schema management **(mandatory)** | Who may change the schema, and what is checked before the first start? | | | | Proposed |
| [D9](../docs/01-migration-path-and-decisions.md#d9) | History exporters | How do exporters publish, and how do consumers read `org.operaton.*` class names? | | | | Proposed |
| [D10](../docs/01-migration-path-and-decisions.md#d10) | Direct database scripts | Which SQL scripts against `ACT_*` tables do you keep? | | | | Proposed |
| [D11](../docs/01-migration-path-and-decisions.md#d11) | Test stack | Which test libraries do the tests use on Operaton? | | | | Proposed |
| [D12](../docs/01-migration-path-and-decisions.md#d12) | Modeler | Which modeler do the teams use? | | | | Proposed |
| [D13](../docs/01-migration-path-and-decisions.md#d13) | Health probes | Which health checks go into liveness and readiness? | | | | Proposed |
| [D14](../docs/01-migration-path-and-decisions.md#d14) | Support model | Who supports Operaton for you: the community, a commercial provider or your own team? | | | | Proposed |
| [D15](../docs/01-migration-path-and-decisions.md#d15) | Rollback and point of no return **(mandatory)** | Until when can you go back, and who decides? | | | | Proposed |
| [D16](../docs/01-migration-path-and-decisions.md#d16) | Webapps | Classic webapps or webapps-neo? | | | | Proposed |
| [D17](../docs/01-migration-path-and-decisions.md#d17) | Camunda EE features **(mandatory for EE)** | Which Camunda EE features, settings and artifacts do you use, and what replaces each of them on Operaton? | | | | Proposed (`N/A` only on CE) |
| [D18](../docs/01-migration-path-and-decisions.md#d18) | Variables with `org.camunda.*` objects **(mandatory)** | What happens to stored variables that contain `org.camunda.*` objects? | | | | Proposed |

<a id="adr-template"></a>

## ADR template

Use an ADR (architecture decision record) for decisions that need more than a table row, for example when you deviate
from the recommendation or accept a risk. Copy the block below into the log and replace the placeholders.

```markdown
### Dx · <title>

Status: Proposed | Accepted | Superseded by Dx · Owner: <name> · Date: YYYY-MM-DD

**Context.** What is true today (assess.sh output, SQL results, versions) and why decide now.

**Decision.** We choose <option> because <reason>. Deviation from the recommendation: <none / what and why>.

**Consequences.** Accepted risks, follow-up work, how we verify it.

**Rollback impact (D15).** Does this create an Operaton-only artifact or a step to reverse on rollback?
```

<a id="worked-example-d5"></a>

## Example · D5 Admin group

A filled-in ADR for the admin-group decision, to show the level of detail that is useful.

Status: Accepted · Owner: security lead (illustrative)

**Context.** Users and groups live in the engine database (DB identity), and the admins are members of
`camunda-admin`. Operaton hard-codes `operaton-admin`, and nothing migrates the rows. So the webapps think this is a
fresh installation and reopen the unauthenticated setup page: `POST …/api/admin/setup/default/user/create` returns
204 and creates an admin.

**Decision.**

- Run `10-migrate-admin-group.sql` after the backup and before the first Operaton start.
- Ship `AdminGroupMigrationPlugin` as a safety net.
- Replace `camunda-admin` with `operaton-admin` in `groupResourceWhitelistPattern`; with the old value, every save of
  `operaton-admin` fails.
- Block `/camunda/api/admin/setup/*` at the ingress.

**Consequences.** Both groups coexist until the clean-up, so admin permission changes go into both. Verified by
`smoke-test.sh` (`admin setup page`: PASS).

**Rollback impact (D15).** None: the script only adds rows, and Camunda 7.24 ignores `operaton-admin`. Drop
`camunda-admin` after the rollback window closes.
