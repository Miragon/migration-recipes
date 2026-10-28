#!/usr/bin/env bash
# latest-versions.sh - current Operaton / recipe / OpenRewrite versions from Maven Central (and the Gradle
# plugin portal), compared with the versions pinned in the starter pack.
#
# Part of the "Camunda 7 -> Operaton Migration Starter Pack" (Apache-2.0).
# Needs curl. Works with bash 3.2+ on macOS (BSD) and Linux (GNU).

set -euo pipefail

# Layout: starter-pack repository (rewrite/rewrite.yml, docs/) or the bundled Claude skill (assets/rewrite.yml
# next to scripts/, no docs/) -> doc links point to the guide on GitHub.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
GUIDE_URL="https://github.com/Miragon/migration-recipies/blob/main/services/c7"
if [ -d "$SCRIPT_DIR/../assets" ] && [ ! -d "$SCRIPT_DIR/../docs" ]; then
  DOCS="$GUIDE_URL/docs"; REWRITE_REL="assets/rewrite.yml"
else
  DOCS="docs"; REWRITE_REL="rewrite/rewrite.yml"
fi

usage() {
  cat <<EOF
Usage: latest-versions.sh [--operaton <version>] [--all-lines]

Prints (Markdown):
  - latest GA of org.operaton.bpm:operaton-bom overall and per line (1.1, 2.1, 2.2, ...), ignoring
    -M / -RC / alpha / beta / SNAPSHOT versions (Maven's <release> tag may point to an RC),
  - the Spring Boot version each of these releases is built with (property version.spring-boot in
    org.operaton.bpm:operaton-root:<version>, the parent of operaton-bom-root -> operaton-bom),
  - which Operaton line matches each Spring Boot minor (e.g. 4.0 -> 2.1.x, 4.1 -> 2.2.x): the newest line
    whose releases are built with it; a line that has only pre-releases so far is shown as such,
  - latest org.operaton:migrate-camunda-recipe, rewrite-maven-plugin, rewrite-spring, rewrite-recipe-bom on
    Maven Central and the OpenRewrite Gradle plugin on the Gradle plugin portal,
  - the versions pinned in the starter pack (scripts/migrate.sh, ${REWRITE_REL}) for comparison.

Options:
  --operaton <version>  Also show the Spring Boot version of this Operaton release (e.g. 2.1.5).
  --all-lines           Show every Operaton line, not only 1.1 and newer.
  -h, --help            Show this help.

Environment: MAVEN_CENTRAL (default https://repo1.maven.org/maven2), GRADLE_PLUGINS (default https://plugins.gradle.org/m2)
EOF
}

CENTRAL="${MAVEN_CENTRAL:-https://repo1.maven.org/maven2}"
PORTAL="${GRADLE_PLUGINS:-https://plugins.gradle.org/m2}"
EXTRA=""; ALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --operaton) [ $# -ge 2 ] || { echo "--operaton needs a value" >&2; exit 2; }; EXTRA="$2"; shift 2 ;;
    --all-lines) ALL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 2; }

# Starter-pack pins (keep in sync with scripts/migrate.sh; PIN_TARGET = default --target of the Spring Boot 4 path
# and of Hop 2, PIN_HOP1 = Hop 1 checkpoint of the Spring Boot 3.5 path)
PIN_PLUGIN="6.46.1"; PIN_RECIPE="1.0.1"; PIN_SPRING="6.37.0"; PIN_GRADLE="7.39.0"; PIN_HOP1="1.1.5"; PIN_TARGET="2.1.5"

fetch() { curl -fsSL --max-time 20 "$1" 2>/dev/null || true; }

