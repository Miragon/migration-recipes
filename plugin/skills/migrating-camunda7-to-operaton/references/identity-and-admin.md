# Identity, admin group and the setup-endpoint security issue

Decision D5 in practice: what changes, why the webapp setup endpoint re-opens, how to close it (SQL, plugin, IdP
mapping), how to prove it is closed without ever POSTing on production, and the LDAP/Keycloak/OAuth2 traps. Plus the
Camunda EE hardening Operaton does not have (decision D17, section 10). Guide chapter:
[07 · Identity, admin group and security](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/07-identity-admin-group-and-security.md).

## Contents

1. Facts
2. The security issue
3. Decide D5: options A–E
4. Add `AdminGroupMigrationPlugin` to a project (Option B)
5. The SQL alternative (Option A)
6. Related fixes: whitelist, `admin-user`, literals, Options C and D
7. Verify without POSTing on production
8. LDAP, Keycloak, OAuth2 specifics
9. Do not
10. Camunda EE hardening Operaton does not have (D17): query-expression allow-list, `validateAuthResourceIdExists`, autocommit check

## 1. Facts

- The admin group is **`operaton-admin`** (`Groups.OPERATON_ADMIN`), hard-coded in: engine `adminGroups`
  (`initAdminGroups()` always adds it), admin-only operations (`checkOperatonAdmin…`), the tenant-check bypass, the id
  whitelist default `[a-zA-Z0-9]+|operaton-admin`, the webapp setup check, and the starter's admin-user bootstrap.
- Memberships and grants are **data** (`ACT_ID_GROUP`, `ACT_ID_MEMBERSHIP`, `ACT_RU_AUTHORIZATION`,
  `ACT_ID_TENANT_MEMBER`). No recipe, upgrade script or startup hook migrates them; the recipe only rewrites the Java
  constant `Groups.CAMUNDA_ADMIN` → `Groups.OPERATON_ADMIN`.
- On a migrated DB with nothing done: normal grants still work (rows keyed by `camunda-admin`); admin-only operations
  fail with `ENGINE-03029 Required admin authenticated group or user.` / `ENGINE-03110` (authorization enabled);
  former admins become tenant-restricted; editing `camunda-admin` fails the whitelist (`Group has an invalid id:
  'camunda-admin' is not a valid resource identifier.`); code querying `Groups.OPERATON_ADMIN` finds no members.
- `operaton.bpm.admin-user` returns immediately if the user id exists (DEBUG log `Skip creating initial Admin User,
  user does exist`). It never adds an existing user to `operaton-admin`. A **new** id creates a user who becomes the
  only `operaton-admin` member (break-glass only; password as a secret). `CAMUNDA_BPM_ADMIN_USER_*` is ignored.
- Unchanged: `Resources`/`Permissions` ids and bit values, authorization types, webapp resource ids (`cockpit`,
  `tasklist`, `admin`, `welcome`), your own group ids, password hashes, tenant memberships. Replicated or persisted
  webapp sessions (Spring Session, Redis) from Camunda become invalid (according to the source): users log in again.

## 2. The security issue

The webapps treat the engine as "not set up" when the identity service is **writable** and
`memberOfGroup(OPERATON_ADMIN).count() == 0`. Then every webapp request redirects to
`<app-path>/app/admin/<engine>/setup/#/setup`, and `POST <app-path>/api/admin/setup/<engine>/user/create` runs
**without authentication** (no authorizer in `securityFilterRules.json`, by design) and creates a user in
`operaton-admin` with GRANT `ALL` on every resource. In the guide's trial: **204** and user `intruder` created;
Camunda 7.24 on the same DB: **403** `Setup action not available`.

| Setup | Exposed? |
|---|---|
| DB identity (default), webapps on the classpath, no `operaton-admin` member | **yes**: release blocker |
| DB identity, no webapps (REST-only/engine-only) | no endpoint; admin-rights effects still apply |
| LDAP or Keycloak plugin (read-only identity) | no |
| `operaton-bpm-spring-boot-starter-security` with OAuth2 registrations | not anonymously (login required; verified in source only): run the check anyway |
| at least one `operaton-admin` member (Option A/B done, or a new `admin-user` id) | no |

If the check ever finds the setup open on production: security incident. List `operaton-admin` members, audit
`ACT_ID_USER` and `ACT_HI_OP_LOG` for unknown users.

