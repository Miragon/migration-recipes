#!/usr/bin/env bash
# test-boot4-path.sh - end-to-end test of the Spring Boot 4 path (Camunda 7.24 EE on Spring Boot 4 -> Operaton 2.x)
# without access to the Camunda EE repository.
#
#   1. Writes a STUB Camunda EE repository: POMs (+ empty jars) for the -4 starters, -4-webapp-ee, the -jackson3
#      artifacts and org.camunda.bpm:camunda-bom:7.24.16-ee. Every stub depends on (BOM: imports) its public CE
#      7.24.0 counterpart on Maven Central, so Maven and OpenRewrite see real org.camunda types. Nothing in it is
#      a real EE artifact.
#   2. Derives a Spring Boot 4 fixture from examples/camunda7-spring-boot-legacy (parent 4.x, camunda.version
#      7.24.16-ee, -4 starters, -jackson3 artifacts - -4-rest-jackson3 next to -4-rest, both map to one Operaton
#      starter -, camunda.bpm.license-file) in a new git repository; scripts/assess.sh must report Camunda EE
#      and the Spring Boot 4 path for it.
#   3. Runs scripts/migrate.sh (source auto-detected) with MAVEN_ARGS pointing at the stub repository: --hop is
#      rejected, --dry-run changes nothing, then the real run (--with-infra-env).
#   4. Checks the result: no org.camunda groupIds except org.camunda.feel, operaton-bom = target, Spring Boot not
#      downgraded (at most a patch upgrade to the target's pairing), no explicit Operaton versions, no duplicate
#      dependencies, no license-file, no org.camunda imports, no Spring Boot 4 / EE findings of
#      scripts/verify-leftovers.sh.
#   5. Builds the result with Maven Central only: mvn -B -DskipTests verify (the tests contain deliberate literal
#      canaries, see examples/operaton-spring-boot-migrated/MIGRATION_REPORT.md - as in the CE e2e job).
#
# Part of the "Camunda 7 -> Operaton Migration Starter Pack" (Apache-2.0).
# Works with bash 3.2+ on macOS (BSD userland) and Linux (GNU userland). Needs git, mvn (3.9+ recommended),
# JDK 17+ and direct access to Maven Central (the user's ~/.m2/settings.xml is NOT used).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd -P)"
EXAMPLE="$ROOT/examples/camunda7-spring-boot-legacy"
MIGRATE="$ROOT/scripts/migrate.sh"
ASSESS="$ROOT/scripts/assess.sh"
VERIFY="$ROOT/scripts/verify-leftovers.sh"
EE_VERSION="7.24.16-ee"   # stub EE version (7.24.16-ee = first patch with the -jackson3 artifacts)
CE_VERSION="7.24.0"       # last Camunda 7 CE release on Maven Central (what the stubs delegate to)

usage() {
  cat <<EOF
Usage: tools/test-boot4-path.sh [options]

End-to-end test of the Spring Boot 4 path (Camunda 7.24 EE on Spring Boot 4 -> Operaton 2.x) with a stub EE
repository; see the header of this script for the steps. Exit code 0 = all checks passed.

Options:
  --spring-boot <version>   Spring Boot version of the fixture (parent; default: 4.0.8).
  --target <version>        Operaton 2.x target passed to migrate.sh (default: 2.1.5 for Spring Boot 4.0.x,
                            2.2.0-RC1 for 4.1.x - switch to 2.2.0 once it is GA).
  --keep                    Keep the work directory (fixture, stub repository, local Maven repository, logs).
                            It is always kept when a check fails.
  --maven-args "<args>"     Extra Maven arguments for every Maven call (split on spaces), e.g.
                            "-Dmaven.repo.local.tail=/path/to/repository".
  -h, --help                Show this help.

Environment:
  MVN   Maven executable (default: mvn). JAVA_HOME selects the JDK (17+).

Examples:
  tools/test-boot4-path.sh
  tools/test-boot4-path.sh --spring-boot 4.1.1 --target 2.2.0-RC1
EOF
}

