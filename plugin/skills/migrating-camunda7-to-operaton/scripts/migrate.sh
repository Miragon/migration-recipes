#!/usr/bin/env bash
# migrate.sh - run the Camunda 7 -> Operaton OpenRewrite recipes of the starter pack on a project.
#
# Part of the "Camunda 7 -> Operaton Migration Starter Pack" (Apache-2.0).
# Works with bash 3.2+ on macOS (BSD userland) and Linux (GNU userland).

set -euo pipefail

# ----------------------------------------------------------------------------------------------
# Pinned defaults (as of 2026-10-06; check with scripts/latest-versions.sh)
# ----------------------------------------------------------------------------------------------
DEFAULT_PLUGIN_VERSION="6.46.1"          # org.openrewrite.maven:rewrite-maven-plugin (latest on Maven Central)
DEFAULT_RECIPE_VERSION="1.0.1"           # org.operaton:migrate-camunda-recipe
DEFAULT_REWRITE_SPRING_VERSION="6.37.0"  # org.openrewrite.recipe:rewrite-spring (matches rewrite 8.89.0 of plugin 6.46.1)
DEFAULT_GRADLE_PLUGIN_VERSION="7.39.0"   # org.openrewrite:plugin (7.40+ cannot resolve rewrite-bom 8.91.0 from public repos)
DEFAULT_TARGET="2.1.5"                   # Operaton 2.x target of the Spring Boot 4 path and of Hop 2
# Fallback when Maven Central cannot be read (version.spring-boot in org.operaton.bpm:operaton-root:<version>)
KNOWN_SPRING_BOOT_FOR_TARGET="2.2.0-RC1=4.1.1 2.1.5=4.0.8 2.1.4=4.0.8 2.1.3=4.0.7 2.1.2=4.0.7 2.1.1=4.0.6 2.1.0=4.0.6 2.0.0=4.0.4"

PLAIN_TEXT_MASKS='**/*.bpmn,**/*.bpmn20.xml,**/*.dmn,**/*.dmn11.xml,**/*.cmmn,**/*.cmmn10.xml,**/*.cmmn11.xml,**/*.form,**/*.groovy,**/*.gvy,**/*.js,**/*.mjs,**/*.py,**/*.rb,**/*.ftl'

# Files and folders the starter pack / Claude skill writes into the project root before a run: they do not
# make the working tree "dirty" (untracked or modified).
DIRTY_IGNORED="MIGRATION_REPORT.md, .operaton-migration-ignore, migration/"

# ----------------------------------------------------------------------------------------------
# layout: starter-pack repository (rewrite/rewrite.yml, docs/) or the bundled Claude skill
# (assets/rewrite.yml next to scripts/, no docs/ -> chapter links point to the guide on GitHub)
# ----------------------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd -P)"
GUIDE_URL="https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton"
if [ -d "$SCRIPT_DIR/../assets" ] && [ ! -d "$SCRIPT_DIR/../docs" ]; then
  LAYOUT="skill"; DOCS="$GUIDE_URL/docs"; REWRITE_REL="assets/rewrite.yml"
else
  LAYOUT="repo"; DOCS="docs"; REWRITE_REL="rewrite/rewrite.yml"
fi

usage() {
  cat <<EOF
Usage: migrate.sh [options] [project-dir]

Runs the starter-pack OpenRewrite recipes (${REWRITE_REL}) on a Maven or Gradle project without
changing its build files: Maven calls the rewrite-maven-plugin by its coordinates and passes the recipes with
-Drewrite.configLocation; Gradle gets a temporary init script (OpenRewrite Gradle plugin).

The path depends on the Spring Boot version of the project (--source, detected by default):

  boot4  Spring Boot 4 (Camunda 7.24 EE, -4 starters): Camunda 7.24 -> Operaton 2.x in one step
         recipe starterpack.operaton.MigrateSpringBoot4App (one run, one commit)
  boot3  Spring Boot 3.5: two hops (${DOCS}/15-coming-from-spring-boot-3.md)
         Hop 1  Camunda 7.24 -> Operaton 1.1.x (Spring Boot 3.5.16)  recipe starterpack.operaton.MigrateSpringBootApp
         Hop 2  Operaton 1.1.x -> Operaton 2.x (Spring Boot 4.0)     recipe starterpack.operaton.UpgradeToOperaton2

Options:
  --source auto|boot4|boot3 Migration path (default: auto). auto picks boot4 if the build uses Spring Boot 4
                            (parent spring-boot-starter-parent, imported spring-boot-dependencies or Gradle
                            plugin org.springframework.boot 4.x) or a camunda-bpm-spring-boot-starter-4*
                            artifact, otherwise boot3.
  --dry-run                 Do not change files; write target/rewrite/rewrite.patch (Gradle:
                            build/reports/rewrite/rewrite.patch) and show its stats.
  --target <version>        Operaton 2.x version (default: 2.1.5). Spring Boot 4.0 -> 2.1.5; Spring Boot
                            4.1 -> 2.2.0 (GA due 2026-10-23; 2.2.0-RC1 for rehearsals only, never production).
                            The Spring Boot version the target is built with is read from
                            org.operaton.bpm:operaton-root:<version> on Maven Central. boot4: Spring Boot is
                            never downgraded; it gets at most a patch upgrade to that version within its minor.
  --spring-boot <version>   Override the Spring Boot version paired with --target (default: derived from
                            --target). boot3: the Spring Boot version of Hop 2.
  --with-infra-env          Also rename CAMUNDA_BPM_* -> OPERATON_BPM_* in Dockerfiles, .env, compose and
                            k8s/helm YAML (recipe starterpack.operaton.InfraEnvVars; boot4 or Hop 1).
  --with-form-keys          Also rename camunda-forms: -> operaton-forms: in BPMN files (decision D4,
                            recipe starterpack.operaton.FormKeys; boot4 or Hop 1). Operaton-only: versions with
                            open tasks on these keys are a rollback hard stop (D15); formRef (D4 option C)
                            is the rollback-safe alternative.
  --hop 1|2|all             boot3 only: which hop to run (default: 1). "all" runs Hop 1 and Hop 2 back to
                            back (one combined diff; only for small, well-tested services - see decision D1).
                            Rejected for boot4 (one step, no hops).
  --plugin-version <v>      rewrite-maven-plugin version (default: 6.46.1).
  --recipe-version <v>      org.operaton:migrate-camunda-recipe version (default: 1.0.1).
  --rewrite-spring-version <v>  org.openrewrite.recipe:rewrite-spring version (default: 6.37.0).
  --gradle-plugin-version <v>   OpenRewrite Gradle plugin version for Gradle builds (default: 7.39.0).
  --rewrite-yml <file>      Use another composite recipe file (default: ${REWRITE_REL} of the
                            $([ "$LAYOUT" = skill ] && echo "skill" || echo "starter pack")).
  --force                   Run even if the project is not a git repository or the working tree is dirty.
                            MIGRATION_REPORT.md, .operaton-migration-ignore and migration/ in the
                            project root never count as dirty (untracked or modified).
  -h, --help                Show this help.

Environment:
  MAVEN_ARGS    Extra Maven arguments, e.g. MAVEN_ARGS="-s /path/settings.xml -Dmaven.repo.local=/tmp/m2"
                (split on spaces; no quoting, so no spaces inside one argument)
  GRADLE_ARGS   Extra Gradle arguments for Gradle builds.
  MVN / GRADLE  Maven / Gradle executable (default: ./mvnw or mvn, ./gradlew or gradle).

Camunda EE builds (7.24.N-ee, -4 starters): the rewrite plugin resolves all dependencies before the recipes
run, so the run needs the Camunda EE repository credentials (server id camunda-bpm-nexus-ee in
~/.m2/settings.xml). After the migration nothing needs the EE repository any more.

Examples:
  scripts/migrate.sh --dry-run ~/src/order-service                        # Spring Boot 4: preview
  scripts/migrate.sh --with-infra-env ~/src/order-service                 # Spring Boot 4.0 -> Operaton 2.1.5
  scripts/migrate.sh --with-infra-env --target 2.2.0 ~/src/order-service  # Spring Boot 4.1 -> Operaton 2.2.0
  scripts/migrate.sh --hop 1 --dry-run ~/src/legacy-service               # Spring Boot 3.5: Hop 1 preview
  MAVEN_ARGS="-s \$HOME/.m2/central.xml" scripts/migrate.sh --hop 1 --with-infra-env ~/src/legacy-service
  scripts/migrate.sh --hop 2 --target 2.1.5 ~/src/legacy-service

After a run: review "git diff", run scripts/verify-leftovers.sh, build and test, commit (Spring Boot 4: one
commit; Spring Boot 3.5: one commit per hop).
Guide: ${DOCS}/03-openrewrite-recipes.md
EOF
}

