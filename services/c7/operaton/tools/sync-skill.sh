#!/usr/bin/env bash
# Copies the canonical toolkit files of this guide (services/c7/operaton/) into the self-contained agent skill of the plugin
# (plugin/skills/migrating-camunda7-to-operaton/, for Claude Code and GitHub Copilot).
#   tools/sync-skill.sh          copy
#   tools/sync-skill.sh --check  exit 1 if the skill copies differ from the (transformed) canonical files, or if the
#                                skill is not portable: ${CLAUDE_SKILL_DIR} anywhere except the one <skill-dir>
#                                definition line in SKILL.md, or a $ARGUMENTS placeholder anywhere (GitHub Copilot
#                                substitutes neither; the skill uses the <skill-dir> convention and reads the mode
#                                from the user's words)
#
# Markdown files are not copied verbatim: their relative links are rewritten to absolute GitHub URLs of the
# guide (https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton/<guide path>), because docs/, examples/,
# checklists/ and sql/test/ are not part of the skill. Links to files that the skill carries at the same
# relative position (e.g. postgresql/*.sql next to assets/sql/README.md) and #anchors stay relative.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"                 # the guide: services/c7/operaton
REPO="$(cd "$ROOT/../../.." && pwd)"                      # the repository root
SKILL="$REPO/plugin/skills/migrating-camunda7-to-operaton"
EX="examples/operaton-spring-boot-migrated/src/main/java/com/example/orders"
EXT="examples/operaton-spring-boot-migrated/src/test/java/com/example/orders"
GH_GUIDE="https://github.com/Miragon/migration-recipies"   # + /blob|tree/main/services/c7/operaton/<guide path>
GUIDE_PREFIX="services/c7/operaton"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# "<canonical source>|<skill destination>" pairs (@EX = migrated example main sources, @EXT = its tests)
PAIRS="
rewrite/rewrite.yml|assets/rewrite.yml
scripts/assess.sh|scripts/assess.sh
scripts/migrate.sh|scripts/migrate.sh
scripts/verify-leftovers.sh|scripts/verify-leftovers.sh
scripts/smoke-test.sh|scripts/smoke-test.sh
scripts/latest-versions.sh|scripts/latest-versions.sh
sql/README.md|assets/sql/README.md
sql/postgresql/00-preflight-checks.sql|assets/sql/postgresql/00-preflight-checks.sql
sql/postgresql/10-migrate-admin-group.sql|assets/sql/postgresql/10-migrate-admin-group.sql
sql/postgresql/20-find-legacy-references.sql|assets/sql/postgresql/20-find-legacy-references.sql
sql/postgresql/30-emergency-job-retries.sql|assets/sql/postgresql/30-emergency-job-retries.sql
sql/postgresql/31-emergency-external-task-retries.sql|assets/sql/postgresql/31-emergency-external-task-retries.sql
@EX/migration/AdminGroupMigrationPlugin.java|assets/snippets/AdminGroupMigrationPlugin.java
@EX/migration/LegacyCamundaConfigGuard.java|assets/snippets/LegacyCamundaConfigGuard.java
@EX/migration/LegacyWebappPathRedirectFilter.java|assets/snippets/LegacyWebappPathRedirectFilter.java
@EX/migration/MigrationHelpersConfiguration.java|assets/snippets/MigrationHelpersConfiguration.java
@EX/history/HistoryExportPlugin.java|assets/snippets/HistoryExportPlugin.java
@EX/history/ExportingHistoryEventHandler.java|assets/snippets/ExportingHistoryEventHandler.java
@EX/history/EventPublisher.java|assets/snippets/EventPublisher.java
@EX/history/ExportedHistoryEvent.java|assets/snippets/ExportedHistoryEvent.java
@EX/operations/IncidentRecoveryService.java|assets/snippets/IncidentRecoveryService.java
@EXT/migration/AdminGroupMigrationPluginTest.java|assets/snippets/test/AdminGroupMigrationPluginTest.java
@EXT/history/ExportingHistoryEventHandlerTest.java|assets/snippets/test/ExportingHistoryEventHandlerTest.java
@EXT/migration/LegacyCamundaConfigGuardTest.java|assets/snippets/test/LegacyCamundaConfigGuardTest.java
"