# ----------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------
if [ -t 1 ]; then BOLD=$(printf '\033[1m'); RED=$(printf '\033[31m'); GRN=$(printf '\033[32m'); RST=$(printf '\033[0m'); else BOLD=""; RED=""; GRN=""; RST=""; fi
info() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 needs a value (see --help)"; }

FAILED=0
pass() { printf '  %sPASS%s %s\n' "$GRN" "$RST" "$*"; }
fail() { printf '  %sFAIL%s %s\n' "$RED" "$RST" "$*"; FAILED=$((FAILED + 1)); }
check() { # check <description> <command...>
  local d="$1"; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

minor_of() { printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }
patch_of() { local v="${1#*.}"; v="${v#*.}"; v="${v%%[!0-9]*}"; printf '%s' "${v:-0}"; }

# ----------------------------------------------------------------------------------------------
# arguments
# ----------------------------------------------------------------------------------------------
SPRING_BOOT="4.0.8"; TARGET=""; KEEP=0; EXTRA_MAVEN_ARGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --spring-boot) need_value "$@"; SPRING_BOOT="$2"; shift 2 ;;
    --spring-boot=*) SPRING_BOOT="${1#*=}"; shift ;;
    --target) need_value "$@"; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --keep) KEEP=1; shift ;;
    --maven-args) need_value "$@"; EXTRA_MAVEN_ARGS="$2"; shift 2 ;;
    --maven-args=*) EXTRA_MAVEN_ARGS="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
case "$SPRING_BOOT" in 4.*) ;; *) die "--spring-boot must be a Spring Boot 4.x version (got '$SPRING_BOOT')" ;; esac
if [ -z "$TARGET" ]; then
  case "$SPRING_BOOT" in
    4.1.*) TARGET="2.2.0-RC1" ;;   # switch to 2.2.0 once it is GA (due 2026-10-23)
    *) TARGET="2.1.5" ;;
  esac
fi

MVN="${MVN:-mvn}"
command -v git >/dev/null 2>&1 || die "git not found"
command -v "$MVN" >/dev/null 2>&1 || die "$MVN not found (set MVN=/path/to/mvn)"
[ -f "$EXAMPLE/pom.xml" ] || die "example not found: $EXAMPLE"
for f in "$MIGRATE" "$ASSESS" "$VERIFY"; do [ -x "$f" ] || die "not executable: $f"; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/boot4-path-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
on_exit() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "$KEEP" -eq 0 ]; then rm -rf "$WORK"; else printf 'Work directory kept: %s\n' "$WORK" >&2; fi
}
trap on_exit EXIT

PROJ="$WORK/project"
STUB_REPO="$WORK/ee-stub-repo"
LOG="$WORK/logs"; mkdir -p "$LOG"

# Maven: no user settings (mirrors would hide the stub repository), own local repository so that no stub
# reaches ~/.m2; ~/.m2/repository is reused read-only as "tail" (Maven 3.9+).
MAVEN_BASE="-B -ntp -Dmaven.repo.local=$WORK/m2"
mvn_ver="$("$MVN" -v 2>/dev/null | sed -n 's/^Apache Maven \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p' | head -n 1)"
if [ -d "$HOME/.m2/repository" ] && [ -n "$mvn_ver" ] && { [ "${mvn_ver% *}" -gt 3 ] || [ "${mvn_ver#* }" -ge 9 ]; }; then
  MAVEN_BASE="$MAVEN_BASE -Dmaven.repo.local.tail=$HOME/.m2/repository"
fi
[ -z "$EXTRA_MAVEN_ARGS" ] || MAVEN_BASE="$MAVEN_BASE $EXTRA_MAVEN_ARGS"

# ----------------------------------------------------------------------------------------------
# 1. stub EE repository
# ----------------------------------------------------------------------------------------------
EMPTY_JAR="$WORK/empty.jar"
make_empty_jar() {
  local d="$WORK/emptyjar"
  mkdir -p "$d/META-INF"; printf 'Manifest-Version: 1.0\n' > "$d/META-INF/MANIFEST.MF"
  if command -v jar >/dev/null 2>&1 && (cd "$d" && jar cfm "$EMPTY_JAR" META-INF/MANIFEST.MF) >/dev/null 2>&1; then return 0; fi
  if command -v zip >/dev/null 2>&1 && (cd "$d" && zip -q "$EMPTY_JAR" META-INF/MANIFEST.MF) >/dev/null 2>&1; then return 0; fi
  # last resort: an empty zip archive (end-of-central-directory record only)
  printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' > "$EMPTY_JAR"
}