# ----------------------------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------------------------
if [ -t 1 ]; then BOLD=$(printf '\033[1m'); RED=$(printf '\033[31m'); YEL=$(printf '\033[33m'); GRN=$(printf '\033[32m'); RST=$(printf '\033[0m'); else BOLD=""; RED=""; YEL=""; GRN=""; RST=""; fi
info() { printf '%s==>%s %s\n' "$BOLD" "$RST" "$*"; }
warn() { printf '%sWARN:%s %s\n' "$YEL" "$RST" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "option $1 needs a value (see --help)"; }

abs_path() { (cd "$1" >/dev/null 2>&1 && pwd -P); }

# ----------------------------------------------------------------------------------------------
# arguments
# ----------------------------------------------------------------------------------------------
HOP="1"; HOP_SET=0; SOURCE="auto"; DRY_RUN=0; TARGET="$DEFAULT_TARGET"; SPRING_BOOT=""; WITH_INFRA=0; WITH_FORMS=0; FORCE=0
PLUGIN_VERSION="$DEFAULT_PLUGIN_VERSION"; RECIPE_VERSION="$DEFAULT_RECIPE_VERSION"
REWRITE_SPRING_VERSION="$DEFAULT_REWRITE_SPRING_VERSION"; GRADLE_PLUGIN_VERSION="$DEFAULT_GRADLE_PLUGIN_VERSION"
REWRITE_YML=""; PROJECT_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hop) need_value "$@"; HOP="$2"; HOP_SET=1; shift 2 ;;
    --hop=*) HOP="${1#*=}"; HOP_SET=1; shift ;;
    --source) need_value "$@"; SOURCE="$2"; shift 2 ;;
    --source=*) SOURCE="${1#*=}"; shift ;;
    --dry-run|--dryrun) DRY_RUN=1; shift ;;
    --target) need_value "$@"; TARGET="$2"; shift 2 ;;
    --target=*) TARGET="${1#*=}"; shift ;;
    --spring-boot) need_value "$@"; SPRING_BOOT="$2"; shift 2 ;;
    --spring-boot=*) SPRING_BOOT="${1#*=}"; shift ;;
    --with-infra-env) WITH_INFRA=1; shift ;;
    --with-form-keys) WITH_FORMS=1; shift ;;
    --plugin-version) need_value "$@"; PLUGIN_VERSION="$2"; shift 2 ;;
    --plugin-version=*) PLUGIN_VERSION="${1#*=}"; shift ;;
    --recipe-version) need_value "$@"; RECIPE_VERSION="$2"; shift 2 ;;
    --recipe-version=*) RECIPE_VERSION="${1#*=}"; shift ;;
    --rewrite-spring-version) need_value "$@"; REWRITE_SPRING_VERSION="$2"; shift 2 ;;
    --rewrite-spring-version=*) REWRITE_SPRING_VERSION="${1#*=}"; shift ;;
    --gradle-plugin-version) need_value "$@"; GRADLE_PLUGIN_VERSION="$2"; shift 2 ;;
    --gradle-plugin-version=*) GRADLE_PLUGIN_VERSION="${1#*=}"; shift ;;
    --rewrite-yml) need_value "$@"; REWRITE_YML="$2"; shift 2 ;;
    --rewrite-yml=*) REWRITE_YML="${1#*=}"; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$PROJECT_DIR" ] || die "only one project directory allowed"; PROJECT_DIR="$1"; shift ;;
  esac
