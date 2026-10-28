# 02 · Readiness assessment

This chapter shows how to find out, before you change any code, how big the migration is and where it can fail
without an error message. It is written for the tech lead who plans the migration, together with ops, the DBA and
security. Do it first: it is the Assess phase of the [phased plan](01-migration-path-and-decisions.md#3-phased-plan).
The chapter assumes the main path of this guide: Camunda 7.24 EE on Spring Boot 4, migrated to Operaton 2.x in one
code change and one cut-over.

**In short**
- Start only when your code runs on **Camunda 7.24 EE, 7.24.3-ee or later, with Camunda's Spring Boot 4 starters**
  (the artifacts with `-4` in their name), on **Java 17+**, and the database is on the **7.24 schema**. This is
  Step 0. Operaton does not check it at startup, so on an older database it starts and then fails at runtime.
- **Your Spring Boot minor version decides the Operaton target.** Spring Boot 4.0 goes to Operaton 2.1.5. Spring
  Boot 4.1 goes to Operaton 2.2.x, whose GA (the final release) is due on 2026-10-23; until then you can only rehearse
  with 2.2.0-RC1, never go live. No Operaton line is built with Spring Boot 4.2 yet.
- The assessment has three sources: [`scripts/assess.sh`](../scripts/assess.sh) on every repository, two read-only
  SQL scans on a **production copy** (a restored copy of the production database, never the live one), and one
  interview with the teams around the engine.
- Hunt the silent failures, because they give no error when you build or start the service: `camunda.bpm.*`
  keys and `CAMUNDA_BPM_*` variables outside the reach of the recipe (the automated code transformation),
  `org.camunda.*` in BPMN scripts, the `camunda-admin` group, class names in exported events, `org.camunda.*`
  objects stored in variables, and the **Camunda EE security hardening that Operaton does not have**.
- The result is a report, a size class, a list of red flags, an owner for every MUST finding, and first entries in
  the [decision log](../checklists/decision-log-template.md) for the target version
  ([D1](01-migration-path-and-decisions.md#d1)), the support model ([D14](01-migration-path-and-decisions.md#d14))
  and Camunda EE features ([D17](01-migration-path-and-decisions.md#d17)). The EE decision is mandatory for every
  team on Spring Boot 4, because Spring Boot 4 on Camunda 7.24 always means Camunda EE.

## What to do

1. Check the [prerequisites](#prerequisites-step-0): edition, patch level, Spring Boot version and database schema.
   If one is missing, finish it on Camunda and ship it first, because the rest of the migration assumes them.
   Operaton does not check the database level: it starts on an older schema and fails at runtime.
2. Run `scripts/assess.sh` on every repository that touches the engine, including workers, shared libraries and
   Helm/GitOps repositories, so that code and configuration outside the main service are counted too. Read the first
   section of each report: it states the edition, the Spring Boot version, the migration path and the recommended
   Operaton target, and these must match what you expect.
3. Dry-run the conversion on a clean branch: `scripts/migrate.sh --dry-run <project-dir>`. On Spring Boot 4.1, add
   `--target 2.2.0-RC1` until Operaton 2.2.0 is GA, and `--target 2.2.0` after that. A dry run changes nothing, and
   the size of the resulting patch is your best estimate of the effort. To list what stays manual, run the same
   command without `--dry-run` on a throw-away branch, then run `scripts/verify-leftovers.sh`. It lists the
   leftovers: Camunda references that no recipe converted. Details: [OpenRewrite recipes](03-openrewrite-recipes.md).
   - The run needs the credentials of the Camunda EE repository, because the rewrite plugin resolves all dependencies
     before any recipe runs: server id `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or
     `MAVEN_ARGS="-s <settings with the EE credentials>"`.
   - The starter pack tests this path with stand-in EE artifacts, not against the real Camunda EE repository. Your
     dry run is therefore the first real test on your build, so do it early.
4. Run both SQL scans on a restored production copy, because the database holds facts that no code scan sees.
5. Interview ops, the DBA, security, the process owners and the consumer teams. They know about configuration,
   identity, EE features and consumers outside your repositories.
6. Size each service and list its red flags. Give every MUST finding an owner and a decision ID, so that no silent
   failure is left without an owner.

## Prerequisites (Step 0)

Step 0 is the starting point the whole migration assumes. The recipe of the main path expects the Camunda 7.24 EE
coordinates with the `-4` starters, and Operaton uses the 7.24 database schema. The right-hand column says how to
check each prerequisite, or what to do if it is not met. Ship anything missing as a normal Camunda release, well
before the cut-over (the one production event in which you stop Camunda and start Operaton on the same database).

| Prerequisite | How to check |
|---|---|
| Camunda **7.24 EE**, patch **7.24.3-ee or later** | The version in the build (`camunda.version` / `camunda-bom`) ends in `-ee`, for example `7.24.16-ee` |
| **Spring Boot 4.0 or 4.1** with the `-4` starters | Parent or BOM version, and `camunda-bpm-spring-boot-starter-4*` artifacts in the build |
| Schema **7.24** | Schema-level check (P01) of `00-preflight-checks.sql` |
| **Java 17+**, build **and** runtime | Toolchain, CI image, Dockerfile base image |
| DB ≥ **PostgreSQL 14 / MariaDB 10.11 / MySQL 8.4** (Operaton 2.1+) | If lower, upgrade the database separately, never in the cut-over window |
| Test dependencies `org.camunda.bpm:camunda-bpm-junit5` / `camunda-bpm-assert` | The recipe does not map the legacy `org.camunda.bpm.extension` / `org.camunda.bpm.assert` coordinates |

`scripts/assess.sh` reads the first two rows for you (see [below](#scan-the-code-scriptsassesssh)). The paragraphs
below explain what to look for if you check by hand.

**Edition.** Spring Boot 4 on Camunda 7.24 exists only in the Enterprise Edition (EE). Camunda shipped the Spring
Boot 4 starters with patch 7.24.3-ee (January 2026). Camunda 7 CE (Community Edition) ended at 7.24.0 and never got
Spring Boot 4 support, and nothing newer than 7.24.0 is on Maven Central. EE versions have the form `7.24.N-ee`,
and the build loads them from the EE repository `https://artifacts.camunda.com/artifactory/private/` (server id
`camunda-bpm-nexus-ee`). Other signs of EE are `-ee` artifacts such as `camunda-bpm-spring-boot-starter-4-webapp-ee`
and a license file (`camunda.bpm.license-file`, `camunda-license.txt`).

> [!NOTE]
> **On Spring Boot 3.5?** That is every Camunda 7.24.0 CE application, and every EE application that has not moved
> to the `-4` starters. Operaton 2.x does not run on Spring Boot 3, so your code changes in two steps. Read
> [Coming from Spring Boot 3.5: the two-hop path](15-coming-from-spring-boot-3.md) first; this chapter still applies.

**Patch level.** EE patches added features that Operaton does not have, so your patch level tells you which of
them you may be using. The table lists the patches that matter for the migration:

| Camunda patch | What it added | What it means for the migration |
|---|---|---|
| 7.24.3-ee (Jan 2026) | `-4` starters for Spring Boot 4, `validateAuthResourceIdExists`, datasource autocommit check | The earliest patch for this path. Operaton has neither check. |
| 7.24.6-ee (Apr 2026) | Official support for Spring 7 and Spring Boot 4.0; `camunda-engine-spring-6` removed | Use `operaton-engine-spring` ([dependencies](04-spring-boot-dependencies-and-configuration.md#dependencies)). |
| 7.24.7-ee (Apr 2026) | Allow-list for expressions in task queries and filters, on by default | Operaton has no allow-list ([red flags](#sizing-and-red-flags)). |
| 7.24.10-ee (Jun 2026) | The starter is based on Spring Boot 4.1 | The matching target is Operaton 2.2.x. |
| 7.24.16-ee (Oct 2026) | Opt-in Jackson 3 artifacts (`-jackson3`) | Operaton has none; you go back to Jackson 2. |

**Spring Boot minor version.** Operaton supports only the Spring Boot version each release is built with, so read
the version your build really uses: the parent `spring-boot-starter-parent`, an imported `spring-boot-dependencies`
or the Gradle plugin `org.springframework.boot`. Do not assume it from the Camunda patch: since 7.24.10-ee the
starter is based on Spring Boot 4.1, but a build can stay on 4.0 by importing `spring-boot-dependencies` 4.0.7. The
table shows which Operaton line matches your Spring Boot minor (as of 2026-10-11):

| Your Spring Boot | Operaton target | Built with | Status |
|---|---|---|---|
| 4.0.x | **2.1.5** | Spring Boot 4.0.8 | GA. Plan the move to 2.2 soon after, because 2.1 support ends in October 2026. |
| 4.1.x | **2.2.x** | Spring Boot 4.1.1 (2.2.0-RC1) | GA due 2026-10-23. Rehearse with 2.2.0-RC1, never use it in production. |
| 4.2 or newer | none yet | — | Migrate on Spring Boot 4.1, or wait for the matching Operaton line. |

`scripts/latest-versions.sh` prints the current pairing. `scripts/migrate.sh` never downgrades Spring Boot and does
not raise its minor version; if your minor does not match the target, it warns. Operaton 2.1.5 on Spring Boot 4.1.1
started and passed a smoke test, but it is not a supported pairing. Details:
[target-version decision (D1)](01-migration-path-and-decisions.md#d1) and
[Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#operaton-2x-needs-spring-boot-4).

**Database schema.** EE patches do not change the database schema (Camunda: "between patch levels, the structure of
the database schema is not changed"), so every 7.24.N-ee database has the 7.24 schema. The schema-level check (P01)
is OK when the newest `ACT_GE_SCHEMA_LOG` row is `7.24.0`, a `7.24.N` patch row (none is known for 7.24.x) or
`7.25.0`, the only row that Operaton 2.2's script `<db>_engine_7.24_to_7.25.sql` adds. Anything else is `NO_GO`.

> [!WARNING]
> **The engine will not stop you.** At startup Operaton only checks `schema.version = 'fox'`, a value every
> Camunda 7 database has. On a 7.22 or older schema it boots, then fails with "column … does not exist".
> A 7.23 schema lacks only the `7.24.0` row. Run the 7.23 → 7.24 script anyway, so that the schema log shows the
> level the pre-flight check expects. Upgrade minor by minor with
> [Camunda's update guides](https://docs.camunda.org/manual/7.24/update/minor/) and Camunda's original scripts.

## Scan the code: `scripts/assess.sh`

`scripts/assess.sh` lists everything in a repository that the migration touches and flags what would break
silently. It is read-only: it does not build, needs no network and changes nothing.

```bash
./scripts/assess.sh path/to/project > assessment.md
```

It also reads Dockerfiles, `.env`, Terraform and Jenkinsfiles, so scan the infrastructure repositories too.

**What the report says about your source.** The first section, *Build and platform*, describes the project before
any finding. It uses the same rule as `scripts/migrate.sh` to pick the migration path: a build on Spring Boot 4.x
(parent, imported `spring-boot-dependencies` or Gradle plugin) or with any `camunda-bpm-spring-boot-starter-4*`
artifact takes the Spring Boot 4 path. These are the rows for a Camunda 7.24.16-ee service on Spring Boot 4.0.8:

```text
| Edition | **Camunda EE** (version 7.24.16-ee, `-4` starters (EE-only, 7.24.3-ee+), `-ee` artifacts, `-jackson3` artifacts (7.24.16-ee), license) - decision D17 (EE features) is mandatory |
| Spring Boot | 4.0.8 (`pom.xml`) |
| Spring Boot 4 artifacts | `-4` starters `camunda-bpm-spring-boot-starter-4-rest`, `camunda-bpm-spring-boot-starter-4-test`, `camunda-bpm-spring-boot-starter-4-webapp-ee`; Jackson 3 opt-in: `camunda-spin-dataformat-json-jackson3` |
| Migration path | **Spring Boot 4 path**: one recipe run (`starterpack.operaton.MigrateSpringBoot4App`), one cut-over (decision D1) |
| Recommended Operaton target | Operaton **2.1.5** (built with Spring Boot 4.0.8); plan 2.2 soon after (2.1 support ends Oct 2026; 2.2 needs Spring Boot 4.1) |
| Integration | Spring Boot starter (`-4`, Spring Boot 4) + webapps (Cockpit/Tasklist/Admin) |
```

On Spring Boot 4.1 the target row reads:

```text
| Recommended Operaton target | Operaton **2.2.x** (built with Spring Boot 4.1; GA due 2026-10-23): rehearse with 2.2.0-RC1 until then, never in production; 2.1.5 on Spring Boot 4.1 is unsupported |
```

Check three things in this section:

- *Edition* says **Camunda EE** and lists the evidence it found. If it says Camunda CE, or *Migration path* does
  not say **Spring Boot 4 path**, the build is not on Spring Boot 4; go back to the
  [prerequisites](#prerequisites-step-0).
- *Recommended Operaton target* matches your Spring Boot minor. If no Spring Boot version could be read but a `-4`
  starter is present, the row says `Spring Boot version not detected: 4.0 → Operaton 2.1.5, 4.1 → Operaton 2.2.x`.
- The last section, *Next steps*, gives the dry-run command for your path. On Spring Boot 4.1 it already contains
  `--target 2.2.0-RC1`, and from 2026-10-23 it switches to `--target 2.2.0`.

**How to read the findings.** The report sorts its findings by severity. The labels mean:

| Severity | Meaning |
|---|---|
| **MUST** | Blocks the migration or **breaks silently** unless somebody acts. Give it an owner and a phase of the [phased plan](01-migration-path-and-decisions.md#3-phased-plan). |
| **SHOULD** | The recipes handle it, or it is a decision with a safe default. Review it in the dry-run patch. |
| **INFO** | Planning context, such as counts and versions. |

**Findings about Camunda EE and Spring Boot 4.** The findings below concern an EE source on Spring Boot 4. Except
for the two Spring Boot version findings and the Spin finding, they belong to the
[Camunda EE features decision (D17)](01-migration-path-and-decisions.md#d17). The table lists them with the place in
this guide that explains the fix:

| Finding | Severity | Details |
|---|---|---|
| EE security hardening that Operaton does not have (query-expression allow-list, `validateAuthResourceIdExists`, autocommit check) | MUST, on every EE build | [Identity, admin group and security](07-identity-admin-group-and-security.md) |
| EE-only engine settings and calls, which fail the start, fail the build or are ignored | MUST, if present | [Spring Boot dependencies and configuration](04-spring-boot-dependencies-and-configuration.md#ee-only-engine-settings), [Identity, admin group and security](07-identity-admin-group-and-security.md) |
| Jackson 3 opt-in: `-jackson3` artifacts, or `tools.jackson` code next to Spin, engine REST or the external task client | MUST | [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#jackson-2-and-jackson-3) |
| Spring Boot 4.1: the matching Operaton line is 2.2.x | SHOULD | [D1 · Target version and path](01-migration-path-and-decisions.md#d1) |
| Spring Boot 4.2 or newer: no Operaton line yet | SHOULD | [D1 · Target version and path](01-migration-path-and-decisions.md#d1) |
| EE webapps, whose EE features disappear without a build error | SHOULD | [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md#camunda-ee-features) |
| EE license file, mounts and secrets | SHOULD | [Webapps, REST API and clients](09-webapps-rest-api-and-clients.md) |
| EE repository and its credentials | SHOULD | [OpenRewrite recipes](03-openrewrite-recipes.md) |
| Spin `DataFormatConfigurator`: keep it on Jackson 2 | SHOULD | [Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#jackson-2-and-jackson-3) |

For EE builds and for Jackson 3 code, the inventory gets an extra section, *Camunda EE and Spring Boot 4*. It lists
every piece of EE evidence with its count, files and examples.

**What the script cannot see.** The script only sees the repository. Run these three checks by hand to cover the
rest (`<exported-config>` stands for an export of your config server, Vault or CI variables):

```bash
mvn -q dependency:tree -Dincludes='org.camunda*:*,io.holunda*:*'       # transitive Camunda/community artifacts
grep -rnE 'camunda\.bpm|CAMUNDA_BPM_|camunda-admin' <exported-config>   # config server, Vault, CI variables
jar tf vendor-lib.jar | grep org/camunda                                # precompiled jars on Camunda classes
```

## Scan the database

The database holds what no code scan can see: the members of the admin group, variables that store Camunda
objects, models that are already deployed, and task filters that use expressions. Two read-only SQL scripts find
them. They are written for PostgreSQL; for other databases see [`sql/README.md`](../sql/README.md). Run them on a
production copy or a replica, not on the live database: the legacy-reference scan reads every stored byte array,
and it has a 15-minute timeout.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/00-preflight-checks.sql      > preflight.txt
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -f sql/postgresql/20-find-legacy-references.sql > legacy-references.txt
```

`00-preflight-checks.sql` is the pre-flight gate: read-only checks P01 to P11, followed by a one-row verdict (P99).
`20-find-legacy-references.sql` finds stored data that still points to Camunda classes, in sections L1 to L9.
The table lists the sections that matter for the assessment:

| Check | Tells you |
|---|---|
| Schema level (**P01**) | The schema level. Anything other than `7.24.0`, a `7.24.N` patch row or `7.25.0` means that Step 0 is not done. |
| Admin group (**P03**) | The members of `camunda-admin`: the data step of the [admin-group decision (D5)](01-migration-path-and-decisions.md#d5). |
| Failed jobs and incidents (**P05**) | Your baseline, to compare with after the cut-over. |
| Schema tools (**P08**) | Whether Liquibase or Flyway is present. |
| Typed variables (**P10**) | A quick count of variables typed with `org.camunda.*` classes. |
| Filters with expressions (**P11**) | The stored task filters that use expressions. Informational: it never changes the verdict. |
| Legacy variables (**L1/L2**) | Variables with `org.camunda.*` classes, which Operaton cannot load. Convert runtime hits on 7.24, or drain them: let those instances finish on Camunda ([legacy-variables decision, D18](01-migration-path-and-decisions.md#d18)). |
| Deployed scripts (**L3/L4**) | **Deployed** definitions with `org.camunda.*` scripts and their running instances. The fix in your repository does not reach them. |
| Activiti models (**L5**) | Models in the Activiti namespace. Operaton rejects them. |
| Form keys (**L6**) | `camunda-forms:` keys, input for the [Camunda Forms keys decision (D4)](01-migration-path-and-decisions.md#d4). |

**Why the filters matter.** Operaton has no allow-list for expressions in stored filters (Camunda 7.24.7-ee has one).
The mitigation is to switch expressions in stored queries off, and the filter check (P11) lists the filters that would
then fail. No rows means you can switch them off without breaking a filter. The summary row (P99) repeats the count as
`filters_with_expressions`. How to mitigate:
[Identity, admin group and security](07-identity-admin-group-and-security.md).

**The EE license is data, too.** Camunda stores the EE license key in the database (`ACT_GE_BYTEARRAY` resource
`camunda-license-key`, referenced by the `ACT_GE_PROPERTY` row `camunda-license-key-id`). Operaton ignores these rows.
Keep them for a rollback to Camunda.

At this stage, a `NO_GO` verdict (exit code 3) is normal if the database has users, because nobody is in
`operaton-admin` yet. Operaton's webapps treat only members of that group as administrators. With nobody in it, they
open a setup page that lets anyone create an admin user without logging in. That is why you mirror the admin group
(copy the members and authorizations of `camunda-admin` to `operaton-admin`) before the first Operaton start. At the
cut-over the verdict must be `GO` or `GO_WITH_WARNINGS`.

## What the scan cannot see (interview)

The interview finds facts that live outside your repositories or only in people's heads, so no scan sees them.
Ask the owners about each item below.

- **Config outside the repository:** Helm values, config server, Vault, CI variables, `JAVA_TOOL_OPTIONS`. Operaton
  silently ignores leftover Camunda keys there, so the engine falls back to its defaults.
- **Consumers** of exported events, REST payloads or `ACT_HI_*` data that depend on class names. Record who owns
  each consumer: the class names change to `org.operaton…`
  ([history-exporters decision, D9](01-migration-path-and-decisions.md#d9)).
- **Direct SQL:** ops scripts and other writers of `ACT_*` tables
  ([direct-database-scripts decision, D10](01-migration-path-and-decisions.md#d10)).
- **Identity provider:** who is admin today (DB group, LDAP, Keycloak), and who will be admin after the switch?
  Details: [Identity, admin group and security](07-identity-admin-group-and-security.md).
- **Webapp URLs** (`/camunda/app/...`) in bookmarks, proxies, ingress, SSO redirects and monitoring
  ([webapp-path decision, D6](01-migration-path-and-decisions.md#d6)).
- **Alerts** on `org.camunda.*` logger names.
- **EE features** that the team uses, for example to handle incidents: the EE screens in Cockpit (history view,
  heatmap, instance modification, migration UI, batches, reports) and Optimize. Operaton has none of them
  ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)).
- **Task filters:** which filters need expressions such as `${currentUser()}`, and who may create or update filters.
  The answer decides how you mitigate the missing EE allow-list.
- **EE license and repository outside the repository:** license files mounted as secrets, and the EE repository
  credentials in CI and shared Maven settings. Operaton needs neither, so plan their removal after the conversion.
- **Other applications** on the same database. They must switch in the same cut-over as yours
  ([cut-over strategy decision, D7](01-migration-path-and-decisions.md#d7)).

## Sizing and red flags

The size class tells you how much effort to plan. Rate each service on every dimension; the **worst** dimension
decides the class. The numbers are person-days without Step 0. Calibrate them with your dry run.

- **Small (3–8):** one service, ≤ 10 models, few scripts, ≤ 5 imports of internal `…impl…` packages, no plugins or
  exporters, and good process tests.
- **Medium (10–25):** 10–50 models, 5–30 internal-API imports, 1–2 plugins, one exporter, a config server.
- **Large (30–80+):** 3+ services on one database, 50+ models with scripts, custom history levels or serializers,
  LDAP/SSO, or `org.camunda.*` in runtime variables. Plan a pilot and one coordinated cut-over.

A red flag can, on its own, block the migration of an application or set its date. Plan for each one before you
convert code:

- **EE features in daily use.** The recipe maps EE webapp artifacts to CE without an error, so the features
  disappear. Replace them before go-live, or stay on Camunda EE
  ([Camunda EE features decision, D17](01-migration-path-and-decisions.md#d17)).
- **The EE security hardening is gone.** Operaton has no query-expression allow-list (7.24.7-ee), no
  `validateAuthResourceIdExists` and no autocommit check (both 7.24.3-ee). It behaves like Camunda before 7.24.7:
  stored task filters evaluate any expression (Camunda security notice 157 describes expression injection through
  filters). Plan the mitigation with security before go-live: switch expressions in stored queries off unless
  filters need them, keep ad-hoc query expressions off, and restrict who may create or update filters. Details:
  [Identity, admin group and security](07-identity-admin-group-and-security.md).
- **Code on Camunda's Jackson 3 artifacts.** Operaton 2.x Spin, REST API and external task client support Jackson 2
  only. The recipe maps the `-jackson3` artifacts back to the Jackson 2 ones, but no recipe rewrites code that uses
  `tools.jackson.*` with Spin, REST or the client. It does not compile until you port it to `com.fasterxml.jackson.*`
  ([Operaton 2 and Spring Boot 4](12-operaton-2-and-spring-boot-4.md#jackson-2-and-jackson-3)).
- **Spring Boot 4.1 before Operaton 2.2.0 is GA.** Production needs Operaton 2.2.0, whose GA is due on 2026-10-23.
  Until then you can only rehearse with 2.2.0-RC1, so the GA date can set your go-live date. Running 2.1.5 on Spring
  Boot 4.1 is not supported ([target-version decision, D1](01-migration-path-and-decisions.md#d1)).
- **Spring Boot 4.2 or newer.** No Operaton release is built with it yet. Migrate on Spring Boot 4.1, or wait for the
  matching Operaton line ([target-version decision, D1](01-migration-path-and-decisions.md#d1)).
- **Polyflow (`camunda-bpm-taskpool`).** There is no Operaton adapter, so it blocks every application that uses it.
- **Liquibase-managed engine schema.** A naive switch fails on the first start, because Operaton changed the
  changelog path and author. Apply the fix from
  [Database: schema, data and SQL scripts](08-database-schema-data-and-sql-scripts.md#liquibase) and set
  `schema-update: false` ([schema-management decision, D8](01-migration-path-and-decisions.md#d8)).
- **Long-running instances with `org.camunda.*` variables or scripts.** Convert the variables
  ([legacy-variables decision, D18](01-migration-path-and-decisions.md#d18)). Make the scripts package-free (no
  `org.camunda.*` reference, only process variables and the pre-bound `S(…)` function), deploy them on 7.24 and
  migrate the running instances to the new version there, **before** the cut-over. The alternative is to drain them.
  The drain time can set the cut-over date
  ([rollback and point-of-no-return decision, D15](01-migration-path-and-decisions.md#d15)).
- **Several applications on one engine database.** Camunda and Operaton nodes must never work on the same database
  at the same time (no mixed cluster), so all applications switch in one coordinated cut-over
  ([cut-over strategy decision, D7](01-migration-path-and-decisions.md#d7)).
- **Typed exporter payloads with many consumers.** Publish on a versioned topic, let consumers read both formats
  (dual-read), and get each consumer team's sign-off
  ([history-exporters decision, D9](01-migration-path-and-decisions.md#d9)).
- **WAR / shared engine.** Out of scope for this guide, which covers Spring Boot with an embedded engine. Use the
  official migration guide.

## Watch out

Each row is a mistake that hides during the assessment and shows up later, with its cause and the fix.

| Symptom | Cause | Fix |
|---|---|---|
| Clean start, then "column … does not exist" | Schema older than 7.23 | Finish Step 0. |
| The report shows no `CAMUNDA_BPM_*`, but production ignores the admin user and the webapp path | The variables live in a Helm/GitOps repository you did not scan | Scan every config repository. |
| No `camunda-admin` in code, yet admins lose their rights and the Admin webapp offers "create initial admin user" | The group exists only as data in the database | Always run the admin-group check (P03). |
| Script import fixed, but old instances still fail | Deployed versions keep the old script | Run the deployed-scripts scan (L3/L4). |
| The dry run of an EE build fails with resolution, 401 or 403 errors | The rewrite plugin resolves all dependencies first and has no EE credentials | Provide `camunda-bpm-nexus-ee` in `~/.m2/settings.xml`, or `MAVEN_ARGS="-s <settings with the EE credentials>"`. |
| `migrate.sh` warns `Operaton 2.1.5 is built with Spring Boot 4.0.8 …` | Spring Boot 4.1 project with the default target | Rehearse with `--target 2.2.0-RC1`, go live with `--target 2.2.0`. |
| The Operaton start fails with `… were left unbound` under `operaton.bpm.generic-properties.properties` | An EE-only engine setting such as `queryExpressionAllowListEnabled` is still a generic property | Remove it ([EE-only engine settings](04-spring-boot-dependencies-and-configuration.md#ee-only-engine-settings)). |
