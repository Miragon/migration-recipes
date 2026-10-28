# Engine plugins, history exporters, SPI files, identity providers

Load this when the project contains a `ProcessEnginePlugin`, a `HistoryEventHandler` or other exporter, custom
incident/job handlers, parse listeners, serializers, `META-INF/services` or `spring.factories` entries, Spin
configurators, or an identity provider (LDAP, Keycloak, OAuth2, custom). Guide chapter:
https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/06-engine-plugins-and-history-exporters.md

## Contents

1. Inventory
2. Extension-point mapping
3. Code changes the recipe does not make
4. Registration and order in Spring Boot
5. History exporter: after-commit pattern (D9)
6. Class-name payloads and the consumer plan
7. Spring event bridge
8. SPI files: Spin, Connect, FEEL, webapp plugins
9. Incident handlers, failed-job factory, job handlers
10. Identity providers
11. Persisted identifiers: never rename
12. Ecosystem status (stop conditions)
13. Tests and done criteria

## 1. Inventory

```bash
grep -rln 'engine\.impl\.' src/main/java src/main/kotlin 2>/dev/null       # internal-API users (plugins, handlers, ...)
find . -path '*/META-INF/services/*' -not -path '*/target/*' | xargs grep -Hn . # file names AND contents
find . -name spring.factories -not -path '*/target/*' | xargs grep -n 'camunda'
grep -rnE '"[^"]*(org\.camunda|camunda\.bpm)[^"]*"' src --include='*.java' --include='*.kt'   # literals: SpEL T(...), @ConfigurationProperties,
                                                     # @ConditionalOnProperty, @Value, @Qualifier, allow-lists, Class.forName
grep -rn 'T(org\.camunda' src                         # SpEL in @EventListener conditions (breaks process execution)
grep -rnE 'useEmailAsCamundaUserId|useUsernameAsCamundaUserId|useGroupPathAsCamundaGroupId|trusted\.packages' src
```

Also list every downstream consumer of exported events (owner, fields read, class-name routing, DLQs, archives).
All of this is internal API (`…engine.impl.*`), unchanged under `org.operaton.*`; keep it behind one plugin and one handler.

## 2. Extension-point mapping

Same simple name, `org.camunda` → `org.operaton`, same signatures unless noted. Plugin SPI is identical in Operaton 1.x and 2.x.

| Extension point (Operaton) | Change vs. Camunda 7.24 |
|---|---|
| `…engine.impl.cfg.ProcessEnginePlugin`, `AbstractProcessEnginePlugin`, `CompositeProcessEnginePlugin` | same |
| `…spring.boot.starter.configuration.impl.AbstractOperatonConfiguration` (was `AbstractCamundaConfiguration`) | **constructor `(OperatonBpmProperties)` required; field is `operatonBpmProperties`** |
| `…impl.history.handler.HistoryEventHandler`, `CompositeHistoryEventHandler`, `CompositeDbHistoryEventHandler`, `DbHistoryEventHandler` | same; event **FQCNs change** (section 6) |
| `…impl.history.event.HistoryEvent` constants `ACTIVITY_/TASK_/VARIABLE_EVENT_TYPE_*` | deprecated for removal → use `HistoryEventTypes` |
| `HistoricJobLogEventEntity` | lives in `…impl.persistence.entity`, not `…impl.history.event` |
| `…impl.history.HistoryLevel` | same; 2.1: `HistoryLevelSetupCommand` is an interface (`DefaultHistoryLevelSetupCommand`, helper in `HistoryLevelUtils`) |
| `…impl.cfg.TransactionContext`/`TransactionListener`/`TransactionState`; `…impl.incident.IncidentHandler`, `DefaultIncidentHandler` | same |
| `…impl.jobexecutor.FailedJobCommandFactory`, `DefaultFailedJobCommandFactory` | same; starter overwrites it at order 0 (section 9) |
| `…impl.jobexecutor.JobHandler<T>` | `onDelete` is a `default` method; lists generic since 1.1.0 (section 3) |
| `…impl.bpmn.parser.BpmnParseListener` | all methods `default`; `AbstractBpmnParseListener` deprecated for removal |
| `BpmnParse.OPERATON_BPMN_EXTENSIONS_NS` (`Namespace`, matches `operaton:` and `camunda:`) | `BpmnParse.CAMUNDA_BPMN_EXTENSIONS_NS` gone; string `BpmnParser.CAMUNDA_BPMN_EXTENSIONS_NS` is rewritten to the operaton URI (trap) |
| `…impl.el.ExpressionManager`, `JuelExpressionManager`, `SpringExpressionManager` | protected members use plain `jakarta.el.*` |
| `…impl.variable.serializer.TypedValueSerializer` | `List<TypedValueSerializer<?>>`; `AbstractTypedValueSerializer.BINARY_VALUE_TYPES` immutable (`add()` throws) |
| Identity SPI (`ReadOnlyIdentityProvider`, `SessionFactory`), `PasswordEncryptor`/`Sha512HashDigest` | same; existing hashes verify |
| `org.operaton.spin.spi.DataFormatConfigurator`, `org.operaton.connect.spi.ConnectorProvider` | same; ServiceLoader file names change (section 8) |
| `org.camunda.feel.valuemapper.CustomValueMapper` | **unchanged, do not rename** |
| `org.operaton.bpm.engine.impl.cfg.JakartaTransactionProcessEngineConfiguration` | `JtaProcessEngineConfiguration` removed (embedded Spring Boot apps unaffected) |