STUB_GAS=""
stub() { # stub <groupId> <artifactId> <CE groupId> <CE artifactId>
  local g="$1" a="$2" cg="$3" ca="$4" d
  d="$STUB_REPO/$(printf '%s' "$g" | tr . /)/$a/$EE_VERSION"; mkdir -p "$d"
  cat > "$d/$a-$EE_VERSION.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$g</groupId><artifactId>$a</artifactId><version>$EE_VERSION</version><packaging>jar</packaging>
  <description>STUB of a Camunda 7.24 EE artifact for tests (delegates to the CE $CE_VERSION artifact)</description>
  <dependencies>
    <dependency><groupId>$cg</groupId><artifactId>$ca</artifactId><version>$CE_VERSION</version></dependency>
  </dependencies>
</project>
POM
  cp "$EMPTY_JAR" "$d/$a-$EE_VERSION.jar"
  STUB_GAS="$STUB_GAS $g:$a"
}

make_stub_repo() {
  local SB=org.camunda.bpm.springboot ga d
  make_empty_jar
  stub $SB camunda-bpm-spring-boot-starter-4                      $SB camunda-bpm-spring-boot-starter
  stub $SB camunda-bpm-spring-boot-starter-4-rest                 $SB camunda-bpm-spring-boot-starter-rest
  stub $SB camunda-bpm-spring-boot-starter-4-webapp               $SB camunda-bpm-spring-boot-starter-webapp
  stub $SB camunda-bpm-spring-boot-starter-4-webapp-ee            $SB camunda-bpm-spring-boot-starter-webapp
  stub $SB camunda-bpm-spring-boot-starter-4-webapp-core          $SB camunda-bpm-spring-boot-starter-webapp-core
  stub $SB camunda-bpm-spring-boot-starter-4-security             $SB camunda-bpm-spring-boot-starter-security
  stub $SB camunda-bpm-spring-boot-starter-4-test                 $SB camunda-bpm-spring-boot-starter-test
  stub $SB camunda-bpm-spring-boot-starter-4-external-task-client $SB camunda-bpm-spring-boot-starter-external-task-client
  # opt-in Jackson 3 artifacts of 7.24.16-ee (the stubs bring the Jackson 2 CE artifacts)
  stub $SB camunda-bpm-spring-boot-starter-4-rest-jackson3        $SB camunda-bpm-spring-boot-starter-rest
  stub org.camunda.spin camunda-spin-dataformat-json-jackson3     org.camunda.spin camunda-spin-dataformat-json-jackson
  stub org.camunda.spin camunda-spin-dataformat-all-jackson3      org.camunda.spin camunda-spin-dataformat-all
  stub org.camunda.bpm camunda-engine-rest-core-jakarta-jackson3  org.camunda.bpm camunda-engine-rest-core-jakarta
  stub org.camunda.bpm camunda-engine-rest-jakarta-jackson3       org.camunda.bpm camunda-engine-rest-jakarta
  stub org.camunda.bpm camunda-external-task-client-jackson3      org.camunda.bpm camunda-external-task-client
  # EE BOM: same coordinates as the CE BOM with the -ee version; imports the CE BOM and manages the stubs
  d="$STUB_REPO/org/camunda/bpm/camunda-bom/$EE_VERSION"; mkdir -p "$d"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<project xmlns="http://maven.apache.org/POM/4.0.0">\n  <modelVersion>4.0.0</modelVersion>\n'
    printf '  <groupId>org.camunda.bpm</groupId><artifactId>camunda-bom</artifactId><version>%s</version><packaging>pom</packaging>\n' "$EE_VERSION"
    printf '  <description>STUB of the Camunda 7.24 EE BOM for tests</description>\n'
    printf '  <dependencyManagement><dependencies>\n'
    printf '    <dependency><groupId>org.camunda.bpm</groupId><artifactId>camunda-bom</artifactId><version>%s</version><type>pom</type><scope>import</scope></dependency>\n' "$CE_VERSION"
    for ga in $STUB_GAS; do
      printf '    <dependency><groupId>%s</groupId><artifactId>%s</artifactId><version>%s</version></dependency>\n' "${ga%%:*}" "${ga#*:}" "$EE_VERSION"
    done
    printf '  </dependencies></dependencyManagement>\n</project>\n'
  } > "$d/camunda-bom-$EE_VERSION.pom"

  cat > "$WORK/settings-stub.xml" <<XML
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <!-- Maven Central + the throw-away stub EE repository (stands in for https://artifacts.camunda.com/artifactory/private/) -->
  <profiles>
    <profile>
      <id>camunda-ee-stub</id>
      <repositories>
        <repository>
          <id>camunda-ee-stub</id>
          <url>file://$STUB_REPO</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>
  <activeProfiles><activeProfile>camunda-ee-stub</activeProfile></activeProfiles>
</settings>
XML
  printf '<settings/>\n' > "$WORK/settings-central.xml"
}

