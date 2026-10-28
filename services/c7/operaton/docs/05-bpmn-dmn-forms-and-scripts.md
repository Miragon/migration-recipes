# 05 · BPMN, DMN, forms and scripts

This chapter covers the parts of your application that no compiler checks: BPMN and DMN models, the scripts inside
them, form keys, script engines and history time to live. Developers who own process models need it while the
application still runs on Camunda 7.24, and again during the code conversion. Whoever plans the cut-over needs the
section on [instances that run on old model versions](#in-flight-instances-on-old-definition-versions).

**In short**
- **Your models deploy without errors and break only at runtime.** The engine compiles a script the first time a
  token reaches it, not when you deploy the model. The official recipe (Operaton's automated OpenRewrite code
  conversion) never opens model files.
- **Script code that uses `org.camunda.(bpm|spin|connect|commons)` classes fails on Operaton when a token reaches
  it**, because Operaton renamed these packages to `org.operaton.*`. Rewrite such scripts package-free on Camunda
  7.24: a package-free script references no `org.camunda.*` or `org.operaton.*` class, only process variables and the
  pre-bound `S(...)` function, so it runs on both engines.
- **A fix in your repository does not reach running instances.** Every instance keeps the model version it started
  on, and the engine reloads that version from the database. Migrate the instances off the old versions before the
  cut-over (the production switch from Camunda to Operaton on the same database), or they fail on Operaton as soon as
  they reach the old script.
- **Keep the `camunda:` namespace**, because Operaton reads it as a fallback. Never mix `camunda:` and `operaton:` in
  one file: where an element carries both, Operaton silently ignores the `camunda:` ones. The old `activiti:`
  namespace is a parse error.
- **Every changed byte creates a new version.** A redeployment resets timer start schedules, and a redeployed model
  without `historyTimeToLive` stops the application start with `ENGINE-12018`.
- **Script engines are not shipped**, so you declare Groovy or GraalJS yourself. FEEL stays `org.camunda.feel`. The
  Operaton Tasklist does not render `camunda-forms:` keys (per the source; untested in a browser).

## What to do

1. **Find what must change in your repository.** Run [`scripts/assess.sh`](../scripts/assess.sh) and sort its model
   findings into the [triage table](#triage-what-in-your-models-must-change), so that you know which models to fix
   first.
2. **Find what must change in the database.** `assess.sh` only scans your source repository, but old model versions
   live in the database. Run
   [`sql/postgresql/20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql) on a production
   copy (a restored copy of the production database, never the live one). It shows which **deployed** versions
   contain `org.camunda.*` and how many instances run on them.
3. **Fix the scripts while you are still on Camunda 7.24.** Rewrite those scripts
   [package-free](#fix-it-in-the-repository), deploy them, and
   [migrate the running instances](#in-flight-instances-on-old-definition-versions) to the fixed version. Because the
   fixed scripts run on both engines, you keep the option to roll back.
4. **Let the recipe catch what you missed.** During the code conversion,
   [`scripts/migrate.sh`](../scripts/migrate.sh) runs this pack's recipe `starterpack.operaton.ScriptImports` as a
   safety net. Then [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh) must exit 0, which means it found
   no Camunda reference that must be fixed.
5. **Close the gaps that Operaton does not handle for you.** Set a history time to live
   ([TTL](#history-time-to-live)) in every model, because a redeployed model without one stops the start. Declare
   the [script engines](#script-engines), because Operaton ships none. Decide on [form keys](#forms), because the
   Operaton Tasklist does not render `camunda-forms:`.
6. **Make your tests run every script and pin your decision results.** Make sure tests execute every script task,
   scripted listener and condition, so that a broken script shows up as a red test instead of an incident in
   production. While you are still on Camunda 7.24, also pin DMN results in tests, because Operaton ships a newer
   [FEEL engine](#feel-and-dmn) than Camunda 7.24.0.

## Triage: what in your models must change

Use this table to decide what to fix. **MUST** means the model breaks a deployment, the application start or a
running instance if you skip the item. **SHOULD** means nothing fails loudly, but behaviour degrades silently, so
plan the item anyway. The last column links to the fix.

| Item | Severity | Action |
|---|---|---|
| `org.camunda.*` in script code (inline, listeners, I/O mappings, conditions, script files) | **MUST** | [Fix package-free](#fix-it-in-the-repository), handle [in-flight instances](#in-flight-instances-on-old-definition-versions) |
| `org.camunda.*` classes in `camunda:class`, `formHandlerClass`, `variableMappingClass` | **MUST** | Change to `org.operaton.*` |
| `http://activiti.org/bpmn` | **MUST** | Convert to `camunda:` |
| Redeployed models without `historyTimeToLive` | **MUST** | [Add a TTL](#history-time-to-live) |
| `camunda-forms:` keys | SHOULD | [Forms](#forms) |
| DMN decision tables | SHOULD (new FEEL version) | [Regression tests](#feel-and-dmn) |

## Namespaces

Engine-specific settings in your models, such as execution listeners, live in an XML namespace, normally
`camunda:`. Operaton has its own `operaton:` namespace but also reads `camunda:`, so the migration does not require
you to touch the namespace. The real risk is a file that contains both.

**Mixed files fail silently.** On one element, `operaton:` wins: an `operaton:executionListener` makes the engine
ignore the `camunda:` listeners on that element, and nothing reports an error. Mixed files come from three sources:
Camunda Modeler editing `operaton:` files, Model API code that adds attributes, and partial renames.

The **BPMN/DMN namespace decision** ([D3](01-migration-path-and-decisions.md#d3)) recommends keeping `camunda:` for
the migration and converting later, one deployment unit at a time. This is safe because Operaton tries
`http://operaton.org/schema/1.0/…` first and then falls back to `http://camunda.org/schema/1.0/…`, and the fallback
is not deprecated.

The **Modeler decision** ([D12](01-migration-path-and-decisions.md#d12)) recommends keeping the Camunda Desktop
Modeler. The Operaton Modeler (no released binaries) asks "Unsupported BPMN file detected" when it opens a
`camunda:` file. **Yes** converts the file, so click **Close File** instead.

### Redeployment: every changed byte is a new version

The migration touches model files, and every change creates new process definition versions with side effects.
Even a modeler re-save counts as a change. With the default `deployChangedOnly=false`, one changed file redeploys
**every** resource of its deployment. Then:

- Running instances stay on their version, which the engine re-parses from `ACT_GE_BYTEARRAY` (the table that holds
  deployed resources). **A fix in your repository does not reach them.**
- The engine recomputes timer start schedules from the deploy time, and message start subscriptions move to the new
  version.
- The first `operaton:` deployment that gets running instances is a rollback **hard stop**: Camunda 7.24 silently
  ignores `operaton:` attributes, so it cannot run those instances as modelled. After that point, a rollback means
  restoring the backup (see the decision on **rollback and point of no return**,
  [D15](01-migration-path-and-decisions.md#d15)).

Switching to `deployChangedOnly=true` is no easy way out. It breaks deployment-scoped references (`…:deployment:…`
form keys, `*Binding="deployment"`), because then only the referencing model is redeployed, without the resource it
points to. Such references fail with `The form with the resource name '…' cannot be found in deployment …`. Switch
them to `latest` or `version` binding first.

## Converting namespaces safely

Converting `camunda:` to `operaton:` is a clean-up step after the migration, not part of it. Do it only after the
rollback window has closed. This is the "convert later, per deployment unit" path (option C) of the
[BPMN/DMN namespace decision (D3)](01-migration-path-and-decisions.md#d3). The reason: Camunda 7.24 silently ignores
`operaton:` attributes, so the first converted deployment with running instances ends the option to roll back.

1. Convert one deployment unit per commit, together with its move to the Operaton Modeler.
2. Convert whole files only. Fix mixed files by hand first, because a blind rename creates duplicate attributes.
3. Check the TTLs and plan the deploy time for timer start events, because each converted file is a new version
   (see [Redeployment](#redeployment-every-changed-byte-is-a-new-version)).

This script does the rename:

```bash
#!/usr/bin/env bash
# convert-model-namespaces.sh: camunda: -> operaton: in BPMN/DMN/CMMN, in place. Commit first!
set -euo pipefail
for f in "$@"; do
  perl -0pi -e '
    s{xmlns:camunda="http://camunda\.org/schema/1\.0/(bpmn|dmn|cmmn)"}{xmlns:operaton="http://operaton.org/schema/1.0/$1"}g;
    s{(</?)camunda:([A-Za-z_])}{$1operaton:$2}g;
    s{(\s)camunda:([A-Za-z_][\w.-]*)(\s*=)}{$1operaton:$2$3}g;
  ' "$f"
done
```

It leaves values alone (`org.camunda.feel`, `camunda-forms:` keys, group ids, script bodies). Verify the result in
three ways: `grep -rnE '(<|</|\s)camunda:[A-Za-z]' src` finds nothing, `xmllint --noout` passes, and a test deploys
the whole unit.

## Scripts: deploy fine, fail at runtime

Deploying a model parses the XML, but the engine compiles script code only on its first execution. A script that
refers to a Camunda class therefore passes every deployment and fails only when a token reaches it, which can be
days later on a timer. The table shows the errors that typical Camunda-only script code produces on Operaton:

| Script code | Runtime error |
|---|---|
| Groovy `import org.camunda.spin.Spin` | `ScriptCompilationException: Unable to compile script: … unable to resolve class org.camunda.spin.Spin` |
| Groovy `org.camunda.bpm.engine.variable.Variables…` | `MissingPropertyException: No such property: org` |
| GraalJS `Java.type('org.camunda.spin.Spin')` | `TypeError: Access to host class org.camunda.spin.Spin is not allowed or does not exist` |

If the script runs behind an async continuation (as a job), the failure becomes an **incident**. Otherwise the API
call that moved the token fails with the exception. `assess.sh` and `verify-leftovers.sh` flag such scripts. This is
the core search they run:

```bash
grep -rInE 'org\.camunda\.(bpm|spin|connect|commons|templateengines)\b' --include='*.bpmn' \
  --include='*.dmn' --include='*.cmmn' --include='*.groovy' --include='*.js' --include='*.ftl' src
```

### Fix it in the repository

**Prefer package-free scripts.** They run on both engines, so you can deploy them on Camunda 7.24 before the
cut-over and keep the way back open. Replace Camunda-only calls as follows:

| Camunda-only | Package-free (both engines) |
|---|---|
| `Spin.JSON(x)`, or `JSON(x)` in a script | `S(x, 'application/json')` |
| `Spin.XML(x)`, or `XML(x)` in a script | `S(x, 'application/xml')` |
| JS `Java.type('org.camunda.spin.Spin').JSON(obj)` | `S(JSON.stringify(obj))` |
| `org.camunda.bpm.engine.variable.Variables.*` | `execution.setVariable('x', value)` with plain values |

```groovy
// before (Camunda-only)
import org.camunda.spin.Spin
def summary = Spin.JSON([orderId: orderId, amount: amount])
// after (Camunda 7.24 and Operaton)
def summary = S([orderId: orderId, amount: amount], 'application/json')
```

**Safety net for what you missed:** the recipe `starterpack.operaton.ScriptImports`
([`rewrite/rewrite.yml`](../rewrite/rewrite.yml), run by `migrate.sh` when it converts the Camunda code) rewrites
`org.camunda.(bpm|spin|connect|commons|templateengines).` to `org.operaton.$1.` in model, `.groovy`, `.js`, `.py`,
`.rb` and `.ftl` files. Search files with other extensions yourself with grep. Never run a blanket
`sed s/org.camunda/org.operaton/`: it breaks FEEL, which still lives in `org.camunda.feel`.

> [!WARNING]
> A deployed script with `org.operaton.*` is **Operaton-only**: it fails on Camunda 7.24. Deploy it only with the
> Operaton release. Once instances run on it, it is a rollback hard stop (see the
> [rollback decision, D15](01-migration-path-and-decisions.md#d15)): Camunda can no longer run those instances, so
> going back means restoring the backup.

**External script files** behave differently depending on where they are loaded from:
- `camunda:resource="classpath://…"` (or no scheme) loads the script from the application, so a fix in the
  repository also reaches old versions (untested).
- `deployment://…` loads the script from the old deployment, like an inline script, so old versions keep the old
  code.

## In-flight instances on old definition versions

Every instance runs on the model version it started with. Instances on an old version that have not yet passed the
broken script will fail on Operaton when they reach it, even after you fixed the repository. The same applies to
`org.camunda…` class attributes and to models in the `activiti:` namespace. Find and move these instances before the
cut-over.

**Detect** them on the Camunda 7.24 database with
[`20-find-legacy-references.sql`](../sql/postgresql/20-find-legacy-references.sql). The script is read-only. Its
sections L3–L7 list the affected definitions, their running instances, jobs and incidents.

**Remediate** each affected definition with one of these options:

- **A. Fix and migrate on Camunda 7.24 (recommended).** Use it when the script can be package-free. Deploy the fix
  and migrate the instances on Camunda 7.24 until the SQL shows no instances on the old version. This is
  rollback-safe, because both engines can run the fixed version.
- **B. Migrate on Operaton.** Use it when the fix needs `org.operaton.*`. Deploy the fix with the Operaton release,
  migrate the instances, then retry the failed jobs. This is a rollback hard stop.
- **C. Drain.** Use it for short-lived processes: let the instances finish on Camunda before the cut-over.
- **D. Instance modification.** Use it for a handful of instances: skip the script activity and set its variables
  by hand.

**Migrate** with the Migration API, which moves running instances to another version of their definition. It works
the same on Camunda 7.24 (REST: `POST /engine-rest/migration/executeAsync`). Keep the activity ids unchanged in the
fixed version, so that `mapEqualActivities()` maps everything:

```java
MigrationPlan plan = runtimeService.createMigrationPlan(sourceDefinitionId, targetDefinitionId)
    .mapEqualActivities().updateEventTriggers().build();
runtimeService.newMigration(plan)
    .processInstanceQuery(runtimeService.createProcessInstanceQuery().processDefinitionId(sourceDefinitionId))
    .executeAsync();   // a Batch; execute() is deprecated in Operaton
```

Jobs that already failed keep `retries = 0` and their incident. Retry them per job or as a batch (`setJobRetries`,
`setJobRetriesAsync`, both wrapped by
[`IncidentRecoveryService`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java)).
Do not use `setJobRetriesByJobDefinitionId`, because it leaves the incidents open. Test the migration plan on a
production copy first.

## Script engines

Neither the Operaton starter nor `operaton-bom` ships a script engine, so you must declare every engine your models
use. Without one you get `Can't find scripting engine for 'javascript'`.

- **Groovy:** declare `org.apache.groovy:groovy-jsr223` without a version and let Spring Boot manage it, because
  `operaton-bom` does not manage Groovy. On Spring Boot 4, which every Operaton 2.x application uses, you get
  **Groovy 5.0.x**. Camunda 7.24.0 used Groovy 4.0, so check which version your Camunda build resolves today with
  `mvn dependency:tree -Dincludes=org.apache.groovy`. If it is already 5.0.x, the Groovy version does not change.
  `groovy-json` is a separate artifact: without it, `JsonOutput` fails with
  `MissingPropertyException: No such property: groovy`.
- **GraalJS:** Camunda 7.24 used 21.3, Operaton 2.1.5 is tested with 25.0.4.1.1, and Operaton 2.2.0-RC1 with
  25.3.4.1. Nothing manages this version, so pin the one that matches your Operaton release (here for 2.1.5):
  ```xml
  <dependency><groupId>org.graalvm.polyglot</groupId><artifactId>polyglot</artifactId><version>25.0.4.1.1</version></dependency>
  <dependency><groupId>org.graalvm.polyglot</groupId><artifactId>js</artifactId><version>25.0.4.1.1</version><type>pom</type></dependency>
  <dependency><groupId>org.graalvm.js</groupId><artifactId>js-scriptengine</artifactId><version>25.0.4.1.1</version></dependency>
  ```
- **Nashorn** is unsupported. Rewrite `importPackage`/`importClass` to `Java.type`.
- Script engine settings (`script-engine-name-java-script`, …) belong under
  `operaton.bpm.generic-properties.properties`. A `camunda.bpm.*` block is silently ignored.

## Expression language (JUEL)

Expressions in your models (`${…}`) do not change. Custom `ELResolver`s need work: for them, the official recipe
produces the compile error `package org.operaton.bpm.impl.juel.jakarta.el does not exist`;
`starterpack.operaton.PreFixes` maps Camunda's shaded EL API to `jakarta.el` instead. **On Operaton 2.x**, delete
`ELResolver#getFeatureDescriptors` overrides, because Jakarta EL 6.0 (part of Jakarta EE 11) removed that method.
Otherwise the build fails with `method does not override or implement a method from a supertype`.

## FEEL and DMN

DMN itself does not change, but the FEEL engine version does. Pin your decision results in tests so that you notice
any difference.

- **FEEL stays `org.camunda.feel`**, including the `META-INF/services/org.camunda.feel.*` files. Operaton still uses
  the Camunda FEEL engine, so never rename it.
- **The FEEL engine version changes.** Camunda 7.24.0 ships feel-scala, the FEEL engine, in version 1.19. Operaton
  2.1 ships 1.21, and Operaton 2.2 ships 1.22 as an unshaded artifact (details:
  [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md)). The 1.20 changes affect unary tests (`null`
  instead of `false`, `?` semantics). To see the version your Camunda build uses, run
  `mvn dependency:tree -Dincludes=org.camunda.feel`. Pin decision results in tests while you are still on Camunda
  7.24, including null and missing inputs.
- DMN 1.1–1.5 and `camunda:` DMN extensions work unchanged.

## Forms

A user task's form key tells the Tasklist (or your own task UI) which form to show. Support changes for Camunda
Forms keys (`camunda-forms:`). The table shows which form references each UI renders; webapps-neo is the new
Operaton webapp (2.2 technical preview).

| Form key | Operaton Tasklist | Camunda 7.24 | webapps-neo |
|---|---|---|---|
| `embedded:`, `app:`, `deployment:` | yes | yes | no |
| `camunda-forms:` | **no** (shown as an external form) | yes | no |
| `operaton-forms:` | yes | **no** | no |
| `formRef` + `formRefBinding` | yes | yes | yes |

The engine resolves all four. The **Camunda Forms keys decision** ([D4](01-migration-path-and-decisions.md#d4))
depends on who renders the forms:
- **Users work in the Operaton Tasklist:** switch to `formRef`. It works on both engines, so it is rollback-safe.
- **You have your own task UI:** keep the key, and switch your client to the REST field `operatonFormRef` (see
  below).

Avoid `operaton-forms:` keys (`migrate.sh --with-form-keys`): Camunda 7.24 cannot render them, so they are a
rollback hard stop while tasks on such versions are open. Whichever key you choose, migrate the instances with open
tasks to the new version, then open one task per form on staging.

- `.form` files are only deployed with `additionalResourceSuffixes=form` in `processes.xml`, or with
  `classpath*:**/*.form` in `operaton.bpm.deployment-resource-pattern`. In that property, repeat the BPMN/DMN/CMMN
  defaults, because your value replaces them.
- `disableStrictCamundaFormParsing` is now `disableStrictOperatonFormParsing`. The old key **stops the start**.
- The REST field `camundaFormRef` is now `operatonFormRef`, with no alias.

## Connectors and CMMN

Connectors need two Operaton dependencies, and CMMN is on its way out:

- `camunda:connector` and the `connectorId`s are unchanged. Add `operaton-engine-plugin-connect` plus
  `operaton-connect-http-client`, or parsing fails with
  "… make sure the connect process engine plugin is registered …".
- CMMN still runs but is marked for removal. Start no new CMMN work.

## History time to live

Every model needs a history time to live (TTL), because the engine enforces it on every **new** deployment. This
hits migrated applications easily: an old model without TTL is redeployed as soon as it or another file in its
deployment changes (see [Redeployment](#redeployment-every-changed-byte-is-a-new-version)), and the application start
then fails with:

```
ENGINE-12018 History Time To Live (TTL) cannot be null.
```

Set `camunda:historyTimeToLive="180"` in each model (in the file's own namespace). Also set a global default,
`operaton.bpm.generic-properties.properties.history-time-to-live: P180D`.

## Watch out

- **Symptom:** `No signature of method … JSON()`, `… is not a function` or `XML is not defined`.
  **Cause:** only `S` is injected into scripts; `JSON()` and `XML()` exist only in JUEL expressions.
  **Fix:** use `S(x, 'application/json')`. If `S` itself is undefined, `operaton-engine-plugin-spin` is missing.
- **Symptom:** code that reads extension attributes gets `null`.
  **Cause:** the recipe turned `CAMUNDA_NS` into `OPERATON_NS` in raw `getAttributeValueNs` lookups, and these
  lookups have no fallback to `camunda:`.
  **Fix:** use the typed `getOperatonX()` accessors.
