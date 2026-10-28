# 07 · Identity, admin group and security

This chapter explains who is an administrator after the switch to Operaton, the security hole that opens if nobody
is, and what changes for LDAP, Keycloak and OAuth2. It also covers the security hardening of Camunda EE (Enterprise
Edition) that Operaton does not have, which concerns every team on Spring Boot 4, because Camunda 7.24 on Spring
Boot 4 is always EE. Read it before the first Operaton start on any database with real users. It concerns the DBA and
security, who own the admin-group decision and the EE hardening, and ops, who configure the ingress.

**In short**
- **Operaton's built-in admin group is `operaton-admin`** (`Groups.OPERATON_ADMIN`), not `camunda-admin`. Nothing
  migrates existing memberships or authorizations; the official recipe (Operaton's automated OpenRewrite code
  conversion) only rewrites the Java constant. After the switch, your Camunda administrators are therefore no longer
  administrators.
- **With users stored in the engine database (DB identity) and nobody in `operaton-admin`, the Admin webapp's
  "create initial admin user" endpoint is open to unauthenticated users.** The webapps think this is a fresh
  installation, so anyone who can reach them can create an administrator without logging in.
- **Close it before the first Operaton start** by mirroring the admin group, i.e. copying the members and
  authorizations of `camunda-admin` to `operaton-admin`. Use
  [`sql/postgresql/10-migrate-admin-group.sql`](../sql/postgresql/10-migrate-admin-group.sql) and/or
  [`AdminGroupMigrationPlugin`](../examples/operaton-spring-boot-migrated/src/main/java/com/example/orders/migration/AdminGroupMigrationPlugin.java).
  `operaton.bpm.admin-user` does not help for existing users, because it skips users that already exist.
- **Verify with the non-mutating check** in [`scripts/smoke-test.sh`](../scripts/smoke-test.sh). Never `POST` to the
  setup endpoint on production: if setup is open, the `POST` creates an administrator.
- **LDAP, Keycloak and OAuth2 have no setup hole while they are active.** But admin rights follow group names, and
  the Keycloak `use*AsCamunda*` keys were renamed.
- **Coming from Camunda EE, you lose security hardening, and Operaton does not warn you.** Operaton has no
  allow-list for expressions in task queries (Camunda 7.24.7-ee), no `validateAuthResourceIdExists` and no datasource
  autocommit check (both 7.24.3-ee). With Operaton's defaults, stored task filters evaluate any expression, as in
  Camunda 7.24.6 and older. Switch expressions in stored queries off, or restrict who may create and update filters.
- **EE-only settings break the first start or the build, or are silently ignored.** As generic properties they stop
  the Operaton start, as Java calls they do not compile, and one Spring Boot key is silently ignored. Remove them
  before the first start.

