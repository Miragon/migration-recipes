#!/usr/bin/env bash
# verify-leftovers.sh - post-migration scan for Camunda 7 leftovers that Operaton ignores silently or
# that break at runtime. Exit code 1 if MUST-FIX findings remain (CI gate), 0 otherwise.
#
# Part of the "Camunda 7 -> Operaton Migration Starter Pack" (Apache-2.0).
# Works with bash 3.2+ and POSIX awk on macOS (BSD) and Linux (GNU). No network access.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify-leftovers.sh [options] [project-dir]

Scans source, configuration, models, build files, SPI files and deployment descriptors of a migrated project.

  MUST-FIX (exit 1)  org.camunda.(bpm|spin|connect|commons|templateengines) references, camunda.bpm.* keys,
                     CAMUNDA_BPM_* env vars, management.health.camunda, camunda.cfg.xml, Camunda descriptor
                     namespaces, webjars/camunda overrides, camunda-changelog.xml, the renamed generic property
                     disable-strict-camunda-form-parsing, camunda* bean names, Keycloak *Camunda* keys,
                     activiti namespace; Spring Boot 4 / EE sources: -4 starters, -jackson3 and -ee artifacts,
                     camunda-engine-spring-6, -ee versions in the build, EE-only engine settings (query expression
                     allow-list, validate-auth-resource-id-exists), the removed license API (setLicenseKey)
  WARN               camunda-admin literals, /camunda/app|api paths and application-path /camunda (decision D6),
                     camunda-forms: form keys (D4), camundaFormRef REST field, org.camunda.community libraries,
                     unused -ee properties and -ee versions outside the build, license-file / camunda-license.txt,
                     the Camunda EE repository (artifacts.camunda.com, camunda-bpm-nexus-ee) - decision D17
  INFO               camunda: model namespace (decision D3: keep), Modeler metadata, org.camunda.feel (correct)

org.camunda.feel is never a finding (Operaton still uses the Camunda FEEL engine).
Comment lines are skipped by default (MIGRATION notes in Javadoc/XML/YAML comments); use --strict to include them.
Migration helpers are skipped by default, because they handle the legacy names on purpose:
  - files that contain the marker token operaton-migration-helper, e.g. the Java line
      // operaton-migration-helper: remove after the rollback window (D15)
  - the folder migration/ in the project root (the cut-over pack: SQL, runbook, notes).
  Both are reported as one INFO line ("skipped N helper files / migration/ pack"); --strict scans them.

Options:
  --strict            Also report matches inside comments, in files with the helper marker and in migration/.
  --ignore-file <f>   Allowlist (default: <project-dir>/.operaton-migration-ignore). Format, one per line:
                        <RULE|*>  <path-glob>  [<extended regex the line must match>]
                      e.g.  WEBAPP_PATH  ops/k8s/*.yaml                              # decision D6
                            *            src/test/java/**/LegacyPayloadTest.java
                            CAMUNDA_PKG  src/main/java/**/Consumer.java  "org\.camunda\.bpm\.engine\.impl\.history"
                      Lines starting with # are comments. A trailing "# ..." comment is allowed after the
                      path glob, or after a regex in double quotes.
  --exclude <glob>    Additional path glob to skip (repeatable), e.g. --exclude 'docs/**'.
  --max <n>           Max findings printed per rule (default 25; all are counted).
  --docs-base <url|path>  Prefix for chapter links (default: docs in the starter-pack repository; the GitHub
                      URL of the guide when the script runs from the Claude skill).
  --no-color          Plain output (default when stdout is not a terminal).
  -h, --help          Show this help.

Output is Markdown on stdout. Typical use:  scripts/verify-leftovers.sh . | tee leftovers.md
EOF
}

# Layout: starter-pack repository (docs/ next to scripts/) or the bundled Claude skill (assets/ next to
# scripts/, no docs/) -> chapter links point to the guide on GitHub.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
GUIDE_URL="https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton"
if [ -d "$SCRIPT_DIR/../assets" ] && [ ! -d "$SCRIPT_DIR/../docs" ]; then DOCS="$GUIDE_URL/docs"; else DOCS="docs"; fi

STRICT=0; IGNORE_FILE=""; MAX=25; EXCLUDES=""; PROJECT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --docs-base) [ $# -ge 2 ] || { echo "--docs-base needs a value" >&2; exit 2; }; DOCS="${2%/}"; shift 2 ;;
    --ignore-file) [ $# -ge 2 ] || { echo "--ignore-file needs a value" >&2; exit 2; }; IGNORE_FILE="$2"; shift 2 ;;
    --exclude) [ $# -ge 2 ] || { echo "--exclude needs a value" >&2; exit 2; }; EXCLUDES="${EXCLUDES}${2}
"; shift 2 ;;
    --max) [ $# -ge 2 ] || { echo "--max needs a value" >&2; exit 2; }; MAX="$2"; shift 2 ;;
    --no-color) shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) PROJECT_DIR="$1"; shift ;;
  esac
