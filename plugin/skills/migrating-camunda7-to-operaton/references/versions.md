<a id="versions-snapshot-dated-2026-10-06"></a>

# Versions (snapshot dated 2026-10-11)

This is the only file in the skill that holds dated version numbers. Other files say "see references/versions.md".
Refresh with `scripts/latest-versions.sh` before you pin anything (section 5). Full background:
[01 · Version matrix](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/01-migration-path-and-decisions.md#2-version-and-compatibility-matrix),
[12 · Operaton 2 and Spring Boot 4](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/12-operaton-2-and-spring-boot-4.md),
Spring Boot 3.5 path: [15 · Coming from Spring Boot 3.5](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/15-coming-from-spring-boot-3.md).

## Contents

1. Rules
2. Operaton lines and platform versions (and the Camunda 7.24 EE source)
3. Spring Boot pairing, support windows, release calendar
4. Migration tooling and ecosystem pins
5. Refreshing: `scripts/latest-versions.sh`
6. Checking what a project actually resolves

## 1. Rules

- **Released versions only in production.** Never `-M*`, `-RC*`, `alpha`, `beta`, `SNAPSHOT`. As of 2026-10-11 Maven
  Central's `maven-metadata.xml` for `org.operaton.bpm:operaton-bom` says `<latest>2.2.0-RC1</latest>` and
  `<release>2.2.0-RC1</release>`, so anything that resolves "latest" (version ranges, `versions:use-latest-releases`,
  Gradle `latest.release`, unconfigured bots) picks the release candidate. Import `operaton-bom` with an explicit version.
  Only exception: a Spring Boot 4.1 project rehearses with `2.2.0-RC1` ("not intended for production") until 2.2.0 is
  GA (due 2026-10-23), on a rehearsal branch, marked as such in the report.
- **Operaton and Spring Boot move together.** Use exactly the Spring Boot minor the Operaton release is built with
  (tables in sections 2 and 3); Operaton supports only these default pairs. Spring Boot 4 path: `migrate.sh` never
  downgrades Spring Boot and raises it at most to the target's patch within the same minor; a different minor only
  gets a warning with the recommended target. Operaton 2.x on Spring Boot 3 fails at startup with
  `could not find class [org.springframework.boot.jersey.autoconfigure.JerseyAutoConfiguration]` (operaton#3162).
- **Step 0 is Camunda 7.24.** Operaton's schema equals Camunda 7.24.0 (EE patch levels do not change it). Anything
  older: stop, upgrade to 7.24 first.
- **1.x never goes to production.** It is the Hop 1 checkpoint of the Spring Boot 3.5 path only (end of life).
- Record the date and the output of the refresh in `MIGRATION_REPORT.md` whenever you choose a version.

## 2. Operaton lines and platform versions

Source: POMs at the release tags, Maven Central, `SECURITY.md`; "via SB" = managed by the Spring Boot BOM.

| | Camunda 7.24.0 | Operaton 1.0.3 | Operaton 1.1.5 | Operaton 2.0.0 | Operaton 2.1.5 | Operaton 2.2.0-RC1 |
|---|---|---|---|---|---|---|
| Released | 2025-10-14 (last CE) | 2026-01-23 | 2026-07-24 | 2026-03-20 | 2026-09-18 | 2026-09-18 |
| Role | Step 0 baseline (CE, Spring Boot 3.5 path) | pinned by the official recipe; do not stop here | **Hop 1 checkpoint** (Spring Boot 3.5 path) | skip | **production target for Spring Boot 4.0** | **target line for Spring Boot 4.1**; rehearsals only until 2.2.0 GA (2026-10-23) |
| Spring Boot | 3.5.x (built with 3.5.5) | 3.5.10 | **3.5.16** | 4.0.4 | **4.0.8** | 4.1.1 |
| Spring Framework | 6.2.10 | 6.2.15 | 6.2.19 | 7.0.5 | 7.0.9 | 7.0.9 |
| Jakarta EE | 10 (+ `javax` variants) | 10 | 10 | 11 | 11 | 11 |
| Java min / tested | 11 / 11, 17, 21, 25 | 17 / 17, 21, 25 | 17 / 17, 21, 25 | 17 / 17, 21, 25 | 17 / 17, 21, 25 | 17 / 17, 21, 25 |
| JUnit Jupiter (via SB) | 5.12 | 5.12 | 5.12.2 | 6.0.3 | 6.0.3 | 6.0.3 |
| Engine test jars | in main jar / `camunda-bpm-junit5` | classifiers `junit4`, `junit5` | `junit4`, `junit5`, `junit6` | same | same | same |
| Jackson: Spring / Spin + REST | 2 / 2 | 2 / 2 | 2 (2.21.4) / 2 | **3** (3.1.0) / 2 | 3 (3.1.5) / 2 (2.21.x) | 3 (3.1.5) / 2 |
| Testcontainers (via SB) | 1.21 | 1.21 | 1.21.4 | 2.0.4 | 2.0.5 | 2.0.5 |
| Liquibase (via SB) | 4.31 | 4.31 | 4.31.1 | 5.0.2 (FSL licence) | 5.0.3 | 5.0.3 |
| Groovy (via SB, embedded apps) | 4 | 4 | 4.0.32 | 5.0.4 | 5.0.8 | 5.0.8 |
| FEEL `org.camunda.feel:feel-engine` | 1.19.3 | 1.19.3 | 1.19.5 (shaded) | 1.21.0 | 1.21.1 (shaded) | 1.22.0 (**unshaded**) |
| Schema log (`ACT_GE_SCHEMA_LOG`) | 7.24.0 | 7.24.0 | 7.24.0 | 7.24.0 | 7.24.0 | 7.25.0 marker row, no DDL |
| `processEngine` health | always UP | always UP | always UP | always UP | DOWN on DB failure | same |
| Support (2026-10-11) | CE: EOL, no patches; EE 7.24 until 04/2030 | EOL | **EOL** (final 1.x) | superseded | maintained until 2.2 GA | not for production |

All Operaton 2.x artifacts exist without a `-4` infix (one set of starters per line: 1.x = Spring Boot 3.5, 2.x =
Spring Boot 4). Operaton 2.x Spin, engine REST and the external task client are **Jackson 2 only**: there are no
`-jackson3` artifacts (Operaton decided to stay on Jackson 2 for 2.x, issue operaton#1672).

**Camunda 7.24 Enterprise (the source of the Spring Boot 4 path).** EE versions are `7.24.N-ee`; the BOM is
`org.camunda.bpm:camunda-bom:7.24.N-ee` from the EE repository `https://artifacts.camunda.com/artifactory/private/`
(server id `camunda-bpm-nexus-ee`). Nothing of 7.24.1+ is on Maven Central: CE ended at 7.24.0 on Spring Boot 3.5 and
gets no Spring Boot 4 support. "Between patch levels, the structure of the database schema is not changed"; no 7.24.x
patch script is known (one would add a `7.24.N` schema-log row, id 1301–1399). EE 7.24 maintenance ends 13 Apr 2030.

| EE patch | Date | What matters for the migration |
|---|---|---|
| 7.24.3-ee | Jan 2026 | Spring Boot 4 via `-4` artifacts (groupId `org.camunda.bpm.springboot`: `camunda-bpm-spring-boot-starter-4`, `-4-rest`, `-4-webapp`, `-4-webapp-core`, `-4-security`, `-4-test`, `-4-external-task-client`; EE webapps `camunda-bpm-spring-boot-starter-4-webapp-ee`); `validateAuthResourceIdExists` (on by default); datasource autocommit verification |
| 7.24.6-ee | Apr 2026 ("Environment Update Release") | Spring 7 / Spring Boot 4.0 supported; `camunda-engine-spring-6` removed (`camunda-engine-spring` = Spring 7) |
| 7.24.7-ee | Apr 2026 | query-API expression allow-list (on by default); Camunda security notice 157 |
| 7.24.9-ee | May 2026 | Java 25 |
| 7.24.10-ee | Jun 2026 | starter based on **Spring Boot 4.1** (staying on 4.0 = import `spring-boot-dependencies` 4.0.7) |
| 7.24.16-ee | Oct 2026 | opt-in Jackson 3 artifacts (`camunda-spin-dataformat-all-jackson3`, `camunda-spin-dataformat-json-jackson3`, `camunda-bpm-spring-boot-starter-4-rest-jackson3`, `camunda-engine-rest-core-jakarta-jackson3`, `camunda-engine-rest-jakarta-jackson3`, `camunda-external-task-client-jackson3`); Jackson 2 stays the default |
| October 2026 environment update | Oct 2026 | ends EE support for Spring Boot 3.5, Spring 6 and Java 11 |

Script engines are **not shipped** and **not managed by `operaton-bom`**. Tested versions (Operaton's `parent/pom.xml` at
each tag; chapter [05 · Script engines](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/05-bpmn-dmn-forms-and-scripts.md#script-engines)):

| Engine | Camunda 7.24.0 | Operaton 1.1.5 | Operaton 2.1.5 | Operaton 2.2.0-RC1 | Who manages the version in your build |
|---|---|---|---|---|---|
| GraalJS (25.x coordinates: `org.graalvm.polyglot:polyglot`, `org.graalvm.polyglot:js` type `pom`, `org.graalvm.js:js-scriptengine`) | 21.3.12 | 25.0.4 | 25.0.4.1.1 | 25.3.4.1 | **nobody** (neither Spring Boot nor `operaton-bom`): pin it to the column of the Operaton version you build (2.1.5: 25.0.4.1.1; Spring Boot 3.5 path Hop 1: 25.0.4) |
| Groovy (`org.apache.groovy:groovy-jsr223`) | 4.0.22 | 5.0.7 | 5.0.8 | 5.1.2 | Spring Boot's BOM (not `operaton-bom`): declared without a version you get the "Groovy (via SB)" row above |
| Jython / JRuby | – | 2.7.4 / 9.1.17.0 | 2.7.4 / 9.1.17.0 | 2.7.4 / 9.1.17.0 | nobody: pin them |

Coordinates and the `pom` type: references/models-and-scripts.md §7. Every script must be executed by a test after the
migration (Spring Boot 3.5 path: after each hop; GraalJS 21 → 25, Groovy 4 → 5).

Database minimums (official): Operaton 2.0 = PostgreSQL 13, MariaDB 10.6, MySQL 8.4; **Operaton 2.1+ = PostgreSQL 14,
MariaDB 10.11, MySQL 8.4**; Oracle 21, SQL Server 2022 and DB2 unchanged. MySQL 8.0 / PostgreSQL 13 users plan a DB
upgrade. The Operaton "Supported Environments" page still shows Camunda-era values; trust the release notes.

## 3. Spring Boot pairing, support windows, release calendar

Spring Boot version each Operaton release is built with (`version.spring-boot` in `org.operaton.bpm:operaton-root:<v>`):

| Operaton | 1.1.5 | 2.0.0 | 2.1.0 / 2.1.1 | 2.1.2 / 2.1.3 | 2.1.4 / 2.1.5 | 2.2.0-RC1 |
|---|---|---|---|---|---|---|
| Spring Boot | 3.5.16 | 4.0.4 | 4.0.6 | 4.0.7 | 4.0.8 | 4.1.1 |

Spring Boot minor of the application → Operaton line (`latest-versions.sh` prints this table, 2026-10-11):

| Spring Boot | Operaton line | Newest release | Built with Spring Boot | Note |
|---|---|---|---|---|
| 3.5 | 1.1.x | 1.1.5 | 3.5.16 | 1.x is end of life: Hop 1 checkpoint of the Spring Boot 3.5 path only |
| 4.0 | 2.1.x | 2.1.5 | 4.0.8 | GA, supported pairing |
| 4.1 | 2.2.x | 2.2.0-RC1 | 4.1.1 | pre-release only, no GA yet: rehearsals, never production |

Spring Boot 4.2 or newer: no Operaton line is built with it yet (`assess.sh` says so): migrate on 4.1 or wait.
Operaton 2.1.5 on Spring Boot 4.1.1 started and passed a smoke test, but it is not a supported pairing. 2.2 uses a
Spring Boot 4.1-only API (`FailureAnalyzedException`), so treat it as a 4.1-only line.

Spring Boot OSS support: 3.5 ended **2026-06-30**; 4.0 ends **2026-12-31**; 4.1 ends **2027-07-31**.

Operaton cadence: a minor every six months (April and October), monthly patches for the current minor, **no LTS**;
each minor is supported until the next one ships. `SECURITY.md` (2026-10-11): 2.1.x fully maintained; 1.1.x EOL
(final 1.1.5); 1.0.x EOL (final 1.0.3).

| Date | Event |
|---|---|
| 2026-10-23 | **Operaton 2.2.0 GA** (Spring Boot 4.1) and 2.1.6; support for 2.1 ends with the 2.2 release |
| 2026-11-20 | 2.2.1 scheduled |
| 2026-12-18 | 2.2.2 scheduled |
| April 2027 | 2.3 / 3.0 planned (roadmap shows a possible Java baseline change, "(17?)") |
| April 2030 | Camunda 7 EE 7.24 maintenance ends (paid extended support until April 2032) |

Target rule (decision D1: production = latest GA patch of the line that matches the application's Spring Boot minor):

| Application on | Go-live before 2026-10-23 | Go-live after 2026-10-23 |
|---|---|---|
| Spring Boot 4.0 (the default of Camunda 7.24.3-ee … 7.24.9-ee) | 2.1.5 (2.1.6 if out); plan 2.2.x right after hypercare (needs Spring Boot 4.1: own commit first) | 2.1.5 / 2.1.6 now; 2.1 support ends with 2.2.0, so plan the Spring Boot 4.1 upgrade and 2.2.x soon after |
| Spring Boot 4.1 (the default from Camunda 7.24.10-ee) | not possible on a supported pairing: rehearse with 2.2.0-RC1 (never production), wait for 2.2.0 | develop and rehearse with 2.2.0-RC1 now; switch to 2.2.0 once GA (`--target 2.2.0`); final rehearsal on the exact version you deploy (or go live on 2.2.1) |
| Spring Boot 3.5 (Spring Boot 3.5 path) | Hop 2 to 2.1.5 (2.1.6 if out); plan the 2.2.x bump right after hypercare | develop and rehearse on 2.1.5 now; optionally a preview branch on 2.2.0-RC1 (never production); switch to 2.2.x once GA; final rehearsal on the exact version you deploy (or go live on 2.2.1) |

2.1 → 2.2 is a small step: Spring Boot 4.0 → 4.1, unshaded FEEL (Scala libraries on your classpath), the `7.25.0`
schema-log row (Flyway/DBA users: `*_engine_7.24_to_7.25.sql`; `migrate.sh` prints the reminder for a 2.2.x target),
previews (`SKIP LOCKED` acquisition, webapps-neo) left off. The `7.25.0` row does not block a rollback (no engine reads
the schema log).

## 4. Migration tooling and ecosystem pins

| Artifact | Pinned | Notes |
|---|---|---|
| `org.operaton:migrate-camunda-recipe` | **1.0.1** | official, latest (main unchanged); pins Operaton `1.0.x` (→ 1.0.3); recipe YAML unchanged since 1.0.0. Maps no `-4` starter, no `-jackson3` artifact, not `-webapp-core`; maps `-webapp-ee` / `camunda-webapp-webjar-ee` to CE; deletes `camunda.bpm.license-file`; leaves `<repositories>` alone |
| `org.openrewrite.maven:rewrite-maven-plugin` | **6.46.1** | newest on Maven Central (rewrite 8.89.0); renames `META-INF/services` contents. Upstream README shows 6.28.1: leaves `org.camunda…` lines in services files and a stale `<camunda.version>` property. Resolves all (test) dependencies before a recipe runs: EE builds need the EE repository |
| `org.openrewrite.recipe:rewrite-spring` | **6.37.0** | provides `UpgradeSpringBoot_4_0` (Hop 2 of the Spring Boot 3.5 path) and `SpringBootProperties_4_1` (no `UpgradeSpringBoot_4_1`); Moderne Source Available License. 6.37.1 exists; 6.37.0 is pinned to match the plugin's rewrite 8.89.0 |
| `org.openrewrite:plugin` (Gradle) | **7.39.0** | 7.40.0 / 7.41.0 need `rewrite-bom` 8.91.0, which is not on Maven Central |
| `org.openrewrite.recipe:rewrite-recipe-bom` | 3.37.0 | only if you add recipe modules; 3.38.0 references modules missing on Central |
| `operaton/operaton-rewrite` (1.x → 2.x) | — | **unreleased** (`0.1.0-SNAPSHOT`); do not use. Hop 2 = `starterpack.operaton.UpgradeToOperaton2` |
| `scripts/migrate.sh` defaults | Spring Boot 4 path: `--target` 2.1.5, Spring Boot never downgraded (patch upgrade within the minor only). Spring Boot 3.5 path: Hop 1 → 1.1.5 + SB 3.5.16; Hop 2 `--target` 2.1.5 | built-in pairs: 2.1.5/2.1.4 = 4.0.8, 2.1.3/2.1.2 = 4.0.7, 2.1.1/2.1.0 = 4.0.6, 2.0.0 = 4.0.4; other targets read from Maven Central |
| `org.operaton.bpm.extension:operaton-keycloak` | **2.1.0** (Operaton 2.1, SB 4.0); 1.1.0 (Operaton 1.1, Hop 1 of the Spring Boot 3.5 path) | 2.0.0-M1 and 2.2.0-M1 are milestones only: wait for a 2.2 GA of the plugin before moving to Operaton 2.2. The official recipe maps it to `1.0.x`: bump it |
| `org.operaton.bpm.identity:operaton-identity-ldap` | managed by `operaton-bom` | available for 1.1.5 and 2.1.5 |
| process-test-coverage fork | `io.github.ronalders:operaton-process-test-coverage-*:1.0.0` | built against Operaton 1.1.2; pin it, import `operaton-bom` |
| scenario runner fork | `io.github.ronalders:operaton-platform-scenario-runner:1.1.2` | align with the BOM |
| `org.operaton.bpm.distro:operaton-sql-scripts` | 7.24.0 on Central (also 7.23.0, 7.23.1) | no 7.25.0 artifact yet: take `7.24_to_7.25` from the `operaton-sql-scripts-7.25.0.tar.gz` release asset or the `operaton-engine` 2.2 jar |
| Docker images `operaton/operaton`, `operaton/tomcat`, `operaton/wildfly` | exact tag (e.g. `2.1.5`) | distributions, not base images for an embedded app; `latest` moves |
| Helm chart `operaton/operaton-helm` | — | stale (chart 1.0.5, appVersion 1.0.3); reference only |

Newer OpenRewrite releases are published to the Code Genome Project repository (login required). Do not switch to
them; the pins above are the newest combination fully available on Maven Central.

## 5. Refreshing: `scripts/latest-versions.sh`

```bash
bash "<skill-dir>/scripts/latest-versions.sh"                     # latest GA per line + paired Spring Boot + Spring Boot minor -> line + tooling
bash "<skill-dir>/scripts/latest-versions.sh" --operaton 2.1.5    # also: Spring Boot of one specific release
bash "<skill-dir>/scripts/latest-versions.sh" --all-lines         # include lines older than 1.1
MAVEN_CENTRAL=https://mirror.example.com/maven2 bash "<skill-dir>/scripts/latest-versions.sh"   # behind a proxy
```

It reads Maven Central (and the Gradle plugin portal), ignores pre-releases for the GA columns (a line with only
pre-releases is shown as such in the Spring Boot table), prints Markdown, and compares with the pins in
`scripts/migrate.sh`. Exit 1 = metadata unreadable (offline/proxy: set `MAVEN_CENTRAL`); exit 2 = usage error.

How to act on the output:

| Output says | Do |
|---|---|
| a newer patch on the 2.x line you target | target it: `migrate.sh --target <v>` (Spring Boot 3.5 path: `--hop 2 --target <v>`) reads the paired Spring Boot from `operaton-root-<v>.pom` |
| the Spring Boot 4.1 row shows a GA (2.2.x) | Spring Boot 4.1 projects: switch from `2.2.0-RC1` to the GA (`--target 2.2.0`), re-run the final rehearsal on it. Spring Boot 4.0 projects: target it after a Spring Boot 4.1 upgrade (own commit). Spring Boot 3.5 path: target it if go-live is after its GA (section 3); `migrate.sh` warns that the Hop 2 recipe list is written for Spring Boot 4.0: afterwards run `org.openrewrite.java.spring.boot4.SpringBootProperties_4_1` and follow [12 · Moving from 2.1.x to 2.2.x](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/12-operaton-2-and-spring-boot-4.md#moving-from-21x-to-22x) |
| `<release>` is a pre-release | expected; pin explicitly, never follow it |
| tooling newer than pinned | keep the pins unless the user asks; newer OpenRewrite artifacts may not resolve from public repositories |
| a newer 1.1.x | impossible by policy (1.x is EOL); if it happens, re-read `SECURITY.md` before changing Hop 1 |
| `n/a (lookup failed)` | network or mirror problem; do not guess versions, report it |

If the refreshed facts contradict this file (new GA, changed support status), trust Maven Central and the Operaton
`SECURITY.md`, keep the pairing rule, and note the difference in the report. Do not edit the skill's files.

## 6. Checking what a project actually resolves

```bash
mvn -B dependency:tree | grep -E 'operaton-engine|spring-boot:jar'     # intended versions, no -RC / -M
mvn -B dependency:tree -Dincludes=org.scala-lang,com.fasterxml.jackson.module   # 2.2+: Scala libraries brought by FEEL
```

- `GET /engine-rest/version` returns the Operaton version (`7.24.0` or any other `7.x` = still Camunda);
  `smoke-test.sh --require-operaton` fails on `7.x`.
- Startup banner `Operaton: (v<version>)` plus `Running with Spring Boot v<version>` confirms the pair.
- Keep bots off pre-releases and Spring Boot minors: Renovate `allowedVersions` excluding `-M`/`-RC`, Dependabot
  `ignore` for `spring-boot-starter-parent` minor/major, and the CI guard that compares `project.parent.version` with
  `version.spring-boot` of `operaton-root-<operaton.version>.pom`. Ready-made configs:
  [12 · Keeping up afterwards](https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/docs/12-operaton-2-and-spring-boot-4.md#7-keeping-up-afterwards).
- A pipeline rule that rejects production releases with an Operaton 1.x dependency keeps the checkpoint out of production.