# ----------------------------------------------------------------------------------------------
# 2. Spring Boot 4 fixture (Camunda 7.24.16-ee) from the legacy example
# ----------------------------------------------------------------------------------------------
make_fixture() {
  local n
  cp -R "$EXAMPLE" "$PROJ"
  rm -rf "$PROJ/target"
  # parent version (inside <parent> only), EE version, -4 starters, -jackson3 artifacts; -4-rest-jackson3 (maps
  # to the same Operaton starter as -4-rest: the recipe must not leave a duplicate) and -4-test before the last
  # </dependencies> (the <dependencies> of the project, not of <dependencyManagement>)
  n="$(grep -c '</dependencies>' "$PROJ/pom.xml")"
  awk -v sb="$SPRING_BOOT" -v ee="$EE_VERSION" -v last="$n" '
    /<parent>/ { inparent = 1 }
    inparent && /<version>/ { sub(/<version>[^<]*<\/version>/, "<version>" sb "</version>") }
    /<\/parent>/ { inparent = 0 }
    { sub(/<camunda\.version>[^<]*<\/camunda\.version>/, "<camunda.version>" ee "</camunda.version>") }
    { sub(/<artifactId>camunda-bpm-spring-boot-starter-webapp<\/artifactId>/, "<artifactId>camunda-bpm-spring-boot-starter-4-webapp-ee</artifactId>") }
    { sub(/<artifactId>camunda-bpm-spring-boot-starter-rest<\/artifactId>/, "<artifactId>camunda-bpm-spring-boot-starter-4-rest</artifactId>") }
    { sub(/<artifactId>camunda-spin-dataformat-json-jackson<\/artifactId>/, "<artifactId>camunda-spin-dataformat-json-jackson3</artifactId>") }
    /<\/dependencies>/ { seen++
      if (seen == last) {
        print "    <dependency>"
        print "      <groupId>org.camunda.bpm.springboot</groupId>"
        print "      <artifactId>camunda-bpm-spring-boot-starter-4-rest-jackson3</artifactId>"
        print "    </dependency>"
        print "    <dependency>"
        print "      <groupId>org.camunda.bpm.springboot</groupId>"
        print "      <artifactId>camunda-bpm-spring-boot-starter-4-test</artifactId>"
        print "      <scope>test</scope>"
        print "    </dependency>"
      }
    }
    { print }
  ' "$EXAMPLE/pom.xml" > "$PROJ/pom.xml"
  # EE-only key (camunda.bpm.license-file) directly below camunda: bpm:
  awk '{ print } /^camunda:/ { c = 1 } c == 1 && /^  bpm:/ { print "    license-file: classpath:camunda-license.txt"; c = 2 }' \
    "$EXAMPLE/src/main/resources/application.yaml" > "$PROJ/src/main/resources/application.yaml"

  for n in "<version>$SPRING_BOOT</version>" "<camunda.version>$EE_VERSION</camunda.version>" \
           camunda-bpm-spring-boot-starter-4-webapp-ee camunda-bpm-spring-boot-starter-4-rest \
           camunda-bpm-spring-boot-starter-4-test camunda-bpm-spring-boot-starter-4-rest-jackson3 \
           camunda-spin-dataformat-json-jackson3; do
    grep -q -- "$n" "$PROJ/pom.xml" || die "fixture: '$n' not set in pom.xml (example changed? adapt make_fixture)"
  done
  grep -q 'license-file:' "$PROJ/src/main/resources/application.yaml" || die "fixture: license-file not added to application.yaml"

  ( cd "$PROJ" && git init -q && git add -A \
      && git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false commit -q --no-verify -m baseline )
}

