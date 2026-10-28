# Models and scripts: BPMN, DMN, CMMN, forms, script engines, EL, FEEL

Load this when the project has `.bpmn`/`.dmn`/`.cmmn`/`.form` files, script code (inline or external), custom EL
code, or when `assess.sh` reports model findings. Guide chapter:
https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/05-bpmn-dmn-forms-and-scripts.md

## Contents

1. Ground rules
2. Find everything
3. Namespace policy (D3)
4. Scripts that reference `org.camunda.*`: fix them package-free
5. In-flight instances on old definition versions
6. Form keys (D4)
7. Script engines (Groovy, GraalJS)
8. Expression language (JUEL) and custom EL code
9. FEEL and DMN
10. CMMN and connectors
11. History time to live and redeployment
12. Done criteria

## 1. Ground rules

- The official recipe never opens `.bpmn`, `.dmn`, `.cmmn` or `.form`. Only `starterpack.operaton.ScriptImports` (part of
  every Camunda → Operaton run: `MigrateSpringBoot4App`, or Hop 1 on the Spring Boot 3.5 path) and the optional
  `starterpack.operaton.FormKeys` (`migrate.sh --with-form-keys`) change models.
- **Every byte change in a model is a new definition version** on the next deployment. With the default
  `deployChangedOnly=false`, one changed file redeploys *all* resources of that deployment: every process/decision gets a
  new version, timer start jobs are recreated with a schedule recomputed from the deploy time, message/signal start
  subscriptions move to the new version. Running instances stay on their version.
- Old versions are re-parsed from `ACT_GE_BYTEARRAY`. **A fix in the repository never reaches deployed versions.**
- Never rename `org.camunda.feel`; never run a blanket `sed s/org.camunda/org.operaton/`. Never hand-edit modeler
  metadata (`exporter`, `exporterVersion`, `modeler:executionPlatform*`, `.form` `executionPlatform`): ignored by the
  engine, editing it only creates versions. List every model change in the report with its consequence.

## 2. Find everything

Run from the project root. Hits 1 and 6 are decisions, all others are work items.

```bash
# 1) camunda: extension namespace (decision D3, not an error)
grep -rIlE 'camunda\.org/schema/1\.0/(bpmn|dmn|cmmn)' --include='*.bpmn' --include='*.bpmn20.xml' --include='*.dmn' --include='*.cmmn' .
# 2) Activiti namespace -> MUST convert (parse error on Operaton)
grep -rIn 'activiti\.org/bpmn' --include='*.bpmn' --include='*.bpmn20.xml' --include='*.xml' .
# 3) org.camunda.* in models and script/template resources (org.camunda.feel is fine)
grep -rInE 'org\.camunda\.(bpm|spin|connect|commons|templateengines)\b' --include='*.bpmn' --include='*.bpmn20.xml' \
  --include='*.dmn' --include='*.cmmn' --include='*.groovy' --include='*.js' --include='*.py' --include='*.rb' --include='*.ftl' --include='*.html' src
# 4) GraalJS / Nashorn / Rhino-isms
grep -rInE "Java\.type\(['\"]org\.camunda|importPackage|importClass|JavaImporter|load\(['\"]nashorn:" src
# 5) class names in model attributes
grep -rInE '(class|formHandlerClass|variableMappingClass|config)="org\.camunda\.' --include='*.bpmn' --include='*.cmmn' src
# 6) Camunda Forms key prefix (decision D4)
grep -rIn 'camunda-forms:' src
# 7) Java code reading the Camunda namespace URI raw (no fallback after the recipe)
grep -rInE 'camunda\.org/schema/1\.0/(bpmn|dmn|cmmn)|getAttributeValueNs\(|attributeNS\(' --include='*.java' --include='*.kt' src
# 8) Camunda's shaded EL API
grep -rIn 'org\.camunda\.bpm\.impl\.juel\.jakarta\.el' src
# 9) files that mix both namespaces / 10) models without a TTL (section 11)
for f in $(grep -rlE 'xmlns:camunda=' --include='*.bpmn' --include='*.dmn' --include='*.cmmn' src); do grep -q 'xmlns:operaton=' "$f" && echo "MIXED: $f"; done
grep -rL 'historyTimeToLive' --include='*.bpmn' --include='*.dmn' --include='*.cmmn' src
```