## 3. Code changes the recipe does not make

**Job handler / serializer lists are generic (since 1.1.0) and the job-handler getter never returns `null` but an
immutable empty list (since 1.0.0).** The C7 idiom fails to compile, and after adding `<?>` throws
`UnsupportedOperationException`. Use **copy, add, set** for every list you touch:

```java
// Camunda 7.24 idiom: compile error / UnsupportedOperationException on Operaton
List<JobHandler> handlers = configuration.getCustomJobHandlers();
if (handlers == null) { handlers = new ArrayList<>(); configuration.setCustomJobHandlers(handlers); }
handlers.add(new ReExportJobHandler());

// Operaton: copy, add, set
List<JobHandler<?>> handlers = new ArrayList<>(configuration.getCustomJobHandlers());
handlers.add(new ReExportJobHandler());
configuration.setCustomJobHandlers(handlers);
```

**`AbstractCamundaConfiguration` subclasses** fail with "constructor AbstractOperatonConfiguration … cannot be applied" /
"cannot find symbol: camundaBpmProperties":

```java
@Component
@Order(Ordering.DEFAULT_ORDER + 1)
public class ExportToggleConfiguration extends AbstractOperatonConfiguration {
  public ExportToggleConfiguration(OperatonBpmProperties operatonBpmProperties) {
    super(operatonBpmProperties);
  }
  @Override
  public void preInit(SpringProcessEngineConfiguration configuration) {
    if (operatonBpmProperties.getEventing().isHistory()) {
      configuration.setEnableDefaultDbHistoryEventHandler(true);
    }
  }
}
```

Subclasses of starter `Default*Configuration` classes need all their constructor args (e.g.
`DefaultJobConfiguration(OperatonBpmProperties, JobExecutor)`).

**Parse listeners:** `implements BpmnParseListener` (drop `AbstractBpmnParseListener`), read extensions with
`extensionElements.elementNS(BpmnParse.OPERATON_BPMN_EXTENSIONS_NS, "properties")` (null-check `extensionElements`),
register via `get/setCustomPreBPMNParseListeners` / `…PostBPMNParseListeners` (copy, add, set). Never build
`new Namespace(BpmnParser.OPERATON_BPMN_EXTENSIONS_NS)` or compare `getUri()` with that string: it no longer matches
`camunda:` models.

**Expression managers:** `jakarta.el.*` imports (`starterpack.operaton.PreFixes`); Operaton 2.x (Jakarta EL 6.0; Spring
Boot 3.5 path: Hop 2): delete `ELResolver#getFeatureDescriptors` overrides.

**Always `mvn clean`** when the engine version changes: an incremental build can report success with stale classes.

## 4. Registration and order in Spring Boot

- The starter picks up every `ProcessEnginePlugin` bean (`@Component` or `@Bean`) and runs them in `@Order` order.
  Declaring your own `ProcessEngineConfigurationImpl` bean switches auto-collection off.