done
if [ $# -gt 0 ] && [ -z "$PROJECT_DIR" ]; then PROJECT_DIR="$1"; fi
PROJECT_DIR="${PROJECT_DIR:-.}"

case "$HOP" in 1|2|all) ;; *) die "--hop must be 1, 2 or all (got '$HOP')" ;; esac
case "$SOURCE" in auto|boot4|boot3) ;; *) die "--source must be auto, boot4 or boot3 (got '$SOURCE')" ;; esac
[ -d "$PROJECT_DIR" ] || die "project directory not found: $PROJECT_DIR"
PROJECT_DIR="$(abs_path "$PROJECT_DIR")"

case "$TARGET" in
  2.*) ;;
  *) die "--target must be an Operaton 2.x version (got '$TARGET'); Hop 1 of the Spring Boot 3.5 path always targets the final 1.1.x" ;;
esac
case "$TARGET" in
  *-M*|*-RC*|*-rc*|*SNAPSHOT*) warn "--target $TARGET is a pre-release; use released versions for production (decision D1)" ;;
esac

# ----------------------------------------------------------------------------------------------
# locate the composite recipe file
# ----------------------------------------------------------------------------------------------
if [ -z "$REWRITE_YML" ]; then
  for candidate in "$SCRIPT_DIR/../rewrite/rewrite.yml" "$SCRIPT_DIR/../assets/rewrite.yml" "$SCRIPT_DIR/rewrite.yml"; do
    if [ -f "$candidate" ]; then REWRITE_YML="$candidate"; break; fi
  done
fi
[ -n "$REWRITE_YML" ] && [ -f "$REWRITE_YML" ] || die "rewrite.yml not found (use --rewrite-yml <file>)"
REWRITE_YML="$(abs_path "$(dirname "$REWRITE_YML")")/$(basename "$REWRITE_YML")"

# ----------------------------------------------------------------------------------------------
# build tool
# ----------------------------------------------------------------------------------------------
BUILD=""
if [ -f "$PROJECT_DIR/pom.xml" ]; then
  BUILD="maven"
elif [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ] || [ -f "$PROJECT_DIR/settings.gradle" ] || [ -f "$PROJECT_DIR/settings.gradle.kts" ]; then
  BUILD="gradle"
else
  die "no pom.xml or build.gradle(.kts) in $PROJECT_DIR (run it on the root of the build)"
fi