Script code hides in script tasks, `<camunda:script>` in listeners and I/O parameters, scripted
`conditionExpression`s, external resources (`camunda:resource`, `resource="…"`), scripted DMN expressions, CMMN listeners, templates.

## 3. Namespace policy (D3)

Default (D3 option A): **keep `camunda:`**. Operaton reads `http://camunda.org/schema/1.0/{bpmn,dmn,cmmn}` as a fallback of
`http://operaton.org/schema/1.0/{bpmn,dmn,cmmn}`. Converting creates new versions of every model, resets timer start
schedules, breaks editing in Camunda Desktop Modeler, and the first `operaton:` deployment with instances is a rollback
hard stop (D15).

- **MUST:** convert `http://activiti.org/bpmn` to the Camunda URI. Operaton no longer accepts the Activiti namespace.
- **Never mix namespaces in one file.** If an element has `camunda:executionListener` *and* `operaton:executionListener`,
  only the `operaton:` ones run (the `camunda:` ones are silently ignored). A duplicated attribute: the `operaton:` value wins.
- Tools that create mixed files: Model API code that *adds* an attribute (written as `operaton:`), Camunda Modeler editing
  an `operaton:` file, the Operaton Modeler's "Unsupported BPMN file detected → Yes" (converts the whole file). Do not
  open production models in the Operaton Modeler.