done
PROJECT_DIR="${PROJECT_DIR:-.}"
[ -d "$PROJECT_DIR" ] || { echo "project directory not found: $PROJECT_DIR" >&2; exit 2; }
ROOT="$(cd "$PROJECT_DIR" && pwd -P)"
case "$MAX" in ''|*[!0-9]*) echo "--max must be a number" >&2; exit 2 ;; esac
[ -n "$IGNORE_FILE" ] || IGNORE_FILE="$ROOT/.operaton-migration-ignore"
[ -f "$IGNORE_FILE" ] || IGNORE_FILE=""

TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-leftovers.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

START=$(date +%s)
US=$(printf '\037')   # field separator of the findings file (never part of source text)

# ------------------------------------------------------------------------------------------------
# 1. candidate files (text types only; build output and VCS folders pruned)
# ------------------------------------------------------------------------------------------------
# .mvn/ is pruned (wrapper jars), except the project-level Maven settings/config in its top level (EE repository)
( cd "$ROOT" && { find . \( -name .git -o -name target -o -name build -o -name node_modules -o -name .gradle \
      -o -name .idea -o -name .vscode -o -name .mvn -o -name bower_components -o -name .terraform \) -prune -o \
    -type f \( -name '*.java' -o -name '*.kt' -o -name '*.groovy' -o -name '*.gvy' -o -name '*.scala' \
      -o -name '*.xml' -o -name '*.bpmn' -o -name '*.dmn' -o -name '*.cmmn' -o -name '*.form' \
      -o -name '*.yml' -o -name '*.yaml' -o -name '*.properties' -o -name '*.json' \
      -o -name '*.js' -o -name '*.mjs' -o -name '*.ts' -o -name '*.py' -o -name '*.rb' -o -name '*.ftl' -o -name '*.html' \
      -o -name '*.gradle' -o -name '*.kts' -o -name '*.toml' -o -name '*.sql' -o -name '*.sh' -o -name '*.env' \
      -o -name '.env' -o -name '.env.*' -o -name 'Dockerfile*' -o -name 'dockerfile*' -o -name '*.dockerfile' \
      -o -name 'Containerfile*' -o -name '*.tf' -o -name '*.tfvars' -o -name 'Jenkinsfile*' -o -name '*.conf' \
      -o -name '*.factories' -o -name '*.imports' -o -name 'banner.txt' -o -path '*/META-INF/services/*' \) -print
    if [ -d .mvn ]; then find .mvn -maxdepth 1 -type f \( -name '*.xml' -o -name 'maven.config' \) -print; fi; } ) \
  | sed 's|^\./||' | LC_ALL=C sort > "$TMP/files.all"

# exclusions (--exclude globs)
if [ -n "$EXCLUDES" ]; then
  : > "$TMP/files"
  while IFS= read -r f; do
    skip=0
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      # shellcheck disable=SC2254 # glob matching is intended
      case "$f" in $g) skip=1; break ;; esac
    done <<EOF
$EXCLUDES
EOF
    [ "$skip" -eq 1 ] || printf '%s\n' "$f"
  done < "$TMP/files.all" > "$TMP/files"
else
  cp "$TMP/files.all" "$TMP/files"
fi
# never scan the allowlist itself
grep -v -x -F '.operaton-migration-ignore' "$TMP/files" > "$TMP/files.tmp" || true
mv "$TMP/files.tmp" "$TMP/files"

# migration helpers (marker token) and the migration/ pack in the project root - skipped unless --strict
: > "$TMP/skipped.pack"; : > "$TMP/skipped.helpers"
if [ "$STRICT" -eq 0 ]; then
  grep -E '^migration/' "$TMP/files" > "$TMP/skipped.pack" || true
  grep -v -E '^migration/' "$TMP/files" > "$TMP/files.tmp" || true
  mv "$TMP/files.tmp" "$TMP/files"
  if [ -s "$TMP/files" ]; then
    ( cd "$ROOT" && tr '\n' '\0' < "$TMP/files" | xargs -0 grep -l -F -e 'operaton-migration-helper' -- 2>/dev/null ) \
      | LC_ALL=C sort > "$TMP/skipped.helpers" || true
  fi
  if [ -s "$TMP/skipped.helpers" ]; then
    grep -v -x -F -f "$TMP/skipped.helpers" "$TMP/files" > "$TMP/files.tmp" || true
    mv "$TMP/files.tmp" "$TMP/files"
  fi
fi
SKIPPED_PACK=$(wc -l < "$TMP/skipped.pack" | tr -d ' ')
SKIPPED_HELPERS=$(wc -l < "$TMP/skipped.helpers" | tr -d ' ')
FILE_COUNT=$(wc -l < "$TMP/files" | tr -d ' ')