- Orders: `GenericPropertiesConfiguration` = −1; all `Default*Configuration` = `Ordering.DEFAULT_ORDER` (0): history level,
  **one** `HistoryEventHandler` bean auto-registered, `JobHandler<?>` beans joined, `DefaultFailedJobCommandFactory` set
  **unconditionally**; plugins without `@Order` (incl. Spin, Connect, event bridge) run last.
- **Rule: annotate every plugin with `@Order(Ordering.DEFAULT_ORDER + 1)`** (`org.operaton.bpm.spring.boot.starter.configuration.Ordering`).
- **Register each `HistoryEventHandler` exactly once.** A `@Component` handler is auto-registered by the starter; if a plugin
  also adds it, every event is exported twice (the legacy example has this bug). Either the plugin constructs the handler
  (recommended) or keep the single handler bean and drop the plugin. Never both. A second `HistoryEventHandler` bean fails
  startup (`NoUniqueBeanDefinitionException … expected single matching bean but found 2`).
- To override a starter plugin (`spinProcessEnginePlugin`, `connectProcessEnginePlugin`, `eventPublisherPlugin`), declare a
  bean with the same name.
- Plain engines (`operaton.cfg.xml`, non-Boot) have no starter defaults: lists are `null` or immutable.

## 5. History exporter: after-commit pattern (D9)

Handlers run synchronously on the caller's thread **inside the engine transaction**. Publishing in `handleEvent` sends
**ghost events** for rolled-back work (every failed job retry, every `OptimisticLockingException`), and a blocking broker
call stalls engine threads. Same on Camunda 7; fix it in this migration because consumers must be touched anyway.

| D9 option | Delivery | Use for |
|---|---|---|
| B · after-commit hand-off (`TransactionState.COMMITTED` listener, never throws) | at-most-once | metrics, dashboards |
| C · transactional outbox (insert into own table, same `DataSource`, relay/CDC) | at-least-once, dedupe on id | audit, SIEM, billing, cross-system state |
| D · CDC/polling on `ACT_HI_*` (schema unchanged, so the migration does not break it) | at-least-once | large volumes, data lake |
| A · publish inside the transaction | at-least-once + ghosts | never |

**Apply option B with the bundled snippets** (package `com.example.orders.history`: adapt it; they compile on Operaton
1.x and 2.x):

1. Copy `assets/snippets/HistoryExportPlugin.java` (`@Component`, `@Order(Ordering.DEFAULT_ORDER + 1)`, constructs the
   handler, copy-add-set into `customHistoryEventHandlers`, keeps `setEnableDefaultDbHistoryEventHandler(true)`, exposes
   `exportingHandler()` for tests).
2. Copy `assets/snippets/ExportingHistoryEventHandler.java`: maps to an envelope **immediately** (entities are mutable),
   publishes from a `COMMITTED` transaction listener, swallows and logs publisher exceptions. **Remove `@Component` from the
   project's old handler class.**
3. Copy `assets/snippets/EventPublisher.java` (the outbound port, one method `publish(ExportedHistoryEvent)`) and
   `assets/snippets/ExportedHistoryEvent.java` (the example's envelope: `eventType`, `processDefinitionKey`,
   `processInstanceId`, `activityId`, `timestamp`, `eventClass`), or keep the project's existing equivalents. This is the
   **v1 envelope**: `eventClass` now carries `org.operaton…`. Before shipping it, extend it per D9 (section 6).
4. The real publisher must not block or throw: hand off to a bounded single-thread executor
   (`ThreadPoolTaskExecutor`, core = max = 1, bounded queue, add a metric for drops) and log failures in
   `kafka.send(...).whenComplete(...)`. `KafkaTemplate.send()` blocks up to `max.block.ms` (default 60 s) when the broker is down.
   Spring Boot 4: depend on `org.springframework.boot:spring-boot-starter-kafka` (a plain `spring-kafka` no longer creates
   a `KafkaTemplate`, so a Spring Boot 4 source whose exporter works today already has it; the Spring Boot 3.5 path adds
   it in Hop 2).
5. Tell consumers: event counts halve if the old code double-registered; no events for rolled-back work any more.

