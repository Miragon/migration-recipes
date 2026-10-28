# camunda7-spring-boot-legacy · Before

This is the starting point of the example migration: a Camunda 7.24.0 CE order-fulfillment app (Spring Boot 3.5.5,
Java 17, embedded engine, webapps, REST). It uses an async service task, a DMN decision, a Groovy script that uses
Spin, a Camunda Form, a timer and an external task. Use it to try the pack's tools before you run them on your own
service. The [migrated app](../operaton-spring-boot-migrated/README.md) shows the result.

**Why Camunda CE on Spring Boot 3.5.** The main path of this guide starts from Camunda 7.24 EE (Enterprise Edition)
on Spring Boot 4. Camunda's Spring Boot 4 starters (with a `-4` infix) and the `7.24.N-ee` versions exist only in Camunda's EE
repository, not on Maven Central, so an example built on them would not build for anyone without EE credentials.
This app uses the public flavour instead. Its migration therefore follows the Spring Boot 3.5 path with two code
changes, called hops ([Coming from Spring Boot 3.5](../../docs/15-coming-from-spring-boot-3.md)). The Spring Boot 4
path is reproduced by [`tools/test-boot4-path.sh`](../../tools/test-boot4-path.sh), which derives a Camunda EE variant
on Spring Boot 4 from this app, with stub EE artifacts
([Reproduce the Spring Boot 4 path](../README.md#reproduce-the-spring-boot-4-path)).

Its 21 hotspots are marked in the code. A hotspot is a place that the migration must change, or that breaks without
an error if nobody changes it. List them with `grep -rn "MIGRATION HOTSPOT" .`

## Run and test

```bash
mvn -B verify          # 10 tests, H2 in-memory
mvn spring-boot:run    # http://localhost:8080/camunda/app/ (demo / demo), REST /engine-rest
```

Good to know:

- **Incidents on demand:** order ids `FAIL-…` raise an incident after 3 retries.
- **Tests that fail on purpose after the migration.** The OpenRewrite recipes (the automated code transformations of
  the migration) leave test literals alone, so these tests act as canaries: they fail where a group id, a form key or
  an exported class name changes.
  - `AdminAuthorizationInitializerTest` expects the literal `camunda-admin`.
  - `OrderFulfillmentProcessTest` expects `camunda-forms:` and an `eventClass` starting with `org.camunda` (consumer
    contract).
- **Run the extracted layout, not the fat jar.** With `@EnableProcessApplication`, plain `java -jar` deploys
  `BOOT-INF/classes/…` and the form key does not resolve. Use the extracted layout as in
  [`Dockerfile`](ops/docker/Dockerfile). Camunda 7.24 and Operaton behave the same here, so this is not a migration
  issue.

## Migration hotspots

The table lists all 21 hotspots: what the trap is, what goes wrong on Operaton if nobody acts, and where to find it.
"Silently ignored" means that nothing fails: the engine just runs with default values.

| # | Hotspot (trap) | What goes wrong | Where |
|---|---|---|---|
| 1 | Coordinates, BOM, Spring Boot version | The Spring Boot version must match the Operaton release | [`pom.xml`](pom.xml) |
| 2 | Packages `org.camunda.bpm.*`, `org.camunda.spin.*` | Renamed to `org.operaton.*` | all Java |
| 3 | `@EnableProcessApplication`, `processes.xml` namespace | Annotation package and XML namespace both change | [`OrderFulfillmentApplication.java`](src/main/java/com/example/orders/OrderFulfillmentApplication.java), [`processes.xml`](src/main/resources/META-INF/processes.xml) |
| 4 | `camunda.bpm.*` keys | **Silently ignored** | [`application.yaml`](src/main/resources/application.yaml), [`application-test.yaml`](src/test/resources/application-test.yaml) |
| 5 | Webapp path `/camunda` | Operaton default is `/operaton`: links, ingress and bookmarks move | `application.yaml`, [`config/WebappLinks.java`](src/main/java/com/example/orders/config/WebappLinks.java), `Dockerfile`, [`ingress.yaml`](ops/k8s/ingress.yaml) |
| 6 | `CAMUNDA_BPM_*` env vars | **Silently ignored** | [`app.env`](ops/docker/app.env), `Dockerfile`, `ingress.yaml` |
| 7 | `Groups.CAMUNDA_ADMIN`, `camunda-admin` (data, also in a regex) | Admins lose their rights; the old regex fails the start | [`security/AdminAuthorizationInitializer.java`](src/main/java/com/example/orders/security/AdminAuthorizationInitializer.java), its test, [`grant-admin.sql`](ops/sql/grant-admin.sql), whitelist in `application.yaml` |
| 8 | `TaskEvent` bridge + `camunda.bpm.eventing.*` | Never fires if the key is not renamed | [`listener/TaskLifecycleLogger.java`](src/main/java/com/example/orders/listener/TaskLifecycleLogger.java) |
| 9 | Starter API `PostDeployEvent`, `CamundaBpmProperties` | Starter package and property class renamed | `AdminAuthorizationInitializer`, `WebappLinks` |
| 10 | Internal `impl` API (`AbstractProcessEnginePlugin`, `HistoryEventHandler`, `DefaultIncidentHandler`, `ClockUtil`) | Only renamed now, but the first to change in later Operaton majors | `history/`, `incident/` |
| 11 | `eventClass = event.getClass().getName()` | Consumers see `org.operaton…` | [`history/ExportingHistoryEventHandler.java`](src/main/java/com/example/orders/history/ExportingHistoryEventHandler.java), `ExportedHistoryEvent` |
| 12 | Spin `DataFormatConfigurator` service file | Wrong name or content: silent default `ObjectMapper` | [`META-INF/services/…`](src/main/resources/META-INF/services/org.camunda.spin.spi.DataFormatConfigurator), [`spin/OrderJsonDataFormatConfigurator.java`](src/main/java/com/example/orders/spin/OrderJsonDataFormatConfigurator.java) |
| 13 | Groovy `import org.camunda.spin.Spin` | Deploys, fails at runtime | BPMN `Task_BuildSummary` |
| 14 | `camunda:` namespace, `executionPlatform` | Still accepted: no change needed | BPMN, [DMN](src/main/resources/order-discount.dmn), [form](src/main/resources/approve-order.form) |
| 15 | `camunda-forms:` form key, REST `camundaFormRef` | Form key prefix and REST field change | BPMN `Task_ApproveOrder` |
| 16 | `camunda:class` listener | Resolved at runtime: a wrong class name fails only then | BPMN, [`listener/OrderAuditListener.java`](src/main/java/com/example/orders/listener/OrderAuditListener.java) |
| 17 | Logger names `org.camunda.bpm.*` | Alerts stop matching | `application.yaml`, [`logback-spring.xml`](src/main/resources/logback-spring.xml) |
| 18 | Direct SQL on `ACT_*` | Keeps "working", behind the engine's back | [`ops/sql/`](ops/sql/) |
| 19 | camunda-bpm-assert, `org.camunda` / `camunda-admin` test literals | Recipes leave the literals alone | `src/test/java` |
| 20 | DB names containing "camunda" | Cosmetic: keep the DB | `application.yaml`, `app.env` |
| 21 | History handler registered as `@Component` **and** by the plugin | Every event exported twice | `ExportingHistoryEventHandler`, [`history/HistoryExportPlugin.java`](src/main/java/com/example/orders/history/HistoryExportPlugin.java) |

How each hotspot is fixed is shown in the [migrated app](../operaton-spring-boot-migrated/README.md) and its
[migration report](../operaton-spring-boot-migrated/MIGRATION_REPORT.md).