# ----------------------------------------------------------------------------------------------
# 4. checks on the migrated build
# ----------------------------------------------------------------------------------------------
# parent_version <pom>: version of spring-boot-starter-parent
parent_version() {
  awk '/<parent>/ { p = 1; b = "" } p { b = b $0 } /<\/parent>/ && p { p = 0
         if (b ~ /<artifactId>spring-boot-starter-parent<\/artifactId>/ && match(b, /<version>[^<]*<\/version>/)) print substr(b, RSTART + 9, RLENGTH - 19) }' "$1" | head -n 1
}

# bom_version <pom>: version of the imported org.operaton.bpm:operaton-bom (${property} resolved)
bom_version() {
  awk '
    /<properties>/ { inp = 1 } /<\/properties>/ { inp = 0 }
    inp && match($0, /<[A-Za-z0-9_.-]+>[^<]*</) { s = substr($0, RSTART + 1, RLENGTH - 2); n = s; sub(/>.*/, "", n); v = s; sub(/^[^>]*>/, "", v); props[n] = v }
    /<dependency>/ { d = 1; b = "" } d { b = b $0 }
    /<\/dependency>/ && d { d = 0
      if (b ~ /<artifactId>operaton-bom<\/artifactId>/ && match(b, /<version>[^<]*<\/version>/)) bom = substr(b, RSTART + 9, RLENGTH - 19) }
    END { if (match(bom, /^[$][{][^}]+[}]$/)) { n = substr(bom, 3, length(bom) - 3); if (n in props) bom = props[n] }; print bom }' "$1"
}

# explicit_operaton_versions <pom>: org.operaton* dependencies with a <version> (except the operaton-bom import)
explicit_operaton_versions() {
  awk '/<dependency>/ { d = 1; b = "" } d { b = b $0 }
       /<\/dependency>/ && d { d = 0
         if (b ~ /<groupId>org\.operaton/ && b ~ /<version>/ && b !~ /<artifactId>operaton-bom<\/artifactId>/) {
           gsub(/[ \t]+/, "", b); print b } }' "$1"
}

# duplicate_dependencies <pom>: groupId:artifactId:scope declared twice in the same <dependencies> section
duplicate_dependencies() {
  awk 'function t(b, n,   s) { if (!match(b, "<" n ">[^<]*</" n ">")) return ""; s = substr(b, RSTART + length(n) + 2, RLENGTH - 2 * length(n) - 5); gsub(/[ \t]/, "", s); return s }
       /<dependencies>/ { sec++ }
       /<dependency>/ { d = 1; b = "" } d { b = b $0 }
       /<\/dependency>/ && d { d = 0; k = t(b, "groupId") ":" t(b, "artifactId") ":" t(b, "scope"); if (seen[sec SUBSEP k]++) print k }' "$1"
}