For an outbox (option C): `JdbcTemplate` on the **same** `DataSource` as the engine (joins the Spring-managed engine
transaction; if the engine uses a separate `operatonBpmDataSource`, use that one), insert `(id, topic, msg_key, payload)` in
`handleEvent`, relay with `select … for update skip locked` or Debezium's outbox router. Table DDL: chapter 06,
[Transactional outbox](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/06-engine-plugins-and-history-exporters.md#54-transactional-outbox).

Never publish raw engine entities from an `AFTER_COMMIT` listener: the engine mutates them in place (`start` arrives as `end`).
Do not use `HistoryEvent.getId()` as a mandatory idempotency key (can be `null` in the handler); generate your own message id.

## 6. Class-name payloads and the consumer plan

`event.getClass().getName()` changes from `org.camunda.bpm.engine.impl.history.event.*` to `org.operaton.…`. Nothing fails in
the engine app; **other teams' consumers** break (routing rules, SIEM filters, Jackson default typing `@class`,
`PolymorphicTypeValidator.allowIfSubType("org.camunda…")`, Spring Kafka `__TypeId__` + `spring.json.trusted.packages`, Java
serialization in JMS/Redis/caches, DLQs and replay archives). Treat it as a **breaking event-schema change**.

Producer, in order of preference: own DTO without type info, with `schemaVersion` + logical `entityType`; logical type names
(`@JsonTypeInfo(use = Id.NAME)`) if polymorphism is needed; never `getClass().getName()` in new payloads; allow both
prefixes in allow-lists only as a transition.

**D9 default when consumers are unknown or have not signed off: keep the payload contract stable.** Extend the bundled v1
envelope to v2: keep every field, add `schemaVersion` and a logical `entityType`, and freeze `eventClass` to the Camunda
value. Existing consumers keep reading what they read before; new consumers route on `entityType`. The consumer canary test
(e.g. "`eventClass` starts with `org.camunda.bpm.engine.`") stays **unchanged**. Flip or drop `eventClass` only after every
consumer owner signed off (report: cut-over gate). Changes to the bundled files:

```java
// ExportedHistoryEvent.java: v2 = v1 fields + schemaVersion + entityType (additive)
public record ExportedHistoryEvent(
    int schemaVersion,             // 2; v1 had none
    String eventType,
    String entityType,             // "process-instance", "activity-instance", ...
    String processDefinitionKey,
    String processInstanceId,
    String activityId,
    Instant timestamp,
    @Deprecated String eventClass) { }   // frozen to the Camunda 7 value until every consumer reads entityType

// ExportingHistoryEventHandler.java: toEnvelope(...) fills the new fields
static final int SCHEMA_VERSION = 2;
ExportedHistoryEvent toEnvelope(HistoryEvent event) {
  return new ExportedHistoryEvent(SCHEMA_VERSION, event.getEventType(), entityTypeOf(event),
      event.getProcessDefinitionKey(), event.getProcessInstanceId(), activityIdOf(event), timestampOf(event),
      legacyEventClassOf(event));
}
static String entityTypeOf(HistoryEvent e) {
  if (e instanceof HistoricProcessInstanceEventEntity) return "process-instance";
  if (e instanceof HistoricActivityInstanceEventEntity) return "activity-instance";
  if (e instanceof HistoricTaskInstanceEventEntity) return "task-instance";
  if (e instanceof HistoricVariableUpdateEventEntity) return "variable-update";
  if (e instanceof HistoricIncidentEventEntity) return "incident";
  if (e instanceof HistoricJobLogEventEntity) return "job-log";        // org.operaton.bpm.engine.impl.persistence.entity
  return "other:" + e.getClass().getSimpleName();
}
/** Transition only: the value Camunda 7 consumers expect. Remove with the next schema version. */
static String legacyEventClassOf(HistoryEvent e) {
  return e.getClass().getName().replaceFirst("^org\\.operaton\\.", "org.camunda.");
}
```

