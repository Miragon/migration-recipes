#!/usr/bin/env bash
# assess.sh - read-only inventory of a Camunda 7 project before the migration to Operaton.
# Prints a Markdown report (MUST / SHOULD / INFO findings + inventory) on stdout.
#
# Part of the "Camunda 7 -> Operaton Migration Starter Pack" (Apache-2.0).
# Works with bash 3.2+ and POSIX awk on macOS (BSD) and Linux (GNU). No network access, changes nothing.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: assess.sh [options] [project-dir]

Scans a Camunda 7 project (Maven or Gradle, any number of modules) and prints a Markdown assessment:
build/platform facts with the source flavour (Camunda CE or EE, Spring Boot 3.5 / 4.0 / 4.1, -4 starters,
-jackson3 artifacts), the migration path and recommended Operaton target, MUST / SHOULD / INFO findings with
links to the guide chapters, an inventory of dependencies, internal API usage, extension points, SPI files,
descriptors, configuration keys and env vars, models (scripts, form keys, connectors, namespaces), direct SQL,
Liquibase/Flyway, tests, loggers and URLs, and the matching scripts/migrate.sh command.

Path detection (same rule as migrate.sh --source auto): Spring Boot 4.x (parent, imported
spring-boot-dependencies, Gradle plugin) or any camunda-bpm-spring-boot-starter-4* artifact -> Spring Boot 4
path (one recipe run, Operaton 2.1.5 for Spring Boot 4.0, 2.2.x for 4.1); otherwise the Spring Boot 3.5 path
(Hop 1 + Hop 2).

  MUST    blocks the migration or breaks silently unless you act (decision or manual work)
  SHOULD  handled by the recipes but needs review, or a decision with a safe default
  INFO    context for planning (counts, versions)

Options:
  --docs-base <url|path>  Prefix for chapter links (default: docs in the starter-pack repository; the guide on
                          GitHub when the script runs from the Claude skill)
  --examples <n>          Example locations shown per finding (default 3).
  -h, --help              Show this help.

Typical use:  scripts/assess.sh ~/src/order-service > assessment.md
Skipped folders: .git, target, build, node_modules, .gradle, .idea, .vscode, .mvn, bower_components.
EOF
}

# Layout: starter-pack repository (docs/, sql/ next to scripts/) or the bundled Claude skill (assets/ next to
# scripts/, no docs/) -> chapter links point to the guide on GitHub, SQL paths to assets/sql/.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
GUIDE_URL="https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton"
if [ -d "$SCRIPT_DIR/../assets" ] && [ ! -d "$SCRIPT_DIR/../docs" ]; then
  DOCS="$GUIDE_URL/docs"; SQL_DIR="assets/sql/postgresql"
else
  DOCS="docs"; SQL_DIR="sql/postgresql"
fi

NEX=3; PROJECT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --docs-base) [ $# -ge 2 ] || { echo "--docs-base needs a value" >&2; exit 2; }; DOCS="${2%/}"; shift 2 ;;
    --examples) [ $# -ge 2 ] || { echo "--examples needs a value" >&2; exit 2; }; NEX="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    *) PROJECT_DIR="$1"; shift ;;
  esac
done
PROJECT_DIR="${PROJECT_DIR:-.}"
[ -d "$PROJECT_DIR" ] || { echo "project directory not found: $PROJECT_DIR" >&2; exit 2; }
ROOT="$(cd "$PROJECT_DIR" && pwd -P)"
case "$NEX" in ''|*[!0-9]*) echo "--examples must be a number" >&2; exit 2 ;; esac

TMP="$(mktemp -d "${TMPDIR:-/tmp}/assess.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
START=$(date +%s)
# Operaton 2.2.0 (the Spring Boot 4.1 line) GA is scheduled for this date; before it, 2.2.0-RC1 is for rehearsals only
GA22_DATE="20261023"
GA22=0; [ "$(date +%Y%m%d)" -lt "$GA22_DATE" ] || GA22=1

# .mvn/ is pruned (wrapper jars), except the project-level Maven settings/config in its top level (EE repository)
( cd "$ROOT" && { find . \( -name .git -o -name target -o -name build -o -name node_modules -o -name .gradle \
      -o -name .idea -o -name .vscode -o -name .mvn -o -name bower_components -o -name .terraform \) -prune -o \
    -type f \( -name '*.java' -o -name '*.kt' -o -name '*.groovy' -o -name '*.gvy' -o -name '*.scala' \
      -o -name '*.xml' -o -name '*.bpmn' -o -name '*.dmn' -o -name '*.cmmn' -o -name '*.form' \
      -o -name '*.yml' -o -name '*.yaml' -o -name '*.properties' -o -name '*.json' \
      -o -name '*.js' -o -name '*.mjs' -o -name '*.py' -o -name '*.rb' -o -name '*.ftl' -o -name '*.html' \
      -o -name '*.gradle' -o -name '*.kts' -o -name '*.toml' -o -name '*.sql' -o -name '*.sh' -o -name '*.env' \
      -o -name '.env' -o -name '.env.*' -o -name 'Dockerfile*' -o -name 'dockerfile*' -o -name '*.dockerfile' \
      -o -name 'Containerfile*' -o -name '*.tf' -o -name '*.tfvars' -o -name 'Jenkinsfile*' -o -name '*.conf' \
      -o -name '*.factories' -o -name '*.imports' -o -name 'banner.txt' -o -path '*/META-INF/services/*' \) -print
    if [ -d .mvn ]; then find .mvn -maxdepth 1 -type f \( -name '*.xml' -o -name 'maven.config' \) -print; fi; } ) \
  | sed 's|^\./||' | LC_ALL=C sort > "$TMP/files"
FILE_COUNT=$(wc -l < "$TMP/files" | tr -d ' ')
WEBJAR_DIRS=$( cd "$ROOT" && find . \( -name .git -o -name target -o -name build -o -name node_modules \) -prune -o -type d -path '*/META-INF/resources/webjars/camunda' -print | sed 's|^\./||' | tr '\n' ' ' )
# Camunda EE license files (classpath default name; not part of the text scan above)
LICENSE_FILES=$( cd "$ROOT" && find . \( -name .git -o -name target -o -name build -o -name node_modules \) -prune -o -type f -name 'camunda-license.txt' -print | sed 's|^\./||' | tr '\n' ' ' )