The **admin-group decision** ([D5](01-migration-path-and-decisions.md#d5)) is mandatory. Its recommendation: mirror
`camunda-admin` to `operaton-admin` before the first start. The **Camunda EE features decision**
([D17](01-migration-path-and-decisions.md#d17)) is mandatory for every EE user and covers the
[EE hardening](#camunda-ee-security-hardening-that-operaton-lacks).

> [!WARNING]
> On a migrated database with DB identity, the first Operaton start exposes an unauthenticated
> `POST <app-path>/api/admin/setup/default/user/create` that creates a user in `operaton-admin` with GRANT `ALL`
> on every resource. Anyone who reaches the webapp owns the engine.

## What to do

1. **Take inventory.** Section P03 of [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql) (the
   read-only pre-flight gate that ends in `GO`, `GO_WITH_WARNINGS` or `NO_GO`) lists the members and grants of both
   groups. Find `camunda-admin` literals with [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh), and grep
   your deployment repos too (whitelist regexes, Helm, env vars, ops SQL, tests, IdP groups). This shows you
   everything that depends on the group name.
2. **Decide the admin-group option per environment** (see [Admin group options](#admin-group-options-d5)). If you
   override the [id whitelist](#the-resource-id-whitelist), fix it, because an old pattern blocks every save of
   `operaton-admin`.
3. **Coming from Camunda EE, deal with the missing EE hardening before the first Operaton start**
   (see [Camunda EE security hardening that Operaton lacks](#camunda-ee-security-hardening-that-operaton-lacks)).
   Remove the EE-only settings and calls, because they stop the start or the build. Then run the pre-flight check
   for stored filters with expressions (P11) on a production copy (a restored copy of the production database, never
   the live one). Based on the filters it lists, decide whether you switch expressions in stored queries off or
   restrict who may create and update filters.
4. **At the cut-over, close the hole before any user can reach Operaton:**
   1. Block the setup path at the ingress, so that it stays unreachable even if a later step fails.
   2. Stop Camunda.
   3. Take the backup.
   4. Run `10-migrate-admin-group.sql`.
   5. Run `00-preflight-checks.sql`. The result must not be `NO_GO`.
   6. Start the first Operaton node without user traffic.
   7. Run the [non-mutating check](#reproduce-it-on-a-staging-copy-never-on-production).
   8. Open traffic.
5. **Keep** the `camunda-admin` rows until the rollback window closes (see the decision on rollback and point of no
   return, [D15](01-migration-path-and-decisions.md#d15)). Camunda needs them for a rollback. Then delete them with
   the commented section at the end of `10-…sql`.
6. **After go-live**, keep the check in synthetic monitoring, so that you notice if the setup page ever opens again.

## The setup endpoint re-opens (security finding)

The Admin webapp has a setup page for fresh installations: it lets the first visitor create an administrator without
logging in. The webapps treat "writable identity service **and** nobody in `operaton-admin`" as a fresh
installation. Requests to the Admin webapp then redirect to the setup page, and the setup `POST` needs no login.

On a migrated database, the second condition is true at first: Operaton only treats `operaton-admin` as the admin
group, and nothing copies your `camunda-admin` members into it. The mechanism itself is not new: Camunda 7 behaves
the same way with an empty `camunda-admin`. What is new is that the migration leaves the admin group empty.
In the starter pack's trial, the setup `POST` returned 204 on a migrated database; Camunda returned 403.

**Who is exposed:** applications with DB identity and the webapps deployed. Anyone who can reach the webapp URL can
create an administrator with full rights.

**Who is not exposed:**
- REST-only apps, because they have no webapps.
- LDAP and Keycloak, because their identity service is read-only.
- The OAuth2 security starter with client registrations, because login is required (untested; check anyway).
- Any database with an `operaton-admin` member.

**How to close and verify it:** give `operaton-admin` at least one member before the webapps are reachable (see
[Admin group options](#admin-group-options-d5)), block the setup path at the ingress (see
[Network hardening](#network-hardening-during-the-cut-over)), and prove that the page is closed with a
[non-mutating check](#reproduce-it-on-a-staging-copy-never-on-production).

## Admin group options (D5)

The table shows which option gives `operaton-admin` at least one member and so closes the hole. Details for each
option follow.

| Option | Closes the setup hole? |
|---|---|
| **A · SQL** (`10-migrate-admin-group.sql`) | **Yes**, from the first start, if `camunda-admin` has members |
| **B · Plugin** (`AdminGroupMigrationPlugin`) | **Yes**, if `camunda-admin` has members |
| C · `AdministratorAuthorizationPlugin(operaton-admin)` | No (adds no members) |
| D · Keep `camunda-admin` as admin group | **No**: the setup check hard-codes `operaton-admin` |
| E · External identity | n/a |

- **A · SQL:** `10-migrate-admin-group.sql` creates `operaton-admin` and mirrors the members, the authorizations held
  by and on `camunda-admin` (GRANT and REVOKE) and the tenant memberships. It runs in one transaction, never changes
  `camunda-admin` rows, is idempotent, and exits with code 3 on any mismatch. It is harmless for a running Camunda
  7.24, which ignores `operaton-admin`, so rehearse it on production early. Never rename the group with an `UPDATE`:
  that breaks the rollback, because Camunda still needs `camunda-admin`.
- **B · Plugin:** `AdminGroupMigrationPlugin` mirrors the members and the authorizations held by `camunda-admin` on
  every start, before the web server accepts requests. It is switched by `orders.migration.admin-group.enabled`
  (default `true`). With an empty `camunda-admin` it only logs a WARN, and the hole stays open. It uses internal
  engine classes, so keep
  [`AdminGroupMigrationPluginTest`](../examples/operaton-spring-boot-migrated/src/test/java/com/example/orders/migration/AdminGroupMigrationPluginTest.java)
  in your build.
- **C · `AdministratorAuthorizationPlugin(operaton-admin)`:** adds the group to `adminGroups` and keeps its `ALL`
  grants complete (authorization enabled only). It adds no members, so on its own it does not close the hole.
- **D · Keep `camunda-admin` as admin group:** `AdministratorAuthorizationPlugin` with
  `administratorGroupName = "camunda-admin"`. Your former admins keep their admin rights, but the setup check
  hard-codes `operaton-admin`, so the hole stays open.
- **E · External identity:** map the admin group in LDAP/Keycloak/OAuth2.

**Recommendation:**
- **DB identity:** use **A and/or B before the first start**. Both is best: A as a step in the runbook, B as a
  safety net in every environment. Add **C** if authorization is enabled. Use **D** only as a short transition aid
  next to A or B.
- **External identity:** use **E**.

<a id="reproduce-it-on-a-staging-copy-never-on-production"></a>

## Verify safely

Before you open traffic, prove that the setup page is closed. Use only checks that cannot change anything: a `GET`
that shows whether the Admin webapp redirects to the setup page, and a count of `operaton-admin` members.

```bash
BASE=https://orders.example.com; APP=/operaton    # operaton.bpm.webapp.application-path
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$BASE$APP/app/admin/default/"
#   open: 302 …/app/admin/default/setup/#/setup      closed: 200
```

```sql
select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin';   -- must be >= 1 before traffic
```

`scripts/smoke-test.sh` runs this `GET` check and never `POST`s to setup.

**Never test with a `POST` on production.** A `POST` is no reliable test, and it can do harm:
- **A bare 403 on the setup `POST` proves nothing.** Without a valid `XSRF-TOKEN` cookie and `X-XSRF-TOKEN` header,
  the CSRF filter answers 403 even while setup is open, and so does an ingress block.
- Only the body `Setup action not available` proves that setup is closed. To get that far, the `POST` must pass the
  CSRF check, and if setup is open, it then creates an administrator. A `POST` probe therefore belongs on a
  throw-away database copy only.

If the check finds setup open on production, treat it as an incident: audit the `operaton-admin` members,
`ACT_ID_USER` and `ACT_HI_OP_LOG`, because someone may already have created an administrator.

## Network hardening during the cut-over

Blocking the setup path at the ingress keeps the endpoint unreachable even if the admin-group step fails or is
forgotten. Setup is never legitimate on a migrated installation, so keep the block permanently. The check
(`GET <app-path>/app/admin/…`) still works through the block, because the block covers only the setup API:

```nginx
location ^~ /operaton/api/admin/setup/ { return 403; }   # your application-path (also /camunda/ if kept)
```

Without an ingress, a servlet filter returning 403 on `<app-path>/api/admin/setup/*` does the same. Keep
Cockpit/Admin behind SSO or VPN.

## The resource id whitelist

Operaton checks user, group and tenant ids against a regex on every save (create **and** update). If you configured
your own pattern on Camunda, it can block the admin-group fix itself. The default is `[a-zA-Z0-9]+|operaton-admin`
(Camunda: `…|camunda-admin`). The recipe renames the property key, not the regex. A custom pattern that still says
`camunda-admin` makes every save of `operaton-admin` fail, typically at startup (admin-user bootstrap,
`AdminGroupMigrationPlugin` from option B, your init code):

```text
Group has an invalid id: 'operaton-admin' is not a valid resource identifier.
```

**Fix:** `groupResourceWhitelistPattern: "[a-zA-Z0-9]+|operaton-admin|order-ops"`. This pattern **replaces** the
general one for groups, so include `operaton-admin` yourself and list extra ids explicitly. Editing the old group
then fails with `Group has an invalid id: 'camunda-admin' …`. Don't edit it, or add `|camunda-admin` temporarily.

## `operaton.bpm.admin-user` on an existing database

The starter can create an initial admin user from `operaton.bpm.admin-user`. On a migrated database it does not make
existing users admins:

- **Existing user id:** nothing happens (DEBUG log `Skip creating initial Admin User, user does exist`).
- **New id** (e.g. `opsadmin`): the user becomes the only `operaton-admin` member and closes the hole. This is
  acceptable as a break-glass (emergency) account with the password in a secret.
- `CAMUNDA_BPM_ADMIN_USER_ID` is ignored; only `OPERATON_BPM_ADMIN_USER_ID` binds. Never set `admin-user` with the
  Keycloak plugin.

## LDAP, Keycloak and OAuth2 specifics

With an external identity provider, the setup hole stays closed while the provider is active. The risks are
different: admin rights follow group names, renamed keys are silently ignored, and a provider that silently fails to
load drops the engine back to DB identity, setup hole included.

### LDAP

Use `org.operaton.bpm.identity:operaton-identity-ldap`; the setters are the same. Prefix strings in Java glue code
(`@ConfigurationProperties(prefix = "camunda.bpm.ldap")`, `@ConditionalOnProperty`) are not rewritten by the
official recipe. `migrate.sh`'s `PreFixes` does rewrite them, but verify it:
- With the condition, the plugin bean silently disappears and the engine falls back to DB identity, setup hole
  included.
- Without it, the plugin starts with empty settings.

Grep Java for `"camunda.bpm.`.

### Keycloak (`camunda-platform-7-keycloak` → `operaton-keycloak`)

- Use `org.operaton.bpm.extension:operaton-keycloak` 2.1.0 (Operaton 2.1). The recipe maps only the main artifact,
  and only to 1.0.x: fix the version and `-jwt`, `-all`, `-run` by hand.
- Some keys were renamed, and the old ones are silently ignored: `useEmailAsCamundaUserId` →
  `useEmailAsOperatonUserId`, `useUsernameAsCamundaUserId` → `useUsernameAsOperatonUserId`,
  `useGroupPathAsCamundaGroupId` → `useGroupPathAsOperatonGroupId`. A forgotten user-id key makes user ids switch to
  Keycloak UUIDs. User authorizations, assignees and filter owners then stop matching, and nothing fails at startup.
- `administratorGroupName` is unchanged: keep `camunda-admin`, or rename the realm group to `operaton-admin`.

### OAuth2 / OIDC

Use `operaton-bpm-spring-boot-starter-security` (it replaces Camunda's `camunda-bpm-spring-boot-starter-4-security`),
with properties under `operaton.bpm.oauth2.*`. An authority
`camunda-admin` is not an admin: rename it at the IdP, map it in a `GrantedAuthoritiesMapper`, or use
`AdministratorAuthorizationPlugin`. Stale class names in `spring.autoconfigure.exclude` are silently ignored. The
starter's security chain does not cover `/engine-rest` (see
[Webapps, REST API and clients](09-webapps-rest-api-and-clients.md)).

## Camunda EE security hardening that Operaton lacks

Several Camunda 7.24 EE patch releases added security hardening that Operaton does not have, because Operaton is a
fork of Camunda 7 CE (Community Edition). The section concerns every EE team. That includes every team on Spring
Boot 4, because Camunda 7.24 on Spring Boot 4 exists only as EE (from 7.24.3-ee on). After the switch the
protections are simply gone: nothing fails, and nothing logs a warning. The section belongs to the **Camunda EE
features decision** ([D17](01-migration-path-and-decisions.md#d17)), which is mandatory for every EE user.

The table lists what is missing and what takes its place:

| Camunda EE hardening | Since | On Operaton | What you do |
|---|---|---|---|
| Allow-list for expressions in task queries | 7.24.7-ee | missing (only on/off switches) | [switch expressions off or restrict filter permissions](#expressions-in-task-queries-security-notice-157) |
| `validateAuthResourceIdExists` | 7.24.3-ee | missing | validate user and group ids in your own code |
| Datasource autocommit check | 7.24.3-ee | missing | keep `spring.datasource.hikari.auto-commit: false` |

### Expressions in task queries (security notice 157)

Task queries may contain expressions, for example `${currentUser()}` for "tasks assigned to me". There are two kinds
of task queries:

- A **stored query** is a saved task filter, created in the Tasklist or through the REST API (`/filter`). The engine
  keeps its query, expressions included, in `ACT_RU_FILTER` and evaluates the expressions whenever someone lists or
  counts the filter's tasks.
- An **ad-hoc query** is sent directly, through REST (`/task`, `/task/count`) or the Java `TaskQuery` API.

Camunda security notice 157 (2026-04-10) describes expression injection through stored task filters and ad-hoc task
queries. According to the notice, it can lead to remote code execution and to privilege escalation across users. It
affects Camunda 7.24.6 and older when `enableExpressionsInStoredQueries` is true (the default) and a user may update
filters, or when `enableExpressionsInAdhocQueries` is true. Camunda fixed it in 7.24.7-ee with an allow-list that is
on by default (`queryExpressionAllowListEnabled`). It lets the built-in functions `now()`, `dateTime()`,
`currentUser()` and `currentUserGroups()` through, and blocks bean references, other functions and property access
unless you allow them (`allowedExpressionFunctionsInQueries`, `allowedExpressionBeansInQueries`,
`allowedExpressionPropertiesInQueries`, or your own `QueryExpressionValidator`).

**Operaton has no allow-list.** It keeps the two switches that Camunda 7 CE already had, and each one allows either
every expression or none. The table shows their defaults:

| Generic property | Operaton default | Effect of the default |
|---|---|---|
| `enable-expressions-in-adhoc-queries` (`enableExpressionsInAdhocQueries`) | `false` | ad-hoc queries with expressions are rejected |
| `enable-expressions-in-stored-queries` (`enableExpressionsInStoredQueries`) | **`true`** | stored filters evaluate **any** expression |

With these defaults, Operaton behaves like Camunda 7.24.6 and older. Operaton has published no advisory about it.
This guide has not tested an exploit against Operaton; the statement rests on the code, which has the same switches
and defaults as Camunda before 7.24.7. Camunda 7.24.0 CE has the same switches and defaults, so teams coming from CE
lose nothing here, but the mitigation applies to them as well.

**Mitigate it before the first Operaton start:**

1. **Find the stored filters that use expressions.** Run
   [`00-preflight-checks.sql`](../sql/postgresql/00-preflight-checks.sql) on a production copy. Its check P11 lists
   every such filter with its id, name, owner and expressions, and the summary row repeats the count as
   `filters_with_expressions`. P11 is informational: it never changes the `GO`/`NO_GO` verdict.
2. **If P11 returns no rows, switch expressions in stored queries off.** No filter needs them, so nothing breaks:

   ```yaml
   operaton:
     bpm:
       generic-properties:
         properties:
           enable-expressions-in-stored-queries: false
           enable-expressions-in-adhoc-queries: false   # the default; keep it
   ```

3. **If P11 returns rows, choose one of two options.** Expect rows, because typical Tasklist filters such as
   "My Tasks" use `${currentUser()}`.
   - Rewrite the listed filters without expressions, then switch expressions off as in step 2. A filter that still
     contains an expression then fails when it is listed or counted, with
     `Expressions are forbidden in stored queries`.
   - Keep the switch on, and restrict who may create and update filters. These are the authorizations on the
     resource Filter (resource type 5 in `ACT_RU_AUTHORIZATION`), which you manage in the Admin webapp.
     Authorizations only take effect with `operaton.bpm.authorization.enabled: true`.

### Authorization references (`validateAuthResourceIdExists`)

Camunda 7.24.3-ee validates every authorization before it saves it, and this is on by default. It rejects null or
empty user and group ids and references that do not fit the authorization's resource type, with a
`ProcessEngineException`. Operaton has no such check and saves these authorizations as they are. This affects all
code that creates authorizations: custom identity providers, direct `AuthorizationService` calls, and bootstrap or
migration code. Validate the user and group ids in that code yourself.

### Datasource autocommit check

Camunda 7.24.3-ee added a check of the datasource's default autocommit setting: if `defaultAutoCommit` is true, the
engine logs a warning during initialization. Operaton has no such check, so a wrong setting goes unnoticed. Keep
`spring.datasource.hikari.auto-commit: false`, as Camunda recommends.

### Remove the EE-only settings before the first start

The properties and calls that configure this hardening do not exist in Operaton. After the conversion they break in
three different ways:

| On Camunda EE | On Operaton |
|---|---|
| Generic properties `queryExpressionAllowListEnabled`, `allowedExpression*InQueries`, `validateAuthResourceIdExists` | **the engine start fails** (unknown property) |
| Java calls `setQueryExpressionValidator`, `setAllowed*InQueries`, `setValidateAuthResourceIdExists` | compile error |
| `camunda.bpm.authorization.validate-auth-resource-id-exists` | renamed to `operaton.bpm.…`, then **silently ignored** |

- **The start fails** because Operaton binds `operaton.bpm.generic-properties.properties` strictly:
  `ignore-unknown-fields` defaults to false. The recipe renames `camunda.bpm.generic-properties` to
  `operaton.bpm.generic-properties` and carries these keys over unchanged, so they reach the first start.
- **The ignored key** causes no error, but it suggests a protection that does not exist.

Remove all of them. They configure protections that Operaton does not have, so there is nothing to translate.

**What the tools report.** The tools find the EE settings and the affected filters, but none of them replaces the
hardening:

- [`scripts/assess.sh`](../scripts/assess.sh) reports the missing hardening as a MUST finding for every EE source,
  and a second MUST finding when it finds EE-only settings or calls. MUST means that skipping the item breaks the
  build, the start, runtime behaviour or security.
- [`scripts/verify-leftovers.sh`](../scripts/verify-leftovers.sh) fails on leftovers with the rules
  `EE_QUERY_EXPRESSION_ALLOWLIST` and `EE_AUTH_RESOURCE_VALIDATION`. They match any spelling (camel case, kebab case,
  snake case), also under `operaton.bpm`.
- The pre-flight check P11 lists the stored filters with expressions.

## Security operations

Operaton ships security fixes only for the latest line, with no SLA (see the **support model decision**,
[D14](01-migration-path-and-decisions.md#d14)). Report vulnerabilities via
[GitHub Security Advisories](https://github.com/operaton/operaton/security/advisories). Include `org.operaton.*` in
your dependency scans and build your own SBOM (software bill of materials).

## Watch out

- **Symptom:** Cockpit redirects to `/app/admin/default/setup/#/setup`.
  **Cause:** nobody is in `operaton-admin`.
  **Fix:** isolate the app, mirror the admin group with the SQL script (option A) or the plugin (option B), and check
  again.
- **Symptom:** former admins get `ENGINE-03029 Required admin authenticated group or user.` or see only some tenants.
  **Cause:** `camunda-admin` is no admin group on Operaton.
  **Fix:** apply the [admin-group decision](#admin-group-options-d5) (D5). Keeping `camunda-admin` as admin group
  (option D) works for a transition.
- **Symptom:** bootstrap code creates an empty `operaton-admin` named "Camunda Administrators".
  **Cause:** the recipe rewrote `Groups.CAMUNDA_ADMIN`, but the display-name literal stayed. An empty group does not
  close the hole.
  **Fix:** populate the group (see [Admin group options](#admin-group-options-d5)), and fix the literals and test
  assertions.
- **Symptom:** LDAP users cannot log in, but the local `demo` user can.
  **Cause:** a `camunda.bpm.ldap` prefix string in Java switched LDAP off.
  **Fix:** fix the string, then re-run the setup check.
- **Symptom:** the first Operaton start fails while it binds `operaton.bpm.generic-properties`.
  **Cause:** EE-only properties such as `queryExpressionAllowListEnabled` or `validateAuthResourceIdExists` survived
  the rename.
  **Fix:** remove them ([EE-only settings](#remove-the-ee-only-settings-before-the-first-start)).
- **Symptom:** Tasklist filters fail with `Expressions are forbidden in stored queries`.
  **Cause:** `enable-expressions-in-stored-queries` is false, but the filter still contains an expression.
  **Fix:** rewrite the filters that P11 lists, or switch expressions back on and restrict who may create and update
  filters ([Expressions in task queries](#expressions-in-task-queries-security-notice-157)).
