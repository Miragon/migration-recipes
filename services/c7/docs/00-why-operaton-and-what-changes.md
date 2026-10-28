# 00 · Why Operaton, and what changes

This chapter explains what Operaton is, why teams on Camunda 7 move to it, and what changes in a Spring Boot
application that embeds the engine. It describes the main path: Camunda 7.24 Enterprise Edition (EE) on Spring Boot 4,
moved to Operaton 2.x. Read it first if you plan or approve the migration. Developers and ops engineers can use the
change table and the list of pitfalls as a checklist for their own service.

On Spring Boot 3.5 (Camunda 7.24 CE, or EE without the Spring Boot 4 starters)? Read
[Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md) first. It adds the pitfalls that
only concern Spring Boot 3.5 applications, such as Operaton 2.x failing to start on Spring Boot 3.

**In short**
- **Operaton** is the community-run fork of Camunda 7 Community Edition (CE), under the Apache-2.0 license. It offers
  the Camunda 7.24 API under the package `org.operaton`, the 7.24.0 database schema, the same REST API and the same
  BPMN files. That is why the Operaton build can open your existing Camunda 7.24 database.
- **Operaton is a fork of CE, not of EE.** Its own documentation claims compatibility with Camunda 7 CE 7.24 only. The
  EE webapp features, the security hardening of the EE patches and the EE option to use Jackson 3 have no Operaton
  counterpart. Every EE team therefore has to decide what replaces them, in the mandatory
  [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17).
- **Operaton has no long-term support (LTS).** A new minor version ships every April and October, with monthly
  patches. Only the current line is maintained (2.1.x); 1.x is end of life. Plan for regular upgrades. Operaton needs
  Java 17 or newer.
- **If you run Camunda 7 EE:** Camunda 7 EE is in long-term support. Version 7.24 gets maintenance, bug and security
  fixes until 13 April 2030, under a commercial license. Spring Boot 4 on Camunda 7.24 exists only in EE (from
  7.24.3-ee), so if your application runs on Spring Boot 4, you are on EE. Operaton 2.x is built on Spring Boot 4 as
  well, so your platform stays: the code changes in one step, and production switches in one cut-over. Whether and
  when you leave EE is your decision; this guide shows what changes when you do.
- **Why now, if you run Camunda 7 CE:** CE gets no fixes after 7.24.0 (2025-10-14), not even security patches, and no
  Spring Boot 4 support. Its Spring Boot 3.5 baseline lost open-source (OSS) support on 2026-06-30. Staying on Camunda 7
  CE therefore leaves both the engine and its Spring Boot baseline without open-source fixes.
- **Alternatives:** Camunda 8 is a re-implementation, and self-managed production use needs a license. CIB seven is
  another fork of Camunda 7; this guide does not cover it. You can also stay on Camunda 7 EE, which needs a commercial
  license and gets patches until 13 April 2030.
- **The code conversion is mostly automatic; the risk is elsewhere.** An OpenRewrite recipe (an automated code
  transformation) does the mechanical renaming. The risk lies in what no compiler sees: configuration values, scripts
  inside BPMN models, rows in the database, the consumers of your events and, on EE, the features and the security
  hardening that Operaton does not have. Mistakes there fail silently or only at runtime.

## What to do