# ----------------------------------------------------------------------------------------------
# source: Spring Boot 4 (one step to Operaton 2.x) or Spring Boot 3.5 (Hop 1, Hop 2)
# ----------------------------------------------------------------------------------------------
# One awk pass over the build files (root first). Output lines, tab-separated:
#   sb <version> <how> <file>      Spring Boot version (Maven ${property} resolved where possible)
#   starter4 <artifactId> <file>   Camunda 7.24 EE Spring Boot 4 starter (camunda-bpm-spring-boot-starter-4*)
#   ee <what> <file>               other Camunda EE markers (-ee version, -ee artifact, -jackson3, EE repository)
scan_build_files() {
  ( cd "$PROJECT_DIR" && find . \( -name target -o -name build -o -name node_modules -o -name .git -o -name .gradle -o -name .idea \) -prune -o \
    -type f \( -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name settings.gradle -o -name settings.gradle.kts \
    -o -name gradle.properties -o -name '*.versions.toml' \) -print 2>/dev/null ) \
    | sed 's|^\./||' | awk -F/ '{ print NF "\t" $0 }' | sort -n | cut -f2- > "$WORK_DIR/build-files"
  [ -s "$WORK_DIR/build-files" ] || return 0
  ( cd "$PROJECT_DIR" && tr '\n' '\0' < "$WORK_DIR/build-files" | xargs -0 awk -v sq="'" '
function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function tag(b, n,   s) { if (!match(b, "<" n ">[^<]*</" n ">")) return ""; s = substr(b, RSTART + length(n) + 2, RLENGTH - 2 * length(n) - 5); return trim(s) }
function quoted(s) { if (!match(s, "[\"" sq "][^\"" sq "]+[\"" sq "]")) return ""; return substr(s, RSTART + 1, RLENGTH - 2) }
function sb(v, how) { if (v != "") { nsb++; SBV[nsb] = v; SBH[nsb] = how; SBF[nsb] = FILENAME } }
function resolve(v,   n, i) {
  for (i = 0; i < 5 && match(v, /[$][{][^}]+[}]/); i++) {
    n = substr(v, RSTART + 2, RLENGTH - 3); if (!(n in props)) break
    v = substr(v, 1, RSTART - 1) props[n] substr(v, RSTART + RLENGTH)
  }
  return v
}
FNR == 1 { pom = (FILENAME ~ /(^|\/)pom\.xml$/); incomment = 0; inparent = 0; indep = 0; inprops = 0 }
{
  line = $0
  if (pom) {
    out = ""                                     # drop XML comments (also multi-line ones)
    while (line != "") {
      if (incomment) { i = index(line, "-->"); if (!i) line = ""; else { line = substr(line, i + 3); incomment = 0 } }
      else { i = index(line, "<!--"); if (!i) { out = out line; line = "" } else { out = out substr(line, 1, i - 1); line = substr(line, i + 4); incomment = 1 } }
    }
    line = out
    if (line ~ /<properties>/) inprops = 1
    if (inprops && match(line, /<[A-Za-z0-9_.-]+>[^<]*<\//)) {
      p = substr(line, RSTART + 1, RLENGTH - 3); n = p; sub(/>.*/, "", n); v = p; sub(/^[^>]*>/, "", v)
      if (!(n in props)) props[n] = trim(v)
    }
    if (line ~ /<\/properties>/) inprops = 0
    if (line ~ /<parent>/) { inparent = 1; pbuf = "" }
    if (inparent) pbuf = pbuf " " line
    if (inparent && line ~ /<\/parent>/) {
      inparent = 0
      if (tag(pbuf, "artifactId") == "spring-boot-starter-parent") sb(tag(pbuf, "version"), "parent spring-boot-starter-parent")
    }
    if (line ~ /<dependency>/) { indep = 1; dbuf = "" }
    if (indep) dbuf = dbuf " " line
    if (indep && line ~ /<\/dependency>/) {
      indep = 0
      if (tag(dbuf, "artifactId") == "spring-boot-dependencies") sb(tag(dbuf, "version"), "imported spring-boot-dependencies")
    }
  } else {
    if (line ~ /^[ \t]*(\/\/|#)/) next
    if (line ~ "org[.]springframework[.]boot[\"" sq ")]*[ \t]+version[ \t(]") { v = line; sub("^.*org[.]springframework[.]boot[\"" sq ")]*[ \t]+version", "", v); sb(quoted(v), "Gradle plugin org.springframework.boot") }
    if (match(line, "spring-boot-gradle-plugin:[0-9][^\"" sq ") ]*")) sb(substr(line, RSTART + 26, RLENGTH - 26), "Gradle plugin org.springframework.boot")
    if (match(line, "spring-boot-dependencies:[0-9][^\"" sq ") ]*")) sb(substr(line, RSTART + 25, RLENGTH - 25), "imported spring-boot-dependencies")
    if (line ~ /^[ \t]*spring[-_.]?[bB]oot([-_.]?[vV]ersion)?[ \t]*=/) { v = line; sub(/^[^=]*=/, "", v); v = trim(v); if (quoted(v) != "") v = quoted(v); sb(v, "Spring Boot version entry") }
    if (line ~ /id[ \t]*=[ \t]*"org\.springframework\.boot"/ && match(line, /version[ \t]*=[ \t]*"[^"]+"/)) sb(quoted(substr(line, RSTART, RLENGTH)), "Gradle plugin org.springframework.boot")
  }
  if (match(line, /camunda-bpm-spring-boot-starter-4[A-Za-z0-9-]*/)) { if (!s4) { s4 = 1; print "starter4\t" substr(line, RSTART, RLENGTH) "\t" FILENAME } }
  if (!ee) {
    if (match(line, /[0-9]+\.[0-9]+\.[0-9]+-ee/)) { ee = 1; print "ee\tversion " substr(line, RSTART, RLENGTH) "\t" FILENAME }
    else if (match(line, /camunda-[A-Za-z0-9-]*-(ee|jackson3)/)) { ee = 1; print "ee\t" substr(line, RSTART, RLENGTH) "\t" FILENAME }
    else if (line ~ /artifacts\.camunda\.com\/artifactory\/(private|camunda-bpm-ee)/) { ee = 1; print "ee\tCamunda EE repository\t" FILENAME }
  }
}
END { for (i = 1; i <= nsb; i++) print "sb\t" resolve(SBV[i]) "\t" SBH[i] "\t" SBF[i] }
' ) > "$WORK_DIR/build-facts" 2>/dev/null || true
}

# major.minor of a version ("4.1.1" -> "4.1"); empty if it does not start with digits
minor_of() { printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }

PROJECT_SB=""; PROJECT_SB_FROM=""; STARTER4=""; EE_MARKER=""; DETECTED=""; DETECTED_WHY=""
detect_source() {
  local kind v how file
  scan_build_files
  while IFS="$(printf '\t')" read -r kind v how file; do
    case "$kind" in
      sb) if [ -z "$PROJECT_SB" ] && [ -n "$(minor_of "$v")" ]; then PROJECT_SB="$v"; PROJECT_SB_FROM="$how in $file"; fi ;;
      starter4) [ -n "$STARTER4" ] || STARTER4="$v in $how" ;;
      ee) [ -n "$EE_MARKER" ] || EE_MARKER="$v in $how" ;;
    esac
  done < "$WORK_DIR/build-facts"
  if [ -n "$PROJECT_SB" ] && [ "${PROJECT_SB%%.*}" -ge 4 ] 2>/dev/null; then
    DETECTED="boot4"; DETECTED_WHY="Spring Boot $PROJECT_SB, $PROJECT_SB_FROM"
  elif [ -n "$STARTER4" ]; then
    DETECTED="boot4"; DETECTED_WHY="$STARTER4"
  elif [ -n "$PROJECT_SB" ]; then
    DETECTED="boot3"; DETECTED_WHY="Spring Boot $PROJECT_SB, $PROJECT_SB_FROM"
  else
    DETECTED="boot3"; DETECTED_WHY="no Spring Boot 4 version and no camunda-bpm-spring-boot-starter-4* artifact found"
  fi
}

TMP_BASE="${TMPDIR:-/tmp}"; WORK_DIR="$(mktemp -d "${TMP_BASE%/}/operaton-migrate.XXXXXX")"
detect_source
if [ "$SOURCE" = "auto" ]; then
  SOURCE="$DETECTED"
elif [ "$SOURCE" != "$DETECTED" ]; then
  warn "--source $SOURCE overrides the detected source $DETECTED ($DETECTED_WHY)"
fi
if [ "$SOURCE" = "boot4" ] && [ "$HOP_SET" -eq 1 ]; then
  if [ "$DETECTED" = "boot4" ]; then
    die "--hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2). This project is on Spring Boot 4 (detected: $DETECTED_WHY): it migrates to Operaton 2.x in one step (recipe starterpack.operaton.MigrateSpringBoot4App) - run without --hop. If the detection is wrong, add --source boot3."
  fi
  die "--hop belongs to the Spring Boot 3.5 path (Hop 1, Hop 2); --source boot4 migrates in one step (recipe starterpack.operaton.MigrateSpringBoot4App) - drop --hop or --source boot4."
fi

# ----------------------------------------------------------------------------------------------
# git safety
# ----------------------------------------------------------------------------------------------
# dirty_paths: changed or untracked paths of the repository (relative to the project dir when inside it),
# without the starter-pack files in the project root (MIGRATION_REPORT.md, .operaton-migration-ignore, migration/).
dirty_paths() {
  local prefix
  prefix="$(git -C "$PROJECT_DIR" rev-parse --show-prefix 2>/dev/null || true)"
  # -z: NUL-separated "XY path" entries; the source path of a rename/copy follows as an entry of its own
  git -C "$PROJECT_DIR" status --porcelain -z 2>/dev/null | {
    skip=0
    while IFS= read -r -d '' entry; do
      if [ "$skip" -eq 1 ]; then skip=0; continue; fi
      case "${entry:0:2}" in *R*|*C*) skip=1 ;; esac
      path="${entry:3}"
      case "$path" in "$prefix"*) path="${path#"$prefix"}" ;; esac
      case "$path" in
        MIGRATION_REPORT.md|.operaton-migration-ignore|migration|migration/*) continue ;;
      esac
      printf '%s\n' "$path"
    done
  }
}

IS_GIT=0
if git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IS_GIT=1
  DIRTY="$(dirty_paths)"
  if [ -n "$DIRTY" ]; then
    if [ "$FORCE" -eq 1 ]; then
      warn "working tree is dirty - continuing because of --force (recipe changes will mix with yours)"
    else
      printf '%s\n' "$DIRTY" | head -n 10 | sed 's/^/  /' >&2
      [ "$(printf '%s\n' "$DIRTY" | wc -l | tr -d ' ')" -le 10 ] || printf '  ...\n' >&2
      die "working tree of $PROJECT_DIR is dirty (paths above). Commit or stash first (or use --force). Ignored: ${DIRTY_IGNORED} in the project root."
    fi
  fi
else
  if [ "$FORCE" -eq 1 ]; then
    warn "$PROJECT_DIR is not a git repository - you will not be able to review or revert the changes easily"
  else
    die "$PROJECT_DIR is not a git repository. Run 'git init && git add -A && git commit -m baseline' first (or use --force)."
  fi
fi

# ----------------------------------------------------------------------------------------------
# Spring Boot 4 path and Hop 2: Spring Boot version that the target Operaton release is built with
# ----------------------------------------------------------------------------------------------
lookup_known_spring_boot() {
  local pair
  for pair in $KNOWN_SPRING_BOOT_FOR_TARGET; do
    if [ "${pair%%=*}" = "$1" ]; then printf '%s' "${pair#*=}"; return 0; fi
  done
  return 1
}

resolve_spring_boot() {
  [ -n "$SPRING_BOOT" ] && return 0
  local pom sb
  if command -v curl >/dev/null 2>&1; then
    pom="$(curl -fsSL --max-time 20 "https://repo1.maven.org/maven2/org/operaton/bpm/operaton-root/${TARGET}/operaton-root-${TARGET}.pom" 2>/dev/null || true)"
    sb="$(printf '%s\n' "$pom" | sed -n 's:.*<version\.spring-boot>\([^<]*\)</version\.spring-boot>.*:\1:p' | head -n 1)"
    if [ -n "$sb" ]; then SPRING_BOOT="$sb"; return 0; fi
  fi
  if sb="$(lookup_known_spring_boot "$TARGET")"; then
    warn "could not read operaton-root-${TARGET}.pom from Maven Central; using the known value Spring Boot $sb"
    SPRING_BOOT="$sb"; return 0
  fi
  die "cannot determine the Spring Boot version of Operaton $TARGET (offline?). Pass --spring-boot <version>."
}

# Operaton line for a Spring Boot minor (as of 2026-10-11; Operaton supports only the pairs it is built with)
recommend_target() {
  case "$1" in
    4.0) printf '%s' "--target 2.1.5 (built with Spring Boot 4.0.8)" ;;
    4.1) printf '%s' "--target 2.2.0 once it is GA (due 2026-10-23); --target 2.2.0-RC1 for rehearsals only, never production" ;;
    *) printf '%s' "the Operaton 2.x release built with Spring Boot $1.x (scripts/latest-versions.sh)" ;;
  esac
}

# Spring Boot 4 path: the recipe never downgrades Spring Boot and upgrades at most the patch level within the
# project's minor line (recipe starterpack.operaton.internal.SpringBootPatchForOperaton2). A different minor
# keeps Spring Boot as it is (KEEP_SB_PATCH=0) and gets a warning with the matching target.
KEEP_SB_PATCH=0
check_spring_boot_pairing() {
  local pm tm
  pm="$(minor_of "$PROJECT_SB")"; tm="$(minor_of "$SPRING_BOOT")"
  if [ -z "$pm" ]; then
    warn "could not determine the Spring Boot version of the project: Spring Boot is left as it is. Operaton $TARGET is built with Spring Boot $SPRING_BOOT and supported only with it."
  elif [ "${pm%%.*}" -lt 4 ]; then
    warn "the project is on Spring Boot $PROJECT_SB: the Spring Boot 4 path does not upgrade Spring Boot. Use --source boot3 (Hop 1, then Hop 2) or upgrade to Spring Boot 4 first."
  elif [ "$pm" = "$tm" ]; then
    KEEP_SB_PATCH=1
    info "  Spring Boot $PROJECT_SB matches the $pm line Operaton $TARGET is built with ($SPRING_BOOT): raised to $SPRING_BOOT if lower, never downgraded"
  else
    warn "Operaton $TARGET is built with Spring Boot $SPRING_BOOT (only that pairing is supported), the project is on Spring Boot $PROJECT_SB. Spring Boot is left as it is (no downgrade, no minor upgrade by the recipe)."
    warn "  Recommended for Spring Boot $pm: $(recommend_target "$pm")."
    if [ "${pm#*.}" -lt "${tm#*.}" ] 2>/dev/null; then
      warn "  Or upgrade the project to Spring Boot $tm first (own commit), then run this migration with --target $TARGET."
    fi
  fi
}

# ----------------------------------------------------------------------------------------------
# recipe file for this run (Hop 2 / Spring Boot 4 markers replaced by --target / --spring-boot)
# ----------------------------------------------------------------------------------------------
RUN_YML="$WORK_DIR/rewrite.yml"
prepare_recipe_file() {
  if [ "$SOURCE" = "boot4" ]; then
    # newVersion/newValue of "# starterpack:boot4-operaton", newVersion of "# starterpack:boot4-spring-boot";
    # the Spring Boot patch recipe ("# starterpack:boot4-spring-boot-patch") is commented out unless the
    # project is on the target's Spring Boot minor.
    local drop="s|^|&|"
    [ "$KEEP_SB_PATCH" -eq 1 ] || drop="s|^\( *\)\(- starterpack\.operaton\.internal\.SpringBootPatchForOperaton2\)\(  *# starterpack:boot4-spring-boot-patch\)$|\1# \2  (dropped by migrate.sh: Spring Boot stays as it is)|"
    sed -e "s|\(new[A-Za-z]*: \)[^ ]*\(  *# starterpack:boot4-operaton\)$|\1${TARGET}\2|" \
        -e "s|\(newVersion: \)[^ ]*\(  *# starterpack:boot4-spring-boot\)$|\1${SPRING_BOOT:-4.0.8}\2|" \
        -e "$drop" \
        "$REWRITE_YML" > "$RUN_YML"
    grep -q "newVersion: ${TARGET}  *# starterpack:boot4-operaton" "$RUN_YML" \
      || die "could not set the Operaton target in $REWRITE_YML (marker '# starterpack:boot4-operaton' missing?)"
    grep -q "# starterpack:boot4-spring-boot-patch" "$RUN_YML" \
      || die "marker '# starterpack:boot4-spring-boot-patch' missing in $REWRITE_YML"
    return 0
  fi
  sed -e "s|newVersion: [^ ]*\(  *# starterpack:hop2-operaton\)|newVersion: ${TARGET}\1|" \
      -e "s|newVersion: [^ ]*\(  *# starterpack:hop2-spring-boot\)|newVersion: ${SPRING_BOOT:-4.0.8}\1|" \
      "$REWRITE_YML" > "$RUN_YML"
  grep -q "newVersion: ${TARGET}  *# starterpack:hop2-operaton" "$RUN_YML" \
    || die "could not set the Hop 2 target in $REWRITE_YML (marker '# starterpack:hop2-operaton' missing?)"
}

# Camunda EE builds: rewrite-maven-plugin (goals run/dryRun: requiresDependencyResolution=test) and the
# Gradle plugin resolve every dependency before a recipe runs -> the EE repository is needed for this run.
ee_hint() {
  printf 'Camunda EE build (%s): the run needs the Camunda EE repository and its credentials, because the
' "$1"
  printf '  rewrite plugin resolves all dependencies before the recipes run (server id camunda-bpm-nexus-ee in
'
  printf '  ~/.m2/settings.xml, or MAVEN_ARGS="-s <settings with the EE credentials>"). After the migration nothing
'
  printf '  needs the EE repository: remove it and the credentials.
'
}

# ----------------------------------------------------------------------------------------------
# Maven split of MAVEN_ARGS (Maven >= 3.9 also reads MAVEN_ARGS itself -> pass explicitly, unset for child)
# ----------------------------------------------------------------------------------------------
EXTRA_MVN_ARGS=()
if [ -n "${MAVEN_ARGS:-}" ]; then
  # shellcheck disable=SC2206 # word splitting is intended (no quoting support inside MAVEN_ARGS)
  EXTRA_MVN_ARGS=(${MAVEN_ARGS})
fi
EXTRA_GRADLE_ARGS=()
if [ -n "${GRADLE_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  EXTRA_GRADLE_ARGS=(${GRADLE_ARGS})
fi

maven_cmd() {
  if [ -n "${MVN:-}" ]; then printf '%s' "$MVN"
  elif [ -x "$PROJECT_DIR/mvnw" ]; then printf '%s' "$PROJECT_DIR/mvnw"
  else command -v mvn >/dev/null 2>&1 || die "mvn not found (set MVN=/path/to/mvn)"; printf '%s' "mvn"; fi
}

gradle_cmd() {
  if [ -n "${GRADLE:-}" ]; then printf '%s' "$GRADLE"
  elif [ -x "$PROJECT_DIR/gradlew" ]; then printf '%s' "$PROJECT_DIR/gradlew"
  else command -v gradle >/dev/null 2>&1 || die "gradle not found (set GRADLE=/path/to/gradle)"; printf '%s' "gradle"; fi
}

# ----------------------------------------------------------------------------------------------
# one hop ("1", "2") or the one step of the Spring Boot 4 path ("boot4")
# ----------------------------------------------------------------------------------------------
hop_label() { if [ "$1" = "boot4" ]; then printf 'Spring Boot 4 path'; else printf 'Hop %s' "$1"; fi; }

run_hop() {
  local hop="$1" label recipes coords goal log mvn rc start end
  label="$(hop_label "$hop")"
  if [ "$hop" = "1" ] || [ "$hop" = "boot4" ]; then
    recipes="starterpack.operaton.MigrateSpringBootApp"
    [ "$hop" = "boot4" ] && recipes="starterpack.operaton.MigrateSpringBoot4App"
    [ "$WITH_INFRA" -eq 1 ] && recipes="$recipes,starterpack.operaton.InfraEnvVars"
    [ "$WITH_FORMS" -eq 1 ] && recipes="$recipes,starterpack.operaton.FormKeys"
    # rewrite-spring >= 6.36 keeps nested YAML (camunda: bpm: -> operaton: bpm:) instead of appending a
    # flattened operaton.bpm: block (the official recipe brings rewrite-spring 6.18.0 transitively).
    coords="org.operaton:migrate-camunda-recipe:${RECIPE_VERSION},org.openrewrite.recipe:rewrite-spring:${REWRITE_SPRING_VERSION}"
  else
    recipes="starterpack.operaton.UpgradeToOperaton2"
    coords="org.openrewrite.recipe:rewrite-spring:${REWRITE_SPRING_VERSION}"
    if [ "$WITH_INFRA" -eq 1 ] || [ "$WITH_FORMS" -eq 1 ]; then
      warn "--with-infra-env / --with-form-keys belong to Hop 1 and are ignored for Hop 2"
    fi
  fi
  log="$WORK_DIR/hop${hop}.log"
  [ "$hop" = "boot4" ] && log="$WORK_DIR/boot4.log"

  if [ "$BUILD" = "gradle" ]; then
    run_gradle "$hop" "$recipes" "$log"
    return
  fi

  goal="run"; [ "$DRY_RUN" -eq 1 ] && goal="dryRun"
  mvn="$(maven_cmd)"
  info "${label}: ${recipes}"
  info "  plugin org.openrewrite.maven:rewrite-maven-plugin:${PLUGIN_VERSION}:${goal}"
  info "  recipe artifacts ${coords}"
  [ "$hop" = "2" ] && info "  target Operaton ${TARGET} / Spring Boot ${SPRING_BOOT}"
  [ "$hop" = "boot4" ] && info "  target Operaton ${TARGET} (built with Spring Boot ${SPRING_BOOT}), project on Spring Boot ${PROJECT_SB:-unknown}"
  info "  log ${log}"
  start=$(date +%s)
  set +e
  ( cd "$PROJECT_DIR" && env -u MAVEN_ARGS "$mvn" -B ${EXTRA_MVN_ARGS[@]+"${EXTRA_MVN_ARGS[@]}"} \
      "org.openrewrite.maven:rewrite-maven-plugin:${PLUGIN_VERSION}:${goal}" \
      "-Drewrite.configLocation=${RUN_YML}" \
      "-Drewrite.recipeArtifactCoordinates=${coords}" \
      "-Drewrite.activeRecipes=${recipes}" \
      "-Drewrite.additionalPlainTextMasks=${PLAIN_TEXT_MASKS}" \
      "-Drewrite.exportDatatables=false" ) > "$log" 2>&1
  rc=$?
  set -e
  end=$(date +%s)
  if [ $rc -ne 0 ]; then
    grep -E '^\[ERROR\]' "$log" | head -n 20 >&2 || true
    if [ -n "$EE_MARKER$STARTER4" ] && grep -qE 'Could not (resolve|find|transfer)|status code: 40[13]|Unauthorized|Forbidden' "$log"; then
      ee_hint "${EE_MARKER:-$STARTER4}" >&2
    fi
    die "${label} failed (exit $rc) after $((end - start))s - see $log and ${DOCS}/03-openrewrite-recipes.md#11-troubleshooting"
  fi
  printf '%s  done in %ss%s\n' "$GRN" "$((end - start))" "$RST"
  grep -E 'Estimate time saved' "$log" | sed 's/^\[WARNING\] /  /' || true

  if [ "$DRY_RUN" -eq 1 ]; then
    local patch
    patch="$(find "$PROJECT_DIR" -path '*/target/rewrite/rewrite.patch' -newer "$RUN_YML" 2>/dev/null | head -n 1)"
    if [ -n "$patch" ]; then
      info "Patch: $patch"
      if [ "$IS_GIT" -eq 1 ]; then git -C "$PROJECT_DIR" apply --stat "$patch" | tail -n 40 || true; fi
      cp "$patch" "$WORK_DIR/$(basename "$log" .log).patch"
    else
      info "No changes proposed (no rewrite.patch written)."
    fi
  elif [ "$IS_GIT" -eq 1 ]; then
    show_changes
  fi
}