cat > "$TMP/assess.awk" <<'AWK'
function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function hit(key) { hitat(key, FILENAME, FNR) }
function hitat(key, f, n) {
  cnt[key]++
  if (!((key SUBSEP f) in seen)) {
    seen[key SUBSEP f] = 1; nfiles[key]++
    if (nex[key] < maxex) { nex[key]++; ex[key] = ex[key] (ex[key] == "" ? "" : ", ") "`" f ":" n "`" }
  }
}
function fhit(key) { if (!((key SUBSEP FILENAME) in seen)) { cnt[key]++; hit_file(key) } }
function hit_file(key) {
  seen[key SUBSEP FILENAME] = 1; nfiles[key]++
  if (nex[key] < maxex) { nex[key]++; ex[key] = ex[key] (ex[key] == "" ? "" : ", ") "`" FILENAME "`" }
}
function first(var, val) { if (!(var in fact) && val != "") fact[var] = val " (`" FILENAME "`)" }
function ftype(f) {
  if (f ~ /\.(java|kt|groovy|gvy|scala|js|mjs|gradle|kts)$/) return "c"
  if (f ~ /\.(xml|bpmn|dmn|cmmn|html)$/) return "xml"
  if (f ~ /\.(yml|yaml)$/) return "yaml"
  if (f ~ /\.properties$/) return "props"
  if (f ~ /\.sql$/) return "sql"
  return "hash"
}
function dep(ga) { if (!(ga in deps)) { deps[ga] = FILENAME; ndeps++ } }
function vers(s,   r) { if (match(s, /[0-9]+(\.[0-9]+)*([-.][A-Za-z0-9]+)*/)) return substr(s, RSTART, RLENGTH); return "" }
# version inside the first XML element of the line (property names may contain digits: version.camunda-7)
function tagv(s) { sub(/^[^>]*>/, "", s); sub(/<.*$/, "", s); return vers(s) }
# --- HistoryEventHandler registered twice: @Component/@Service handler bean + plugin that adds it again ---
# hreg = files that mention setCustomHistoryEventHandlers / getCustomHistoryEventHandlers().add (bash pre-pass);
# only their code is kept in memory to look up the handler class names at the end.
function endfile() {
  if (pf_file != "" && pf_plugin && pf_reg) { np++; PF[np] = pf_file ":" pf_regline; PT[np] = pf_text }
  # Jackson 3 (tools.jackson) in a file that also customises Spin / engine REST / the external task client
  if (pf_file != "" && tj_line && tj_spin) hitat("jackson3_code", pf_file, tj_line)
  pf_file = FILENAME; pf_plugin = 0; pf_reg = 0; pf_regline = 0; pf_text = ""; pendbean = 0; indecl = 0
  pf_capture = (FILENAME in hreg); tj_line = 0; tj_spin = 0
}
function classdecl(d) {
  if (pendbean && (d ~ /(implements|extends)[^{]*HistoryEventHandler/ || (FILENAME ~ /\.kt$/ && d ~ /:[^{]*HistoryEventHandler/))) {
    nhb++; HB[nhb] = cname; HBL[nhb] = cloc
  }
  pendbean = 0
}
BEGIN { if (hregfile != "") while ((getline l < hregfile) > 0) hreg[l] = 1 }
FNR == 1 {
  endfile()
  type = ftype(FILENAME); depth = 0; inblock = 0; lastgid = ""; parentpom = 0; sbdeps = 0; bomline = 0
  model = (FILENAME ~ /\.(bpmn|dmn|cmmn)$/ || FILENAME ~ /\.(bpmn20|dmn11|cmmn10|cmmn11)\.xml$/)
  srcset = (FILENAME ~ /(^|\/)src\/[^\/]+\/resources\//)
  appcfg = (FILENAME ~ /(^|\/)(application|bootstrap)[^\/]*\.(ya?ml|properties)$/)
  if (FILENAME ~ /(^|\/)pom\.xml$/) { npom++; if (FILENAME == "pom.xml") rootpom = 1 }
  if (FILENAME ~ /(^|\/)(build\.gradle|build\.gradle\.kts)$/) ngradle++
  if (FILENAME ~ /\.bpmn$|\.bpmn20\.xml$/) nbpmn++
  if (FILENAME ~ /\.dmn$|\.dmn11\.xml$/) ndmn++
  if (FILENAME ~ /\.cmmn$|\.cmmn1[01]\.xml$/) ncmmn++
  if (FILENAME ~ /\.form$/) nform++
  if (FILENAME ~ /\.java$/) njava++
  if (FILENAME ~ /\.kt$/) { nkotlin++; fhit("kotlin") }
  if (FILENAME ~ /(^|\/)META-INF\/services\/org\.camunda\./) fhit("spi_services")
  if (FILENAME ~ /(^|\/)META-INF\/services\/org\.camunda\.feel\./) fhit("spi_feel")
  if (FILENAME ~ /(^|\/)processes\.xml$/) fhit("processes_xml")
  if (FILENAME ~ /(^|\/)bpm-platform\.xml$/) fhit("bpm_platform_xml")
  if (FILENAME ~ /(^|\/)camunda\.cfg\.xml$/) fhit("camunda_cfg_xml")
  if (FILENAME ~ /(^|\/)libs\.versions\.toml$/) catalog = 1; else catalog = 0
  if (FILENAME ~ /\.sql$/) sqlfile = 1; else sqlfile = 0
}
{
  line = $0; t = trim(line)
  # comments (single line heuristic + XML/C blocks) - inventory counts only code/config
  comment = 0
  if (inblock) { comment = 1; if ((type == "c" && index(line, "*/")) || (type == "xml" && index(line, "-->"))) inblock = 0 }
  else if (t ~ /^(\/\/|\*|#)/ || (type == "sql" && t ~ /^--/)) comment = 1
  else if (type == "c" && t ~ /^\/\*/) { comment = 1; if (!index(t, "*/")) inblock = 1 }
  else if (type == "xml" && t ~ /^<!--/) { comment = 1; if (!index(t, "-->")) inblock = 1 }
  if (comment) next
  if (type == "yaml" || type == "props" || type == "hash") sub(/[ \t]+#.*$/, "", line)

  # ---------------- build facts ----------------
  if (FILENAME ~ /(^|\/)pom\.xml$/) {
    if (line ~ /<artifactId>spring-boot-starter-parent<\/artifactId>/) parentpom = 1
    if (parentpom && line ~ /<version>/) { first("spring_boot", vers(line)); parentpom = 0 }
    # Spring Boot without the parent: imported spring-boot-dependencies or a version property
    if (line ~ /<artifactId>spring-boot-dependencies<\/artifactId>/) sbdeps = 1
    else if (sbdeps && line ~ /<version>/) { first("spring_boot", tagv(line)); sbdeps = 0 }
    if (line ~ /<(spring-boot\.version|version\.spring-boot|spring\.boot\.version|springboot\.version|version\.springboot|springBootVersion)>/) first("spring_boot", tagv(line))
    if (line ~ /<(camunda\.version|version\.camunda(-7)?|camunda-version|camundaVersion|camunda\.bpm\.version|version\.camunda\.bpm)>/) first("camunda", tagv(line))
    if (line ~ /<(java\.version|maven\.compiler\.release|maven\.compiler\.target|maven\.compiler\.source)>/) first("java", vers(line))
    if (line ~ /<packaging>war<\/packaging>/) fhit("war")
    if (line ~ /<module>/) nmodules++
    if (line ~ /<groupId>/) { g = line; sub(/.*<groupId>[ \t]*/, "", g); sub(/[ \t]*<\/groupId>.*/, "", g); lastgid = g }
    if (line ~ /<artifactId>/ && lastgid != "") {
      a = line; sub(/.*<artifactId>[ \t]*/, "", a); sub(/[ \t]*<\/artifactId>.*/, "", a)
      if (lastgid ~ /^(org\.camunda|io\.camunda|org\.operaton|org\.cibseven)/) dep(lastgid ":" a)
      lastgid = ""
    }
    if (line ~ /camunda-bom<\/artifactId>/) bomline = 1
    else if (bomline && line ~ /<version>/) { first("camunda", vers(line)); bomline = 0 }
  }
  if (FILENAME ~ /\.(gradle|kts|toml)$/ || FILENAME ~ /(^|\/)gradle\.properties$/) {
    s = line
    while (match(s, /(org\.camunda|io\.camunda|org\.operaton)[A-Za-z0-9.-]*:[A-Za-z0-9.-]+/)) {
      dep(substr(s, RSTART, RLENGTH)); s = substr(s, RSTART + RLENGTH)
    }
    if (line ~ /camunda[A-Za-z]*[Vv]ersion|camunda-bom:/) first("camunda", vers(line))
    if (line ~ /org\.springframework\.boot/ && line ~ /version/) first("spring_boot", vers(line))
    # springBootVersion=4.1.1 (gradle.properties), spring-boot = "4.1.1" (version catalog)
    if (line ~ /^[ \t]*(spring-boot|springBoot|spring_boot)[A-Za-z.-]*[ \t]*[=:][ \t]*["']?[0-9]/) { v = line; sub(/^[^=:]*[=:]/, "", v); first("spring_boot", vers(v)) }
    if (line ~ /languageVersion|JavaVersion\.VERSION_|sourceCompatibility|jvmTarget/) { v = line; gsub(/_/, ".", v); first("java", vers(v)) }
    if (catalog && line ~ /camunda/) hit("gradle_catalog")
  }

  # ---------------- dependencies / coordinates (text level) ----------------
  # Camunda EE (Enterprise Edition): 7.24.N-ee versions, -ee artifacts, license, EE repository
  if (line ~ /[0-9]+\.[0-9]+\.[0-9]+-ee([^A-Za-z0-9]|$)/) hit("ee_version")
  eel = line; gsub(/camunda-bpm-nexus-ee|artifactory\/camunda-bpm-ee[a-z-]*/, "", eel)   # repository id / path, not an artifact
  if (eel ~ /(camunda|operaton)-[a-z0-9-]*-ee([^A-Za-z0-9]|$)/) hit("ee_artifact")
  if (line ~ /(camunda|operaton)\.bpm\.license-file|license-file[ \t]*[:=]|camunda-license|BEGIN CAMUNDA BPM LICENSE KEY|\.camunda\/license\.txt|BPM_LICENSE_?FILE/) hit("ee_license")
  if (line ~ /artifacts\.camunda\.com\/artifactory\/(private|camunda-bpm-ee)|camunda-bpm-nexus-ee/) hit("ee_repo")
  # Spring Boot 4 starters (-4 infix, 7.24.3-ee+) and the Jackson 3 opt-in artifacts (7.24.16-ee)
  if (line ~ /camunda-bpm-spring-boot-starter-4([^0-9A-Za-z.]|$)/) hit("starter4")
  if (line ~ /(camunda|operaton)-[a-z0-9-]*-jackson3([^0-9A-Za-z]|$)/) hit("jackson3_dep")
  # EE-only engine settings (7.24.3-ee / 7.24.7-ee) that Operaton does not know, and the removed license API
  lc = tolower(line)
  if (lc ~ /query[-_]?expression[-_]?allow[-_]?list|allowed[-_]?expression[-_]?(functions|beans|properties)[-_]?in[-_]?queries|queryexpressionvalidator/) hit("ee_allowlist")
  if (lc ~ /validate[-_]?auth[-_]?resource[-_]?id[-_]?exists/) hit("ee_authcheck")
  if (type == "c" && line ~ /\.(set|get|delete)LicenseKey[ \t]*\(/) hit("license_api")
  if (line ~ /org\.camunda\.bpm\.extension\.springboot|<groupId>org\.camunda\.bpm\.assert<|org\.camunda\.bpm\.assert:|org\.camunda\.bpm\.extension[:<]/) hit("legacy_coords")
  if (line ~ /camunda-bpm-junit5|org\.camunda\.bpm\.extension\.junit5/) hit("junit5_ext")
  if (line ~ /org\.camunda\.community|camunda-platform-7-mockito|camunda-bpm-mockito|process[-_]test[-_]coverage|camunda-bpm-assert-scenario|camunda-bpm-data|camunda-platform-7-keycloak|camunda-bpm-reactor|camunda-bpm-spring-boot-starter-(eventing|mail)/) hit("community")
  if (line ~ /io\.camunda/) hit("camunda8")
  if (line ~ /camunda-sql-scripts|camunda-engine-rest-openapi|camunda-bpm-tomcat|camunda-bpm-run|camunda-bpm-wildfly/) hit("unmapped_coords")
  # classic and -4 starters (-webapp, -webapp-ee, -webapp-core, -4-webapp, -4-webapp-ee, ...)
  if (line ~ /camunda-bpm-spring-boot-starter(-4)?-webapp/) webapp = 1
  if (line ~ /camunda-bpm-spring-boot-starter(-4)?(-rest(-jackson3)?|-webapp(-ee|-core)?|-security)?([<"':]|$)/) springboot = 1
  if (line ~ /camunda-bpm-spring-boot-starter(-4)?-external-task-client|camunda-external-task-client/) hit("ext_client")
  if (line ~ /camunda-engine-plugin-connect|camunda-connect-/) hit("connect_dep")

  # ---------------- Java / Kotlin code ----------------
  if (type == "c") {
    if (line ~ /^[ \t]*import[ \t]+(static[ \t]+)?org\.camunda\.bpm\.engine\.impl\./) {
      hit("impl_api"); p = line; sub(/^[ \t]*import[ \t]+(static[ \t]+)?/, "", p); sub(/;.*/, "", p)
      n = split(p, parts, "."); pk = parts[1]; for (i = 2; i <= 6 && i < n; i++) pk = pk "." parts[i]; implpkg[pk]++
    }
    if (line ~ /^[ \t]*import[ \t]+(static[ \t]+)?org\.camunda\.(bpm|spin|connect|commons)\./) hit("camunda_imports")
    if (line ~ /^[ \t]*import[ \t]+org\.camunda\.bpm\.spring\.boot\.starter\./) hit("starter_api")
    if (line ~ /^[ \t]*import[ \t]+org\.camunda\.bpm\.client\./) hit("ext_client")
    if (line ~ /(implements|extends)[^{]*(ProcessEnginePlugin|AbstractProcessEnginePlugin)/) hit("ep_plugin")
    if (line ~ /(implements|extends)[^{]*HistoryEventHandler/) hit("ep_history")
    if (line ~ /(implements|extends)[^{]*(IncidentHandler|DefaultIncidentHandler)/) hit("ep_incident")
    if (line ~ /(implements|extends)[^{]*JobHandler/) hit("ep_jobhandler")
    if (line ~ /(implements|extends)[^{]*(BpmnParseListener|AbstractBpmnParseListener)/) hit("ep_parselistener")
    if (line ~ /extends[ \t]+AbstractBpmnParseListener/) hit("abstract_parse_listener")
    if (line ~ /(implements|extends)[^{]*(TypedValueSerializer|AbstractTypedValueSerializer|VariableSerializerFactory)/) hit("ep_serializer")
    if (line ~ /(implements|extends)[^{]*(DataFormatConfigurator|DataFormatProvider)/) hit("ep_spin")
    if (line ~ /(implements|extends)[^{]*(CockpitPlugin|TasklistPlugin|AdminPlugin|WelcomePlugin|AbstractCockpitPlugin)/) hit("ep_webapp_plugin")
    if (line ~ /(implements|extends)[^{]*(JavaDelegate|ExecutionListener|TaskListener|ActivityBehavior)/) hit("ep_delegate")
    if (line ~ /(implements|extends)[^{]*(FailedJobCommandFactory|ExpressionManager|IdGenerator|HistoryLevel)[ \t{,]/) hit("ep_engine_other")
    if (line ~ /extends[ \t]+AbstractCamundaConfiguration/) hit("abstract_camunda_config")
    if (line ~ /List<JobHandler>|List<TypedValueSerializer>|getCustomJobHandlers\(\)[ \t]*==[ \t]*null/) hit("raw_generics")
    if (line ~ /getExecutionContext\(\)/) hit("exec_context")
    if (line ~ /"org\.camunda\.(bpm|spin|connect|commons)\.[A-Za-z]/) hit("fqcn_strings")
    if (line ~ /camundaBpm(DataSource|TransactionManager|JdbcTemplate)|camundaTaskExecutor/) hit("bean_names")
    if (line ~ /prefix[ \t]*=[ \t]*"camunda\.bpm|@ConfigurationProperties\("camunda\.bpm|"\$\{camunda\.bpm/) hit("prop_literals")
    if (line ~ /Groups\.CAMUNDA_ADMIN/) hit("camunda_admin_const")
    if (line ~ /ProcessEngineRule|ProcessEngineExtension|@Deployment|BpmnAwareTests|ProcessEngineTests/) hit("test_engine")
    if (line ~ /org\.camunda\.bpm\.engine\.test\.mock\.|Mocks\.register/) hit("test_mocks")
    if (line ~ /ACT_(RU|HI|RE|GE|ID)_[A-Z_]+/) hit("sql_in_code")
    if (line ~ /JdbcTemplate|createNativeQuery|@Query\(.*nativeQuery/ && line ~ /ACT_/) hit("sql_in_code")
    if (line ~ /LdapIdentityProviderPlugin/) hit("ldap")
    if (line ~ /KeycloakIdentityProviderPlugin/) hit("keycloak")
    if (line ~ /AdministratorAuthorizationPlugin/) hit("admin_auth_plugin")
    if (line ~ /ObjectInputStream|SerializationDataFormats\.JAVA|javaSerializationFormatEnabled/) hit("java_serialization")
    # Jackson 3 next to Spin / engine REST / external task client (checked per file in endfile())
    if (!tj_line && line ~ /(^|[^A-Za-z0-9_.])tools\.jackson\.[a-z]/) tj_line = FNR
    if (line ~ /org\.camunda\.(spin|bpm\.engine\.rest|bpm\.client)\.|JacksonJsonDataFormat|DataFormatConfigurator/) tj_spin = 1
    # handler beans (class declaration may span lines up to the opening brace) and registering plugins
    if (line ~ /^[ \t]*@(org\.springframework\.stereotype\.)?(Component|Service)([ \t(]|$)/) pendbean = 1
    if (indecl) { cdecl = cdecl " " line; if (index(line, "{")) { indecl = 0; classdecl(cdecl) } }
    else if (match(line, /(class|object)[ \t]+[A-Za-z_][A-Za-z0-9_]*/) && (RSTART == 1 || substr(line, RSTART - 1, 1) !~ /[A-Za-z0-9_.]/)) {
      cname = substr(line, RSTART, RLENGTH); sub(/^(class|object)[ \t]+/, "", cname); cloc = FILENAME ":" FNR; cdecl = line
      if (index(line, "{") || FILENAME ~ /\.kt$/) classdecl(cdecl); else indecl = 1
    }
    if (pf_capture) {
      pf_text = pf_text " " line
      if (line ~ /ProcessEnginePlugin|Abstract(Camunda|Operaton)Configuration/) pf_plugin = 1
      if (line ~ /setCustomHistoryEventHandlers[ \t]*\(|getCustomHistoryEventHandlers\(\)[ \t]*\.[ \t]*add(All)?[ \t]*\(/) { if (!pf_reg) pf_regline = FNR; pf_reg = 1 }
    }
  }

  # ---------------- configuration ----------------
  if (type == "yaml") {
    if (line ~ /^---/) depth = 0
    else if (line ~ /^[ ]*[A-Za-z0-9_"'][^:#]*:([ \t]|$)/ && line !~ /^[ ]*-/) {
      ind = match(line, /[^ ]/) - 1
      k = line; sub(/^[ ]*/, "", k); sub(/:([ \t].*)?$/, "", k); gsub(/["']/, "", k)
      while (depth > 0 && kind[depth] >= ind) depth--
      parent = (depth > 0) ? kpath[depth] : ""
      depth++; kind[depth] = ind; kpath[depth] = (parent == "" ? k : parent "." k)
      full = tolower(kpath[depth])
      if (full ~ /^camunda\.bpm\./ && line ~ /:[ \t]*[^ \t]/) { hit(srcset ? "cfg_keys" : "cfg_keys_outside") }
      if (full ~ /^camunda\.bpm\.authorization\.enabled$/ && line ~ /true/) hit("authz_enabled")
      if (full ~ /^camunda\.bpm\.webapp\.application-path$/) hit("app_path_cfg")
      if (full ~ /^camunda\.bpm\.history-level$/) { v = line; sub(/.*:[ \t]*/, "", v); first("history_level", trim(v)) }
      if (full ~ /^camunda\.bpm\.database\.schema-update$/) { v = line; sub(/.*:[ \t]*/, "", v); first("schema_update", trim(v)) }
      if (full ~ /^management\.health\.camunda/) hit("health_camunda")
      if (full ~ /^logging\.level\.org\.camunda\.(bpm|spin|connect|commons)/) hit("log_levels")
      if (full ~ /^spring\.liquibase/) hit("liquibase_cfg")
      if (full ~ /^spring\.flyway/) hit("flyway_cfg")
      if (full ~ /^camunda\.bpm\.generic-properties/ && full ~ /whitelist/) hit("whitelist_cfg")
      if (full ~ /^camunda\.bpm\.(admin-user|filter)/) adminuser = 1
    }
  }
  if (type == "props") {
    if (line ~ /^[ \t]*camunda\.bpm\./) hit(srcset ? "cfg_keys" : "cfg_keys_outside")
    if (line ~ /^[ \t]*camunda\.bpm\.authorization\.enabled[ \t]*[=:][ \t]*true/) hit("authz_enabled")
    if (line ~ /^[ \t]*camunda\.bpm\.webapp\.application-path/) hit("app_path_cfg")
    if (line ~ /^[ \t]*camunda\.bpm\.history-level[ \t]*[=:]/) { v = line; sub(/^[^=:]*[=:][ \t]*/, "", v); first("history_level", trim(v)) }
    if (line ~ /^[ \t]*camunda\.bpm\.database\.schema-update[ \t]*[=:]/) { v = line; sub(/^[^=:]*[=:][ \t]*/, "", v); first("schema_update", trim(v)) }
    if (line ~ /^[ \t]*management\.health\.camunda/) hit("health_camunda")
    if (line ~ /^[ \t]*logging\.level\.org\.camunda\.(bpm|spin|connect|commons)/) hit("log_levels")
    if (line ~ /^[ \t]*spring\.liquibase/) hit("liquibase_cfg")
    if (line ~ /^[ \t]*spring\.flyway/) hit("flyway_cfg")
  }
  if (line ~ /CAMUNDA_BPM_[A-Z0-9_]+/) hit("env_vars")
  if (line ~ /[dD]isable-?[sS]trict-?[cC]amunda-?[fF]orm-?[pP]arsing/) hit("strict_form")
  if (line ~ /use(Email|Username)AsCamundaUserId|useGroupPathAsCamundaGroupId/) hit("keycloak_keys")
  if (FILENAME ~ /(^|\/)META-INF\/spring\.factories$|\.imports$/ && line ~ /org\.camunda\.(bpm|spin|connect|commons)/) hit("spi_factories")
  if (FILENAME ~ /(^|\/)META-INF\/services\// && line ~ /org\.camunda\.(bpm|spin|connect|commons)/) hit("spi_content")
  if (line ~ /www\.camunda\.org\/schema\/1\.0\/(ProcessApplication|BpmPlatform)/) hit("descriptor_ns")
  if (line ~ /camunda-changelog\.xml/) hit("liquibase_changelog")
  if (line ~ /activiti\.[a-z0-9]+\.create\.[a-z]+\.sql|camunda_engine_7|camunda-engine.*\.sql/) hit("flyway_scripts")
  if (line ~ /webjars\/camunda/) hit("webjar_ref")

  # ---------------- logging ----------------
  if (type == "xml" && line ~ /<(logger|Logger|AsyncLogger)[ \t][^>]*name="org\.camunda\.(bpm|spin|connect|commons)/) hit("log_config")

  # ---------------- literals, URLs ----------------
  if (line ~ /camunda-admin/) hit("camunda_admin")
  if (line ~ /\/camunda\/(app|api)([\/"' ]|$)/) hit("camunda_urls")
  if (line ~ /camundaFormRef/) hit("form_ref")

  # ---------------- models ----------------
  if (model) {
    if (line ~ /activiti\.org\/bpmn|xmlns:activiti=/) hit("activiti")
    if (line ~ /xmlns:camunda="http:\/\/camunda\.org\/schema\/1\.0\//) fhit("ns_camunda")
    if (line ~ /xmlns:operaton="http:\/\/operaton\.org\/schema\/1\.0\//) fhit("ns_operaton")
    if (line ~ /<([a-z]+:)?scriptTask[ \t>]/) {
      hit("script_tasks"); f = "?"
      if (match(line, /scriptFormat="[^"]*"/)) f = tolower(substr(line, RSTART + 14, RLENGTH - 15))
      sf[f]++
    }
    if (line ~ /<camunda:script[ \t>]/) {
      hit("camunda_scripts"); f = "?"
      if (match(line, /scriptFormat="[^"]*"/)) f = tolower(substr(line, RSTART + 14, RLENGTH - 15))
      sf[f]++
    }
    if (line ~ /camunda:resource="|resource="(classpath|deployment):/) hit("external_scripts")
    if (line ~ /org\.camunda\.(bpm|spin|connect|commons|templateengines)\./) hit("model_camunda_refs")
    if (line ~ /importPackage|importClass|JavaImporter|load\(["']nashorn:/) hit("nashorn")
    if (line ~ /camunda-forms:/) hit("forms_key")
    if (line ~ /camunda:formKey="embedded:|formKey="embedded:/) hit("embedded_forms")
    if (line ~ /camunda:formRef=/) hit("form_ref_attr")
    if (line ~ /camunda:connector|<camunda:connectorId>/) hit("connectors")
    if (line ~ /camunda:class="/) hit("model_class")
    if (line ~ /camunda:(delegateExpression|expression)="/) hit("model_expr")
    if (line ~ /camunda:asyncBefore="true"|camunda:asyncAfter="true"/) hit("model_async")
    if (line ~ /camunda:type="external"/) hit("model_external")
  } else if (FILENAME ~ /\.(groovy|gvy|js|mjs|py|rb|ftl)$/) {
    if (line ~ /org\.camunda\.(bpm|spin|connect|commons|templateengines)\./) hit("script_camunda_refs")
    if (line ~ /importPackage|importClass|JavaImporter|load\(["']nashorn:/) hit("nashorn")
  }

  # ---------------- SQL ----------------
  if (sqlfile && line ~ /ACT_(RU|HI|RE|GE|ID)_/) {
    hit("sql_files")
    if (toupper(line) ~ /(UPDATE|DELETE[ \t]+FROM|INSERT[ \t]+INTO|TRUNCATE)[ \t]+ACT_/) hit("sql_dml")
  }
}
END {
  endfile()
  # handler beans that a registering plugin references by class name
  for (i = 1; i <= nhb; i++) for (j = 1; j <= np; j++) {
    t = " " PT[j] " "
    if (t ~ ("[^A-Za-z0-9_]" HB[i] "[^A-Za-z0-9_]")) {
      ndouble++; dbl = dbl (dbl == "" ? "" : "; ") "`" HB[i] "` bean (`" HBL[i] "`) + plugin `" PF[j] "`"
      if (dblnames !~ ("`" HB[i] "`")) dblnames = dblnames (dblnames == "" ? "" : ", ") "`" HB[i] "`"
    }
  }
  # ---------- facts ----------
  build = (npom > 0 ? "Maven (" npom " pom.xml" (nmodules > 0 ? ", " nmodules " modules" : "") ")" : "") \
          (ngradle > 0 ? (npom > 0 ? " + " : "") "Gradle (" ngradle " build files)" : "")
  if (build == "") build = "unknown (no pom.xml / build.gradle found)"
  # ("x" in fact) first: referencing fact["x"] would create the element
  cv = ("camunda" in fact ? fact["camunda"] : ""); sub(/ .*/, "", cv)
  sbv = ("spring_boot" in fact ? fact["spring_boot"] : ""); sub(/ .*/, "", sbv); split(sbv, sbp, "."); sbmaj = sbp[1] + 0; sbmin = sbp[2] + 0
  sbminor = (sbv != "" ? sbmaj "." sbmin : "")
  # source flavour: EE = -ee version / EE artifact / license / EE repository / -4 starters (the -4 line is EE-only)
  ee = (cv ~ /-ee$/ || cnt["ee_version"] || cnt["ee_artifact"] || cnt["ee_license"] || cnt["ee_repo"] || cnt["starter4"] || cnt["jackson3_dep"] || licfiles != "")
  eeev = ""
  if (cv ~ /-ee$/) eeev = "version " cv; else if (cnt["ee_version"]) eeev = "`-ee` versions"
  if (cnt["starter4"]) eeev = eeev (eeev == "" ? "" : ", ") "`-4` starters (EE-only, 7.24.3-ee+)"
  if (cnt["ee_artifact"]) eeev = eeev (eeev == "" ? "" : ", ") "`-ee` artifacts"
  if (cnt["jackson3_dep"]) eeev = eeev (eeev == "" ? "" : ", ") "`-jackson3` artifacts (7.24.16-ee)"
  if (cnt["ee_license"] || licfiles != "") eeev = eeev (eeev == "" ? "" : ", ") "license"
  if (cnt["ee_repo"]) eeev = eeev (eeev == "" ? "" : ", ") "EE repository"
  # migration path, same rule as migrate.sh --source auto: Spring Boot >= 4 or any -4 starter = Spring Boot 4 path
  boot4 = (sbmaj >= 4 || cnt["starter4"])
  s4 = ""; j3 = ""; ndl = 0
  for (d in deps) dl[++ndl] = d
  isort(dl, ndl)
  for (i = 1; i <= ndl; i++) {
    a = dl[i]; sub(/^[^:]*:/, "", a)
    if (a ~ /^camunda-bpm-spring-boot-starter-4/) s4 = s4 (s4 == "" ? "" : ", ") "`" a "`"
    if (a ~ /-jackson3$/) j3 = j3 (j3 == "" ? "" : ", ") "`" a "`"
  }
  if (boot4) {
    path = "**Spring Boot 4 path**: one recipe run (`starterpack.operaton.MigrateSpringBoot4App`), one cut-over (decision D1)"
    if (sbminor == "4.0") target = "Operaton **2.1.5** (built with Spring Boot 4.0.8); plan 2.2 soon after (2.1 support ends Oct 2026; 2.2 needs Spring Boot 4.1)"
    else if (sbminor == "4.1") target = (ga22 ? "Operaton **2.2.x** (built with Spring Boot 4.1; GA scheduled for 2026-10-23, check `scripts/latest-versions.sh`)" \
                                             : "Operaton **2.2.x** (built with Spring Boot 4.1; GA due 2026-10-23): rehearse with 2.2.0-RC1 until then, never in production; 2.1.5 on Spring Boot 4.1 is unsupported")
    else if (sbminor == "") target = "Spring Boot version not detected: 4.0 → Operaton 2.1.5, 4.1 → Operaton 2.2.x"
    else target = "no Operaton line is built with Spring Boot " sbminor " (2.1 = 4.0, 2.2 = 4.1) - check `scripts/latest-versions.sh`"
  } else {
    path = "**Spring Boot 3.5 path**: Hop 1 (Operaton 1.1.5 checkpoint) + Hop 2 (Operaton 2.x, Spring Boot 4), one cut-over ([ch. 15](" docs "/15-coming-from-spring-boot-3.md), decision D1)" \
           (sbv == "" ? "; Spring Boot version not detected" : "")
    target = "Hop 1: Operaton 1.1.5 (Spring Boot 3.5.16, checkpoint only - 1.x is end of life); Hop 2: Operaton 2.1.5 (Spring Boot 4.0) or 2.2.x (Spring Boot 4.1)"
  }
  if (factsfile != "") printf "source=%s\nsbminor=%s\nee=%d\n", (boot4 ? "boot4" : "boot3"), sbminor, ee >> factsfile

  printf "## 1. Build and platform\n\n| Item | Value |\n|---|---|\n"
  printf "| Build | %s |\n", build
  printf "| Camunda version | %s |\n", ("camunda" in fact ? fact["camunda"] : "not detected")
  printf "| Edition | %s |\n", (ee ? "**Camunda EE** (" eeev ") - decision D17 (EE features) is mandatory" : "Camunda CE (no `-ee` version, EE artifact, license or EE repository found)")
  printf "| Spring Boot | %s |\n", ("spring_boot" in fact ? fact["spring_boot"] : "not detected (no parent / BOM / plugin version)")
  printf "| Spring Boot 4 artifacts | %s; Jackson 3 opt-in: %s |\n", (s4 != "" ? "`-4` starters " s4 : "no `-4` starters"), (j3 != "" ? j3 : "none")
  printf "| Migration path | %s |\n", path
  printf "| Recommended Operaton target | %s |\n", target
  printf "| Java | %s |\n", ("java" in fact ? fact["java"] : "not detected")
  printf "| Integration | %s%s |\n", (springboot ? "Spring Boot starter" (s4 != "" ? " (`-4`, Spring Boot 4)" : "") : "no Spring Boot starter found"), (webapp ? " + webapps (Cockpit/Tasklist/Admin)" : "")
  printf "| Sources | %d Java, %d Kotlin files; %d BPMN, %d DMN, %d CMMN, %d form-js files |\n", njava, nkotlin, nbpmn, ndmn, ncmmn, nform
  printf "| History level / schema-update | %s / %s |\n", ("history_level" in fact ? fact["history_level"] : "default"), ("schema_update" in fact ? fact["schema_update"] : "default (true)")
  printf "\n"

  # ---------- findings ----------
  if (cv != "" && cv !~ /^7\.24\./ && cv ~ /^7\./) F("MUST", "Camunda " cv " detected - upgrade to **7.24** first (DB schema + code), then migrate (decision D1)", "version " cv, "01-migration-path-and-decisions.md#d1")
  jv = fact["java"]; sub(/ .*/, "", jv); sub(/^1\./, "", jv); split(jv, jp, ".")
  if (jv != "" && jp[1] + 0 < 17) F("MUST", "Java " jv " - Operaton requires Java 17+", "java " jv, "01-migration-path-and-decisions.md#d1")
  # Camunda EE (decision D17, mandatory for EE users): security hardening, EE-only settings, Jackson 3
  if (ee) F("MUST", "Camunda EE **security hardening that Operaton does not have**: the query-API expression allow-list (7.24.7-ee, on by default), `validateAuthResourceIdExists` and the datasource autocommit check (both 7.24.3-ee). " \
      "Operaton behaves like Camunda before 7.24.7: stored task filters evaluate any expression (`enableExpressionsInStoredQueries` defaults to true; Camunda security notice 157, expression injection via filters). " \
      "Mitigate: generic property `enable-expressions-in-stored-queries: false` unless filters need expressions such as `${currentUser()}`, keep ad-hoc query expressions off, restrict who may create/update filters, keep `spring.datasource.hikari.auto-commit: false` (decision D17)", \
      "EE source (" eeev ")" (cnt["ee_allowlist"] || cnt["ee_authcheck"] ? "; explicit settings: " E2("ee_allowlist", "ee_authcheck") : ""), "07-identity-admin-group-and-security.md")
  if (cnt["ee_allowlist"] || cnt["ee_authcheck"] || cnt["license_api"]) F("MUST", "EE-only engine settings and calls - remove them before the first Operaton start: as generic properties (`queryExpressionAllowListEnabled`, `allowedExpression*InQueries`) they **fail the engine start** (unknown property), " \
      "Java calls (`setQueryExpressionValidator`, `setAllowed*InQueries`, `setValidateAuthResourceIdExists`, `ManagementService#setLicenseKey`) do not compile, `operaton.bpm.authorization.validate-auth-resource-id-exists` is **ignored silently** (decision D17)", \
      E3("ee_allowlist", "ee_authcheck", "license_api"), "07-identity-admin-group-and-security.md")
  if (cnt["jackson3_dep"] || cnt["jackson3_code"]) F("MUST", "Jackson 3 opt-in (`-jackson3` artifacts, 7.24.16-ee) or `tools.jackson` code next to Spin / engine REST / external task client - Operaton 2.x Spin, REST and client are **Jackson 2 only** (no `-jackson3` artifacts): " \
      "`MigrateSpringBoot4App` maps the artifacts back to the Jackson 2 ones; rewrite that code to `com.fasterxml.jackson.*`, it does not compile otherwise (decision D17)", E2("jackson3_dep", "jackson3_code"), "12-operaton-2-and-spring-boot-4.md")
  if (cnt["legacy_coords"]) F("MUST", "Pre-7.24 / legacy coordinates (not mapped by the recipe) - move to the 7.24 coordinates first", E("legacy_coords"), "03-openrewrite-recipes.md")
  if (cnt["model_camunda_refs"] || cnt["script_camunda_refs"]) F("MUST", "`org.camunda.*` referenced inside models/scripts - deploys fine, **fails at runtime**; best: package-free scripts (`S(...)`) deployed on Camunda 7.24 before the cut-over (rollback-safe), else `starterpack.operaton.ScriptImports` (Operaton-only, D15); plan instance migration for deployed versions (D3)", E2("model_camunda_refs", "script_camunda_refs"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["activiti"]) F("MUST", "`activiti:` namespace in models - not accepted by Operaton", E("activiti"), "05-bpmn-dmn-forms-and-scripts.md")
  if (webapp) F("MUST", "Webapps + DB identity: plan the **admin group migration** `camunda-admin` -> `operaton-admin` before the first Operaton start, or the setup endpoint is open (decision D5)", (cnt["camunda_admin"] ? E("camunda_admin") : "webapp starter present"), "07-identity-admin-group-and-security.md")
  else if (cnt["camunda_admin"] || cnt["camunda_admin_const"]) F("MUST", "`camunda-admin` used - group id is data; migrate memberships/authorizations (decision D5)", E2("camunda_admin", "camunda_admin_const"), "07-identity-admin-group-and-security.md")
  if (cnt["cfg_keys_outside"]) F("MUST", "`camunda.bpm.*` keys **outside** `src/*/resources` (recipes do not touch them; ignored silently after the migration)", E("cfg_keys_outside"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["env_vars"]) F("MUST", "`CAMUNDA_BPM_*` environment variables - ignored silently by Operaton; rename (optional recipe `InfraEnvVars`) incl. Helm/CI outside the repo", E("env_vars"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["liquibase_changelog"]) F("MUST", "Liquibase includes Camunda's changelog - apply the verified changelog fix (decision D8)", E("liquibase_changelog"), "08-database-schema-data-and-sql-scripts.md")
  if (cnt["webjar_ref"] || webjars != "") F("MUST", "Webapp customisations under `webjars/camunda` - move to `webjars/operaton`", (webjars != "" ? "`" webjars "`" : E("webjar_ref")), "09-webapps-rest-api-and-clients.md")
  if (cnt["ep_history"]) F("MUST", "History event handler / exporter - class names change (`org.operaton...`), consumers break silently; publish after commit (decision D9)", E("ep_history"), "06-engine-plugins-and-history-exporters.md")
  if (ndouble) F("MUST", "History handler **registered twice** (starter auto-registers a single `HistoryEventHandler` bean): " dblnames " is a Spring bean (`@Component`/`@Service`) **and** a `ProcessEnginePlugin` adds it again via `setCustomHistoryEventHandlers` - every event is handled (exported) twice, already on Camunda 7; fix it while migrating: bean **or** plugin registration, never both", dbl, "06-engine-plugins-and-history-exporters.md#43-three-problems-the-recipe-cannot-see")
  if (cnt["fqcn_strings"]) F("MUST", "Class names in string literals (`\"org.camunda...\"`) - not renamed by the recipe; often data contracts (consumers, allow-lists, Class.forName)", E("fqcn_strings"), "06-engine-plugins-and-history-exporters.md")
  if (cnt["sql_dml"]) F("MUST", "Direct DML on `ACT_*` tables - replace with the API (decision D10); review data such as `camunda-admin`", E("sql_dml"), "08-database-schema-data-and-sql-scripts.md")
  if (cnt["abstract_camunda_config"]) F("MUST", "`extends AbstractCamundaConfiguration` - constructor injection + field rename in Operaton, does not compile after the recipe", E("abstract_camunda_config"), "06-engine-plugins-and-history-exporters.md")
  if (cnt["gradle_catalog"]) F("MUST", "Gradle version catalog with Camunda coordinates - not migrated by the recipes", E("gradle_catalog"), "03-openrewrite-recipes.md")
  if (cnt["keycloak_keys"]) F("MUST", "Keycloak plugin keys `use*AsCamunda*` were renamed `use*AsOperaton*` - old keys are ignored, user ids change", E("keycloak_keys"), "07-identity-admin-group-and-security.md")
  # Spring Boot pairing of the Operaton target (decision D1); Camunda EE features (decision D17)
  if (boot4 && sbminor == "4.1") F("SHOULD", "Spring Boot 4.1 - the matching Operaton line is **2.2.x** (GA scheduled for 2026-10-23)" \
      (ga22 ? ": use `--target 2.2.0` or the latest 2.2.x" : ": rehearse with `--target 2.2.0-RC1` (pre-release, never production), go live with `--target 2.2.0`") \
      "; `migrate.sh`'s default target 2.1.5 is built with Spring Boot 4.0.8 (unsupported on 4.1), and the recipe never downgrades Spring Boot (decision D1)", "Spring Boot " fact["spring_boot"], "01-migration-path-and-decisions.md#d1")
  else if (boot4 && sbmaj == 4 && sbmin >= 2) F("SHOULD", "Spring Boot " sbminor " - no Operaton release is built with it yet (2.1 = Spring Boot 4.0, 2.2 = 4.1): migrate on Spring Boot 4.1, or wait for the matching Operaton line (decision D1)", "Spring Boot " fact["spring_boot"], "01-migration-path-and-decisions.md#d1")
  if (cnt["ee_artifact"]) F("SHOULD", "EE webapps (`-webapp-ee`, `camunda-webapp-webjar-ee`) - Operaton has the CE webapps only; the recipe maps them to the CE starter, so the EE Cockpit features (history view, heatmap, instance modification, migration UI, batches, reports) disappear without a build error: inventory their use and test a replacement for each (decision D17)", E("ee_artifact"), "09-webapps-rest-api-and-clients.md")
  if (cnt["ee_license"] || licfiles != "") F("SHOULD", "EE license (`camunda.bpm.license-file`, `camunda-license.txt`, license mounts) - Operaton needs none: the recipe deletes `camunda.bpm.license-file`; remove the file, mounts and secrets. The key stored in the database (`ACT_GE_BYTEARRAY` `camunda-license-key`) is inert: keep it for rollback (decision D17)", \
      (cnt["ee_license"] ? E("ee_license") : "") (licfiles != "" ? (cnt["ee_license"] ? "; " : "") "license file(s): `" trim(licfiles) "`" : ""), "09-webapps-rest-api-and-clients.md")
  if (cnt["ee_repo"]) F("SHOULD", "EE repository (`artifacts.camunda.com`, server id `camunda-bpm-nexus-ee`) - keep access while the recipe runs (Maven resolves all dependencies first), then remove the repository, its credentials and CI secrets: Operaton resolves from Maven Central (decision D17)", E("ee_repo"), "03-openrewrite-recipes.md")
  if (cnt["descriptor_ns"]) F("SHOULD", "`processes.xml` / `bpm-platform.xml` with the Camunda namespace - the recipe fixes it (startup fails otherwise)", E("descriptor_ns"), "03-openrewrite-recipes.md")
  if (cnt["cfg_keys"]) F("SHOULD", cnt["cfg_keys"] " `camunda.bpm.*` keys in Spring config files - renamed by `MigrateSpringBootApplication`; also review profiles, tests and config servers", E("cfg_keys"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["authz_enabled"]) F("SHOULD", "`authorization.enabled: true` - a forgotten key would switch authorization OFF silently; add the fail-fast guard", E("authz_enabled"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["app_path_cfg"] || cnt["camunda_urls"]) F("SHOULD", "Webapp path / `/camunda/app`, `/camunda/api` URLs - Operaton's default is `/operaton`; decide keep vs move (decision D6)", E2("app_path_cfg", "camunda_urls"), "09-webapps-rest-api-and-clients.md")
  if (cnt["forms_key"]) F("SHOULD", "`camunda-forms:` form keys - Operaton Tasklist recognises `operaton-forms:` only; decide keep / `operaton-forms:` (open tasks on such versions = rollback hard stop, D15) / rollback-safe `formRef` (decision D4)" \
      (webapp ? ". **Suggested D4 default:** webapp starter present → assume the Operaton Tasklist renders them → D4 option **C** (`formRef`, rollback-safe) unless told otherwise" \
              : ". No webapp starter in this build: ask which UI renders these forms (own UI via `deployed-form` → option A)"), E("forms_key"), "01-migration-path-and-decisions.md#d4")
  if (cnt["form_ref"]) F("SHOULD", "REST clients read `camundaFormRef` - renamed `operatonFormRef`", E("form_ref"), "09-webapps-rest-api-and-clients.md")
  if (cnt["log_config"] || cnt["log_levels"]) F("SHOULD", "Logger names `org.camunda.*` in log config - fixed by the starter-pack recipe; dashboards/alerts outside the repo too", E2("log_config", "log_levels"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["health_camunda"]) F("SHOULD", "`management.health.camunda` - renamed `management.health.operaton` (recipe); review probes (decision D13)", E("health_camunda"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["spi_services"] || cnt["spi_factories"] || cnt["spi_content"]) F("SHOULD", "SPI registrations (`META-INF/services`, `spring.factories`) with `org.camunda` - renamed by the recipes; verify they load (silent if wrong)", E3("spi_services", "spi_factories", "spi_content"), "06-engine-plugins-and-history-exporters.md")
  if (cnt["camunda_cfg_xml"]) F("SHOULD", "`camunda.cfg.xml` - Operaton tests read `operaton.cfg.xml` (recipe renames)", E("camunda_cfg_xml"), "10-testing.md")
  if (cnt["junit5_ext"] || cnt["test_mocks"]) F("SHOULD", "Test setup (`camunda-bpm-junit5`, Mocks) - recipe bugs fixed by the starter-pack composite; use the junit5 starter (decision D11)", E2("junit5_ext", "test_mocks"), "10-testing.md")
  if (cnt["community"]) F("SHOULD", "Community extensions / test libraries - check Operaton-compatible versions or replacements", E("community"), "14-ecosystem-support-and-resources.md")
  if (cnt["unmapped_coords"]) F("SHOULD", "Artifacts not mapped by the official recipe (sql-scripts, openapi, distros) - starter-pack recipe maps sql-scripts/openapi; distros manually", E("unmapped_coords"), "03-openrewrite-recipes.md")
  if (cnt["ep_spin"]) F("SHOULD", "Spin `DataFormatConfigurator` - keep it on **Jackson 2** (`com.fasterxml.jackson`), Operaton 2.x Spin is Jackson 2 only" \
      (boot4 ? ": `MigrateSpringBoot4App` renames it and runs no Jackson 3 step; never run `--hop 2` or the stock `UpgradeSpringBoot_4_0` recipe on it (they rewrite it to `tools.jackson` and drop module registrations)" \
             : ": Hop 2 excludes it from the Jackson 3 step only because Hop 1 renamed it first - never run `--hop 2` on un-renamed code"), E("ep_spin"), "12-operaton-2-and-spring-boot-4.md")
  if (cnt["raw_generics"]) F("SHOULD", "Raw `List<JobHandler>` / null-check idioms - compile/runtime break since Operaton 1.1", E("raw_generics"), "06-engine-plugins-and-history-exporters.md")
  if (cnt["abstract_parse_listener"]) F("SHOULD", "`extends AbstractBpmnParseListener` - deprecated for removal; implement `BpmnParseListener`", E("abstract_parse_listener"), "06-engine-plugins-and-history-exporters.md")
  if (cnt["bean_names"] || cnt["prop_literals"]) F("SHOULD", "Starter bean names / `camunda.bpm` prefixes in string literals - renamed by the starter-pack PreFixes; review", E2("bean_names", "prop_literals"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["strict_form"]) F("SHOULD", "`disable-strict-camunda-form-parsing` - renamed `disableStrictOperatonFormParsing` (recipe)", E("strict_form"), "04-spring-boot-dependencies-and-configuration.md")
  if (cnt["sql_in_code"] || (cnt["sql_files"] && !cnt["sql_dml"])) F("SHOULD", "SQL against `ACT_*` tables (queries/reports) - same schema in Operaton, but review and prefer the API (decision D10)", E2("sql_in_code", "sql_files"), "08-database-schema-data-and-sql-scripts.md")
  if (cnt["nashorn"]) F("SHOULD", "Nashorn/Rhino-only JavaScript helpers - Operaton uses GraalJS", E("nashorn"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["java_serialization"]) F("SHOULD", "Java serialization of variables - `org.camunda.*` objects in the DB need conversion or draining (decision D18)", E("java_serialization"), "08-database-schema-data-and-sql-scripts.md")
  if (cnt["ldap"] || cnt["keycloak"]) F("SHOULD", "LDAP/Keycloak identity - map the admin group in the provider or via `AdministratorAuthorizationPlugin` (decision D5)", E2("ldap", "keycloak"), "07-identity-admin-group-and-security.md")
  if (cnt["impl_api"]) F("INFO", cnt["impl_api"] " imports of internal API `org.camunda.bpm.engine.impl.*` (renamed 1:1; first to change in later majors)", topimpl(), "06-engine-plugins-and-history-exporters.md")
  if (cnt["ns_camunda"]) F("INFO", cnt["ns_camunda"] " model files use the `camunda:` namespace - accepted by Operaton, keep it (decision D3)" (cnt["ns_operaton"] ? "; " cnt["ns_operaton"] " already use `operaton:`" : ""), E("ns_camunda"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["script_tasks"] || cnt["camunda_scripts"]) F("INFO", (cnt["script_tasks"] + cnt["camunda_scripts"]) " scripts in models (" langs() "); " cnt["external_scripts"] + 0 " external script resources", E2("script_tasks", "camunda_scripts"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["connectors"] || cnt["connect_dep"]) F("INFO", "Connectors (camunda-connect) in use", E2("connectors", "connect_dep"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["embedded_forms"]) F("INFO", "Embedded HTML forms - directives (`cam-variable-name`, `camForm`) unchanged in Operaton", E("embedded_forms"), "05-bpmn-dmn-forms-and-scripts.md")
  if (cnt["exec_context"]) F("INFO", "`Context.getExecutionContext()` - replaced by the starter-pack PreFixes (`getBpmnExecutionContext`)", E("exec_context"), "03-openrewrite-recipes.md")
  if (cnt["ext_client"]) F("INFO", "External task client in use - renamed artifacts/packages (recipe)", E("ext_client"), "09-webapps-rest-api-and-clients.md")
  if (cnt["camunda8"]) F("INFO", "`io.camunda` (Camunda 8) references - not part of a Camunda 7 -> Operaton migration", E("camunda8"), "00-why-operaton-and-what-changes.md")
  if (cnt["kotlin"]) F("INFO", "Kotlin sources - the Maven plugin parses them; recipe behaviour not verified by the starter pack", E("kotlin"), "03-openrewrite-recipes.md")
  if (cnt["liquibase_cfg"] || cnt["flyway_cfg"] || cnt["flyway_scripts"]) F("INFO", "Liquibase/Flyway configuration present - check whether it manages the engine schema (decision D8)", E3("liquibase_cfg", "flyway_cfg", "flyway_scripts"), "08-database-schema-data-and-sql-scripts.md")
  if (cnt["war"]) F("INFO", "WAR packaging - shared-engine/container deployments are out of the starter pack's scope", E("war"), "01-migration-path-and-decisions.md")
  F("INFO", "Always check outside the repository: Helm/K8s, config server, CI variables, dashboards and alert rules (logger names), runbooks, DB data (`20-find-legacy-references.sql`, decision D18)", "-", "02-assessment.md")

  printf "## 2. Findings\n\n**Summary: %d MUST · %d SHOULD · %d INFO**\n", nf["MUST"], nf["SHOULD"], nf["INFO"]
  split("MUST SHOULD INFO", sevs, " ")
  for (s = 1; s <= 3; s++) {
    sev = sevs[s]; if (!nf[sev]) continue
    printf "\n### %s\n\n| # | Finding | Evidence | Read |\n|---|---|---|---|\n", sev
    for (i = 1; i <= nf[sev]; i++) printf "| %s%d | %s | %s | [%s](%s/%s) |\n", substr(sev, 1, 1), i, FT[sev, i], FE[sev, i], chap(FL[sev, i]), docs, FL[sev, i]
  }

  # ---------- inventory ----------
  printf "\n## 3. Inventory\n\n### 3.1 Camunda / Operaton coordinates (%d)\n\n", ndeps
  if (ndeps == 0) printf "None found.\n"
  else { for (d in deps) list[++nl] = d; isort(list, nl); for (i = 1; i <= nl; i++) printf "- `%s` (%s)\n", list[i], deps[list[i]] }
  printf "\n### 3.2 Code and extension points\n\n| What | Count | Files | Examples |\n|---|---|---|---|\n"
  row("Imports of `org.camunda.{bpm,spin,connect,commons}`", "camunda_imports")
  row("  of which internal API `org.camunda.bpm.engine.impl.*`", "impl_api")
  row("  of which Spring Boot starter API", "starter_api")
  row("Delegates / listeners (JavaDelegate, ExecutionListener, TaskListener)", "ep_delegate")
  row("Process engine plugins", "ep_plugin")
  row("History event handlers (exporters)", "ep_history")
  row("Incident handlers", "ep_incident")
  row("Job handlers", "ep_jobhandler")
  row("BPMN parse listeners", "ep_parselistener")
  row("Variable serializers", "ep_serializer")
  row("Spin data format configurators/providers", "ep_spin")
  row("Webapp plugins (Cockpit/Tasklist/Admin)", "ep_webapp_plugin")
  row("Other engine SPI (FailedJobCommandFactory, ExpressionManager, IdGenerator, HistoryLevel)", "ep_engine_other")
  row("Engine test setup (rules/extensions/@Deployment/assert)", "test_engine")
  row("Class names in string literals", "fqcn_strings")
  printf "\n### 3.3 Configuration, SPI and descriptors\n\n| What | Count | Files | Examples |\n|---|---|---|---|\n"
  row("`camunda.bpm.*` keys in `src/*/resources`", "cfg_keys")
  row("`camunda.bpm.*` keys elsewhere", "cfg_keys_outside")
  row("`CAMUNDA_BPM_*` env vars", "env_vars")
  row("`management.health.camunda`", "health_camunda")
  row("`logging.level.org.camunda.*` keys", "log_levels")
  row("Logger entries in logback/log4j2 XML", "log_config")
  row("`META-INF/services/org.camunda.*` files", "spi_services")
  row("`spring.factories` / `*.imports` with org.camunda", "spi_factories")
  row("`processes.xml` files", "processes_xml")
  row("`bpm-platform.xml` files", "bpm_platform_xml")
  row("`camunda.cfg.xml` files", "camunda_cfg_xml")
  row("`camunda-admin` literals", "camunda_admin")
  row("`/camunda/app`, `/camunda/api` URLs", "camunda_urls")
  printf "\n### 3.4 Models\n\n| What | Count | Files | Examples |\n|---|---|---|---|\n"
  row("Files with `camunda:` namespace", "ns_camunda")
  row("Files with `operaton:` namespace", "ns_operaton")
  row("Script tasks", "script_tasks")
  row("`camunda:script` (listeners, IO mappings)", "camunda_scripts")
  row("External script resources", "external_scripts")
  row("`org.camunda.*` inside models", "model_camunda_refs")
  row("`org.camunda.*` in script files", "script_camunda_refs")
  row("`camunda-forms:` form keys", "forms_key")
  row("`camunda:formRef`", "form_ref_attr")
  row("Embedded HTML forms", "embedded_forms")
  row("Connectors", "connectors")
  row("`camunda:class`", "model_class")
  row("`camunda:delegateExpression` / `expression`", "model_expr")
  row("Async continuations", "model_async")
  row("External tasks", "model_external")
  printf "\nScript languages: %s\n", langs()
  printf "\n### 3.5 Database and SQL\n\n| What | Count | Files | Examples |\n|---|---|---|---|\n"
  row("SQL files touching `ACT_*`", "sql_files")
  row("  DML statements (UPDATE/DELETE/INSERT/TRUNCATE)", "sql_dml")
  row("`ACT_*` table names in code", "sql_in_code")
  row("Liquibase config / Camunda changelog includes", "liquibase_cfg")
  row("Camunda changelog includes", "liquibase_changelog")
  row("Flyway config / Camunda DDL scripts", "flyway_cfg")
  if (ee || cnt["jackson3_dep"] || cnt["jackson3_code"]) {
    printf "\n### 3.6 Camunda EE and Spring Boot 4\n\n| What | Count | Files | Examples |\n|---|---|---|---|\n"
    row("`-ee` versions (`7.24.N-ee`)", "ee_version")
    row("`-ee` artifacts (EE webapps / webjar)", "ee_artifact")
    row("License (`license-file`, `camunda-license.txt`, key)", "ee_license")
    if (licfiles != "") { n = split(trim(licfiles), lf, " "); printf "| `camunda-license.txt` files | %d | %d | `%s` |\n", n, n, trim(licfiles) }
    row("EE repository (`artifacts.camunda.com`, `camunda-bpm-nexus-ee`)", "ee_repo")
    row("`camunda-bpm-spring-boot-starter-4*` references", "starter4")
    row("`-jackson3` artifacts", "jackson3_dep")
    row("`tools.jackson` next to Spin / REST / client", "jackson3_code")
    row("Query expression allow-list settings (7.24.7-ee)", "ee_allowlist")
    row("`validateAuthResourceIdExists` (7.24.3-ee)", "ee_authcheck")
    row("License API calls (`setLicenseKey` ...)", "license_api")
  }
}
function F(sev, text, evidence, link) { nf[sev]++; FT[sev, nf[sev]] = text; FE[sev, nf[sev]] = evidence; FL[sev, nf[sev]] = link }
function E(k) { return cnt[k] " in " nfiles[k] " file(s): " ex[k] }
function E2(a, b,   s) { s = ""; if (cnt[a]) s = E(a); if (cnt[b]) s = s (s == "" ? "" : "; ") E(b); return s }
function E3(a, b, c,   s) { s = E2(a, b); if (cnt[c]) s = s (s == "" ? "" : "; ") E(c); return s }
function row(label, k) { if (cnt[k]) printf "| %s | %d | %d | %s |\n", label, cnt[k], nfiles[k], ex[k] }
function langs(   l, s) { s = ""; for (l in sf) s = s (s == "" ? "" : ", ") l " " sf[l]; return s == "" ? "none" : s }
function topimpl(   p, s, n, i, j, tmp, arr) {
  n = 0; for (p in implpkg) arr[++n] = p
  for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (implpkg[arr[j]] > implpkg[arr[i]]) { tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp }
  s = ""; for (i = 1; i <= n && i <= 6; i++) s = s (s == "" ? "" : ", ") "`" substr(arr[i], 29) "` " implpkg[arr[i]]
  return "top packages below `org.camunda.bpm.engine.impl`: " s
}
function isort(a, n,   i, j, t) { for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t } }
function chap(l,   c) { c = l; sub(/-.*/, "", c); return "ch. " c }
AWK

printf '# Operaton migration assessment: %s\n\n' "$(basename "$ROOT")"
printf 'Generated by `scripts/assess.sh` (Camunda 7 -> Operaton Migration Starter Pack) on %s. Read-only scan of `%s`.\n' "$(date +%Y-%m-%d)" "$ROOT"
printf 'Severity: **MUST** = blocks the migration or breaks silently unless you act · **SHOULD** = handled by the recipes but review, or decide · **INFO** = planning context.\n\n'

# pre-pass: code files that register custom history event handlers (for the "registered twice" rule)
: > "$TMP/hreg"
if grep -q -E '\.(java|kt|groovy|scala)$' "$TMP/files"; then
  ( cd "$ROOT" && grep -E '\.(java|kt|groovy|scala)$' "$TMP/files" | tr '\n' '\0' \
      | xargs -0 grep -l -E 'setCustomHistoryEventHandlers|getCustomHistoryEventHandlers\(\)[[:space:]]*\.[[:space:]]*add' -- 2>/dev/null ) > "$TMP/hreg" || true
fi
# facts for the next steps below (source=boot4|boot3, sbminor=4.1, ee=0|1), written by the awk END block
: > "$TMP/report.md"; : > "$TMP/facts"
if [ "$FILE_COUNT" -gt 0 ]; then
  ( cd "$ROOT" && tr '\n' '\0' < "$TMP/files" | xargs -0 awk -v maxex="$NEX" -v docs="$DOCS" -v webjars="$WEBJAR_DIRS" -v hregfile="$TMP/hreg" \
      -v licfiles="$LICENSE_FILES" -v factsfile="$TMP/facts" -v ga22="$GA22" -f "$TMP/assess.awk" ) > "$TMP/report.md" 2>"$TMP/awk.err" || true
fi
# xargs may split huge file lists into several awk runs -> warn (counts would be per batch)
if [ "$(grep -c '^## 1\. Build and platform' "$TMP/report.md" 2>/dev/null || echo 0)" -gt 1 ]; then
  echo "WARN: very large repository - the file list was split into several batches; run assess.sh per module." >&2
fi
cat "$TMP/report.md"
END=$(date +%s)
MUSTS=$(sed -n 's/^\*\*Summary: \([0-9]*\) MUST.*/\1/p' "$TMP/report.md" | head -n 1)
SHOULDS=$(sed -n 's/^\*\*Summary: [0-9]* MUST · \([0-9]*\) SHOULD.*/\1/p' "$TMP/report.md" | head -n 1)
INFOS=$(sed -n 's/^\*\*Summary: .* SHOULD · \([0-9]*\) INFO.*/\1/p' "$TMP/report.md" | head -n 1)
SOURCE=$(sed -n 's/^source=//p' "$TMP/facts" | head -n 1)
SB_MINOR=$(sed -n 's/^sbminor=//p' "$TMP/facts" | head -n 1)
IS_EE=$(sed -n 's/^ee=//p' "$TMP/facts" | head -n 1)
# the right migrate.sh call for the detected source (same detection as migrate.sh --source auto)
if [ "$SOURCE" = "boot4" ]; then
  if [ "$SB_MINOR" = "4.1" ] && [ "$GA22" -eq 0 ]; then
    STEP2="Dry-run the recipe on a clean branch: \`scripts/migrate.sh --dry-run --target 2.2.0-RC1 <project-dir>\` (Spring Boot 4 path, one recipe run; Spring Boot 4.1 needs Operaton 2.2: RC1 for rehearsals only, \`--target 2.2.0\` once GA)"
  elif [ "$SB_MINOR" = "4.1" ]; then
    STEP2="Dry-run the recipe on a clean branch: \`scripts/migrate.sh --dry-run --target 2.2.0 <project-dir>\` (Spring Boot 4 path, one recipe run; Spring Boot 4.1 needs Operaton 2.2.x)"
  else
    STEP2="Dry-run the recipe on a clean branch: \`scripts/migrate.sh --dry-run <project-dir>\` (Spring Boot 4 path, one recipe run)"
  fi
  STEP2="$STEP2 ([ch. 03](${DOCS}/03-openrewrite-recipes.md))."
else
  STEP2="Dry-run Hop 1 on a clean branch: \`scripts/migrate.sh --hop 1 --dry-run <project-dir>\` (Spring Boot 3.5 path: [ch. 15](${DOCS}/15-coming-from-spring-boot-3.md), [ch. 03](${DOCS}/03-openrewrite-recipes.md))."
fi
# EE builds: rewrite-maven-plugin resolves every (test) dependency before the recipe runs
[ "$IS_EE" != "1" ] || STEP2="$STEP2 Camunda EE build: the run needs access to the Camunda EE repository; remove it after the conversion."
cat <<EOF

## 4. Next steps

1. Record the decisions D1-D18 ([decision log](${DOCS}/01-migration-path-and-decisions.md)), starting with every MUST above.
2. ${STEP2}
3. Check the database of a production copy: \`${SQL_DIR}/00-preflight-checks.sql\` and \`${SQL_DIR}/20-find-legacy-references.sql\` ([ch. 08](${DOCS}/08-database-schema-data-and-sql-scripts.md)).

---
assess.sh summary: ${MUSTS:-0} MUST · ${SHOULDS:-0} SHOULD · ${INFOS:-0} INFO · ${FILE_COUNT} files scanned in $((END - START))s
EOF