# file-name based findings
: > "$TMP/findings"
grep -E '(^|/)camunda\.cfg\.xml$' "$TMP/files" | awk -v S="$US" '{ print "MUST" S "CAMUNDA_CFG_XML" S $0 S 0 S "file name camunda.cfg.xml (Operaton reads operaton.cfg.xml only)" }' >> "$TMP/findings" || true
grep -E '(^|/)META-INF/services/org\.camunda\.(bpm|spin|connect|commons)\.' "$TMP/files" | awk -v S="$US" '{ print "MUST" S "CAMUNDA_PKG" S $0 S 0 S "SPI file name still org.camunda.* (ServiceLoader will not find it)" }' >> "$TMP/findings" || true
( cd "$ROOT" && find . \( -name .git -o -name target -o -name build -o -name node_modules \) -prune -o -type d -path '*/META-INF/resources/webjars/camunda' -print ) \
  | sed 's|^\./||' | awk -v S="$US" -v strict="$STRICT" '!strict && /^migration\// { next }
      { print "MUST" S "WEBJARS_CAMUNDA" S $0 S 0 S "webapp customisation folder webjars/camunda (Operaton: webjars/operaton)" }' >> "$TMP/findings" || true
( cd "$ROOT" && find . \( -name .git -o -name target -o -name build -o -name node_modules \) -prune -o -type f -name 'camunda-license.txt' -print ) \
  | sed 's|^\./||' | awk -v S="$US" -v strict="$STRICT" '!strict && /^migration\// { next }
      { print "WARN" S "EE_LICENSE" S $0 S 0 S "Camunda EE license file camunda-license.txt (Operaton needs no license)" }' >> "$TMP/findings" || true