Follow-ups: imports for the entity classes (section 2: `HistoricJobLogEventEntity` lives in `…impl.persistence.entity`);
the bundled `ExportingHistoryEventHandlerTest` filters on `eventClass` equal to the Operaton class name: filter on
`entityType` instead (`"process-instance"`). `verify-leftovers.sh` reports the unchanged canary literal
(`"org.camunda.bpm.engine."`) as `CAMUNDA_PKG`: accept it in `.operaton-migration-ignore` with the reason
"D9: eventClass frozen until consumer sign-off" (e.g. `CAMUNDA_PKG  src/test/java/**/OrderFulfillmentProcessTest.java  "org\.camunda\.bpm\.engine\."`). Consumers that
validate strictly (schema registry, `additionalProperties: false`, `FAIL_ON_UNKNOWN_PROPERTIES`) need the v2 schema
registered before the release. If consumers already signed off, ship v2 without freezing (`event.getClass().getName()`) and
flip the canary in the same commit, recorded as a manual fix.

Consumer plan (put it in the report and the cut-over pack; list owners): (1) inventory consumers, fields, DLQs, archives;
(2) **dual-read before the cut-over** while Camunda still produces (route on `entityType`, fall back to the simple class name
of `eventClass`, prefix-agnostic); (3) drain retry topics and DLQs; (4) Operaton writes v2: on the same topic while
`eventClass` is frozen, or on a new versioned topic (e.g. `process-history.v2`) when the consumers can switch in a
coordinated way; (5) each consumer owner signs off (cut-over gate); after the rollback window (D15) unfreeze or remove
`eventClass` and the v1 path.
Jackson default-typing consumers on Operaton jars can read old payloads with a `DeserializationProblemHandler` that maps
`org.camunda.bpm.` type ids to `org.operaton.bpm.` (consumer steps: chapter 06,
[Consumer cut-over plan](https://github.com/Miragon/migration-recipies/blob/main/services/c7/docs/06-engine-plugins-and-history-exporters.md#64-consumer-cut-over-plan)).

## 7. Spring event bridge

- Keys `camunda.bpm.eventing.{execution,task,history,skippable}` → `operaton.bpm.eventing.*` (default `true`). A missed key
  means the listener compiles and never fires. If nothing listens to history events, set `operaton.bpm.eventing.history: false`.
- Plain `@EventListener`s run inside the engine transaction (ghosts). For after-commit: copy to a DTO in a synchronous
  `@EventListener`, publish the DTO from `@TransactionalEventListener(phase = AFTER_COMMIT)`, never throw.
- **A stale SpEL condition `T(org.camunda…)` breaks `startProcessInstanceByKey`** (`SpelEvaluationException: EL1005E: Type
  cannot be found`). Replace SpEL type checks with typed listener parameters.

## 8. SPI files: Spin, Connect, FEEL, webapp plugins

| Registration | Operaton | Recipe |
|---|---|---|
| `META-INF/services/org.camunda.spin.spi.DataFormatConfigurator` | `META-INF/services/org.operaton.spin.spi.DataFormatConfigurator` | file renamed; **content** rewritten only with rewrite-maven-plugin ≥ 6.36.0 (`migrate.sh` default is newer). Check that listed engine classes are `org.operaton.*`; your own classes stay |
| `spring.factories` key `org.camunda.spin.spi.DataFormatConfigurator=…` | key `org.operaton.spin.spi.DataFormatConfigurator=…` | **never migrated: fix by hand** (otherwise the configurator silently stops loading) |
| `META-INF/services/org.camunda.connect.spi.*` | `org.operaton.connect.spi.ConnectorProvider` / `ConnectorConfigurator` | as Spin |
| Webapp plugins `…cockpit.plugin.spi.CockpitPlugin` etc. | `org.operaton.bpm.cockpit.plugin.spi.CockpitPlugin` (+ admin/tasklist/welcome); webjar path `META-INF/resources/webjars/operaton/…` | services renamed; custom MyBatis XML must reference `org.operaton.bpm.engine.impl.persistence.entity.*` |
| `META-INF/services/org.camunda.feel.*` | **unchanged** | excluded on purpose |

- Starter configurators renamed: `org.operaton.bpm.spring.boot.starter.spin.OperatonJacksonFormatConfiguratorJSR310` /
  `…ParameterNames` / `…Jdk8`.
- **Spin stays on Jackson 2 in Operaton 2.x** (no `-jackson3` Spin, REST or client artifacts). Keep Spin
  `DataFormatConfigurator`s and every `ObjectMapper` that touches Spin/engine on `com.fasterxml.jackson` (error
  otherwise: "com.fasterxml.jackson.databind.ObjectMapper cannot be converted to tools.jackson.databind.ObjectMapper").
  Spring Boot 4 sources that opted into Camunda's Jackson 3 artifacts (`-jackson3`, 7.24.16-ee) rewrite that code back
  to `com.fasterxml.jackson.*`; the Spring Boot 3.5 path keeps it there in Hop 2.
- Persisted format names stay: `application/json`, `application/xml`, `spin://application/json`, `serializable`.
- Verify with a test that **your** configurator is active. A `LocalDate`-as-ISO-string check is weak: the starter's
  `OperatonJacksonFormatConfiguratorJSR310` already does that. Assert a setting only your configurator applies (e.g. with
  `FAIL_ON_UNKNOWN_PROPERTIES` disabled, map JSON with an unknown property to your DTO, which fails with
  `UnrecognizedPropertyException` otherwise), or check the startup log for
  `SPIN-01011 Discovered Spin data format configurator: class <your configurator>`.

## 9. Incident handlers, failed-job factory, job handlers

- Incident handlers: unchanged. A custom handler of type `failedJob`/`failedExternalTask` **replaces** the default (extend
  `DefaultIncidentHandler`, call `super.handleIncident`). With `composite-incident-handlers-enabled: true` (generic property) it
  is **added** instead. `handleIncident` runs in the engine transaction: notify after commit, non-blocking.
- Alerting on logger `org.camunda.bpm.engine.incident` must move to `org.operaton.bpm.engine.incident`.
- Custom `FailedJobCommandFactory`: register it in a plugin with `@Order(Ordering.DEFAULT_ORDER + 1)`, otherwise the starter's
  order-0 `DefaultFailedJobConfiguration` overwrites it silently. Assert the type in a test.
- Custom job handlers: `@Bean JobHandler<?>` (joined by the starter) or copy-add-set in a plugin. Delete empty `onDelete`
  overrides if you like. **Keep `getType()` byte-identical** (persisted in `ACT_RU_JOB.HANDLER_TYPE_`).
- Retry config: `failed-job-retry-time-cycle`, `default-number-of-retries` as generic properties under `operaton.bpm`;
  executor bean `operatonTaskExecutor` (was `camundaTaskExecutor`; `@Qualifier` strings are not migrated).

## 10. Identity providers

If an external provider silently fails to register, the engine falls back to the **writable DB identity service**, and on a
migrated DB with an empty `operaton-admin` the setup page can reopen. **Assert the active provider type in a test.**

| Provider | Operaton coordinates and changes |
|---|---|
| LDAP | `org.operaton.bpm.identity:operaton-identity-ldap`, `org.operaton.bpm.identity.impl.ldap.plugin.LdapIdentityProviderPlugin`; all setters identical. **Fix prefix strings** in `@ConfigurationProperties("camunda.bpm.ldap")` / `@ConditionalOnProperty(prefix = "camunda.bpm.ldap")` (not migrated → LDAP silently off). Prefer an own prefix (e.g. `orders.identity.ldap`); change annotation strings and YAML in the same commit |
| Keycloak | `org.operaton.bpm.extension:operaton-keycloak` (+ `-jwt`, `-all`, `-run`), plugin `org.operaton.bpm.extension.keycloak.plugin.KeycloakIdentityProviderPlugin`. Use the plugin line matching the Operaton minor (2.1.x for Operaton 2.1; Spring Boot 3.5 path: 1.1.x for the Hop 1 checkpoint; no 2.0.0 final; versions: references/versions.md). The recipe maps only the base artifact (to 1.0.x): bump it, change `-jwt`/`-all`/`-run` by hand. **Rename** `useEmailAsCamundaUserId` → `useEmailAsOperatonUserId`, `useUsernameAsCamundaUserId` → `useUsernameAsOperatonUserId`, `useGroupPathAsCamundaGroupId` → `useGroupPathAsOperatonGroupId`. A missed key silently changes user ids and breaks authorizations, assignees and identity links. Keep the user-id mode identical. Do not set `operaton.bpm.admin-user` with Keycloak |
| OAuth2 starter | `org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-security`, keys `operaton.bpm.oauth2.*`, auto-configs `…security.oauth2.OperatonSpringSecurityOAuth2AutoConfiguration` / `…OperatonBpmSpringSecurityDisableAutoConfiguration` |
| Custom provider | package rename only (`ReadOnlyIdentityProvider`, `SessionFactory`, `setIdentityProviderSessionFactory`). Check admin group ids returned (`operaton-admin` vs `camunda-admin`) and custom whitelist patterns (default `[a-zA-Z0-9]+\|operaton-admin`) |

Admin group semantics and the setup endpoint: references/identity-and-admin.md.

## 11. Persisted identifiers: never rename

Keep byte-identical: `JobHandler.getType()`, incident types (`failedJob`, `failedExternalTask`, custom), serializer names
(`TypedValueSerializer.getName()`), custom `HistoryLevel` id/name (mismatch fails startup: "historyLevel mismatch"), Spin
data format names, identity ids produced by providers, event-schema values and topic names consumers route on.

## 12. Ecosystem status (stop conditions)

No ready-made exporter exists for Operaton. Treat the exporter as home-grown and budget for it.

| Library | Status | Action |
|---|---|---|
| Polyflow / `camunda-bpm-taskpool` (`io.holunda.polyflow`) | no Operaton support | **Stop condition** until the user decides: ask holunda, fork the collector (engine-plugin code, migrates like section 5), or replace |
| `camunda-kafka-polling-client`, `bpmn.ai`, `camunda-platform-7-reactor`, `camunda-bpm-elasticsearch` | archived | replace (reactor → built-in event bridge) |
| Camunda Optimize | EE, not supported | decision D17 (mandatory for every EE source) |
| `camunda-platform-7-mail`, Holunda REST client for Spring Boot, `camunda-platform-7-graphql` | none | fork + recipe, replace (Spring Mail; client generated from `org.operaton.bpm:operaton-engine-rest-openapi`), or drop |
| `operaton-keycloak`, `operaton-identity-ldap`, `datakurre/operaton-cockpit-plugins` | maintained / core | migrate |
| `viadee/external-task-retry-aspect` | upstream supports Operaton from 1.12.0 (detects the Operaton client) | keep, bump to ≥ 1.12.0 |
| Operaton external-history API with outbox | planned ("likely for 2.3"), not released | do not wait for it; keep the engine-facing code thin |

## 13. Tests and done criteria

Add these tests (code and adaptation notes: references/testing.md §8): plain-engine test per plugin
(`StandaloneInMemProcessEngineConfiguration` + plugin + `buildProcessEngine()`), Spring Boot registration test asserting
counts and types (`Collections.frequency(cfg.getCustomHistoryEventHandlers(), plugin.exportingHandler()) == 1`,
`getIncidentHandler("failedJob")`, `getFailedJobCommandFactory()`, identity provider factory type), exporter rollback test,
commit test, envelope contract test. For the bundled exporter start from `assets/snippets/test/ExportingHistoryEventHandlerTest.java`.

- [ ] Generics, copy-add-set, `AbstractOperatonConfiguration` constructors, parse listeners, EL imports fixed; `mvn clean verify` green.
- [ ] Every plugin has `@Order(Ordering.DEFAULT_ORDER + 1)`; each `HistoryEventHandler` registered exactly once.
- [ ] Exporter publishes after commit (or outbox), never throws or blocks; rollback test green.
- [ ] Envelope v2 (`schemaVersion`, `entityType`, `eventClass` frozen until sign-off) or documented consumer sign-off;
      consumer plan with owners in the report (dual-read before cut-over, versioned topic, drain, cleanup after D15 window).
- [ ] `spring.factories` keys fixed; `META-INF/services` names and contents checked; `org.camunda.feel` untouched.
- [ ] String literals (SpEL, prefixes, qualifiers, allow-lists, Keycloak keys) fixed; `verify-leftovers.sh` exit 0.
- [ ] Identity provider asserted active; Keycloak user-id mode unchanged; persisted identifiers unchanged.
- [ ] Unsupported ecosystem libraries have a decision recorded.