# all <version> entries of a maven-metadata.xml, GA only, sorted ascending (numeric per segment)
ga_versions() {
  fetch "$1" | sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' \
    | grep -E '^[0-9]+(\.[0-9]+)*$' \
    | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n || true
}
all_versions() { fetch "$1" | sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p'; }
minor_of() { printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'; }
latest() { tail -n 1; }
spring_boot_of() {
  fetch "$CENTRAL/org/operaton/bpm/operaton-root/$1/operaton-root-$1.pom" \
    | sed -n 's:.*<version\.spring-boot>\([^<]*\)</version\.spring-boot>.*:\1:p' | head -n 1
}
mark() { if [ -z "$2" ]; then printf 'n/a (lookup failed)'; elif [ "$1" = "$2" ]; then printf '%s (= pinned)' "$2"; else printf '**%s** (pinned: %s)' "$2" "$1"; fi; }

BOM_META="$CENTRAL/org/operaton/bpm/operaton-bom/maven-metadata.xml"
BOM_GA="$(ga_versions "$BOM_META")"
[ -n "$BOM_GA" ] || { echo "Could not read $BOM_META (offline or proxy?). Set MAVEN_CENTRAL to a mirror." >&2; exit 1; }
BOM_RELEASE_TAG="$(fetch "$BOM_META" | sed -n 's:.*<release>\([^<]*\)</release>.*:\1:p' | head -n 1)"
BOM_LATEST="$(printf '%s\n' "$BOM_GA" | latest)"
BOM_ALL="$(all_versions "$BOM_META" | grep -v -E 'SNAPSHOT' || true)"   # metadata order = publishing order
PRE="$(printf '%s\n' "$BOM_ALL" | grep -E -- '-(M|RC|rc|alpha|beta)' | tail -n 3 | tr '\n' ' ')"

printf '# Operaton and tooling versions (%s)\n\n' "$(date +%Y-%m-%d)"
printf 'Source: %s (GA versions only; pre-releases ignored)\n\n' "$CENTRAL"
printf '## Operaton (org.operaton.bpm:operaton-bom)\n\n'
printf '| Line | Latest GA | Built with Spring Boot | Note |\n|---|---|---|---|\n'
LINES="$(printf '%s\n' "$BOM_GA" | awk -F. '{print $1"."$2}' | uniq)"
for line in $LINES; do
  major="${line%%.*}"; minor="${line#*.}"
  if [ "$ALL" -eq 0 ] && { [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 1 ]; }; }; then continue; fi
  v="$(printf '%s\n' "$BOM_GA" | grep -E "^${major}\.${minor}\." | latest)"
  sb="$(spring_boot_of "$v")"
  note=""
  [ "$v" = "$BOM_LATEST" ] && note="latest GA - production target if it matches your Spring Boot minor (next table, decision D1)"
  [ "$major" -eq 1 ] && note="final 1.x line, end of life - Hop 1 checkpoint only"
  printf '| %s | %s | %s | %s |\n' "$line" "$v" "${sb:-n/a}" "$note"
done
printf '\nMaven metadata `<release>` says: `%s`%s. Newest pre-releases: %s\n' "$BOM_RELEASE_TAG" \
  "$( [ "$BOM_RELEASE_TAG" != "$BOM_LATEST" ] && printf ' (a pre-release - pin versions, do not use "latest")' || true)" "${PRE:-none}"
if [ -n "$EXTRA" ]; then
  printf '\nOperaton %s is built with Spring Boot %s.\n' "$EXTRA" "$(spring_boot_of "$EXTRA" | sed 's/^$/n\/a (version not found)/')"
fi

# Spring Boot minor -> Operaton line: per Operaton line its newest GA (else its newest pre-release) and the Spring
# Boot version that release is built with; per Spring Boot minor the newest line with a GA wins, a newer line that
# has only pre-releases so far is shown as "next" (or as the only match).
printf '\n## Spring Boot minor -> Operaton line\n\n'
printf 'Operaton supports only the Spring Boot version each release is built with. Pick the line that matches the\n'
printf 'Spring Boot minor of your application (Spring Boot 4 path: `migrate.sh --target <version>`).\n\n'
printf '| Spring Boot | Operaton line | Newest release | Built with Spring Boot | Note |\n|---|---|---|---|---|\n'
ALL_LINES="$(printf '%s\n' "$BOM_ALL" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\)\..*/\1/p' | sort -t. -k1,1n -k2,2n | uniq)"
MAP=""; idx=0
for line in $ALL_LINES; do
  major="${line%%.*}"; minor="${line#*.}"
  if [ "$ALL" -eq 0 ] && { [ "$major" -lt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -lt 1 ]; }; }; then continue; fi
  v="$(printf '%s\n' "$BOM_GA" | grep -E "^${major}\.${minor}\." | latest || true)"; kind="GA"
  if [ -z "$v" ]; then v="$(printf '%s\n' "$BOM_ALL" | grep -E "^${major}\.${minor}\.[0-9]+-" | latest || true)"; kind="pre"; fi
  [ -n "$v" ] || continue
  sb="$(spring_boot_of "$v")"; sbm="$(minor_of "$sb")"
  idx=$((idx + 1))
  MAP="${MAP}${sbm:-?}|${line}|${v}|${sb:-n/a}|${kind}|${idx}