# ------------------------------------------------------------------------------------------------
# 2. content scan (one awk pass over all files)
# ------------------------------------------------------------------------------------------------
cat > "$TMP/scan.awk" <<'AWK'
function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function emit(sev, rule, text) { emitf(sev, rule, FILENAME, FNR, text) }
function emitf(sev, rule, f, n, text,   t) {
  t = trim(text); if (length(t) > 160) t = substr(t, 1, 157) "..."
  printf "%s\037%s\037%s\037%d\037%s\n", sev, rule, f, n, t
}
# Build files: a <groupId>org.camunda...</groupId> line waits for the end of its <dependency>/<plugin>/... block;
# if the block hit a specific rule (STARTER_4, JACKSON3_ARTIFACT, ENGINE_SPRING_6, EE_ARTIFACT), that rule
# carries the fix and the generic CAMUNDA_PKG finding is dropped.
function flushpkg() {
  if (pend_n && !blockspec) emitf("MUST", "CAMUNDA_PKG", pend_file, pend_n, pend_text)
  pend_n = 0; blockspec = 0
}
function buildfile(f) { return (f ~ /(^|\/)pom\.xml$/ || f ~ /\.(gradle|kts|toml)$/ || f ~ /(^|\/)gradle\.properties$/) }
function ftype(f,   b) {
  b = f; sub(/.*\//, "", b)
  if (b ~ /\.(java|kt|groovy|gvy|scala|js|mjs|ts|gradle|kts)$/) return "c"
  if (b ~ /\.(xml|bpmn|dmn|cmmn|html)$/) return "xml"
  if (b ~ /\.(yml|yaml)$/) return "yaml"
  if (b ~ /\.properties$/) return "props"
  if (b ~ /\.sql$/) return "sql"
  return "hash"
}
FNR == 1 {
  flushpkg()
  type = ftype(FILENAME); inblock = 0; depth = 0
  model = (FILENAME ~ /\.(bpmn|dmn|cmmn)$/ || FILENAME ~ /\.(bpmn20|dmn11|cmmn10|cmmn11)\.xml$/)
  appcfg = (FILENAME ~ /(^|\/)(application|bootstrap)[^\/]*\.(ya?ml|properties)$/)
}
{
  line = $0; licdone = 0
  # ---- comment detection (heuristic; --strict disables it) ----
  comment = 0
  if (!strict) {
    t = trim(line)
    if (inblock) {
      comment = 1
      if (type == "c" && index(line, "*/") > 0) inblock = 0
      if (type == "xml" && index(line, "-->") > 0) inblock = 0
    } else if (t ~ /^(\/\/|\*|#|--)/) {
      comment = 1
      if (type == "c" && t ~ /^\/\*/ && index(t, "*/") == 0) inblock = 1
    } else if (type == "c" && t ~ /^\/\*/) {
      comment = 1; if (index(t, "*/") == 0) inblock = 1
    } else if (type == "xml" && t ~ /^<!--/) {
      comment = 1; if (index(t, "-->") == 0) inblock = 1
    }
  }

  # ---- YAML key flattening (block style) for camunda.bpm / management.health.camunda ----
  if (type == "yaml" && !comment) {
    if (line ~ /^---/) { depth = 0 }
    else if (line ~ /^[ ]*[A-Za-z0-9_"'][^:#]*:([ \t]|$)/ && line !~ /^[ ]*-/) {
      ind = match(line, /[^ ]/) - 1
      k = line; sub(/^[ ]*/, "", k); sub(/:([ \t].*)?$/, "", k); gsub(/["']/, "", k)
      while (depth > 0 && kind[depth] >= ind) depth--
      parent = (depth > 0) ? kpath[depth] : ""
      depth++; kind[depth] = ind; kpath[depth] = (parent == "" ? k : parent "." k)
      full = tolower(kpath[depth]); p = tolower(parent)
      if (full ~ /^camunda\.bpm(\.|$)/ && p !~ /^camunda\.bpm(\.|$)/) emit("MUST", "CAMUNDA_PROPERTY", line)
      if (full ~ /^management\.health\.camunda(\.|$)/ && p !~ /^management\.health\.camunda(\.|$)/) emit("MUST", "HEALTH_CAMUNDA", line)
      if (full ~ /^logging\.level\.org\.camunda\.(bpm|spin|connect|commons)/ && p !~ /^logging\.level\.org\.camunda/) emit("MUST", "CAMUNDA_PKG", line)
      if (full ~ /^(camunda|operaton)\.bpm\.license-file$/ && !comment) { emit("WARN", "EE_LICENSE", line); licdone = 1 }
    }
  }
  if (comment) next
  # trailing comments in YAML/properties/env/shell-like files
  if (!strict && (type == "yaml" || type == "props" || type == "hash")) sub(/[ \t]+#.*$/, "", line)

  # ---- build coordinates without a 1:1 Operaton counterpart (Spring Boot 4 / EE source) ----
  if (type == "xml" && line ~ /<\/?(dependency|plugin|parent|exclusion|extension|path|annotationProcessorPath)[ \t>]/) flushpkg()
  # (Maven/Gradle build files and XML only: Docker image names such as camunda-bpm-platform-ee are not artifacts)
  spec = 0
  if (type == "xml" || buildfile(FILENAME)) {
    eel = line; gsub(/camunda-bpm-nexus-ee|artifactory\/camunda-bpm-ee[a-z-]*/, "", eel)   # repository id / path, not an artifact
    if (line ~ /(camunda|operaton)-[a-z0-9-]*-jackson3([^0-9A-Za-z]|$)/) { emit("MUST", "JACKSON3_ARTIFACT", line); spec = 1 }
    else if (line ~ /(camunda|operaton)-bpm-spring-boot-starter-4([^0-9A-Za-z.]|$)/) { emit("MUST", "STARTER_4", line); spec = 1 }
    else if (line ~ /(camunda|operaton)-engine-spring-6([^0-9A-Za-z.]|$)/) { emit("MUST", "ENGINE_SPRING_6", line); spec = 1 }
    else if (eel ~ /(camunda|operaton)-[a-z0-9-]*-ee([^A-Za-z0-9]|$)/) { emit("MUST", "EE_ARTIFACT", line); spec = 1 }
    if (spec) blockspec = 1
  }
  # -ee versions (7.24.N-ee): a <version>/coordinate in a build file breaks a Central-only build (MUST); a property
  # is MUST when it is referenced (${name}, $name, version.ref), else WARN (decided in END); elsewhere WARN
  if (line ~ /[0-9]+\.[0-9]+\.[0-9]+-ee([^A-Za-z0-9]|$)/) {
    if (type == "xml" && match(line, /<[A-Za-z0-9_.-]+>[ \t]*[^<]*-ee[ \t]*<\//)) {
      tag = substr(line, RSTART + 1); sub(/>.*/, "", tag)
      if (tag == "version" && buildfile(FILENAME)) emit("MUST", "EE_VERSION", line)
      else { neep++; EPN[neep] = tag; EPF[neep] = FILENAME; EPL[neep] = FNR; EPT[neep] = line }
    } else if ((type == "props" || FILENAME ~ /\.(gradle|kts|toml)$/) && line ~ /^[ \t]*((val|def|var)[ \t]+)?[A-Za-z0-9_.-]+[ \t]*[=:][ \t]*["']?[0-9][0-9.]*-ee["']?[ \t;]*$/) {
      name = line; sub(/^[ \t]*((val|def|var)[ \t]+)?/, "", name); sub(/[ \t]*[=:].*/, "", name); sub(/^ext\./, "", name)
      neep++; EPN[neep] = name; EPF[neep] = FILENAME; EPL[neep] = FNR; EPT[neep] = line
    } else emit(buildfile(FILENAME) ? "MUST" : "WARN", "EE_VERSION", line)
  }
  # property references for the -ee property check
  if (index(line, "$") > 0) {
    s = line; while (match(s, /\$\{[A-Za-z0-9_.-]+\}/)) { REF[substr(s, RSTART + 2, RLENGTH - 3)] = 1; s = substr(s, RSTART + RLENGTH) }
    s = line; while (match(s, /\$[A-Za-z_][A-Za-z0-9_]*/)) { REF[substr(s, RSTART + 1, RLENGTH - 1)] = 1; s = substr(s, RSTART + RLENGTH) }
  }
  if (match(line, /(version\.ref[ \t]*=[ \t]*|[pP]roperty\(|extra\[)["'][A-Za-z0-9_.-]+["']/)) {
    r = substr(line, RSTART, RLENGTH); sub(/^[^"']*["']/, "", r); sub(/["']$/, "", r); REF[r] = 1
  }

  # ---- MUST ----
  if (line ~ /(^|[^A-Za-z0-9_.])org\.camunda\.(bpm|spin|connect|commons|templateengines)([^A-Za-z0-9_]|$)/ ||
      line ~ /org\.camunda\.(bpm|spin|connect|commons|template-engines)[A-Za-z0-9.]*:camunda-/ ||
      line ~ /<groupId>org\.camunda\.(bpm|spin|connect|commons|template-engines)/) {
    if (type == "yaml" && line ~ /^[ ]*org\.camunda\.[a-z.]*:/) ;            # logging.level keys: reported above
    else if (spec) ;                                                          # the specific build rule above carries the fix
    else if (type == "xml" && line ~ /<groupId>/ && line !~ /<artifactId>/) {  # decide at the end of the block
      if (pend_n) emitf("MUST", "CAMUNDA_PKG", pend_file, pend_n, pend_text)
      pend_n = FNR; pend_file = FILENAME; pend_text = line
    } else emit("MUST", "CAMUNDA_PKG", line)
  }
  # EE-only engine settings (7.24.3-ee / 7.24.7-ee): unknown generic properties fail the start, calls do not compile
  lc = tolower(line)
  if (lc ~ /query[-_]?expression[-_]?allow[-_]?list|allowed[-_]?expression[-_]?(functions|beans|properties)[-_]?in[-_]?queries|queryexpressionvalidator/) emit("MUST", "EE_QUERY_EXPRESSION_ALLOWLIST", line)
  if (lc ~ /validate[-_]?auth[-_]?resource[-_]?id[-_]?exists/) emit("MUST", "EE_AUTH_RESOURCE_VALIDATION", line)
  # license: the ManagementService license API is gone (compile error); files/properties are dead weight
  if (type == "c" && line ~ /\.(set|get|delete)LicenseKey[ \t]*\(/) emit("MUST", "EE_LICENSE", line)
  else if (!licdone && line ~ /(camunda|operaton)\.bpm\.license-file|(CAMUNDA|OPERATON)_BPM_LICENSE_?FILE|camunda-license\.txt|BEGIN CAMUNDA BPM LICENSE KEY|\.camunda\/license\.txt/) emit("WARN", "EE_LICENSE", line)
  if (line ~ /artifacts\.camunda\.com\/artifactory\/(private|camunda-bpm-ee)|camunda-bpm-nexus-ee/) emit("WARN", "EE_REPOSITORY", line)
  if (type == "props" && line ~ /^[ \t]*camunda\.bpm([.=:]|[ \t])/) emit("MUST", "CAMUNDA_PROPERTY", line)
  if (type == "props" && line ~ /^[ \t]*management\.health\.camunda/) emit("MUST", "HEALTH_CAMUNDA", line)
  if (type == "props" && line ~ /^[ \t]*logging\.level\.org\.camunda\.(bpm|spin|connect|commons)/) emit("MUST", "CAMUNDA_PKG", line)
  if (type == "c" && line ~ /["{]camunda\.bpm([.}"]|$)/) emit("MUST", "CAMUNDA_PROPERTY", line)
  if (line ~ /\$\{camunda\.bpm\./) { if (type != "c") emit("MUST", "CAMUNDA_PROPERTY", line) }
  if (line ~ /CAMUNDA_BPM_[A-Z0-9_]*/) emit("MUST", "CAMUNDA_ENV", line)
  if (line ~ /MANAGEMENT_HEALTH_CAMUNDA/ || (type == "c" && line ~ /management\.health\.camunda/)) emit("MUST", "HEALTH_CAMUNDA", line)
  if (line ~ /camunda\.cfg\.xml/) emit("MUST", "CAMUNDA_CFG_XML", line)
  if (line ~ /webjars\/camunda/) emit("MUST", "WEBJARS_CAMUNDA", line)
  if (line ~ /camunda-changelog\.xml/) emit("MUST", "LIQUIBASE_CAMUNDA", line)
  if (line ~ /[dD]isable-?[sS]trict-?[cC]amunda-?[fF]orm-?[pP]arsing/) emit("MUST", "STRICT_FORM_PARSING", line)
  if (line ~ /camundaBpm(DataSource|TransactionManager|JdbcTemplate)|camundaTaskExecutor/) emit("MUST", "CAMUNDA_BEAN_NAME", line)
  if (line ~ /use(Email|Username)AsCamundaUserId|useGroupPathAsCamundaGroupId/) emit("MUST", "KEYCLOAK_CAMUNDA_KEY", line)
  if (line ~ /www\.camunda\.org\/schema\/1\.0\/(ProcessApplication|BpmPlatform)/) emit("MUST", "DESCRIPTOR_NAMESPACE", line)
  if (model && line ~ /activiti\.org\/bpmn/) emit("MUST", "ACTIVITI_NAMESPACE", line)

  # ---- WARN ----
  if (line ~ /camunda-admin/) emit("WARN", "CAMUNDA_ADMIN", line)
  if (line ~ /\/camunda\/(app|api)([\/"' ]|$)/ || (appcfg && line ~ /application-path[ \t]*[:=][ \t]*["']?\/camunda/) ||
      line ~ /APPLICATION_PATH[ \t]*[:=][ \t]*["']?\/camunda/) emit("WARN", "WEBAPP_PATH", line)
  if (line ~ /camunda-forms:/) emit("WARN", "CAMUNDA_FORMS_KEY", line)
  if (line ~ /camundaFormRef/) emit("WARN", "CAMUNDA_FORM_REF", line)
  if (line ~ /org\.camunda\.community/) emit("WARN", "CAMUNDA_COMMUNITY", line)

  # ---- INFO ----
  if (model && line ~ /xmlns:camunda="http:\/\/camunda\.org\/schema\/1\.0\/(bpmn|dmn|cmmn)"/) emit("INFO", "CAMUNDA_NAMESPACE", line)
  if (model && line ~ /executionPlatform="Camunda/) emit("INFO", "MODELER_METADATA", line)
  if (line ~ /org\.camunda\.feel/) emit("INFO", "CAMUNDA_FEEL", line)
}
END {
  flushpkg()
  for (i = 1; i <= neep; i++) emitf((EPN[i] in REF) ? "MUST" : "WARN", "EE_VERSION", EPF[i], EPL[i], EPT[i])
}
AWK

if [ "$FILE_COUNT" -gt 0 ]; then
  ( cd "$ROOT" && tr '\n' '\0' < "$TMP/files" | xargs -0 awk -v strict="$STRICT" -f "$TMP/scan.awk" ) >> "$TMP/findings" 2>/dev/null || true
fi

# ------------------------------------------------------------------------------------------------
# 3. allowlist
# ------------------------------------------------------------------------------------------------
IGNORED=0
if [ -n "$IGNORE_FILE" ]; then
  awk -F"$US" -v ignore="$IGNORE_FILE" '
    function glob2re(g,   r, i, c, n) {
      r = "^"; n = length(g)
      for (i = 1; i <= n; i++) {
        c = substr(g, i, 1)
        if (c == "*" && substr(g, i + 1, 1) == "*") {
          if (substr(g, i + 2, 1) == "/") { r = r "(.*/)?"; i += 2 } else { r = r ".*"; i++ }
        } else if (c == "*") r = r "[^/]*"
        else if (c == "?") r = r "[^/]"
        else if (index(".+()|^$[]{}\\", c) > 0) r = r "\\" c
        else r = r c
      }
      return r "$"
    }
    BEGIN {
      n = 0
      while ((getline l < ignore) > 0) {
        sub(/\r$/, "", l); sub(/^[ \t]+/, "", l)
        if (l == "" || l ~ /^#/) continue
        rule = l; sub(/[ \t].*/, "", rule); rest = l; sub(/^[^ \t]+[ \t]+/, "", rest)
        if (rest == l) continue
        path = rest; sub(/[ \t].*/, "", path); rx = rest; sub(/^[^ \t]+[ \t]*/, "", rx)
        # trailing comment: "<RULE> <glob>   # why" or "<RULE> <glob> \"<regex>\"   # why"
        if (rx ~ /^#/) rx = ""
        else if (rx ~ /^"/) sub(/"[ \t]+#.*$/, "\"", rx)
        sub(/[ \t]+$/, "", rx)
        gsub(/^"|"$/, "", rx)
        n++; R[n] = rule; P[n] = glob2re(path); X[n] = rx
      }
    }
    {
      for (i = 1; i <= n; i++) {
        if ((R[i] == "*" || R[i] == $2) && $3 ~ P[i] && (X[i] == "" || $5 ~ X[i])) { print > "/dev/stderr"; next }
      }
      print
    }' "$TMP/findings" > "$TMP/findings.kept" 2> "$TMP/findings.ignored"
  IGNORED=$(wc -l < "$TMP/findings.ignored" | tr -d ' ')
  mv "$TMP/findings.kept" "$TMP/findings"
fi

# ------------------------------------------------------------------------------------------------
# 4. report
# ------------------------------------------------------------------------------------------------
count() { grep -c "^$1$US" "$TMP/findings" 2>/dev/null || true; }
MUST=$(count MUST); WARN=$(count WARN); INFO=$(count INFO)
END=$(date +%s)

explain() {
  case "$1" in
    CAMUNDA_PKG) echo "org.camunda.(bpm|spin|connect|commons|templateengines) -> org.operaton.\$1 (code, logger names, SPI files, models, build; build coordinates change the artifactId too: camunda-* -> operaton-*). Class names in strings may be data contracts: fix consumers too. [docs/03](${DOCS}/03-openrewrite-recipes.md)" ;;
    STARTER_4) echo "Camunda's Spring Boot 4 starters (-4 infix, EE-only) have no Operaton artifact of that name: camunda-bpm-spring-boot-starter-4[-x] -> org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter[-x] without <version> (managed by operaton-bom); -4-test -> operaton-bpm-spring-boot-starter-test-junit5 (D11); -4-webapp-ee -> operaton-bpm-spring-boot-starter-webapp (EE features are lost, D17). Left as is, the build fails (no managed version, EE repository). [docs/03](${DOCS}/03-openrewrite-recipes.md)" ;;
    JACKSON3_ARTIFACT) echo "Operaton 2.x Spin, REST and external task client are Jackson 2 only (no -jackson3 artifacts): camunda-spin-dataformat-json-jackson3 -> org.operaton.spin:operaton-spin-dataformat-json-jackson, camunda-spin-dataformat-all-jackson3 -> operaton-spin-dataformat-all, camunda-bpm-spring-boot-starter-4-rest-jackson3 -> operaton-bpm-spring-boot-starter-rest, camunda-engine-rest(-core)-jakarta-jackson3 -> org.operaton.bpm:operaton-engine-rest(-core), camunda-external-task-client-jackson3 -> operaton-external-task-client; rewrite Spin/REST/client code from tools.jackson.* to com.fasterxml.jackson.* (D17). [docs/12](${DOCS}/12-operaton-2-and-spring-boot-4.md)" ;;
    ENGINE_SPRING_6) echo "camunda-engine-spring-6 was removed in Camunda 7.24.6 and operaton-engine-spring-6 ended at 1.0.0-beta-3: use org.operaton.bpm:operaton-engine-spring (Spring 7, managed by operaton-bom); the build fails otherwise. [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    EE_ARTIFACT) echo "Operaton has no EE artifacts: camunda-bpm-spring-boot-starter-webapp-ee -> org.operaton.bpm.springboot:operaton-bpm-spring-boot-starter-webapp, camunda-webapp-webjar-ee -> org.operaton.bpm.webapp:operaton-webapp-webjar. The EE webapp features are lost: decision D17. [docs/09](${DOCS}/09-webapps-rest-api-and-clients.md)" ;;
    EE_VERSION) echo "7.24.N-ee versions exist only in the Camunda EE repository; no Operaton artifact has one. Let operaton-bom manage the version (\${operaton.version}) and delete -ee properties. MUST = a <version>/coordinate in a build file or a referenced property (the build needs the EE repository or fails); WARN = an unused property or a value outside the build (Docker image tags, CI). [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    EE_QUERY_EXPRESSION_ALLOWLIST) echo "The query-API expression allow-list (Camunda 7.24.7-ee) does not exist in Operaton: as generic properties these names fail the engine start (unknown property), setQueryExpressionValidator / setAllowed*InQueries do not compile. Remove them and mitigate (Camunda security notice 157, expression injection via stored filters): generic property enable-expressions-in-stored-queries: false unless filters need expressions such as \${currentUser()}, keep enable-expressions-in-adhoc-queries false, restrict who may create/update filters (D17). [docs/07](${DOCS}/07-identity-admin-group-and-security.md)" ;;
    EE_AUTH_RESOURCE_VALIDATION) echo "validateAuthResourceIdExists (Camunda 7.24.3-ee) does not exist in Operaton: as generic property it fails the engine start, setValidateAuthResourceIdExists does not compile, operaton.bpm.authorization.validate-auth-resource-id-exists is ignored silently. Remove it; validate user and group ids in the code that creates authorizations (D17). [docs/07](${DOCS}/07-identity-admin-group-and-security.md)" ;;
    EE_LICENSE) echo "Operaton needs no license: remove camunda.bpm.license-file / operaton.bpm.license-file, camunda-license.txt and license mounts/secrets. ManagementService set/get/deleteLicenseKey do not exist in Operaton (compile error, MUST). The key stored in the database (ACT_GE_BYTEARRAY camunda-license-key) is inert: keep it for rollback (D17). [docs/09](${DOCS}/09-webapps-rest-api-and-clients.md)" ;;
    EE_REPOSITORY) echo "Camunda EE repository (artifacts.camunda.com, server id camunda-bpm-nexus-ee): only the recipe run needed it. Remove it, its <server> credentials and CI secrets, and prove that the build resolves from Maven Central alone (D17). [docs/03](${DOCS}/03-openrewrite-recipes.md)" ;;
    CAMUNDA_PROPERTY) echo "camunda.bpm.* is ignored silently -> operaton.bpm.* (also config servers, -D flags, @Value/@ConditionalOnProperty). [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    CAMUNDA_ENV) echo "CAMUNDA_BPM_* env vars are ignored silently -> OPERATON_BPM_* (Docker, compose, Helm, ConfigMaps, CI). [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    HEALTH_CAMUNDA) echo "management.health.camunda.* -> management.health.operaton.* (decision D13 for probes). [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    CAMUNDA_CFG_XML) echo "Operaton test support reads operaton.cfg.xml only (1.0.x: FileNotFoundException; 1.1+: ProcessEngineExtension silently falls back to a default in-memory engine without your config) -> rename the file and its references. [docs/10](${DOCS}/10-testing.md)" ;;
    WEBJARS_CAMUNDA) echo "Webapp customisations must move to META-INF/resources/webjars/operaton/... [docs/09](${DOCS}/09-webapps-rest-api-and-clients.md)" ;;
    LIQUIBASE_CAMUNDA) echo "Liquibase changelog path changed (operaton-changelog.xml) - apply the verified fix, do not just switch the include. [docs/08](${DOCS}/08-database-schema-data-and-sql-scripts.md)" ;;
    STRICT_FORM_PARSING) echo "Generic property renamed: disableStrictOperatonFormParsing (unknown generic properties fail the start). [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    CAMUNDA_BEAN_NAME) echo "Starter bean names changed (operatonBpmDataSource, operatonBpmTransactionManager, operatonBpmJdbcTemplate, operatonTaskExecutor); old names are ignored silently. [docs/04](${DOCS}/04-spring-boot-dependencies-and-configuration.md)" ;;
    KEYCLOAK_CAMUNDA_KEY) echo "operaton-keycloak renamed use*AsCamunda* -> use*AsOperaton*; old keys are ignored and user ids change. [docs/07](${DOCS}/07-identity-admin-group-and-security.md)" ;;
    DESCRIPTOR_NAMESPACE) echo "processes.xml / bpm-platform.xml must use http://www.operaton.org/schema/1.0/... (startup fails otherwise). [docs/03](${DOCS}/03-openrewrite-recipes.md)" ;;
    ACTIVITI_NAMESPACE) echo "Operaton does not accept the activiti: namespace - convert the model. [docs/05](${DOCS}/05-bpmn-dmn-forms-and-scripts.md)" ;;
    CAMUNDA_ADMIN) echo "Group id is data: operaton-admin is the admin group now; migrate memberships/authorizations (decision D5) and fix literals. [docs/07](${DOCS}/07-identity-admin-group-and-security.md)" ;;
    WEBAPP_PATH) echo "Webapps default to /operaton; keeping /camunda needs operaton.bpm.webapp.application-path (decision D6). Allowlist once decided. [docs/09](${DOCS}/09-webapps-rest-api-and-clients.md)" ;;
    CAMUNDA_FORMS_KEY) echo "Operaton Tasklist recognises operaton-forms: only (according to the source); decision D4: keep, operaton-forms: (Operaton-only: open tasks on such versions are a rollback hard stop, D15), or the rollback-safe formRef. [docs/05](${DOCS}/05-bpmn-dmn-forms-and-scripts.md)" ;;
    CAMUNDA_FORM_REF) echo "REST field renamed camundaFormRef -> operatonFormRef. [docs/09](${DOCS}/09-webapps-rest-api-and-clients.md)" ;;
    CAMUNDA_COMMUNITY) echo "Camunda community extension - check for an Operaton-compatible replacement. [docs/14](${DOCS}/14-ecosystem-support-and-resources.md)" ;;
    CAMUNDA_NAMESPACE) echo "camunda: model namespace is accepted by Operaton (decision D3: keep for the migration)." ;;
    MODELER_METADATA) echo "Modeler metadata only, no runtime effect." ;;
    CAMUNDA_FEEL) echo "Correct: Operaton still uses org.camunda.feel (never rename it)." ;;
    *) echo "" ;;
  esac
}