src_path() { # canonical repo-relative path of a pair source
  case "$1" in
    @EXT/*) printf '%s/%s' "$EXT" "${1#@EXT/}" ;;
    @EX/*) printf '%s/%s' "$EX" "${1#@EX/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# keep_list <src dir> <dst dir>: link targets (relative to the Markdown file) that exist at the same relative
# position in the skill, because another pair copies them there.
keep_list() {
  local pair s d
  for pair in $PAIRS; do
    s="$(src_path "${pair%%|*}")"; d="${pair#*|}"
    case "$s" in "$1"/*) ;; *) continue ;; esac
    case "$d" in "$2"/*) ;; *) continue ;; esac
    [ "${s#"$1"/}" = "${d#"$2"/}" ] && printf '%s\n' "${s#"$1"/}"
  done
}

# md_transform <src file> <repo-relative src dir> <keep-list file>: relative links -> absolute GitHub URLs
md_transform() {
  awk -v gh="$GH_GUIDE" -v prefix="$GUIDE_PREFIX" -v base="$2" -v keepfile="$3" '
    BEGIN { while ((getline k < keepfile) > 0) keep[k] = 1 }
    function norm(p,   n, i, parts, out, k, o) {          # resolve "." and ".." segments
      n = split(p, parts, "/"); k = 0
      for (i = 1; i <= n; i++) {
        if (parts[i] == "." || (parts[i] == "" && i < n)) continue
        if (parts[i] == "..") { if (k > 0) k--; continue }
        out[++k] = parts[i]
      }
      o = ""; for (i = 1; i <= k; i++) o = o (i > 1 ? "/" : "") out[i]
      return o
    }
    function fix(t,   path, frag, rest, abs, kind) {
      rest = ""; if (match(t, /[ \t]/)) { rest = substr(t, RSTART); t = substr(t, 1, RSTART - 1) }
      if (t == "" || t ~ /^#/ || t ~ /^[A-Za-z][A-Za-z0-9+.-]*:/ || t ~ /^\//) return t rest
      frag = ""; path = t; if (index(t, "#")) { frag = substr(t, index(t, "#")); path = substr(t, 1, index(t, "#") - 1) }
      sub(/^\.\//, "", path)
      if (path in keep) return t rest
      abs = norm(base "/" path)
      kind = (path ~ /\/$/ || path == "" ? "tree" : "blob")
      return gh "/" kind "/main/" prefix "/" abs frag rest
    }
    /^[ \t]*(```|~~~)/ { fence = !fence; print; next }
    fence { print; next }
    {
      line = $0; out = ""
      while (match(line, /\]\([^)]*\)/)) {
        s = RSTART; l = RLENGTH                          # fix() calls match() itself
        out = out substr(line, 1, s - 1) "](" fix(substr(line, s + 2, l - 3)) ")"
        line = substr(line, s + l)
      }
      print out line
    }' "$1"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/sync-skill.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

status=0
for pair in $PAIRS; do
  rel="$(src_path "${pair%%|*}")"
  src="$ROOT/$rel"
  dst="$SKILL/${pair#*|}"
  if [ ! -f "$src" ]; then
    echo "missing canonical file: $rel" >&2
    status=1
    continue
  fi
  expected="$src"
  case "$rel" in
    *.md)
      keep_list "$(dirname "$rel")" "$(dirname "${pair#*|}")" > "$TMP/keep"
      expected="$TMP/$(basename "$rel")"
      md_transform "$src" "$(dirname "$rel")" "$TMP/keep" > "$expected"
      ;;
  esac
  if [ "$CHECK" = 1 ]; then
    if ! cmp -s "$expected" "$dst"; then
      echo "out of sync: ${dst#"$REPO"/} (run tools/sync-skill.sh)" >&2
      status=1
    fi
  else
    mkdir -p "$(dirname "$dst")"
    cp "$expected" "$dst"
    case "$dst" in *.sh) chmod +x "$dst" ;; esac
  fi
done

if [ "$CHECK" = 1 ]; then
  # Portability: Claude-Code-only substitutions. Allowed: exactly one line that mentions CLAUDE_SKILL_DIR, in SKILL.md,
  # and that line defines <skill-dir>. Not allowed: $ARGUMENTS anywhere in the skill.
  skill_dir_lines="$(grep -rn -F 'CLAUDE_SKILL_DIR' "$SKILL" || true)"
  skill_dir_count="$(printf '%s' "$skill_dir_lines" | grep -c . || true)"
  definition_ok=0
  if [ "$skill_dir_count" = 1 ]; then
    case "$skill_dir_lines" in
      "$SKILL/SKILL.md:"*'<skill-dir>'*) definition_ok=1 ;;
    esac
  fi
  if [ "$definition_ok" != 1 ]; then
    echo "not portable: CLAUDE_SKILL_DIR must appear exactly once, in the <skill-dir> definition line of SKILL.md (found $skill_dir_count line(s)); write <skill-dir>/... elsewhere:" >&2
    [ -z "$skill_dir_lines" ] || printf '%s\n' "$skill_dir_lines" | sed -e "s|^$REPO/||" -e 's/^/  /' >&2
    status=1
  fi
  # shellcheck disable=SC2016 # the literal text $ARGUMENTS is what we look for
  arguments_lines="$(grep -rn -F '$ARGUMENTS' "$SKILL" || true)"
  if [ -n "$arguments_lines" ]; then
    # shellcheck disable=SC2016 # literal text
    echo 'not portable: $ARGUMENTS placeholder found (GitHub Copilot does not substitute it; take the mode from the request):' >&2
    printf '%s\n' "$arguments_lines" | sed -e "s|^$REPO/||" -e 's/^/  /' >&2
    status=1
  fi
  if [ "$status" = 0 ]; then
    echo "skill assets are in sync; skill is portable (one <skill-dir> definition, no \$ARGUMENTS)"
  fi
fi
exit "$status"