show_changes() {
  local untracked
  git -C "$PROJECT_DIR" diff --stat | tail -n 40 || true
  untracked="$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard)"
  if [ -n "$untracked" ]; then
    printf '  untracked files (renamed/moved by the recipes, or build output without .gitignore):\n'
    printf '%s\n' "$untracked" | head -n 20 | sed 's/^/    /'
    if [ "$(printf '%s\n' "$untracked" | wc -l | tr -d ' ')" -gt 20 ]; then printf '    ...\n'; fi
  fi
}

# ----------------------------------------------------------------------------------------------
# Gradle (init script, no build changes). Verified with the OpenRewrite Gradle plugin 7.39.0.
# ----------------------------------------------------------------------------------------------
run_gradle() {
  local hop="$1" recipes="$2" log="$3" init deps task gradle masks_groovy m rc
  init="$WORK_DIR/rewrite-init.gradle"
  if [ "$hop" = "1" ] || [ "$hop" = "boot4" ]; then
    deps="rewrite(\"org.operaton:migrate-camunda-recipe:${RECIPE_VERSION}\")
    rewrite(\"org.openrewrite.recipe:rewrite-spring:${REWRITE_SPRING_VERSION}\")"
  else
    deps="rewrite(\"org.openrewrite.recipe:rewrite-spring:${REWRITE_SPRING_VERSION}\")"
  fi
  # plainTextMask() REPLACES the plugin defaults -> re-add the usual ones plus models/scripts.
  masks_groovy=""
  for m in '**/*.md' '**/*.txt' '**/*.sql' '**/*.sh' '**/*.env' '**/Dockerfile*' '**/dockerfile*' '**/*.htm*' '**/META-INF/services/**' '**/META-INF/spring/**' '**/META-INF/spring.factories' $(printf '%s' "$PLAIN_TEXT_MASKS" | tr ',' ' '); do
    masks_groovy="${masks_groovy}    plainTextMask(\"${m}\")
"
  done
  cat > "$init" <<EOF
initscript {
  repositories { maven { url "https://plugins.gradle.org/m2" } }
  dependencies { classpath("org.openrewrite:plugin:${GRADLE_PLUGIN_VERSION}") }
}
rootProject {
  plugins.apply(org.openrewrite.gradle.RewritePlugin)
  dependencies {
    ${deps}
  }
  rewrite {
    configFile = file("${RUN_YML}")
$(printf '%s' "$recipes" | tr ',' '\n' | sed 's/.*/    activeRecipe("&")/')
${masks_groovy}  }
  afterEvaluate { if (repositories.isEmpty()) { repositories { mavenCentral() } } }
}
EOF
  task="rewriteRun"; [ "$DRY_RUN" -eq 1 ] && task="rewriteDryRun"
  gradle="$(gradle_cmd)"
  info "$(hop_label "$hop") (Gradle): ${recipes}"
  info "  init script ${init} (org.openrewrite:plugin:${GRADLE_PLUGIN_VERSION}), task ${task}"
  info "  log ${log}"
  set +e
  ( cd "$PROJECT_DIR" && "$gradle" --no-daemon ${EXTRA_GRADLE_ARGS[@]+"${EXTRA_GRADLE_ARGS[@]}"} --init-script "$init" "$task" ) > "$log" 2>&1
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    tail -n 30 "$log" >&2
    [ -z "$EE_MARKER$STARTER4" ] || ee_hint "${EE_MARKER:-$STARTER4}" >&2
    die "Gradle ${task} failed (exit $rc) - see $log"
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "Patch: $PROJECT_DIR/build/reports/rewrite/rewrite.patch"
  elif [ "$IS_GIT" -eq 1 ]; then
    show_changes
  fi
  warn "Gradle: version catalogs (gradle/libs.versions.toml) are NOT migrated by the recipes - edit them by hand."
}

# ----------------------------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------------------------
if [ "$SOURCE" = "boot3" ] && { [ "$HOP" = "2" ] || [ "$HOP" = "all" ]; }; then
  resolve_spring_boot
  case "$TARGET" in
    2.1.*) ;;
    *) warn "Hop 2 is verified for Operaton 2.1.x / Spring Boot 4.0. For $TARGET (Spring Boot $SPRING_BOOT) review the Spring Boot upgrade recipe list in rewrite.yml." ;;
  esac