section() {
  local sev="$1" title="$2" rules rule n
  [ "$(count "$sev")" -gt 0 ] || return 0
  printf '\n## %s\n' "$title"
  rules="$(grep "^$sev$US" "$TMP/findings" | cut -d"$US" -f2 | LC_ALL=C sort | uniq -c | sort -rn | awk '{print $2}')"
  for rule in $rules; do
    n=$(grep -c "^$sev$US$rule$US" "$TMP/findings" || true)
    printf '\n### %s (%s)\n%s\n\n' "$rule" "$n" "$(explain "$rule")"
    grep "^$sev$US$rule$US" "$TMP/findings" | head -n "$MAX" | awk -F"$US" '{ if ($4 == 0) printf "- `%s` %s\n", $3, $5; else printf "- `%s:%s` `%s`\n", $3, $4, $5 }'
    if [ "$n" -gt "$MAX" ]; then printf -- '- ... %s more\n' "$((n - MAX))"; fi
  done
}

printf '# Camunda leftovers: %s\n\n' "$(basename "$ROOT")"
printf 'Scanned %s files in %ss (`%s`). Comment lines %s. Allowlist: %s.\n\n' \
  "$FILE_COUNT" "$((END - START))" "$ROOT" "$([ "$STRICT" -eq 1 ] && echo included || echo skipped)" \
  "$([ -n "$IGNORE_FILE" ] && echo "$IGNORE_FILE ($IGNORED findings ignored)" || echo none)"