"
done
# input sorted by Spring Boot minor (numeric major, minor) -> table rows in that order
printf '%s' "$MAP" | sort -t. -k1,1n -k2,2n | awk -F'|' '
  NF >= 6 {
    if ($5 == "GA") { if ($6 + 0 > gai[$1] + 0) { ga[$1] = $0; gai[$1] = $6 } }
    else if ($6 + 0 > prei[$1] + 0) { pre[$1] = $0; prei[$1] = $6 }
    if (!($1 in seen)) { seen[$1] = 1; order[++n] = $1 }
  }
  END {
    for (i = 1; i <= n; i++) {
      m = order[i]
      if (m in ga) {
        split(ga[m], f, "|"); note = (f[2] ~ /^1\./ ? "1.x is end of life - Hop 1 checkpoint of the Spring Boot 3.5 path only" : "GA, supported pairing")
        if ((m in pre) && prei[m] > gai[m]) { split(pre[m], q, "|"); note = note "; next: " q[3] " (pre-release)" }
        printf "| %s | %s.x | %s | %s | %s |\n", m, f[2], f[3], f[4], note
      } else {
        split(pre[m], f, "|")
        printf "| %s | %s.x | %s | %s | pre-release only, no GA yet - rehearsals, never production |\n", m, f[2], f[3], f[4]
      }
    }
  }'

printf '\n## Migration tooling\n\n| Artifact | Latest | Starter pack |\n|---|---|---|\n'
RECIPE="$(ga_versions "$CENTRAL/org/operaton/migrate-camunda-recipe/maven-metadata.xml" | latest)"
PLUGIN="$(ga_versions "$CENTRAL/org/openrewrite/maven/rewrite-maven-plugin/maven-metadata.xml" | latest)"
RSPRING="$(ga_versions "$CENTRAL/org/openrewrite/recipe/rewrite-spring/maven-metadata.xml" | latest)"
RBOM="$(ga_versions "$CENTRAL/org/openrewrite/recipe/rewrite-recipe-bom/maven-metadata.xml" | latest)"
GPLUGIN="$(ga_versions "$PORTAL/org/openrewrite/plugin/maven-metadata.xml" | latest)"
printf '| `org.operaton:migrate-camunda-recipe` | %s | %s |\n' "${RECIPE:-n/a}" "$(mark "$PIN_RECIPE" "$RECIPE")"
printf '| `org.openrewrite.maven:rewrite-maven-plugin` | %s | %s |\n' "${PLUGIN:-n/a}" "$(mark "$PIN_PLUGIN" "$PLUGIN")"
printf '| `org.openrewrite.recipe:rewrite-spring` | %s | %s (pinned to match rewrite 8.89.0 of plugin %s) |\n' "${RSPRING:-n/a}" "$PIN_SPRING" "$PIN_PLUGIN"
printf '| `org.openrewrite.recipe:rewrite-recipe-bom` | %s | 3.37.0 recommended (3.38.0 references modules missing on Central) |\n' "${RBOM:-n/a}"
printf '| `org.openrewrite:plugin` (Gradle portal) | %s | %s (7.40.0+ cannot resolve rewrite-bom 8.91.0 from public repos) |\n' "${GPLUGIN:-n/a}" "$PIN_GRADLE"
printf '| Operaton target (`migrate.sh --target` default: Spring Boot 4 path, Hop 2) | %s | %s |\n' "$BOM_LATEST" "$(mark "$PIN_TARGET" "$BOM_LATEST")"
LATEST_11="$(printf '%s\n' "$BOM_GA" | grep -E '^1\.1\.' | latest || true)"
printf '| Operaton Hop 1 checkpoint (Spring Boot 3.5 path) | %s | %s |\n' "${LATEST_11:-n/a}" "$(mark "$PIN_HOP1" "$LATEST_11")"

cat <<EOF

Notes
- Newer OpenRewrite releases are published to the Code Genome Project repository (login required); the latest
  versions on Maven Central are what the starter pack pins. See ${DOCS}/03-openrewrite-recipes.md#3-versions-and-plugin-choice.
- Keep Spring Boot on the minor the Operaton release is built with (tables above). Spring Boot 4 path: migrate.sh
  never downgrades Spring Boot and warns when your minor differs from the --target's; Hop 2 of the Spring Boot 3.5
  path sets the version that --target <v> is built with (read from operaton-root-<v>.pom).
EOF