fi

info "Project: $PROJECT_DIR ($BUILD)"
info "Recipes: $REWRITE_YML"
if [ "$SOURCE" = "boot4" ]; then
  info "Source: Spring Boot 4 (boot4; detected: $DETECTED_WHY)"
  info "Path: Camunda 7.24 -> Operaton $TARGET in one step (one commit, one cut-over)"
  resolve_spring_boot
  check_spring_boot_pairing
else
  info "Source: Spring Boot 3.5 (boot3; detected: $DETECTED_WHY)"
  case "$HOP" in
    1) info "Path: two hops - this run: Hop 1 (Camunda 7.24 -> Operaton 1.1.x); then --hop 2 (Operaton 2.x + Spring Boot 4)" ;;
    2) info "Path: two hops - this run: Hop 2 (Operaton 1.1.x -> Operaton $TARGET + Spring Boot 4)" ;;
    all) info "Path: two hops - this run: Hop 1 and Hop 2 back to back (one combined diff)" ;;
  esac
fi
if [ -n "$EE_MARKER$STARTER4" ]; then ee_hint "${EE_MARKER:-$STARTER4}" | sed "1s/^/${BOLD}==>${RST} /"; fi
prepare_recipe_file

if [ "$SOURCE" = "boot4" ]; then
  run_hop boot4