1. Run [`scripts/assess.sh`](../scripts/assess.sh) on every service, so that you know which rows of the
   [change table](#what-changes-and-what-stays-the-same) affect you. The script only reads your code and prints a
   report of findings. It also names the edition (CE or EE), the Spring Boot version, the migration path and the
   recommended Operaton target. Mark each table row "affects us" or "does not". Details:
   [Assessment](02-assessment.md).
2. If you run Camunda EE, start the [Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17)
   early. EE features disappear without a build error, and the missing EE hardening changes your security posture, so
   your process owners and your security team need time to plan replacements.
3. Put [the 12 things that bite](#the-12-things-that-bite) on the test plan of your first rehearsal, because most of
   them pass the build and only show up when the application runs. A rehearsal is a trial run of the cut-over (the
   one event that switches production from Camunda to Operaton on the same database) on a restored copy of the
   production database.

## What changes and what stays the same

The table compares Camunda 7.24 with Operaton area by area. The second column shows what changes, the third how serious
it is, and the last one what you do about it. The labels mean:

- **MUST**: if you skip it, the build, the start, the runtime behaviour or security breaks.
- **SHOULD**: if you skip it, something degrades silently. No error appears, but a URL, a form, a client or a log
  filter no longer works as before.
- **KEEP**: leave it as it is; do not rename or convert it.
- **(EE)** marks rows that only concern Camunda EE builds. Every team on Spring Boot 4 has such a build.

Where a migration decision covers the area, the link leads to its recommendation in
[Migration path and decisions](01-migration-path-and-decisions.md#d1). The ID in parentheses (for example D5) is the
decision's number in that chapter and in the decision log.

| Area | Camunda 7.24 → Operaton | Label | What you do |
|---|---|---|---|
| Maven coordinates | `org.camunda.bpm(.springboot)` → `org.operaton.bpm(.springboot)`, `camunda-bom` → `operaton-bom` | **MUST** | `migrate.sh` renames them and sets the target version through `operaton-bom`. The official recipe alone pins Operaton 1.0.x. |
| Spring Boot 4 starters (EE) | `camunda-bpm-spring-boot-starter-4[-x]` → `operaton-bpm-spring-boot-starter[-x]` (no `-4` infix), `-4-test` → `operaton-bpm-spring-boot-starter-test-junit5` | **MUST** | `migrate.sh` maps them. The official recipe does not, and the build breaks. |
| Java packages | `org.camunda.bpm\|spin\|connect\|commons\|templateengines.*` → `org.operaton.*`, `Camunda*` → `Operaton*` types | **MUST** | The recipe renames them. |
| FEEL engine | `org.camunda.feel:feel-engine` stays | **KEEP** | Never rename it. |
| Properties, env vars | `camunda.bpm.*` → `operaton.bpm.*`, `CAMUNDA_BPM_*` → `OPERATON_BPM_*`, no alias | **MUST** | Rename every key. Old keys are silently ignored, and config outside the repo is manual work. |
| Admin group | `camunda-admin` → `operaton-admin` (hard-coded, rows are not migrated) | **MUST** (security) | Copy the group's members and authorizations to `operaton-admin` before the first start: [Admin group (D5)](01-migration-path-and-decisions.md#d5). |
| Webapp path | `/camunda/app` → `/operaton/app`, overlays → `webjars/operaton/` | **SHOULD** | Keep `/camunda` for the cut-over: [Webapp path (D6)](01-migration-path-and-decisions.md#d6). |
| EE webapps (EE) | `…-4-webapp-ee`, `…-webapp-ee`, `camunda-webapp-webjar-ee` silently mapped to the CE webapps | **MUST** | Inventory the EE features you use and test a replacement for each: [Camunda EE features (D17)](01-migration-path-and-decisions.md#d17). |
| REST API | `/engine-rest` unchanged, `camundaFormRef` → `operatonFormRef`, `GET /version` reports Operaton | **SHOULD** | Check your REST clients. |
| Database schema | identical DDL; 2.2 adds only a `7.25.0` marker row to the schema log (`ACT_GE_SCHEMA_LOG`) | **KEEP** | Leave the schema alone. Run the read-only pre-flight checks before the first start: [Schema management (D8)](01-migration-path-and-decisions.md#d8). |
| Persisted `org.camunda.*` data | serialized variables, Spin type names, deployed scripts; no compatibility layer | **MUST** | Detect the data and decide what to do: [Variables with `org.camunda.*` objects (D18)](01-migration-path-and-decisions.md#d18). |
| BPMN/DMN namespace | `camunda:` and `operaton:` accepted, `activiti:` no longer | **KEEP** | Keep `camunda:` and convert later: [BPMN/DMN namespace (D3)](01-migration-path-and-decisions.md#d3). |
| Forms | Operaton Tasklist does not render `camunda-forms:` keys; `formRef` works on both | **SHOULD** | Decide who renders the forms: [Camunda Forms keys (D4)](01-migration-path-and-decisions.md#d4). |
| Logging, JMX | `org.camunda.*` → `org.operaton.*`; `ENGINE-xxxxx` codes unchanged | **SHOULD** | Rename logger names. The official recipe skips logback/log4j2 XML. |
| Tests | `camunda-bpm-assert` → `operaton-bpm-assert`, `camunda.cfg.xml` → `operaton.cfg.xml`, JUnit 6 on 2.x | **MUST** | Switch the test dependencies: [Test stack (D11)](01-migration-path-and-decisions.md#d11). |
| Spring Boot 4.0 | Operaton **2.1.5** is built with Spring Boot 4.0.8 (Camunda 7.24.3-ee to 7.24.9-ee use 4.0) | **MUST** | Target 2.1.5 (the `migrate.sh` default), then plan 2.2: [Target version (D1)](01-migration-path-and-decisions.md#d1). |
| Spring Boot 4.1 | Operaton **2.2.x** is built with Spring Boot 4.1 (GA due 2026-10-23); Camunda 7.24.10-ee and later use 4.1 | **MUST** | Target 2.2.0 once GA, rehearse with 2.2.0-RC1; 2.1.5 on 4.1 is unsupported: [Target version (D1)](01-migration-path-and-decisions.md#d1). |
| Jackson (EE) | Spring stays on Jackson 3; Spin, engine REST and external task client are Jackson 2 only; the `-jackson3` artifacts (7.24.16-ee) have no counterpart | **MUST** if you opted in | `migrate.sh` maps the artifacts back to Jackson 2. Port `tools.jackson.*` code for Spin, REST or the client by hand: [EE features (D17)](01-migration-path-and-decisions.md#d17). |
| Actuator health | `management.health.operaton.enabled`; DOWN when the DB is unreachable (2.1+) | **MUST** | Rename the key and use the engine check for readiness only: [Health probes (D13)](01-migration-path-and-decisions.md#d13). |
| EE security hardening (EE) | query-expression allow-list (7.24.7-ee), `validateAuthResourceIdExists` and the autocommit check (7.24.3-ee) have no counterpart | **MUST** (security) | Remove the EE-only settings, which stop the Operaton start, and mitigate: [EE features (D17)](01-migration-path-and-decisions.md#d17). |
| EE license (EE) | `camunda.bpm.license-file`, `camunda-license.txt` and the key in the database are not needed | **SHOULD** | The recipe deletes the property. Remove files, mounts and secrets; keep the key in the database for rollback: [EE features (D17)](01-migration-path-and-decisions.md#d17). |
| EE repository (EE) | `https://artifacts.camunda.com/artifactory/private/` → Maven Central | **SHOULD** | Keep access while the recipe runs, then remove the repository and its credentials: [EE features (D17)](01-migration-path-and-decisions.md#d17). |

## The 12 things that bite

Each of these problems slips past the recipe, and most of them also past the build: they show up at startup, at
runtime or in another system. Each item says what happens, how to avoid it and where to read more.

1. **The setup endpoint re-opens to anyone.** Camunda's webapps treat members of `camunda-admin` as administrators.
   Operaton hard-codes `operaton-admin`, and nothing migrates the group. On a migrated database with DB identity
   (users stored in the engine database), nobody is in `operaton-admin`, so the webapps treat the installation as new
   and an unauthenticated request can create an admin user. Setting `operaton.bpm.admin-user` to an existing user id
   does not fix this, because the engine skips users that already exist. Mirror the group (copy its members and
   authorizations to `operaton-admin`) before the first start, and block `<app-path>/api/admin/setup/*` at the ingress
   (`<app-path>` is your webapp path, for example `/camunda`). Decision:
   [Admin group (D5)](01-migration-path-and-decisions.md#d5). Details:
   [Identity, admin group and security](07-identity-admin-group-and-security.md).
2. **Old configuration is silently ignored.** Spring Boot ignores unknown keys, and Operaton has no alias for the old
   names. Leftover `camunda.bpm.*` keys, `CAMUNDA_BPM_*` environment variables and Helm values therefore change
   nothing, and the defaults take over: `schema-update: true`, webapp path `/operaton`, no admin user. The recipe only
   renames keys inside the repository, so rename the configuration outside it (Helm, CI variables, config server) by
   hand. Details: [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).
3. **`org.camunda.*` imports in scripts fail at runtime.** Scripts inside BPMN and DMN models are compiled only when a
   process reaches them. The deployment succeeds, and the failure comes later:
   `unable to resolve class org.camunda.spin.Spin`. Running instances on old process versions fail too, because each
   instance keeps the model version it started on and a fix in the repository does not reach it. These instances need
   instance migration (the Migration API moves them to the fixed version). Details:
   [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
4. **`camunda-admin` in a whitelist regex stops the start.** The engine checks every user, group and tenant id against
   a regular expression when it is saved. If a custom pattern still allows `camunda-admin` instead of `operaton-admin`,
   saving `operaton-admin` fails, typically at startup:
   `Group has an invalid id: 'operaton-admin' is not a valid resource identifier.` Put `operaton-admin` into the
   pattern. Details: [Identity, admin group and security](07-identity-admin-group-and-security.md).
5. **Liquibase re-runs the engine changelog.** This affects you if your application applies the engine schema with
   Liquibase. Liquibase identifies a change by id, author and file, and Operaton ships its changelog under a new path
   and author. Liquibase therefore runs it again and fails on existing tables or on the duplicate key `'1300'`.
   Details: [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md).
6. **JUnit 5 support is missing after the official recipe.** The engine's test helpers left the main jar, and the
   official recipe maps the test dependency to the empty `operaton-bpm-junit5`. Use
   `operaton-bpm-spring-boot-starter-test-junit5` instead; `migrate.sh` maps Camunda's `-4-test` starter to it. Also
   rename `camunda.cfg.xml` to `operaton.cfg.xml`: without it, tests silently run a default engine without your
   plugins and settings. Decision: [Test stack (D11)](01-migration-path-and-decisions.md#d11). Details:
   [Testing](10-testing.md).
7. **History exporters change their payload.** History exporters publish engine history events to other systems, such
   as Kafka. If the payload contains Java class names, those names become `org.operaton…`, and consumers that route or
   deserialize on them break without any build error. Make the consumer teams accept both prefixes before the
   cut-over. Decision: [History exporters (D9)](01-migration-path-and-decisions.md#d9). Details:
   [Engine plugins and history exporters](06-engine-plugins-and-history-exporters.md).
8. **The Tasklist may stop rendering Camunda Forms.** For Camunda Forms, the Operaton Tasklist recognizes only
   `operaton-forms:` keys. It shows tasks with `camunda-forms:` keys as an external form (this follows from the source
   code; it is untested in a browser). Use `formRef`, which works on both engines, and open one task per form on
   staging. Decision: [Camunda Forms keys (D4)](01-migration-path-and-decisions.md#d4). Details:
   [BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).
9. **The webapps move to `/operaton`.** Operaton's default webapp path is `/operaton` instead of `/camunda`. Bookmarks,
   ingress rules and SSO redirects then return 404, unless you set
   `operaton.bpm.webapp.application-path: /camunda`. Decision:
   [Webapp path (D6)](01-migration-path-and-decisions.md#d6). Details:
   [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md).
10. **The EE security hardening is gone.** Camunda added three hardening features in EE patches, and Operaton has
    none of them: the query-API expression allow-list (7.24.7-ee, on by default), `validateAuthResourceIdExists` and
    the datasource autocommit check (both 7.24.3-ee). Operaton behaves like Camunda before 7.24.7: stored task filters
    evaluate any expression, because `enableExpressionsInStoredQueries` defaults to true. Camunda security notice 157
    describes expression injection via such filters. The EE-only settings also break the migrated application: as
    generic properties they stop the engine start (unknown property), the Java calls no longer compile, and
    `operaton.bpm.authorization.validate-auth-resource-id-exists` is silently ignored. Remove them. Then set the
    generic property `enable-expressions-in-stored-queries: false`, unless your filters need expressions such as
    `${currentUser()}`; the pre-flight check P11 lists those filters. Keep ad-hoc query expressions off, and restrict
    who may create or update filters. Decision: [Camunda EE features (D17)](01-migration-path-and-decisions.md#d17).
    Details: [Identity, admin group and security](07-identity-admin-group-and-security.md).
11. **Spin, the engine REST API and the external task client stay on Jackson 2.** Spin is the engine's library for
    JSON and XML variables. Operaton 2.x has no Jackson 3 variant of it, of the REST API or of the client, while
    Spring Boot 4 gives your own code Jackson 3. On Spring Boot 4, `migrate.sh` renames your Spin configurators and
    runs no Jackson 3 step, so they stay on Jackson 2. If you opted into Camunda's `-jackson3` artifacts (7.24.16-ee),
    `migrate.sh` maps them back to the Jackson 2 artifacts, but code you wrote against `tools.jackson.*` for Spin, REST
    or the client does not compile until you port it to `com.fasterxml.jackson.*`. Never run the stock Spring Boot 4
    recipe (`UpgradeSpringBoot_4_0`) or `migrate.sh --hop 2` on Spin configurators: they rewrite them to Jackson 3 and
    drop module registrations, and compilation then fails with `incompatible types`. Details:
    [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md).
12. **Never rename `org.camunda.feel`.** Operaton still uses the Camunda FEEL engine (the expression language of DMN
    decisions) under its original package. A blanket rename of `org.camunda` breaks FEEL. Rename only
    `org.camunda.(bpm|spin|connect|commons|templateengines)`. Details: [OpenRewrite recipes](03-openrewrite-recipes.md).

## What does not change

Operaton uses the same database schema and the same stored formats as Camunda 7.24, so most of what runs today carries
over unchanged:

- Running instances, jobs, timers, incidents and history carry over. Job types, serializer names and password hashes
  are the same.
- Unchanged models create no new deployment.
- Extension points (engine plugins, history event handlers, incident handlers and so on) keep their names under
  `org.operaton`.
- Log message codes and metric names stay the same.
- Your Spring Boot 4 platform stays. `migrate.sh` never downgrades Spring Boot; at most it raises the patch version to
  the one your Operaton target is built with.
- You can keep using Camunda Modeler: [Modeler (D12)](01-migration-path-and-decisions.md#d12).