## 3. Decide D5: options A–E

| Option | Closes the setup hole? | Use |
|---|---|---|
| **A** `10-migrate-admin-group.sql` after Camunda stops, before the first Operaton start | yes, from the first start (if `camunda-admin` has members) | DB identity, in the runbook |
| **B** `AdminGroupMigrationPlugin` (runs in `postProcessEngineBuild`, before the web server accepts requests) | yes (if `camunda-admin` has members; otherwise only a WARN) | DB identity, every environment |
| **C** `AdministratorAuthorizationPlugin` for `operaton-admin` | **no** (adds no members) | complement when authorization is enabled |
| **D** also treat `camunda-admin` as admin group | **no** (setup check hard-codes `operaton-admin`) | time-boxed transition aid only |
| **E** external identity: map/rename the group in LDAP, Keycloak, IdP | n/a (read-only or login-protected) | LDAP, Keycloak, OAuth2 |

Recommendation: DB identity → **A and B** (A in the runbook, B as safety net for dev/test/staging copies and admins
added after the rehearsal); add C if authorization is enabled; E for external identity. Always block
`<app-path>/api/admin/setup/*` at the edge during the cut-over (permanently is fine). Keep every `camunda-admin` row
until the rollback window (D15) closes; Camunda 7.24 needs them after a rollback.

Differences: A also mirrors tenant memberships, authorizations that others hold **on** the group, and re-points the
group's self-READ row to `operaton-admin`; B does not (it copies members and every authorization **held by**
`camunda-admin`, GRANT and REVOKE, and OR-merges missing bits into existing `operaton-admin` GRANTs). B copies only
authorizations under a read-only identity provider. Both are idempotent and safe together.

## 4. Add `AdminGroupMigrationPlugin` to a project (Option B)

1. Find the package of the `@SpringBootApplication` class (`<base>`). Target package: `<base>.migration`, so component
   scanning picks up the configuration.
2. Copy `assets/snippets/AdminGroupMigrationPlugin.java` and `assets/snippets/MigrationHelpersConfiguration.java` to
   `src/main/java/<base as path>/migration/`. Replace `package com.example.orders.migration;` in both files. Keep the
   marker line `// operaton-migration-helper: remove after the rollback window (D15)`: the plugin holds `camunda-admin`
   literals on purpose, and `verify-leftovers.sh` skips files with the marker (one INFO line; `--strict` shows them).
3. `MigrationHelpersConfiguration` also declares the opt-in legacy-path redirect (`legacyWebappPathRedirectFilter`, off
   unless `orders.migration.legacy-webapp-redirect.enabled=true`) and **does not compile without
   `LegacyWebappPathRedirectFilter`**. Either copy `assets/snippets/LegacyWebappPathRedirectFilter.java` too (useful
   later for D6), or delete that `@Bean` method and its now-unused imports (`OperatonBpmProperties`,
   `FilterRegistrationBean`, `Ordered`). Its class Javadoc links `LegacyCamundaConfigGuard`: adjust it if you do not
   copy that class.
4. Properties (defaults are correct): `orders.migration.admin-group.enabled` (default `true` via `matchIfMissing`),
   `orders.migration.admin-group.legacy-group-id` (default `camunda-admin`). You MAY rename the `orders.migration`
   prefix to the project's own prefix: change the `@ConditionalOnProperty` prefix, the `@Value` placeholder and the
   Javadoc together. Never under `camunda.bpm.*`/`operaton.bpm.*`.