if [ $((SKIPPED_HELPERS + SKIPPED_PACK)) -gt 0 ]; then
  HELPER_NAMES="$(sed 's|.*/||' "$TMP/skipped.helpers" | head -n 8 | awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 }')"
  [ "$SKIPPED_HELPERS" -le 8 ] || HELPER_NAMES="$HELPER_NAMES, ..."
  printf 'INFO: skipped %s helper files / migration/ pack - %s with the `operaton-migration-helper` marker%s, %s below `migration/`. Remove the helpers after the rollback window (D15); `--strict` scans them.\n\n' \
    "$((SKIPPED_HELPERS + SKIPPED_PACK))" "$SKIPPED_HELPERS" "${HELPER_NAMES:+ ($HELPER_NAMES)}" "$SKIPPED_PACK"
fi
printf '| Severity | Findings |\n|---|---|\n| MUST-FIX | %s |\n| WARN | %s |\n| INFO | %s |\n' "$MUST" "$WARN" "$INFO"
section MUST "MUST-FIX (fails the scan)"
section WARN "WARN (decide, fix or allowlist)"
section INFO "INFO"
printf '\n'
if [ "$MUST" -gt 0 ]; then
  printf '**Result: FAIL** - %s MUST-FIX finding(s). Fix them or, if a finding is intended, add it to .operaton-migration-ignore with a comment.\n' "$MUST"
  exit 1
fi
printf '**Result: PASS** - no MUST-FIX findings.\n'
exit 0