elif [ "$HOP" = "all" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    warn "--dry-run with --hop all only previews Hop 1 (Hop 2 needs the Hop 1 result). Run Hop 2 after applying Hop 1."
    run_hop 1
  else
    run_hop 1
    warn "Running Hop 2 on top of the uncommitted Hop 1 changes (combined diff)."
    run_hop 2
  fi
else
  run_hop "$HOP"
fi

# ----------------------------------------------------------------------------------------------
# next steps
# ----------------------------------------------------------------------------------------------
VERIFY="$SCRIPT_DIR/verify-leftovers.sh"
if [ "$BUILD" = "gradle" ]; then BUILD_CMD="./gradlew clean build"; else BUILD_CMD="mvn -B clean verify"; fi
if [ "$SOURCE" = "boot4" ]; then
  COMMIT_STEP="Commit the result as one change."
  [ -z "$EE_MARKER$STARTER4" ] || COMMIT_STEP="Remove the Camunda EE repository and its credentials (nothing needs them any more),
     commit the result as one change."
  cat <<EOF

${BOLD}Next steps${RST}
  1. Review the diff:          git -C "$PROJECT_DIR" diff        (logs: $WORK_DIR)
  2. Scan for leftovers:       "$VERIFY" "$PROJECT_DIR"
  3. Build and run the tests:  (cd "$PROJECT_DIR" && $BUILD_CMD)
  4. Fix what the recipes cannot know (gap list: ${DOCS}/03-openrewrite-recipes.md#52-gap-list-what-the-official-recipe-does-not-touch):
     test literals ("camunda-admin", "org.camunda..." class names), downstream consumers of class names,
     the admin group data (decision D5), webapp path (D6), in-flight instances on old definitions, and the
     Camunda EE features Operaton does not have (D17: EE webapps, license, query expression allow-list,
     Spin/REST code on Jackson 3 tools.jackson.*).
  5. ${COMMIT_STEP}
EOF
  case "$TARGET" in
    2.1.*) ;;
    *) printf '  Operaton %s records schema version 7.25.0: run <db>_engine_7.24_to_7.25.sql (no DDL) at the cut-over.\n' "$TARGET" ;;
  esac
else
cat <<EOF

${BOLD}Next steps${RST}
  1. Review the diff:          git -C "$PROJECT_DIR" diff        (logs: $WORK_DIR)
  2. Scan for leftovers:       "$VERIFY" "$PROJECT_DIR"
  3. Build and run the tests:  (cd "$PROJECT_DIR" && $BUILD_CMD)
  4. Fix what the recipes cannot know (gap list: ${DOCS}/03-openrewrite-recipes.md#52-gap-list-what-the-official-recipe-does-not-touch):
     test literals ("camunda-admin", "org.camunda..." class names), downstream consumers of class names,
     the admin group data (decision D5), webapp path (D6), in-flight instances on old definitions.
  5. Commit each hop separately (Hop 1 = rename, Hop 2 = Operaton 2.x + Spring Boot 4).
EOF
fi
[ "$DRY_RUN" -eq 1 ] && printf '\nDry run only: nothing was changed. Apply with the same command without --dry-run.\n'
exit 0
