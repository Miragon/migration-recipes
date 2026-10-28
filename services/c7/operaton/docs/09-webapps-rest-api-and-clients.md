# 09 · Webapps, REST API and clients

This chapter covers everything that users and other systems reach over HTTP: the webapps Cockpit, Tasklist and
Admin, their URLs and customizations, the REST API under `/engine-rest`, and the clients that call it. For Camunda
EE users, which includes every team on Spring Boot 4, it also covers the EE webapp features and the license. Ops
engineers need it for ingress, SSO and monitoring. Developers need it for custom UIs, workers and REST clients. Most
of it keeps working; the surprises are at the edges.

**In short**
- **The webapps move from `/camunda/…` to `/operaton/…` by default; `/engine-rest` stays.** Every bookmark, ingress
  rule and health check with `/camunda` breaks unless you set `operaton.bpm.webapp.application-path: /camunda`
  **explicitly** for the cut-over (see the [webapp-path decision, D6](01-migration-path-and-decisions.md#d6)).
- **Overlays (`config.js`, `user-styles.css`, plugins) under `webjars/camunda/` are silently ignored.** The webapps
  still look fine, but without your branding and plugins. Move them to `webjars/operaton/`.
- **REST paths are unchanged, but two responses changed:** `camundaFormRef` → `operatonFormRef`, and `GET /version`
  returns the Operaton version (`{"version":"2.1.5"}`). Clients that read the old field or check for `7.` break.
- **Camunda EE (Enterprise Edition) Cockpit features are gone without a build error; their REST APIs remain**
  (see the [Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)). Every Camunda 7.24 build
  on Spring Boot 4 is EE, so check whether yours uses the EE webapps. Operators who rely on these screens need a
  tested replacement before go-live.
- **Operaton needs no license.** Remove the license file, mounts and secrets, but keep the license key in the
  database, because the Camunda build needs it for a rollback.
- **With nobody in `operaton-admin`, the setup page creates an admin for unauthenticated callers.** Operaton treats
  only `operaton-admin` as the admin group, so the webapps think this is a fresh installation. Migrate the
  admin group before the first start ([Identity, admin group and security](07-identity-admin-group-and-security.md));
  [`scripts/smoke-test.sh`](../scripts/smoke-test.sh) checks that the page is closed.

## What to do

1. **Set `operaton.bpm.webapp.application-path`** (or `OPERATON_BPM_WEBAPP_APPLICATION_PATH`), because
   `CAMUNDA_BPM_WEBAPP_APPLICATION_PATH` is ignored and the webapps would silently move to `/operaton`.
2. **List every place that contains the path** ([below](#everything-that-contains-the-path)), so that nothing points
   to a dead URL when the path changes.
3. **Move the overlays:**
   `git mv src/main/resources/META-INF/resources/webjars/camunda src/main/resources/META-INF/resources/webjars/operaton`.
   Delete a `webjar-classpath` key pointing to `webjars/camunda`
   ([`verify-leftovers.sh`](../scripts/verify-leftovers.sh) flags both). Otherwise your customizations disappear
   without an error.
4. **Flush persisted sessions** (Spring Session or replicated sessions) at the cut-over. Session attributes are
   renamed, so old sessions cannot be used, and users log in again.
5. **Open one task per form type in the Operaton Tasklist on staging.** It is the cheapest test for unrendered
   `camunda-forms:` keys, a forgotten overlay and a broken embedded form.
6. **Inventory EE usage**, and put tested REST replacements into the
   [cut-over runbook](../checklists/cutover-runbook.md), so that operators have them on day one. Remove the
   [license](#license) supply (file, mounts, secrets, API calls), because Operaton needs none, and keep the key rows
   in the database for a rollback.
7. **Search clients and pipelines for `camundaFormRef`, `/version` and `/camunda/api/`**, and regenerate OpenAPI
   clients, so that no client reads the old field, expects a `7.` version or calls the webapps' internal API under
   the old path.
8. **Smoke-test `/engine-rest` authentication** (`401` without credentials) **and every worker on staging**, because a
   leftover provider class name can leave the REST API without authentication.

## Webapp path

The webapp path is the URL prefix of Cockpit, Tasklist and Admin. Camunda uses `/camunda`, Operaton defaults to
`/operaton`. Doing nothing therefore moves every webapp URL in the same window as the engine switch.

The **webapp-path decision** ([D6 · Webapp path](01-migration-path-and-decisions.md#d6)) recommends: keep `/camunda`
for the cut-over release, move to `/operaton` later with a redirect. Then nothing changes for users, ingress, WAF,
identity provider, health checks and runbooks in the cut-over window. Write the key down even though it equals the
old default, because a lost key silently moves you to `/operaton`.

```yaml
operaton:
  bpm:
    webapp:
      application-path: /camunda      # explicit: the default is /operaton now
```

For the later move, use
[`LegacyWebappPathRedirectFilter`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/LegacyWebappPathRedirectFilter.java)
from the migrated example (off by default). It keeps old bookmarks and links working:

- It redirects only `GET`/`HEAD`. Other methods pass through and get a 404, because a redirect would silently drop
  the request body. Change those clients instead.
- It keeps the query string. Browsers re-apply `#/…` fragments themselves, so deep links keep working.
- It refuses to start on a redirect loop.

```yaml
operaton.bpm.webapp.application-path: /operaton
orders.migration.legacy-webapp-redirect:
  enabled: true
  legacy-path: /camunda
  status: 302            # 301 once the move is final
```

### Everything that contains the path

Whichever option you pick, the path also lives outside the application. The table lists where to look and what to
change, so that you can change everything in one go:

| Where | What to change |
|---|---|
| Ingress, proxy, WAF, allow-lists | `/camunda/app/`, `/camunda/api/` rules (incl. the setup-endpoint block); add new rules **before** switching |
| IdP clients (Keycloak, Entra ID, Okta) | redirect URIs and web origins with `/camunda/` |
| Health checks | `HEALTHCHECK … /camunda/app/welcome/default/`; prefer `/actuator/health/readiness` |
| Generated links | derive from `OperatonBpmProperties`, as [`WebappLinks.java`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/config/WebappLinks.java) does |
| Scripts on `/camunda/api/…` | move to `/engine-rest` with real REST authentication |
| CSRF entry points, CSP, dashboards, bookmarks | values containing `/camunda/` |

## Customizations

You customize the webapps by putting your own files on the classpath at the webjar's location; your files win over
the defaults. That location moved from `webjars/camunda` to `webjars/operaton`. Files left in the old place are
ignored without an error: Operaton serves its defaults, and the webapps look fine, just without your changes.

- **Overlays** under `META-INF/resources/webjars/operaton/app/<app>/scripts/config.js` and
  `…/styles/user-styles.css` replace the defaults. Check that your file is served, not the default:
  `curl -s http://localhost:8080/camunda/app/cockpit/scripts/config.js | head -5`.
- **`config.js` and frontend plugins**: options and plugin API are unchanged. Build URLs from
  `render(node, { api })` (`api.engineApi`, `api.CSRFToken`), never from `'/camunda/api/…'`. The `api` values follow
  the webapp path. A hard-coded path breaks when the path moves. Camunda 7.24.10-ee moved its webapps to jQuery 4.0.0
  and jQuery UI 1.14.2, without jquery-migrate. Operaton's webapps come from the CE code base, so do not assume the
  same library versions: test each frontend plugin in the Operaton webapps.
- **Java plugins**: the recipe renames SPI interfaces, service files and base classes. MyBatis
  `<include refid="org.camunda.bpm.engine.impl.persistence.entity.…"/>` is **manual**, because the recipe does not
  change XML text: `grep -rn 'org\.camunda\.bpm\.engine\.impl\.persistence' --include='*.xml' src/`.
- **Embedded forms** (`cam-*`, `camForm`, `CamSDK`), CSRF cookie/header and `JSESSIONID` are unchanged.

## Forms in Tasklist

Tasks whose Camunda Form is bound with a `camunda-forms:` key need a change if people work them in the Tasklist. The
engine still resolves `camunda-forms:` keys, but the Operaton Tasklist only recognizes `operaton-forms:` and treats
`camunda-forms:` as an external form (untested in a browser). Switch these tasks to one of these bindings:

- `formRef`: rollback-safe, because Camunda 7.24 renders it too.
- `operaton-forms:`: a rollback hard stop while tasks are open, because Camunda cannot load these forms. A hard stop
  is data that only Operaton can use. While it exists, you cannot simply start the Camunda build again on the same
  database ([rollback details](08-database-schema-data-and-sql-scripts.md#rollback-on-the-same-database-d15)).

Background: the [Camunda Forms keys decision (D4)](01-migration-path-and-decisions.md#d4) and
[BPMN, DMN, forms and scripts](05-bpmn-dmn-forms-and-scripts.md).

## Camunda EE features

Camunda 7.24 on Spring Boot 4 exists only in the Enterprise Edition (EE), so if you are on Spring Boot 4, check
whether your build uses the EE webapps (`-webapp-ee` artifacts). Operaton is a fork of Camunda 7 CE (Community Edition), so its
webapps have the CE scope. After the switch, the EE screens in Cockpit are missing, and the build does not tell you.
The engine API behind these screens was never EE-only, so REST calls can replace each of them.

The **Camunda EE features decision** ([D17 · Camunda EE features](01-migration-path-and-decisions.md#d17)) is
mandatory for every EE user. For the webapps it recommends: inventory usage and test a replacement for each feature
before go-live. The decision also covers the [license](#license), Optimize, the Jackson 3 opt-in, the EE repository
and the [EE security hardening](07-identity-admin-group-and-security.md#camunda-ee-security-hardening-that-operaton-lacks)
that Operaton lacks.

### What happens to the webapp artifacts

The conversion turns the EE webapp artifacts into the CE ones, without a build error, and maps Camunda's Spring
Boot 4 webapp starters to Operaton's. Operaton artifacts have no `-4` infix: there is one set of starters per Operaton
line, and the 2.x starters are the Spring Boot 4 ones. Their versions come from `operaton-bom`. The table shows the
webapp artifacts and what maps them:

| Camunda artifact | Operaton artifact | Mapped by |
|---|---|---|
| `camunda-bpm-spring-boot-starter-4-webapp-ee` | `operaton-bpm-spring-boot-starter-webapp` | `migrate.sh` (Spring Boot 4 path) |
| `camunda-bpm-spring-boot-starter-4-webapp` | `operaton-bpm-spring-boot-starter-webapp` | `migrate.sh` (Spring Boot 4 path) |
| `camunda-bpm-spring-boot-starter-4-webapp-core`, `camunda-bpm-spring-boot-starter-webapp-core` | `operaton-bpm-spring-boot-starter-webapp-core` | `migrate.sh` (Spring Boot 4 path) |
| `camunda-bpm-spring-boot-starter-webapp-ee` (no `-4`) | `operaton-bpm-spring-boot-starter-webapp` | official recipe (part of the `migrate.sh` run) |
| `camunda-webapp-webjar-ee` | `org.operaton.bpm.webapp:operaton-webapp-webjar` | official recipe (part of the `migrate.sh` run) |

`scripts/verify-leftovers.sh` fails on any EE artifact left behind (rule `EE_ARTIFACT`), and `scripts/assess.sh`
reports the EE webapps it finds. The full artifact mapping is in [OpenRewrite recipes](03-openrewrite-recipes.md).

### Replace the EE screens

Most EE actions write the user operation log with the user id, so query `act_hi_op_log` (`operation_type_`,
`user_id_`, last 90 days) to see who used what, then ask them. The table lists a REST replacement for each EE
feature:

| EE feature | REST replacement |
|---|---|
| History view, heatmap | `GET /history/process-instance`, `/history/process-definition/{id}/statistics` |
| Instance modification | `POST /process-instance/{id}/modification`, `/modification/executeAsync` |
| Migration UI | `POST /migration/generate`, `/migration/executeAsync` |
| Restart | `POST /process-definition/{id}/restart-async` |
| Batch page | `POST /process-instance/delete`, `/job/retries`, `GET /batch` |
| Reports, cleanup page | `GET /history/process-instance/report`, `POST /history/cleanup` |

Community plugins: [`datakurre/operaton-cockpit-plugins`](https://github.com/datakurre/operaton-cockpit-plugins).
Optimize, Camunda's EE analytics product, is not supported
([Camunda Optimize](06-engine-plugins-and-history-exporters.md#camunda-optimize)).

### License

Operaton needs no license. Camunda stores the license key in the database, and Camunda states that "the license
mechanism has no impact on the engine or other runtime components". Remove everything that supplies the license,
but leave the key in the database alone:

- **Configuration and files:** the recipe deletes `camunda.bpm.license-file`. Remove the other places Camunda reads
  the license from (`camunda-license.txt` on the classpath, `${user.home}/.camunda/license.txt`), license mounts,
  secrets and `*_BPM_LICENSE_FILE` environment variables.
- **API calls:** `ManagementService#setLicenseKey`, `getLicenseKey` and `deleteLicenseKey` do not exist in Operaton,
  so code that calls them does not compile. Delete it.
- **Admin webapp:** the EE license page is gone.
- **Database:** the key lives in `ACT_GE_BYTEARRAY` (resource `camunda-license-key`), referenced by the
  `ACT_GE_PROPERTY` row `camunda-license-key-id`. Operaton ignores these rows. **Keep them**, because a rollback
  (starting the last Camunda build again on the same database) needs them.

`scripts/verify-leftovers.sh` reports license leftovers with the rule `EE_LICENSE`. A license API call in code fails
the scan; license files, properties, environment variables and key text are warnings, which you decide on, fix or
allow-list.

## webapps-neo

**webapps-neo** is the new webapp implementation in Operaton 2.2: a technical preview, off by default. Its starters
(`operaton-bpm-spring-boot-starter-webapp-neo`, `-webapp-neo-core`) exist only from Operaton 2.2 on. It has its own
plugin system and does **not** render embedded HTML forms. Stay on the classic webapps for the migration (see the
[webapps decision, D16](01-migration-path-and-decisions.md#d16)).

## REST API

The REST API keeps its paths, so most clients keep working. A few response fields and the reported version changed,
and the authentication setup has one trap.

- **Unchanged:** the `/engine-rest` base path, all 305 paths and the error shape.
- **`operatonFormRef`** replaces `camundaFormRef` in `TaskDto` and `FormDto`, without alias: clients reading the old
  field get `null` and show no form. Read `task.operatonFormRef ?? task.camundaFormRef` during the transition.
- **`GET /version`** returns the Operaton version instead of Camunda's. Client checks for a `7.` version break.
- **OpenAPI:** regenerate clients from `org.operaton.bpm:operaton-engine-rest-openapi` (only the starter-pack recipe
  maps it), so that generated models contain `operatonFormRef`.
- **Jackson 3 opt-in:** Operaton's REST API is Jackson 2 only. If your build used Camunda's
  `camunda-bpm-spring-boot-starter-4-rest-jackson3` or `camunda-engine-rest(-core)-jakarta-jackson3` (7.24.16-ee),
  `migrate.sh` maps them to the Jackson 2 artifacts. Camunda states that the REST API writes the same JSON with both
  Jackson versions. Code that customizes the REST mapper with `tools.jackson.*` must be ported to
  `com.fasterxml.jackson.*` ([Coming from Camunda's Jackson 3 opt-in](12-operaton-2-and-spring-boot-4.md#coming-from-camundas-jackson-3-opt-in)).
- **Authentication:** the REST starter does not secure the API. If you register the engine's authentication filter,
  register its provider as a class literal:

```java
// registration = new FilterRegistrationBean<>(new ProcessEngineAuthenticationFilter())
registration.addInitParameter(ProcessEngineAuthenticationFilter.AUTHENTICATION_PROVIDER_PARAM,
    org.operaton.bpm.engine.rest.security.auth.impl.HttpBasicAuthenticationProvider.class.getName());
```

> [!WARNING]
> A provider given as the string `"org.camunda.bpm.engine.rest.security.auth.impl.HttpBasicAuthenticationProvider"`
> survives the recipe, because the recipe changes types and imports, not string literals. On Operaton the start
> fails or `/engine-rest` runs **without authentication**. [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh)
> finds such literals; keep a smoke test that expects `401` for `GET /engine-rest/task`.

If you use the OAuth2 starter, note that its security filter chain permits `/engine-rest/**`. Order your own chain
before it, or the REST API stays open. Details:
[Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md).

## Clients and tools

Clients talk HTTP to `/engine-rest`, so they keep working as long as topics, variables and authentication stay the
same. Only the Java client changes its coordinates. The table shows what to do per client type:

| Client | Status |
|---|---|
| Java workers | `org.operaton.bpm:operaton-external-task-client` (Jackson 2), prefix `operaton.bpm.client.*` ([Spring Boot configuration](04-spring-boot-dependencies-and-configuration.md)) |
| JavaScript | keep `camunda-external-task-client-js`; `operaton-external-task-client-js` does not exist on npm |
| Python | Camunda client keeps working; community: `operaton-tasks`, `operaton-external-task-client-python3` |
| Camunda Modeler | keeps deploying via `/engine-rest/deployment/create`; try one deployment on staging |

The Java client has no Jackson 3 variant in Operaton, so `migrate.sh` maps Camunda's
`camunda-external-task-client-jackson3` (7.24.16-ee) to `operaton-external-task-client`. Test fetch-and-lock,
complete, `handleFailure` and `handleBpmnError` per worker against the migrated engine on staging. Details:
[Testing](10-testing.md).

**`operaton-mcp`** (npm 1.1.0) is an MCP (Model Context Protocol) server that lets an AI assistant query
`/engine-rest`. 1.1.0 silently ignores `OPERATON_GUARD=read-only`, so write tools stay available. Use it only on a
throw-away copy with a read-only technical user and `operaton.bpm.authorization.enabled: true` (without
authorization checks, every authenticated user may do everything); never against production or a shared database.

## Watch out

Each item names what you see, its cause and the fix.

- **Symptom:** bookmarks and health checks return 404.
  **Cause:** the path key was not renamed, so the webapps moved to `/operaton`.
  **Fix:** set `application-path: /camunda`.
- **Symptom:** logo, CSS or Cockpit plugin gone.
  **Cause:** the overlays are still under `webjars/camunda/`.
  **Fix:** `git mv` them to `webjars/operaton/`.
- **Symptom:** users logged out, session deserialization errors.
  **Cause:** old session attributes in the session store.
  **Fix:** flush the store.
- **Symptom:** a custom task UI shows an empty form.
  **Cause:** it reads `camundaFormRef`.
  **Fix:** read `operatonFormRef`.
- **Symptom:** `POST /camunda/api/…` gets 404 with the redirect on.
  **Cause:** the redirect covers only `GET` and `HEAD`, by design.
  **Fix:** use `/engine-rest`.
- **Symptom:** Cockpit has no heatmap, migration UI or batch page after the switch, although the build was green.
  **Cause:** the conversion mapped the EE webapp to the CE webapp.
  **Fix:** use the [REST replacements](#replace-the-ee-screens), planned before go-live under the Camunda EE features
  decision (D17).
- **Symptom:** `cannot find symbol` on `setLicenseKey`, `getLicenseKey` or `deleteLicenseKey`.
  **Cause:** Operaton has no license API.
  **Fix:** delete the calls ([License](#license)).