no_camunda_groupids() {
  ! grep -rn --include=pom.xml '<groupId>org\.camunda' "$PROJ" | grep -v 'org\.camunda\.feel'
}
no_ee_coordinates() {
  ! grep -rnE --include=pom.xml 'camunda-bpm-spring-boot-starter-4|jackson3|[0-9]-ee<' "$PROJ"
}
no_camunda_imports() {
  ! grep -rnE '^import (static )?org\.camunda\.(bpm|spin|connect|commons)\.' "$PROJ/src"
}
no_license_file() {
  ! grep -rn 'license-file' "$PROJ/src/main/resources" "$PROJ/src/test/resources"
}
no_camunda_bpm_yaml() {
  ! grep -nE '^camunda:' "$PROJ/src/main/resources/application.yaml" && grep -qE '^operaton:' "$PROJ/src/main/resources/application.yaml"
}
bom_is_target() {
  local v; v="$(bom_version "$PROJ/pom.xml")"
  [ "$v" = "$TARGET" ] || { printf '    operaton-bom version: %s (expected %s)\n' "${v:-<none>}" "$TARGET"; return 1; }
}
no_duplicate_dependencies() {
  local x; x="$(duplicate_dependencies "$PROJ/pom.xml")"
  [ -z "$x" ] || { printf '%s\n' "$x" | sed 's/^/    duplicate: /'; return 1; }
}
no_explicit_operaton_versions() {
  local x; x="$(explicit_operaton_versions "$PROJ/pom.xml")"
  [ -z "$x" ] || { printf '%s\n' "$x" | sed 's/^/    /'; return 1; }
}
# Spring Boot: never downgraded, minor unchanged; on the target's minor raised to the target's Spring Boot.
spring_boot_policy() {
  local after expected
  after="$(parent_version "$PROJ/pom.xml")"
  expected="$SPRING_BOOT"
  if [ -n "$TARGET_SB" ] && [ "$(minor_of "$TARGET_SB")" = "$(minor_of "$SPRING_BOOT")" ] \
     && [ "$(patch_of "$TARGET_SB")" -gt "$(patch_of "$SPRING_BOOT")" ]; then
    expected="$TARGET_SB"
  fi
  printf '    Spring Boot %s -> %s (target %s is built with %s; expected %s)\n' "$SPRING_BOOT" "${after:-<none>}" "$TARGET" "${TARGET_SB:-?}" "$expected"
  [ "$after" = "$expected" ]
}

# ----------------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------------
info "Spring Boot 4 path end-to-end: Camunda $EE_VERSION (stub) on Spring Boot $SPRING_BOOT -> Operaton $TARGET"
info "Work directory: $WORK"
make_stub_repo
make_fixture
info "Fixture: $PROJ (git baseline committed), stub EE repository: $STUB_REPO"

# 2b. assess.sh on the fixture (read-only): EE edition and the Spring Boot 4 path
"$ASSESS" "$PROJ" > "$LOG/assessment.md" 2>&1 || true
check "assess.sh reports Camunda EE and the Spring Boot 4 path" \
  eval 'grep -q "^| Edition | \*\*Camunda EE" "$LOG/assessment.md" && grep -q "^| Migration path | \*\*Spring Boot 4 path" "$LOG/assessment.md"'

MIGRATE_ARGS="-s $WORK/settings-stub.xml $MAVEN_BASE"
info "MAVEN_ARGS for migrate.sh: $MIGRATE_ARGS"

# 3a. --hop is rejected for a Spring Boot 4 project (fails before Maven runs)
set +e
"$MIGRATE" --hop 1 "$PROJ" > "$LOG/hop-rejected.log" 2>&1; rc=$?
set -e
check "--hop 1 is rejected for a Spring Boot 4 project" \
  eval '[ "$rc" -ne 0 ] && grep -q -- "--hop belongs to the Spring Boot 3.5 path" "$LOG/hop-rejected.log"'

# 3b. dry run: detection boot4, nothing changed
info "migrate.sh --dry-run (log: $LOG/dry-run.log)"
set +e
MAVEN_ARGS="$MIGRATE_ARGS" "$MIGRATE" --dry-run --target "$TARGET" "$PROJ" > "$LOG/dry-run.log" 2>&1; rc=$?
set -e
check "dry run succeeds (exit $rc)" [ "$rc" -eq 0 ]
check "source auto-detected as boot4" grep -q 'Source: Spring Boot 4 (boot4' "$LOG/dry-run.log"
check "dry run writes target/rewrite/rewrite.patch" [ -s "$PROJ/target/rewrite/rewrite.patch" ]
check "dry run leaves the working tree unchanged" eval '[ -z "$(git -C "$PROJ" status --porcelain)" ]'
if [ "$rc" -ne 0 ]; then tail -n 40 "$LOG/dry-run.log" >&2; die "dry run failed - see $LOG/dry-run.log"; fi