5. The starter picks up every `ProcessEnginePlugin` bean. The plugin is deliberately not a `@Component`;
   `MigrationHelpersConfiguration` registers it as a `@Bean`. Do not move the logic into an `ApplicationRunner` or
   `@EventListener(ApplicationReadyEvent)`: those run after the web server accepts requests (race window). Order is
   `Ordering.DEFAULT_ORDER + 1` (after the starter's admin-user bootstrap).
6. Add the test: copy `assets/snippets/test/AdminGroupMigrationPluginTest.java` to `src/test/java/<base as path>/migration/`
   and change the package. It seeds a Camunda-era `camunda-admin` (members + authorizations) on H2 in-memory with an engine
   whose `groupResourceWhitelistPattern` is `[a-zA-Z0-9]+|camunda-admin`, reopens the same DB with the plugin and asserts
   members and authorizations mirrored, idempotency, no-op on a fresh DB. Two details make the reopen work
   (references/testing.md §8): `databaseSchemaUpdate "true"` (the standalone default `create-drop` drops the schema when
   the first engine closes) with `DB_CLOSE_DELAY=-1`, and a unique engine name per engine. Keep it in the build: the plugin
   uses internal API (`AbstractProcessEnginePlugin`, `AuthorizationEntity`) without compatibility promise, so upgrades must
   fail the build.
7. Empty `camunda-admin` (exists, no members): the plugin logs a WARN and the hole stays open. Check P03 of
   `00-preflight-checks.sql` (or ask the user). Then: add an administrator before the webapps are reachable, configure a
   **new** break-glass `operaton.bpm.admin-user` id (secret), or make your copy throw in that case.
8. Fix bootstrap code the recipe touched: code that now creates `operaton-admin` with a leftover display name such as
   "Camunda Administrators" must use `operaton BPM Administrators` (Operaton's own name, as used by the SQL and plugin).
   Test assertions like `.contains("camunda-admin")` need the same review.
9. Build and test after the migration (Spring Boot 3.5 path: on each hop). Cut-over log line to expect: `Admin group migration camunda-admin -> operaton-admin:
   group created=…, members added=…, authorizations copied=…`.
10. After the rollback window: delete the plugin (or set `orders.migration.admin-group.enabled=false`) together with the
    `camunda-admin` clean-up. The marker line makes the helpers easy to find: `grep -rl operaton-migration-helper src`.

## 5. The SQL alternative (Option A)

Copy `assets/sql/postgresql/10-migrate-admin-group.sql` to `migration/sql/<vendor>/` for human review. Never run it
against a real database yourself. One transaction, never changes or deletes a `camunda-admin` row:
S0 state before · S1 create `operaton-admin` ("operaton BPM Administrators", `SYSTEM`) if `camunda-admin` exists ·
S2 memberships · S3 authorizations held by `camunda-admin` (GRANT and REVOKE; self rows of resource types 2/3
re-pointed) · S4 authorizations others hold on the group · S5 tenant memberships · S6 verification (`missing_*` = 0) ·
S7 assertion that rolls back on mismatch (psql exit 3). Idempotent (`not exists` guards).

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f migration/sql/postgresql/10-migrate-admin-group.sql
# dry run: replace the final COMMIT by ROLLBACK and read S6. Never add --single-transaction.
```

- When: after the last Camunda node stopped and the backup, before the first Operaton node (runbook T0-06). Also safe
  earlier (rehearsal, even while Camunda runs: it ignores `operaton-admin`); re-run in the window to catch admin changes.
- Gate: `00-preflight-checks.sql` P03b/P03c return no rows and the verdict is not `NO_GO`.
- Custom schema/table prefix: `set search_path to <schema>;` first.
- Other vendors (untested): UUID `gen_random_uuid()::text` → Oracle `rawtohex(sys_guid())`, SQL Server
  `cast(newid() as varchar(64))`, MySQL/MariaDB `uuid()`, H2 `cast(random_uuid() as varchar(64))`, DB2
  `hex(generate_unique())`; `insert … select … where not exists` without a table: Oracle `from dual`, DB2
  `from sysibm.sysdummy1`; the PL/pgSQL `do $$ … $$` assertion: vendor block or check S6 by hand; transaction start:
  SQL Server `begin transaction`, MySQL `start transaction`. Mark the copy `NOT TESTED on <vendor>`.
- Never "rename" with `update … set GROUP_ID_ = 'operaton-admin'`: it breaks the rollback path. Copy, don't move.
- The commented clean-up block at the end deletes `camunda-admin` rows: only after the rollback window closed.
- Ops scripts that grant `camunda-admin` (e.g. a `grant-admin.sql`) now grant nothing useful: replace with API calls (D10).

## 6. Related fixes: whitelist, `admin-user`, literals, Options C and D

String literals are never touched by a recipe. Grep code, YAML, env vars, Helm values, tests, SQL and IdP config for
`camunda-admin`; `verify-leftovers.sh` flags them.

```diff
 operaton:
   bpm:
     generic-properties:
       properties:
-        groupResourceWhitelistPattern: "[a-zA-Z0-9]+|camunda-admin|order-ops"
+        groupResourceWhitelistPattern: "[a-zA-Z0-9]+|operaton-admin|order-ops"
```

Leaving `camunda-admin` there fails startup: `Group has an invalid id: 'operaton-admin' is not a valid resource
identifier.` A custom `groupResourceWhitelistPattern` replaces the general one for groups, so include `operaton-admin`.
List exceptions explicitly; no broad classes like `[a-zA-Z0-9._-]+`. Add `|camunda-admin` only while you must still
**edit** that group (Option D transition).

Option C (with authorization enabled) and Option D (transition only, never alone):

```java
@Bean
AdministratorAuthorizationPlugin operatonAdminAuthorizations() {        // org.operaton.bpm.engine.impl.plugin
  AdministratorAuthorizationPlugin plugin = new AdministratorAuthorizationPlugin();
  plugin.setAdministratorGroupName(Groups.OPERATON_ADMIN);             // D: "camunda-admin", remove after the window
  return plugin;
}
```

Edge block for the cut-over (use your application path). Plain nginx / a reverse proxy you configure directly:

```nginx
location ^~ /camunda/api/admin/setup/ { return 403; }
location ^~ /operaton/api/admin/setup/ { return 403; }
```

Kubernetes ingress-nginx has no path-deny field; the rule needs a snippet annotation on the app's Ingress:

```yaml
metadata:
  annotations:
    nginx.ingress.kubernetes.io/server-snippet: |
      location ^~ /camunda/api/admin/setup/ { return 403; }
```

Caveat: snippet annotations are **disabled by default since ingress-nginx controller 1.9** (`allow-snippet-annotations:
"false"` in the controller ConfigMap; newer controllers additionally gate them by `annotations-risk-level`). Many
platform teams keep them off for security reasons: ask before relying on it, and check that the Ingress is accepted
(the controller rejects or ignores it otherwise; the rehearsal check is the ingress's own 403, runbook P-05). Alternatives
without snippets: a path rule in the WAF or load balancer in front (e.g. a deny rule for the path prefix
`<app-path>/api/admin/setup/`), or the in-app filter below. The in-app filter works everywhere; keep an edge rule where
you can, because it also covers builds that do not contain the filter.

```java
@Bean
FilterRegistrationBean<OncePerRequestFilter> blockWebappSetup(
    @Value("${operaton.bpm.webapp.application-path:/operaton}") String appPath) {
  OncePerRequestFilter deny = new OncePerRequestFilter() {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain) throws IOException {
      res.sendError(HttpServletResponse.SC_FORBIDDEN);   // setup is never legitimate on a migrated DB
    }
  };
  FilterRegistrationBean<OncePerRequestFilter> reg = new FilterRegistrationBean<>(deny);
  reg.addUrlPatterns(appPath + "/api/admin/setup/*");
  reg.setOrder(Ordered.HIGHEST_PRECEDENCE);
  return reg;
}
```

`/engine-rest` from the REST starter is unauthenticated by default (unchanged); an auth filter registered with the
**string** `"org.camunda.bpm.engine.rest.security.auth.impl.HttpBasicAuthenticationProvider"` is not rewritten by the recipe.

## 7. Verify without POSTing on production

**Agent, local (SKILL step 6.3): cut-over simulation on a throw-away file DB.**
1. Check out the last Camunda 7.24 commit (the step-3b release if there is one, else the baseline) into a temp
   worktree (`git worktree add --detach /tmp/opmig-c7 <commit>`). Start the Camunda 7.24 app on a file DB, e.g.
   `--spring.datasource.url=jdbc:h2:file:/tmp/opmig/db --server.port=8091` (or a local throw-away instance of the
   production DB vendor; H2 is often test-scoped only). Make sure `camunda-admin` has a member (the app's admin-user
   config on the fresh file DB, or create one via REST).
   `smoke-test.sh` against it reports a Camunda `7.x` version (`7.24.0` on CE) and the setup page
   closed. The H2 file written by Camunda 7.24 /
   Spring Boot 3.5.5 (H2 2.3.232) opens with Spring Boot 4.0.8's H2 2.4.240 (verified 2026-10-07), so the simulation
   also works for a Spring Boot 4 build (Spring Boot 3.5 path: the Hop 2 build). Spring Boot 4 sources: building the Camunda
   7.24 EE commit needs the EE repository; if it is not available locally, report that and use the rehearsal on a
   production copy as evidence instead.
2. Stop it. Copy the DB file twice (copy A, copy B).
3. Start the migrated app on copy A (same datasource settings, schema already present). Expect the plugin's log line.
4. `bash "<skill-dir>/scripts/smoke-test.sh" --base-url http://localhost:<port> --webapp-path <path> --user <u> --password <p> --require-operaton`
   must report `admin setup page` **PASS** (closed).
5. Optional control on copy B with `--orders.migration.admin-group.enabled=false`: smoke test must FAIL with
   "admin setup page OPEN". That proves the check detects the hole. The disabled plugin logs **nothing** (the
   `@ConditionalOnProperty` bean is not created), so the evidence for this run is the smoke-test result, not a log line.
   On this local copy the POST probe from the chapter is allowed; it is not needed.
6. Record commands and results in the report ("Admin setup endpoint closed on migrated DB"). With SQL-only D5 (no
   plugin), run the script on a local PostgreSQL copy instead (the H2 dialect differs).

**Humans, staging (restored production copy).** The non-mutating check plus the DB count; the mutating POST probe
only on a throw-away copy, and only the body `Setup action not available` proves "closed": a bare 403 also comes from
the CSRF filter (missing XSRF cookie/header) or the edge block while setup is **open**. Delete any probe user.

**Production.** Only the non-mutating check (and the SQL count), then keep it as a synthetic monitor:

```bash
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "$BASE$APP/app/admin/default/"
#   open:   302 …/app/admin/default/setup/#/setup        closed: 200 (login page)
```

```sql
select count(*) from ACT_ID_MEMBERSHIP where GROUP_ID_ = 'operaton-admin';   -- must be >= 1 before traffic
```

`smoke-test.sh` performs the GET checks (`…/app/admin/<engine>/` and `…/setup/` without following redirects) and never
POSTs. A `WARN … undetermined` result usually means SSO in front: verify manually with a logged-in session.

## 8. LDAP, Keycloak, OAuth2 specifics

**LDAP** (`org.camunda.bpm.identity:camunda-identity-ldap` → `org.operaton.bpm.identity:operaton-identity-ldap`, class
`org.operaton.bpm.identity.impl.ldap.plugin.LdapIdentityProviderPlugin`, same setters). Trap: `@ConfigurationProperties`
/ `@ConditionalOnProperty` **strings** `"camunda.bpm.ldap…"` are not renamed while the YAML is. With the condition the
plugin bean silently disappears, the engine falls back to DB identity, and the setup hole returns. Grep
`grep -rn '"camunda\.bpm' src/main/java`; prefer the project's own prefix. LDAP admin group named `camunda-admin`:
register `AdministratorAuthorizationPlugin` with `administratorGroupName = "camunda-admin"`.

**Keycloak** (`org.camunda.bpm.extension:camunda-platform-7-keycloak` → `org.operaton.bpm.extension:operaton-keycloak`;
version per Operaton line: see references/versions.md). The recipe maps only the main artifact (to `1.0.x`): bump it and
change `-jwt`, `-all`, `-run` by hand. Rename these keys (old ones are silently ignored):

| camunda-platform-7-keycloak | operaton-keycloak |
|---|---|
| `useEmailAsCamundaUserId` | `useEmailAsOperatonUserId` |
| `useUsernameAsCamundaUserId` | `useUsernameAsOperatonUserId` |
| `useGroupPathAsCamundaGroupId` | `useGroupPathAsOperatonGroupId` |

A forgotten `useEmailAsCamundaUserId: true` switches user ids to Keycloak UUIDs: user authorizations, assignees,
candidate users and filter owners stop matching, with no startup error. `administratorGroupName` keeps its name: keep
`camunda-admin` for the transition or rename in the realm and set `operaton-admin`. Never configure
`operaton.bpm.admin-user` with Keycloak. Moving the webapp path: update redirect, post-logout redirect URIs and web origins.

**OAuth2** (`org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-security`): `camunda.bpm.oauth2.*` →
`operaton.bpm.oauth2.*` (`identity-provider.enabled`, `.group-name-attribute`, `.group-name-delimiter`,
`sso-logout.enabled`, `.post-logout-redirect-uri`), including Secrets. Update class names in
`spring.autoconfigure.exclude` (`…OperatonSpringSecurityOAuth2AutoConfiguration`,
`…OperatonBpmSpringSecurityDisableAutoConfiguration`): a stale string is ignored. The chain secures
`<app-path>/app/**` and `<app-path>/api/**` only, not `/engine-rest`. An authority `camunda-admin` is not admin: rename
it at the IdP, map it in a `GrantedAuthoritiesMapper`, or register `AdministratorAuthorizationPlugin` with
`administratorGroupName = "camunda-admin"`.
Operaton 2.x runs on Spring Security 7 (Spring Boot 3.5 path: Hop 2 brings it): re-run the setup check and one
admin-only action after the migration (after Hop 2).

## 9. Do not

- Do not rely on `operaton.bpm.admin-user`, Option C or Option D to close the setup endpoint.
- Do not POST to the setup endpoint on production or any shared environment; do not accept a bare 403 as proof.
- Do not delete or rename `camunda-admin` rows before the rollback window closes.
- Do not run `10-migrate-admin-group.sql` (or any SQL) against a real database yourself.
- Do not run the admin-group migration from an `ApplicationRunner` or `ApplicationReadyEvent` listener.
- Do not let an empty `camunda-admin` pass unnoticed: the plugin only WARNs and the endpoint stays open.
- Do not widen the id whitelist with character classes.
- Do not keep Camunda EE-only settings (`queryExpressionAllowListEnabled`, `allowedExpression*InQueries`,
  `validateAuthResourceIdExists`) as generic properties, and do not silence them with `ignore-unknown-fields: true`.
- Do not claim a tested exploit for the missing query-expression allow-list; state the behaviour (section 10).

## 10. Camunda EE hardening Operaton does not have (D17)

Camunda 7.24 EE patches added hardening that Operaton (checked against Operaton main) does not have. After the rename,
Java calls to `setValidateAuthResourceIdExists`, `setQueryExpressionValidator` and `setAllowed*InQueries` do not compile,
the same names as `generic-properties` **fail the engine start** (unknown field; `ignore-unknown-fields` defaults to
false), and `operaton.bpm.authorization.validate-auth-resource-id-exists` is ignored silently. `assess.sh` reports it as
a MUST for every EE source; `verify-leftovers.sh` rules `EE_QUERY_EXPRESSION_ALLOWLIST` and `EE_AUTH_RESOURCE_VALIDATION`.

**Query-API expression allow-list (7.24.7-ee).** Camunda added `queryExpressionAllowListEnabled` (default on),
`allowedExpressionFunctionsInQueries`, `allowedExpressionBeansInQueries`, `allowedExpressionPropertiesInQueries` and
`setQueryExpressionValidator(QueryExpressionValidator)`. Camunda security notice 157 (2026-04-10): expression injection
via stored task filters and ad-hoc task queries; affected up to 7.24.6 when `enableExpressionsInStoredQueries=true`
(default) and a user may update filters, or when `enableExpressionsInAdhocQueries=true`. Operaton keeps only the two
all-or-nothing switches (`enableExpressionsInAdhocQueries` default false, `enableExpressionsInStoredQueries` default
**true**) and has published no advisory, so Operaton behaves like Camunda before 7.24.7. Mitigation (default of D17):

1. Ask a DBA for pre-flight P11 on a production copy (`00-preflight-checks.sql`, references/database.md §3): it lists the
   stored filters with expressions.
2. No rows: set the generic property `enable-expressions-in-stored-queries: false` (YAML in references/configuration.md §3).
3. Rows (filters need expressions such as `${currentUser()}` or `${currentUserGroups()}`): rewrite them without
   expressions, or keep stored-query expressions on and restrict who may create and update filters (authorization
   resource type 5 = Filter; authorizations only apply with `operaton.bpm.authorization.enabled: true`). With the
   switch off, such a filter fails with "Expressions are forbidden in stored queries".
4. Keep `enable-expressions-in-adhoc-queries` false (the default).
5. Record the choice in D17 and the reason in the report. Delete the EE-only names.

**`validateAuthResourceIdExists` (7.24.3-ee).** Camunda validates user, group and resource references of
authorizations before saving them (`camunda.bpm.authorization.validate-auth-resource-id-exists`, default true). Operaton
saves them unchecked: delete the key and validate user and group ids in the code that creates authorizations (bootstrap
code, migration scripts, custom identity providers).

**Datasource autocommit check (7.24.3-ee).** Camunda can verify the datasource's default autocommit setting and logs a
warning when it is true. Operaton has no such check: keep `spring.datasource.hikari.auto-commit: false`.