- Convert only if the user chose D3 option B/C, after the rollback window, one deployment unit at a time, whole files,
  never single attributes. Fix mixed files by hand first. Tooling and verification: chapter 05,
  [Converting namespaces safely](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/05-bpmn-dmn-forms-and-scripts.md#converting-namespaces-safely).
  Do not replace: `org.camunda.feel.*`, `connectorId` values, form-key prefixes `embedded:`/`app:`/`deployment:`, group ids
  like `camunda-admin`, OMG prefixes, the DMN `definitions/@namespace` attribute.
- **Model API trap:** the recipe rewrites `BpmnModelConstants.CAMUNDA_NS` → `OPERATON_NS`. Raw lookups such as
  `getAttributeValueNs(BpmnModelConstants.CAMUNDA_NS, "x")` then return `null` for every `camunda:` model, without error.
  Use typed accessors (`getOperatonX()` read `camunda:` values too), or read `OPERATON_NS` first and fall back to the
  literal `"http://camunda.org/schema/1.0/bpmn"`.

## 4. Scripts that reference `org.camunda.*`: fix them package-free

They deploy fine and fail when a token reaches them (scripts compile lazily):

| Script code | Runtime error |
|---|---|
| Groovy `import org.camunda.spin.Spin` | `ScriptCompilationException … unable to resolve class org.camunda.spin.Spin` |
| Groovy `org.camunda.bpm.engine.variable.Variables…` (fully qualified) | `MissingPropertyException: No such property: org` |
| JS `Java.type('org.camunda.spin.Spin')` | `TypeError: Access to host class org.camunda.spin.Spin is not allowed or does not exist` |
| JS `importPackage(...)` / `importClass(...)` | fails, even with `enableScriptEngineNashornCompatibility=true` → use `Java.type` |

With an async continuation the job fails and becomes an incident; without one the caller's transaction rolls back.
**Fix order:** (1) preferred: **package-free code** that runs on Camunda 7.24 *and* Operaton, done in the pre-migration
release on the unchanged Camunda 7.24 code (SKILL step 3b: edit models and tests, `mvn -B verify` on 7.24, separate
commit), deployed before the cut-over with instances migrated there (section 5), which keeps the rollback open. The
recipe's `ScriptImports` then finds nothing. (2) Only where an engine class is unavoidable and the user accepted it (D3):
`org.operaton.*` (what `ScriptImports` produces), shipped only with the Operaton release, a D15 hard stop.

**Only `S` is pre-bound in scripts** (Groovy, JavaScript, Python, Ruby; Camunda 7.24 and Operaton alike). `JSON()` and
`XML()` are **not** script bindings (they exist only as JUEL functions in `${…}`): Groovy `JSON('{}')` →
`MissingMethodException`, JS `JSON('{}')` → `TypeError … is not a function`, `XML('<a/>')` → `ReferenceError`.
`S` needs the Spin plugin (`org.operaton.bpm:operaton-engine-plugin-spin`; the starter registers `spinProcessEnginePlugin`
when it is on the classpath). XML also needs `org.operaton.spin:operaton-spin-dataformat-xml-dom` (or `-all`).

| Camunda-only script code | Package-free replacement |
|---|---|
| `Spin.JSON(x)` after `import org.camunda.spin.Spin` | `S(x, 'application/json')` (string parsed; map/list/object mapped with Jackson, `null` kept) |
| `Spin.XML(x)` | `S(x, 'application/xml')` or `S(xmlString)` |
| `JSON(x)` / `XML(x)` in a script | `S(x, 'application/json')` / `S(x, 'application/xml')` |
| JS `Java.type('org.camunda.spin.Spin').JSON(obj)` | `S(JSON.stringify(obj))` (`JSON` = native JS object) |
| `org.camunda.bpm.engine.variable.Variables.*` | often unnecessary: `execution.setVariable('x', plainValue)`. No package-free way to name an engine class |

```groovy
// before (Camunda-only)
import org.camunda.spin.Spin
def summary = Spin.JSON([orderId: orderId, amount: amount, discount: discount, approvalRequired: amount > 1000])
execution.setVariable('orderSummary', summary)

// after (runs on Camunda 7.24 AND Operaton)
def summary = S([orderId: orderId, amount: amount, discount: discount, approvalRequired: amount > 1000], 'application/json')
execution.setVariable('orderSummary', summary)
```

Traps: `S('{}').prop(name, null)` fails in Groovy (`Ambiguous method overloading … JacksonJsonNode#prop`): guard nulls or use
the map form above. `groovy.json.JsonOutput` needs `org.apache.groovy:groovy-json` (not in `groovy-jsr223`); without it you
get `No such property: groovy`.

Other model fixes:
- Model attributes (`camunda:class`, `formHandlerClass`, `variableMappingClass`, validator `config`) naming `org.camunda.*`
  classes → `org.operaton.*` (map: `org.camunda.{bpm,spin,connect,commons}` → `org.operaton.…`; keep `org.camunda.feel`).
- External scripts: `classpath://…` (or no scheme) loads from the current classpath, so a repo fix reaches all versions
  after restart; `deployment://…` loads from the definition's deployment, so old versions keep the broken copy.
- `ScriptImports` also rewrites comments; review the diff. Add the model lint test (references/testing.md).

## 5. In-flight instances on old definition versions

Every instance on an old version that has not passed the broken script **will fail on Operaton**, even after the repo fix
(observed in the guide's trial). Same for `camunda:class="org.camunda…"` and `activiti:` in old versions.

**Step 1, detect** (human runs it on a production copy; never run it yourself against a real DB):
`assets/sql/postgresql/20-find-legacy-references.sql`, sections L3 (deployed resources referencing renamed classes),
L4 (affected definitions with running instances, jobs, tasks, incidents), L5 (Activiti), L6 (`camunda-forms:` keys),
L7 (decision/case definitions). REST alternative for any database: the loop in references/testing.md.

**Step 2, choose a remediation per definition version** and record it in the report:

| Option | When | How |
|---|---|---|
| **A. Fix and migrate on Camunda 7.24 before the cut-over** (recommended) | Script can be written package-free | Deploy the fixed version on C7.24, migrate instances of old versions there, re-run the detection SQL until no running instances remain |
| B. Migrate on Operaton right after the cut-over | Fix needs `org.operaton.*` | Deploy with the Operaton release, migrate (code below), set retries on failed jobs. Operaton-only (D15) |
| C. Drain | Short-lived processes | Stop starting new instances on affected versions; let running ones finish on Camunda |
| D. Process instance modification | A handful that cannot be migrated | Cancel the script activity, start the next one with the variables the script would have set |

**Step 3, migrate with the Migration API** (identical on Camunda 7.24 for option A; fixed version keeps activity ids):

```java
Batch migrateToLatest(ProcessEngine engine, String key, int fromVersion) {
  RepositoryService repo = engine.getRepositoryService();
  RuntimeService runtime = engine.getRuntimeService();
  String source = repo.createProcessDefinitionQuery()
      .processDefinitionKey(key).processDefinitionVersion(fromVersion).singleResult().getId();
  String target = repo.createProcessDefinitionQuery()
      .processDefinitionKey(key).latestVersion().singleResult().getId();
  MigrationPlan plan = runtime.createMigrationPlan(source, target)
      .mapEqualActivities()
      .updateEventTriggers()
      .build();                                   // validates the plan
  return runtime.newMigration(plan)
      .processInstanceQuery(runtime.createProcessInstanceQuery().processDefinitionId(source))
      .executeAsync();                            // execute() is @Deprecated in Operaton ("only in tests")
}
```

- The batch runs in the job executor (watch: `managementService.createBatchStatisticsQuery()`, `GET /engine-rest/batch/statistics`).
  REST: `POST /engine-rest/migration/generate`, then `POST /engine-rest/migration/executeAsync`. With authorization:
  `MIGRATE_INSTANCE` on both definitions, `CREATE` or `CREATE_BATCH_MIGRATE_PROCESS_INSTANCES` on `BATCH`.
- **Failed jobs move with their incident and keep `retries = 0`.** After migrating, retry per job
  (`managementService.setJobRetries(jobId, 1)`) or as a batch (`setJobRetriesAsync` / `setJobRetriesByJobsAsync`).
  Do not use `setJobRetriesByJobDefinitionId` for this: it leaves the `failedJob` incidents open until each job succeeds.
  `assets/snippets/IncidentRecoveryService.java` wraps both (`retryJob`, `retryFailedJobsAsync`).
- Test the plan on a production copy first. Last resort only if the user asks (thousands of instances, no time): a
  custom `ScriptFactory` bridge, internal API, inline scripts only, time-boxed, never the fix (not in the guide; write it
  only on explicit request and mark it as a migration helper).

## 6. Form keys (D4)

The engine resolves `camunda-forms:` and `operaton-forms:`; according to the source the **Operaton Tasklist only recognizes
`operaton-forms:`** (a `camunda-forms:` task falls through to "external form"). REST `GET /task/{id}/deployed-form`
works with both. Evidence rule for D4: webapp starter on the classpath plus `camunda-forms:` keys → assume the Tasklist
renders them → option C, unless the user says otherwise (references/decisions.md).

| Option | Change | Consequence |
|---|---|---|
| A. Keep `camunda-forms:` | none | OK only if no human opens these tasks in the Operaton Tasklist |
| B. `operaton-forms:` | `migrate.sh --with-form-keys` (`starterpack.operaton.FormKeys`) | Operaton-only; versions with open tasks are a **D15 hard stop**. Deploy only with the Operaton release |
| **C. `formRef`** (recommended when Tasklist renders the form) | manual edit in the pre-migration release (SKILL step 3b) | Works on Camunda 7.24 (deploy and migrate before the cut-over), rollback-safe, only form-js variant webapps-neo renders |

```xml
<!-- legacy -->
<bpmn:userTask id="Task_ApproveOrder" camunda:formKey="camunda-forms:deployment:approve-order.form" camunda:candidateGroups="order-ops" />
<!-- B -->
<bpmn:userTask id="Task_ApproveOrder" camunda:formKey="operaton-forms:deployment:approve-order.form" camunda:candidateGroups="order-ops" />
<!-- C: formRef = the "id" inside approve-order.form; attributes stay in the file's namespace (D3) -->
<bpmn:userTask id="Task_ApproveOrder" camunda:formRef="approve-order" camunda:formRefBinding="latest" camunda:candidateGroups="order-ops" />
```

After B or C: migrate instances whose open tasks use the form (section 5); update test assertions such as
`.hasFormKey("camunda-forms:…")` (the recipe never touches Java literals); verify one task per form in the Tasklist on staging.

Other form facts:
- REST field `camundaFormRef` → `operatonFormRef` (no alias): custom task UIs and generated clients must read the new field.
- `.form` deployment: process application `<property name="additionalResourceSuffixes">form</property>`; starter
  auto-deployment: `operaton.bpm.deployment-resource-pattern` = the defaults (`classpath*:**/*.bpmn`, `*.bpmn20.xml`,
  `*.dmn`, `*.dmn11.xml`, `*.cmmn`, `*.cmmn10.xml`, `*.cmmn11.xml`) plus `classpath*:**/*.form`.
- Generic property `disableStrictCamundaFormParsing` → `disableStrictOperatonFormParsing` (old key fails startup).
- Fat jar + `@EnableProcessApplication` + `java -jar`: `…:deployment:x.form` does not resolve (also on C7); run the
  extracted layout (`java -Djarmode=tools -jar app.jar extract`) or use `formRef`. Embedded HTML forms: check hard-coded
  `/camunda/app/…`, `/camunda/api/…` URLs (D6).

## 7. Script engines (Groovy, GraalJS)

Neither the starter nor `operaton-bom` ships a script engine. Missing engine → `Can't find scripting engine for 'javascript'`
(or `'groovy'`) at runtime.

- **Groovy:** declare `org.apache.groovy:groovy-jsr223` **without a version** (Spring Boot manages it: Groovy 4 on Spring Boot
  3.5, **Groovy 5 on Spring Boot 4**: Spring Boot 4 sources already run Groovy 5, the Spring Boot 3.5 path upgrades it
  in Hop 2). Replace `org.codehaus.groovy:*` with `org.apache.groovy:*`.
  Add `groovy-json`/`groovy-xml` if scripts use `JsonOutput`/`XmlSlurper`.
- **GraalJS:** managed by neither Spring Boot nor `operaton-bom`: **pin it** to the version the target Operaton release
  is tested with (table in references/versions.md, read from Operaton's `parent/pom.xml` at the release tag). Camunda 7.24
  was tested with GraalJS 21.3, Operaton with GraalJS 25.

```xml
<dependency><groupId>org.graalvm.polyglot</groupId><artifactId>polyglot</artifactId><version>${graaljs.version}</version></dependency>
<dependency><groupId>org.graalvm.polyglot</groupId><artifactId>js</artifactId><version>${graaljs.version}</version><type>pom</type></dependency>
<dependency><groupId>org.graalvm.js</groupId><artifactId>js-scriptengine</artifactId><version>${graaljs.version}</version></dependency>
```

- **Nashorn** is not shipped and not supported. Rewrite `importPackage`/`importClass` to `Java.type`.
- Engine settings (`script-engine-name-java-script`, `enable-script-engine-caching`, `configure-script-engine-host-access`,
  …; defaults equal C7.24) are generic properties under `operaton.bpm.generic-properties.properties`. A leftover
  `camunda.bpm.generic-properties` block is silently ignored.
- **Every script task, scripted listener and scripted condition must be executed by a test**, after the migration
  (Spring Boot 3.5 path: on each hop; major engine versions change semantics).

## 8. Expression language (JUEL) and custom EL code

- `${…}`/`#{…}` expressions and built-in JUEL functions (`now()`, `currentUser()`, Spin's `S()`/`JSON()`/`XML()`) are unchanged.
- Custom `ELResolver`/`FunctionMapper`/`ExpressionManager` code: Camunda's shaded `org.camunda.bpm.impl.juel.jakarta.el.*`
  becomes plain `jakarta.el.*`. The official recipe maps it to `org.operaton.bpm.impl.juel.jakarta.el`, which does not
  exist (`package … does not exist`). `starterpack.operaton.PreFixes` fixes it; without the composite, change the imports by hand.
- **Operaton 2.x** (Jakarta EL 6.0; Spring Boot 3.5 path: Hop 2) removed `ELResolver#getFeatureDescriptors`. Delete such
  `@Override`s (compile error "method does not override or implement a method from a supertype"). No recipe does it.

## 9. FEEL and DMN

- FEEL is still `org.camunda.feel:feel-engine`. Keep `org.camunda.feel.*` imports (e.g. `CustomValueMapper`), their
  `META-INF/services/org.camunda.feel.*` files and the `org.camunda.feel` logger. Engine-side wrappers are renamed
  (`org.operaton.bpm.dmn.feel.impl.scala.function.FeelCustomFunctionProvider`, property `dmnFeelCustomFunctionProviders`).
- A Maven warning `Could not transfer metadata … camunda-nexus … 401` comes from feel-engine's parent POM. Harmless.
- **The migration to Operaton 2.x crosses feel-scala 1.20** (Camunda 7.24.0 ships feel-engine 1.19.3, Operaton 2.1.5
  1.21.1; check what your EE patch resolves with `mvn dependency:tree -Dincludes=org.camunda.feel`. Spring Boot 3.5 path:
  in Hop 2. Unary tests return `null` instead of `false`, `?` semantics, list functions with position 0, normalized
  durations). Before the migration, record a golden-master test per decision table, including null and missing inputs
  (pattern in references/testing.md), and keep it green afterwards.
- DMN 1.1–1.5 files are read as DMN 1.3. `camunda:historyTimeToLive`, `camunda:versionTag`, `camunda:inputVariable` work
  through the DMN fallback. Business-rule-task result mappings store plain `java.util` values.
- FEEL in BPMN works as a script language (`language="feel"`, `scriptFormat="feel"`), not as `${}`.

## 10. CMMN and connectors

- **CMMN** works and is enabled, but the 2.x REST OpenAPI marks it deprecated ("scheduled for removal in a future major").
  Keep existing cases running, start no new CMMN work, add "replace CMMN with BPMN" to the report's open items.
- **Connectors:** `<camunda:connector>` and `connectorId` values (`http-connector`, `soap-http-connector`) are unchanged.
  Add `org.operaton.bpm:operaton-engine-plugin-connect` + `org.operaton.connect:operaton-connect-http-client` (or
  `-soap-http-client`); without the plugin: parse error "… make sure the connect process engine plugin is registered …".

## 11. History time to live and redeployment

`enforceHistoryTimeToLive` is `true` and checked for **new** deployments only. An old model without TTL that is redeployed
now (script fix, form key, re-save, or any other changed file in the same deployment with `deployChangedOnly=false`) fails
the **application start** with `ENGINE-12018 History Time To Live (TTL) cannot be null`.

Fix both, never disable enforcement: the attribute per model, in the namespace the file already uses
(`<bpmn:process … camunda:historyTimeToLive="180">`; never add `operaton:` to a `camunda:` file), and the global safety net
`operaton.bpm.generic-properties.properties.history-time-to-live: P180D`.

Limiting redeployments: `isDeployChangedOnly=true` (process archive property in `processes.xml`) or generic property
`deploy-changed-only: true` (starter auto-deployment). **Before enabling it**, grep for `deployment:` and
`Binding="deployment"`/`deployment://`: deployment-scoped references break when only the referencing model is redeployed
(`NotFoundException: The form with the resource name '…' cannot be found in deployment …`). Switch them to
`latest`/`version` binding first, or keep the default.

## 12. Done criteria

- [ ] Grep pack run; every hit classified in the report (MUST work item or decision).
- [ ] No script references `org.camunda.(bpm|spin|connect|commons)`; package-free where possible; remaining
      `org.operaton.*` scripts and `operaton-forms:` keys listed as D15 hard stops.
- [ ] No `activiti:`, no mixed files, `camunda:` kept unless D3 says otherwise; D4 applied, form-key assertions updated.
- [ ] Script engines declared, every script executed by a test; custom EL on `jakarta.el.*`; DMN golden master green.
- [ ] Every model has a TTL plus the global default; detection SQL/REST prepared and remediation per affected version recorded.
