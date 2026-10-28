# 06 · Engine plugins, history exporters and other extension points

This chapter covers code that hooks into the engine: process engine plugins, history exporters (handlers that
publish engine history events to other systems such as Kafka), job handlers, serializers and identity providers.
Developers who own such code need it during the code conversion. The teams that read the exported events (the
consumers) need the [consumer cut-over plan](#64-consumer-cut-over-plan) before the cut-over, the production switch
from Camunda to Operaton on the same database.

**In short**
- **Every Camunda 7 extension point still exists under `org.operaton.*`, and the official recipe (Operaton's
  automated OpenRewrite code conversion) renames the imports.** Some hand work remains: job-handler and serializer
  lists are now generic, `getCustomJobHandlers()` returns an immutable list, and subclasses of
  `AbstractOperatonConfiguration` (formerly `AbstractCamundaConfiguration`) need a new constructor.
- **Register plugins with `@Order(Ordering.DEFAULT_ORDER + 1)`**, so that they run after the starter's defaults,
  which would otherwise overwrite some of your settings. A `HistoryEventHandler` that is both a Spring bean and added
  by a plugin exports every event twice.
- **History handlers run inside the engine transaction.** A handler that publishes directly has already sent events
  for work that is then rolled back. Publish after commit or through a transactional outbox (a table in your own
  database that a relay publishes later); see the **history exporters decision**
  ([D9](01-migration-path-and-decisions.md#d9)).
- **Engine class names in event payloads change to `org.operaton…`.** That is a breaking schema change for
  consumers, and no build fails because of it. Consumers must be able to read both formats (dual-read) before the
  cut-over.
- **The official recipe silently misses string literals, `spring.factories` and Keycloak `use…AsCamundaUserId`
  keys.** `migrate.sh` fixes `"camunda.bpm…"` prefixes and `spring.factories`. SpEL `T(org.camunda…)`, class names in
  strings and Keycloak keys stay manual.

## What to do

1. **Find your extension points.** [`scripts/assess.sh`](../scripts/assess.sh) lists extension points, history
   handlers (and double registration), `AbstractCamundaConfiguration` subclasses and class-name strings, so that you
   know what to review.
2. **Build cleanly after the conversion.** After [`scripts/migrate.sh`](../scripts/migrate.sh), run
   `mvn clean verify`, because incremental builds hide generics errors. Then fix the
   [mapping](#extension-point-mapping) items.
3. **Order your plugins and copy lists.** Put `@Order(Ordering.DEFAULT_ORDER + 1)` on every plugin, so that the
   starter's defaults do not overwrite your settings. Use copy, add, set for every list, because the lists you get
   from the engine configuration can be immutable.
4. **Fix the exporter and prepare its consumers.** Fix the [history exporter](#history-exporters) and deploy
   dual-read consumers before the cut-over, because the event payloads change with the first Operaton start. If you
   use [Camunda Optimize](#camunda-optimize), plan its replacement, because Operaton does not claim compatibility
   with it.
5. **Search for Camunda names in strings.** Run [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh) and
   `grep -rnE '"[^"]*(org\.camunda|camunda\.bpm)' src/main/java`. Such strings compile fine, and the official recipe
   does not rewrite them.
6. **Migrate identity providers and add tests.** Migrate your [identity providers](#identity-providers), because a
   provider that silently fails to register can reopen the Admin setup page. Add the
   [tests](#testing-plugins-and-exporters), so that every build checks registrations and the event contract.

## Extension-point mapping

Most extension points only change their package. The table gives an overview; the items marked "below" need hand
work and are explained after it.

| Extension point | Change vs. Camunda 7.24 |
|---|---|
| `ProcessEnginePlugin`, `HistoryEventHandler`, `IncidentHandler`, `FailedJobCommandFactory`, `CommandInterceptor`, identity providers, Spin/Connect SPIs | package only |
| `JobHandler`, `TypedValueSerializer` lists | generic types, immutable list (below) |
| `AbstractCamundaConfiguration` | becomes `AbstractOperatonConfiguration` (below) |
| `BpmnParseListener` | interface with `default` methods (below) |
| `BpmnParser.CAMUNDA_BPMN_EXTENSIONS_NS` (`String`) | use a `Namespace` constant (below) |
| `ELResolver`, expression managers | `jakarta.el.*` ([BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md)) |
| `JtaProcessEngineConfiguration` | removed: `JakartaTransactionProcessEngineConfiguration` |
| FEEL `org.camunda.feel.*` | **unchanged. Never rename** |

- **Job handler and serializer lists** are typed `List<JobHandler<?>>` / `List<TypedValueSerializer<?>>`
  (since Operaton 1.1.0, so on every 2.x version). `getCustomJobHandlers()` returns an immutable empty list, not
  `null`.
- **`AbstractCamundaConfiguration`** becomes `AbstractOperatonConfiguration` with a `(OperatonBpmProperties)`
  constructor; the field is `operatonBpmProperties`. The constructor is shown in
  [Plugin registration in Spring Boot](#plugin-registration-in-spring-boot).
- **`BpmnParseListener`:** implement the interface (its methods are `default`). `AbstractBpmnParseListener` is
  deprecated. Register your listener via `customPre/PostBPMNParseListeners`.
- **`BpmnParser.CAMUNDA_BPMN_EXTENSIONS_NS`:** the recipe turns this `String` into the Operaton URI, which misses
  models that still use `camunda:`. Use the `BpmnParse.OPERATON_BPMN_EXTENSIONS_NS` `Namespace` instead, because it
  matches both.

The Camunda 7 idiom for job handlers (get the list, check for null, add) no longer works. It doesn't compile on
Operaton, and on a plain engine (one built without the Spring Boot starter) it throws
`UnsupportedOperationException`. Use copy, add, set:

```java
List<JobHandler<?>> handlers = new ArrayList<>(configuration.getCustomJobHandlers());
handlers.add(new ReExportJobHandler());
configuration.setCustomJobHandlers(handlers);
```

## Plugin registration in Spring Boot

The Spring Boot starter registers your plugins for you, but it also applies its own defaults, and those can
overwrite what your plugins set:

- The starter collects every `ProcessEnginePlugin` bean in `@Order` order, unless you declare your own
  `ProcessEngineConfigurationImpl` bean.
- Its defaults run at order 0. They register **one** `HistoryEventHandler` bean, join `JobHandler<?>` beans and
  **overwrite** the `FailedJobCommandFactory`. This is why your plugins need `@Order(Ordering.DEFAULT_ORDER + 1)`:
  they then run after the defaults.
- A second `HistoryEventHandler` bean fails the start
  (`NoUniqueBeanDefinitionException … expected single matching bean but found 2`).
- Plain engines read only `operaton.cfg.xml`. This pack's `PostFixes` recipe (run by `migrate.sh`) renames
  `camunda.cfg.xml`; the official recipe doesn't.

**`AbstractCamundaConfiguration` subclasses** don't compile after the recipe
(`cannot find symbol: variable camundaBpmProperties`). Add the constructor:

```java
public ExportToggleConfiguration(OperatonBpmProperties operatonBpmProperties) {
  super(operatonBpmProperties);   // then use the field operatonBpmProperties
}
```

## History exporters

A history exporter receives every history event the engine produces and forwards it to another system. The
migration breaks exporters in ways no compiler sees, and the damage lands in other teams' systems. The migrated
example's [`history/`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/history/) package
is a working reference:

- [`HistoryExportPlugin`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/history/HistoryExportPlugin.java)
  creates
  [`ExportingHistoryEventHandler`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/history/ExportingHistoryEventHandler.java).
  The handler is **not** a bean, so it is registered only once.
- The handler maps each event to an
  [`ExportedHistoryEvent`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/history/ExportedHistoryEvent.java)
  immediately and hands it to the
  [`EventPublisher`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/history/EventPublisher.java)
  port after commit.
- Its envelope is still the legacy one: it has no `schemaVersion`/`entityType`, and `eventClass` now says
  `org.operaton…`. Its consumers must therefore dual-read.

<a id="43-three-problems-the-recipe-cannot-see"></a>

### Three problems the recipe cannot see

1. **Double registration.** A `@Component` handler that a plugin also adds exports every event twice. This already
   happens on Camunda 7, so your consumers receive duplicates today. Register the handler one way only, and warn
   consumers that their event counts will halve.
2. **In-transaction exporters lie.** `handleEvent` runs inside the engine transaction. If that transaction rolls back
   afterwards (for example because a delegate fails or optimistic locking hits), the events are already published.
   Consumers then see "ghost events" for work that never happened, again on every retry of a failing job. Events are
   also mutable, because the engine may still change them later in the transaction: copy them immediately.
3. **Class names in payloads.** `getClass().getName()`, Jackson `@class`, Spring Kafka `__TypeId__` and
   `allowIfSubType("org.camunda…")` allow-lists break consumers without a build error
   (`InvalidTypeIdException … no such class found` / `… denied resolution`). The fix is your own DTO without type
   info, with a `schemaVersion` and a logical `entityType` (`process-instance`, `job-log`, …). Until old messages are
   gone, allow-lists must accept both prefixes.

### Delivery patterns

The table compares four delivery patterns: what consumers see when engine work is rolled back, what happens while
the broker is down, and which delivery guarantee you get. At-most-once means events can be lost; at-least-once means
events can arrive twice, so consumers must deduplicate.

| Pattern | Rolled-back work | Broker down | Delivery |
|---|---|---|---|
| Publish in `handleEvent` (typical Camunda 7) | **ghost events** | blocks the engine thread up to `max.block.ms` | at-least-once + ghosts |
| After commit, via a bounded executor | none | event lost and logged | at-most-once |
| [Transactional outbox](#transactional-outbox) | none | rows wait | at-least-once |
| CDC (change data capture) or polling of `ACT_HI_*` | none | lag | at-least-once, same schema in Camunda 7.24 and Operaton |

The **history exporters decision** ([D9](01-migration-path-and-decisions.md#d9)) recommends an outbox for business
streams (audit, SIEM, billing) and after-commit publishing for observability. Make the switch in the migration
release.

**Catch every exception in an after-commit listener.** An exception thrown in a `COMMITTED` listener reaches the API
caller even though the data is committed, and client retries then create duplicates.

<a id="54-transactional-outbox"></a>

### Transactional outbox

An outbox gives you at-least-once delivery without ghost events. The handler inserts the envelope into your own
table, inside the engine transaction, so the row commits or rolls back together with the engine's work. A relay
publishes it later.

```sql
create table history_outbox (id varchar(64) primary key, created_at timestamp not null default now(),
  topic varchar(255) not null, msg_key varchar(64), payload text not null, published_at timestamp);
```

- Insert with a `JdbcTemplate` on the engine's `DataSource` (or `operatonBpmDataSource`, formerly
  `camundaBpmDataSource`), so that the insert joins the engine transaction.
- The relay polls with `for update skip locked`, publishes, then sets `published_at`. CDC (Debezium outbox router)
  works too.
- Consumers dedupe on `id`. Generate the id yourself, because `HistoryEvent.getId()` can still be `null`.

<a id="64-consumer-cut-over-plan"></a>

### Consumer cut-over plan

Consumers must cope with the new class names before the first Operaton event arrives, and with old messages that
still wait in retry topics and archives. Agree on these steps with every consumer team:

1. **Inventory** every consumer: the fields it reads, class-name routing, dead-letter queues (DLQs) and archives.
2. **Dual-read before the cut-over:** route on `entityType`, else on the *simple* class name in `eventClass`, which
   is the same on both engines.
3. **Drain** (empty) retry topics and DLQs before you stop Camunda 7.
4. **Cut over** to a new versioned topic (`process-history.v2`).
5. **After the rollback window** (see the decision on rollback and point of no return,
   [D15](01-migration-path-and-decisions.md#d15)), remove the v1 path.

### Spring event bridge

The Spring Boot starter can also publish engine events as Spring application events. Three things need attention:

- `camunda.bpm.eventing.*` becomes `operaton.bpm.eventing.*`. Miss a key and the listener never fires.
- `@TransactionalEventListener(AFTER_COMMIT)` on the raw `HistoryEvent` receives mutated objects (`start` arrives as
  `end`). Copy the event to a DTO in a synchronous `@EventListener`, then publish the DTO after commit.
- A SpEL condition `T(org.camunda…)` is not migrated. It throws
  `SpelEvaluationException: EL1005E: Type cannot be found` and **fails `startProcessInstanceByKey`**.

### Camunda Optimize

Camunda Optimize is a Camunda Enterprise product that needs a Camunda license and imports engine data through the
engine REST API. Operaton does not claim compatibility with it, and there is no license path. The `/optimize/*`
endpoints still exist in Operaton's engine REST API, but treat "it might still connect" as unsupported. If you use
Optimize, plan a replacement as part of the
[Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17), for example your own history exporter
feeding BI or process-mining tools. There is no ready-made exporter to switch to, so apply the patterns above.

## Spin and Connect data formats

Custom Spin data format configurators (for example, one that sets how JSON variables serialize dates) are found
through ServiceLoader files whose names contain the package name, so the rename affects them.

- `META-INF/services/org.camunda.spin.spi.DataFormatConfigurator` is renamed. The official recipe rewrites its
  content only with rewrite-maven-plugin ≥ 6.36.0 and never touches **`spring.factories` keys** (`PostFixes` fixes
  both). A configurator that doesn't load fails silently: dates serialize differently.
- Spin stays on **Jackson 2** in Operaton 2.x, while Spring Boot 4 itself uses Jackson 3. Keep your
  configurator on `com.fasterxml.jackson`. The recipe that `migrate.sh` runs on a Spring Boot 4 project
  (`starterpack.operaton.MigrateSpringBoot4App`) renames the configurator and runs no Jackson 3 step. Never run the
  stock `UpgradeSpringBoot_4_0` recipe on it: it rewrites the configurator to `tools.jackson` and drops its module
  registrations (such as `registerModule(new JavaTimeModule())`).
- **Camunda's Jackson 3 opt-in has no Operaton counterpart.** If your Camunda EE build used the `-jackson3` artifacts
  of 7.24.16-ee (for example `camunda-spin-dataformat-json-jackson3`), `migrate.sh` maps them back to the Jackson 2
  artifacts, because Operaton 2.x has no Jackson 3 variant of Spin. A configurator written against `tools.jackson.*`
  then no longer compiles: port it to `com.fasterxml.jackson.*` by hand (see the
  [Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17), and
  [Coming from Camunda's Jackson 3 opt-in](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in)).
- Connect moves to `operaton-engine-plugin-connect` and `org.operaton.connect.spi.*`, with the same ServiceLoader
  caveat.

## Incidents, retries, job handlers

These two points concern code that reacts to failed jobs:

- **Incident handlers:** a custom `failedJob` handler replaces the default one. It runs inside the transaction, so
  send notifications after commit. Move alerts on the logger `org.camunda.bpm.engine.incident` to `org.operaton…`.
- **Retries:** reset them through the API with
  [`IncidentRecoveryService`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/operations/IncidentRecoveryService.java).
  Retry settings and the `operatonTaskExecutor` bean are covered in
  [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).

## Identity providers

An external identity provider (LDAP, Keycloak or OAuth2) has new coordinates on Operaton, and each one has a trap
that fails silently.

> [!WARNING]
> If an external identity provider silently fails to register, the engine falls back to the **writable** database
> identity service. With nobody in `operaton-admin`, that reopens the Admin setup page, where anyone can create an
> administrator without logging in (see [Identity, admin group and security](07-identity-admin-group-and-security.md)).
> Assert the active provider in a test.

- **LDAP:** use `org.operaton.bpm.identity:operaton-identity-ldap`; the setters are the same. **Trap:** unmigrated
  `"camunda.bpm.ldap"` prefix strings in `@ConfigurationProperties`/`@ConditionalOnProperty` silently switch LDAP
  off. This pack's `PreFixes` recipe (run by `migrate.sh`) fixes them.
- **Keycloak:** use `org.operaton.bpm.extension:operaton-keycloak` 2.1.0 for Operaton 2.1. **Trap:** fix
  `-jwt`/`-all`/`-run` and the version by hand. `use{Email,Username}AsCamundaUserId` and
  `useGroupPathAsCamundaGroupId` become `…Operaton…`. Old keys are ignored, so user ids change and authorizations
  stop matching.
- **OAuth2 starter:** use `operaton-bpm-spring-boot-starter-security` (Camunda's Spring Boot 4 starter
  `camunda-bpm-spring-boot-starter-4-security` maps to it) with `operaton.bpm.oauth2.*`. **Trap:** the
  auto-configurations you exclude are renamed `Operaton…`.

## Persisted identifiers do not rebrand

Some identifiers are stored in the database. Never rename them, even if they contain "camunda": existing rows still
carry the old value, so a renamed identifier no longer matches them. The table shows where each one is stored and
what breaks if you rename it.

| Identifier | Stored in | If you rename it |
|---|---|---|
| `JobHandler.getType()` | `ACT_RU_JOB` | jobs without a handler |
| Incident types (`failedJob`) | `ACT_RU_INCIDENT` | incidents not handled |
| Serializer names (`spin://application/json`, `serializable`) | `ACT_RU_VARIABLE` | unreadable variables |
| `HistoryLevel` id | `ACT_GE_PROPERTY` | `historyLevel mismatch` at start |

Variables that hold Java-serialized `org.camunda.*` objects are a separate problem: see the decision on
**variables with `org.camunda.*` objects** ([D18](01-migration-path-and-decisions.md#d18)).

<a id="14-testing-plugins-and-exporters"></a>

## Testing plugins and exporters

Most problems in this chapter cause no compile error: double registration, overwritten defaults, a missing
`operaton.cfg.xml` and changed payloads only show up at runtime. Tests must therefore check registrations, counts and
the event contract:

1. **Write a plain-engine test per plugin** (`StandaloneInMemProcessEngineConfiguration`). It catches immutable
   lists.
2. **Rename `camunda.cfg.xml`.** Since Operaton 1.1.0, `ProcessEngineExtension` silently uses a default engine
   without your plugins. Assert that `operaton.cfg.xml` is on the classpath.
3. **Assert counts:** `Collections.frequency(cfg.getCustomHistoryEventHandlers(), plugin.exportingHandler()) == 1`,
   plus the types of the incident handler, factory and identity provider. This catches double registration and
   defaults that overwrite your settings.
4. **Write a rollback test:** a failing start publishes nothing. The example's `ApplicationConfigurationTest` and
   `ExportingHistoryEventHandlerTest` show steps 3 and 4.
5. **Write a contract test:** compare the envelope JSON with a checked-in file, and make sure there are no engine
   class names outside `eventClass`.

## Watch out

- **Symptom:** `incompatible types: List<JobHandler<?>> cannot be converted to List<JobHandler>`.
  **Cause:** the job handler lists are generic since Operaton 1.1.0.
  **Fix:** use generics and copy, add, set.
- **Symptom:** LDAP users cannot log in, and the setup page appears.
  **Cause:** `camunda.bpm.ldap` strings were not migrated, so the LDAP plugin is off and the engine falls back to
  database identity.
  **Fix:** migrate the prefix strings, then check the setup page again.