# 3c. the real run
info "migrate.sh --with-infra-env --target $TARGET (log: $LOG/migrate.log)"
set +e
MAVEN_ARGS="$MIGRATE_ARGS" "$MIGRATE" --with-infra-env --target "$TARGET" "$PROJ" > "$LOG/migrate.log" 2>&1; rc=$?
set -e
if [ "$rc" -ne 0 ]; then tail -n 40 "$LOG/migrate.log" >&2; die "migrate.sh failed (exit $rc) - see $LOG/migrate.log"; fi
sed -n -e '/Source:/p' -e '/Path:/p' -e '/line Operaton/p' -e '/WARN/p' "$LOG/migrate.log" | sed 's/^/    /'
TARGET_SB="$(sed -n 's/.*target Operaton [^ ]* (built with Spring Boot \([^)]*\)).*/\1/p' "$LOG/migrate.log" | head -n 1)"
git -C "$PROJ" diff --stat | tail -n 1 | sed 's/^/    /'

# 4. checks
info "Checks"
check "no org.camunda groupIds left (except org.camunda.feel)" no_camunda_groupids
check "no -4 starters, -jackson3 artifacts or -ee versions left" no_ee_coordinates
check "operaton-bom version = $TARGET" bom_is_target
check "Operaton versions managed by operaton-bom (no explicit <version>)" no_explicit_operaton_versions
check "no duplicate dependencies (-4-rest and -4-rest-jackson3 -> one starter)" no_duplicate_dependencies
check "Spring Boot not downgraded, at most a patch upgrade to the target's pairing" spring_boot_policy
check "camunda.bpm.license-file removed" no_license_file
check "application.yaml: camunda: -> operaton:" no_camunda_bpm_yaml
check "no org.camunda.(bpm|spin|connect|commons) imports left" no_camunda_imports
# exit 1 is expected: the deliberate test canaries (MIGRATION_REPORT.md); none of the Spring Boot 4 / EE rules may fire
"$VERIFY" --no-color "$PROJ" > "$LOG/verify-leftovers.md" 2>&1 || true
check "verify-leftovers.sh: no Spring Boot 4 / EE findings (STARTER_4, JACKSON3_ARTIFACT, EE_*, ...)" \
  eval '! grep -E "^### (STARTER_4|JACKSON3_ARTIFACT|ENGINE_SPRING_6|EE_[A-Z_]+) " "$LOG/verify-leftovers.md"'

# 5. build with Maven Central only (stub artifacts removed from the local repository as well)
rm -rf "$STUB_REPO"
find "$WORK/m2" -type d -name "$EE_VERSION" -prune -exec rm -rf {} + 2>/dev/null || true
info "mvn -DskipTests verify with Maven Central only (log: $LOG/verify.log)"
set +e
# shellcheck disable=SC2086 # word splitting of the Maven arguments is intended
( cd "$PROJ" && env -u MAVEN_ARGS "$MVN" -s "$WORK/settings-central.xml" $MAVEN_BASE -DskipTests verify ) > "$LOG/verify.log" 2>&1; rc=$?
set -e
check "migrated project builds with Maven Central only (exit $rc)" [ "$rc" -eq 0 ]
[ "$rc" -eq 0 ] || grep -E '^\[ERROR\]' "$LOG/verify.log" | head -n 20 >&2 || true

if [ "$FAILED" -gt 0 ]; then
  printf '\n%s%s check(s) failed%s - fixture, logs and diff: %s\n' "$RED" "$FAILED" "$RST" "$WORK"
  exit 1
fi
printf '\n%sAll checks passed%s: Camunda %s on Spring Boot %s -> Operaton %s\n' "$GRN" "$RST" "$EE_VERSION" "$SPRING_BOOT" "$TARGET"
