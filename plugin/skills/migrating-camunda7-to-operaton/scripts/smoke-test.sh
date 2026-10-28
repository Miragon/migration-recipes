#!/usr/bin/env bash
# =====================================================================================================
# Camunda 7 -> Operaton Migration Starter Pack
# scripts/smoke-test.sh  -  REST + webapp smoke test against a running engine (Camunda 7 or Operaton)
# =====================================================================================================
#
# Read-only by default:
#   - GET <rest>/version            prints the product version; warns if it is not Operaton (7.x = Camunda 7)
#   - GET <rest>/engine             the engine exists
#   - GET <rest>/process-definition/count, /deployment/count (+ latest deployment)
#                                   0 definitions after a cut-over usually means "wrong/empty schema"
#   - GET <rest>/incident/count, /job/count?noRetriesLeft=true, /external-task/count?noRetriesLeft=true
#   - GET <webapp>/app/welcome/<engine>/           webapps reachable at the expected path
#   - GET <webapp>/app/admin/<engine>/setup/ and /app/admin/<engine>/ WITHOUT following redirects:
#       the "create initial admin user" setup page must be CLOSED. Operaton serves it (HTTP 200, or redirects
#       the admin app to .../setup/) while nobody is a member of `operaton-admin` (ProcessEnginesFilter /
#       SetupResource). Detection is non-destructive: this script never POSTs to the setup endpoint.
#   - GET <base>/actuator/health    (optional, SKIP if not exposed)
# --write additionally:
#   deploys a tiny BPMN (camunda: namespace, start -> user task -> expression service task -> end), starts an
#   instance, completes the task, checks runtime + history, then deletes the deployment with cascade=true.
#
# Usage:
#   scripts/smoke-test.sh --base-url http://localhost:8080 [--rest-path /engine-rest] [--webapp-path /camunda]
#                         [--engine default] [--user demo --password demo] [--write] [--require-operaton]
#   Options:
#     --base-url URL         scheme://host:port[/context] (or env SMOKE_BASE_URL)            required
#     --rest-path PATH       REST API path                                       default: /engine-rest
#     --webapp-path PATH     webapp application path; "auto" probes /operaton then /camunda   default: auto
#     --no-webapp            skip the webapp checks (REST-only application)
#     --engine NAME          process engine name                                 default: default
#     --user U --password P  HTTP basic auth for REST/actuator (or env SMOKE_USER / SMOKE_PASSWORD)
#     --header 'K: V'        extra header for REST/actuator calls, repeatable (e.g. 'Authorization: Bearer …')
#     --health-path PATH     actuator health path; "none" to skip                default: /actuator/health
#     --write                run the deploy/start/complete/history/delete round trip
#     --require-operaton     FAIL (instead of WARN) if the engine is not Operaton
#     --insecure             curl -k (self-signed TLS)
#     --timeout SECONDS      per request                                         default: 15
#     -h, --help
#   Exit codes: 0 = no FAIL, 1 = at least one FAIL, 2 = usage error / missing curl.
#
# Requirements: bash 3.2+ (macOS default works), curl. jq is used when installed; without jq the script
# falls back to grep/sed for the few JSON fields it needs.
#
# Docs: docs/11-cutover-rollback-and-operations.md (smoke tests in the cut-over runbook),
#       docs/07-identity-admin-group-and-security.md (setup page), checklists/cutover-runbook.md
# License: Apache-2.0. As of 2026-10-06 (Camunda 7.24.0 -> Operaton 2.1.5 / 2.2.x).
# =====================================================================================================

set -o pipefail

# Layout: starter-pack repository (docs/, sql/ next to scripts/) or the bundled Claude skill (assets/ next to
# scripts/, no docs/) -> hints point to assets/sql/ and to the guide on GitHub.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
GUIDE_URL="https://github.com/Miragon/migration-recipies/blob/main/services/c7/operaton"
if [ -d "$SCRIPT_DIR/../assets" ] && [ ! -d "$SCRIPT_DIR/../docs" ]; then
  DOCS="$GUIDE_URL/docs"; SQL_DIR="assets/sql/postgresql"
else
  DOCS="docs"; SQL_DIR="sql/postgresql"
fi

BASE_URL="${SMOKE_BASE_URL:-}"
REST_PATH="/engine-rest"
WEBAPP_PATH="auto"
ENGINE="default"
USER_NAME="${SMOKE_USER:-}"
USER_PASSWORD="${SMOKE_PASSWORD:-}"
HEALTH_PATH="/actuator/health"
WRITE=0
REQUIRE_OPERATON=0
INSECURE=0
TIMEOUT=15
NO_WEBAPP=0
EXTRA_HEADERS=()

usage() { sed -n '/^# Usage:/,/^#   Exit codes/p' "$0" | sed 's/^# \{0,1\}//'; }
# options that take a value: fail instead of looping forever when the value is missing
need_value() { if [ $# -lt 2 ]; then echo "option $1 needs a value" >&2; usage >&2; exit 2; fi; }

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)         need_value "$@"; BASE_URL="$2"; shift 2 ;;
    --rest-path)        need_value "$@"; REST_PATH="$2"; shift 2 ;;
    --webapp-path)      need_value "$@"; WEBAPP_PATH="$2"; shift 2 ;;
    --no-webapp)        NO_WEBAPP=1; shift ;;
    --engine)           need_value "$@"; ENGINE="$2"; shift 2 ;;
    --user)             need_value "$@"; USER_NAME="$2"; shift 2 ;;
    --password)         need_value "$@"; USER_PASSWORD="$2"; shift 2 ;;
    --header)           need_value "$@"; EXTRA_HEADERS+=("$2"); shift 2 ;;
    --health-path)      need_value "$@"; HEALTH_PATH="$2"; shift 2 ;;
    --write)            WRITE=1; shift ;;
    --require-operaton) REQUIRE_OPERATON=1; shift ;;
    --insecure)         INSECURE=1; shift ;;
    --timeout)          need_value "$@"; TIMEOUT="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) echo "--timeout must be a number of seconds" >&2; exit 2 ;; esac

if [ -z "$BASE_URL" ]; then echo "--base-url is required" >&2; usage >&2; exit 2; fi
if ! command -v curl >/dev/null 2>&1; then echo "curl is required" >&2; exit 2; fi
BASE_URL="${BASE_URL%/}"
REST_URL="$BASE_URL/${REST_PATH#/}"
REST_URL="${REST_URL%/}"
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && [ -z "${SMOKE_NO_JQ:-}" ] && HAVE_JQ=1   # SMOKE_NO_JQ=1 forces the grep/sed fallback

# ------------------------------------------------------------------------------------------- output helpers
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_PASS=""; C_WARN=""; C_FAIL=""; C_DIM=""; C_OFF=""
fi
R_NAME=(); R_STATUS=(); R_DETAIL=()
FAILS=0; WARNS=0

record() { # status name detail
  R_STATUS+=("$1"); R_NAME+=("$2"); R_DETAIL+=("$3")
  case "$1" in FAIL) FAILS=$((FAILS + 1)); c="$C_FAIL" ;; WARN) WARNS=$((WARNS + 1)); c="$C_WARN" ;; PASS) c="$C_PASS" ;; *) c="$C_DIM" ;; esac
  printf '%s%-4s%s %-34s %s\n' "$c" "$1" "$C_OFF" "$2" "$3"
}

# ------------------------------------------------------------------------------------------- HTTP helpers
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t smoketest)"
# shellcheck disable=SC2329  # invoked via trap
cleanup_tmp() { rm -rf "$TMP_DIR"; }
trap cleanup_tmp EXIT

HTTP_STATUS=""; HTTP_BODY=""; HTTP_LOCATION=""
# http <auth|noauth> <METHOD> <URL> [curl args...]   - never follows redirects
http() {
  local auth="$1" method="$2" url="$3"; shift 3
  local args=(-sS -X "$method" --max-time "$TIMEOUT" -o "$TMP_DIR/body" -w '%{http_code}\n%{redirect_url}')
  [ "$INSECURE" = 1 ] && args+=(-k)
  if [ "$auth" = auth ]; then
    [ -n "$USER_NAME" ] && args+=(-u "$USER_NAME:$USER_PASSWORD")
    local h
    for h in ${EXTRA_HEADERS[@]+"${EXTRA_HEADERS[@]}"}; do args+=(-H "$h"); done
  fi
  local out
  out="$(curl "${args[@]}" "$@" "$url" 2>"$TMP_DIR/err")"
  HTTP_STATUS="$(printf '%s\n' "$out" | sed -n 1p)"
  HTTP_LOCATION="$(printf '%s\n' "$out" | sed -n 2p)"
  HTTP_BODY="$(cat "$TMP_DIR/body" 2>/dev/null)"
  if [ -z "$HTTP_STATUS" ] || [ "$HTTP_STATUS" = "000" ]; then
    HTTP_STATUS="000"
    HTTP_BODY="$(tr '\n' ' ' < "$TMP_DIR/err")"
  fi
}

# json_str <json> <key>: first string (or scalar) value of <key>, document order
json_str() {
  if [ "$HAVE_JQ" = 1 ]; then
    printf '%s' "$1" | jq -r --arg k "$2" 'first(.. | objects | select(has($k)) | .[$k]) // empty | tostring' 2>/dev/null
  else
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -n 1 | sed 's/^.*:[[:space:]]*"\(.*\)"$/\1/'
  fi
}
# json_num <json> <key>: first numeric/boolean/null value of <key>
json_num() {
  if [ "$HAVE_JQ" = 1 ]; then
    printf '%s' "$1" | jq -r --arg k "$2" 'first(.. | objects | select(has($k)) | .[$k]) | tostring' 2>/dev/null
  else
    printf '%s' "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[-0-9a-z.]*" | head -n 1 | sed 's/^.*:[[:space:]]*//'
  fi
}
short() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-140; }

auth_hint() {
  case "$HTTP_STATUS" in
    401) printf 'HTTP 401: REST requires authentication, pass --user/--password or --header' ;;
    403) printf 'HTTP 403: user lacks permissions' ;;
    000) printf 'no connection: %s' "$(short "$HTTP_BODY")" ;;
    *)   printf 'HTTP %s: %s' "$HTTP_STATUS" "$(short "$HTTP_BODY")" ;;
  esac
}

# ------------------------------------------------------------------------------------------- read-only checks
echo "Smoke test against $BASE_URL (REST $REST_URL, engine '$ENGINE')$([ "$HAVE_JQ" = 0 ] && echo ', no jq: basic JSON parsing')"
echo

PRODUCT="unknown"
REST_OK=0
http auth GET "$REST_URL/version"
if [ "$HTTP_STATUS" = 200 ]; then
  REST_OK=1
  VERSION="$(json_str "$HTTP_BODY" version)"
  case "$VERSION" in
    7.*)   PRODUCT="camunda"
           if [ "$REQUIRE_OPERATON" = 1 ]; then record FAIL "REST /version" "Camunda $VERSION, not Operaton"
           else record WARN "REST /version" "Camunda $VERSION (not Operaton yet)"; fi ;;
    [1-9].*|[1-9][0-9].*)
           PRODUCT="operaton"; record PASS "REST /version" "Operaton $VERSION" ;;
    *)     if [ "$REQUIRE_OPERATON" = 1 ]; then record FAIL "REST /version" "unknown version '$VERSION'"
           else record WARN "REST /version" "unknown version '$VERSION'"; fi ;;
  esac
else
  record FAIL "REST /version" "$(auth_hint)"
fi

if [ "$REST_OK" = 1 ]; then
  http auth GET "$REST_URL/engine"
  if [ "$HTTP_STATUS" = 200 ] && printf '%s' "$HTTP_BODY" | grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$ENGINE\""; then
    record PASS "REST /engine" "engine '$ENGINE' found"
  elif [ "$HTTP_STATUS" = 200 ]; then
    record FAIL "REST /engine" "engine '$ENGINE' not in $(short "$HTTP_BODY")"
  else
    record FAIL "REST /engine" "$(auth_hint)"
  fi

  count_check() { # name path warn_if_zero(0|1) info_label
    http auth GET "$REST_URL$2"
    if [ "$HTTP_STATUS" = 200 ]; then
      local n; n="$(json_num "$HTTP_BODY" count)"
      if [ "$3" = 1 ] && [ "$n" = 0 ]; then
        record WARN "$1" "0 - wrong or empty schema? (check schema-name/table-prefix, schema-update)"
      else
        record INFO "$1" "$n${4:+ $4}"
      fi
    else
      record FAIL "$1" "$(auth_hint)"
    fi
  }
  count_check "process definitions" "/process-definition/count" 1
  count_check "deployments" "/deployment/count" 1

  http auth GET "$REST_URL/deployment?sortBy=deploymentTime&sortOrder=desc&maxResults=1"
  if [ "$HTTP_STATUS" = 200 ]; then
    record INFO "latest deployment" "$(json_str "$HTTP_BODY" name) at $(json_str "$HTTP_BODY" deploymentTime) (source: $(json_str "$HTTP_BODY" source))"
  fi
  count_check "open incidents" "/incident/count" 0 "(compare with the pre-flight baseline)"
  count_check "jobs without retries" "/job/count?noRetriesLeft=true" 0
  count_check "external tasks without retries" "/external-task/count?noRetriesLeft=true" 0
else
  record SKIP "other REST checks" "REST API not usable, see REST /version (wrong --rest-path, credentials, or app down?)"
fi

# ------------------------------------------------------------------------------------------- webapps
if [ "$NO_WEBAPP" = 1 ]; then
  record SKIP "webapps" "--no-webapp"
else
  if [ "$WEBAPP_PATH" = auto ]; then
    WEBAPP_PATH=""
    for candidate in /operaton /camunda; do
      http noauth GET "$BASE_URL$candidate/app/welcome/$ENGINE/"
      if [ "$HTTP_STATUS" = 200 ] || [ "$HTTP_STATUS" = 302 ]; then WEBAPP_PATH="$candidate"; break; fi
    done
  fi
  if [ -z "$WEBAPP_PATH" ]; then
    record FAIL "webapp path" "neither /operaton nor /camunda answers; pass --webapp-path or --no-webapp"
  else
    WEBAPP_URL="$BASE_URL/${WEBAPP_PATH#/}"
    http noauth GET "$WEBAPP_URL/app/welcome/$ENGINE/"
    if [ "$HTTP_STATUS" = 200 ]; then
      TITLE="$(printf '%s' "$HTTP_BODY" | tr '\n' ' ' | sed -n 's/.*<title>\([^<]*\)<\/title>.*/\1/p')"
      record PASS "webapp welcome" "$WEBAPP_PATH/app/welcome/$ENGINE/ (title: ${TITLE:-?})"
    elif [ "$HTTP_STATUS" = 302 ] && printf '%s' "$HTTP_LOCATION" | grep -q '/setup/'; then
      record FAIL "webapp welcome" "redirects to the setup page: $HTTP_LOCATION"
    else
      record FAIL "webapp welcome" "$WEBAPP_PATH/app/welcome/$ENGINE/ -> HTTP $HTTP_STATUS $HTTP_LOCATION (Operaton default path: /operaton, see operaton.bpm.webapp.application-path, D6)"
    fi
    WELCOME_STATUS="$HTTP_STATUS"

    ADMIN_GROUP="operaton-admin"; [ "$PRODUCT" = camunda ] && ADMIN_GROUP="camunda-admin"
    if [ "$WELCOME_STATUS" = 404 ] || [ "$WELCOME_STATUS" = 000 ]; then
      record SKIP "admin setup page" "webapp not reachable at $WEBAPP_PATH"
    else
      # 1) the setup page itself: served (200) only while the setup is open, otherwise redirect to the admin app
      http noauth GET "$WEBAPP_URL/app/admin/$ENGINE/setup/"
      SETUP_STATUS="$HTTP_STATUS"; SETUP_LOCATION="$HTTP_LOCATION"
      # 2) the admin app: redirects to .../setup/#/setup while the setup is open
      http noauth GET "$WEBAPP_URL/app/admin/$ENGINE/"
      ADMIN_STATUS="$HTTP_STATUS"; ADMIN_LOCATION="$HTTP_LOCATION"
      if [ "$SETUP_STATUS" = 200 ] || { [ "$ADMIN_STATUS" = 302 ] && printf '%s' "$ADMIN_LOCATION" | grep -q '/setup/'; }; then
        if [ "$PRODUCT" = camunda ]; then FIX="add an admin user to camunda-admin"
        else FIX="run $SQL_DIR/10-migrate-admin-group.sql or AdminGroupMigrationPlugin ($DOCS/07-identity-admin-group-and-security.md)"; fi
        record FAIL "admin setup page" "OPEN: nobody is in '$ADMIN_GROUP', anyone can create an admin - $FIX"
      elif [ "$SETUP_STATUS" = 302 ] && ! printf '%s' "$SETUP_LOCATION" | grep -q '/setup/' && [ "$ADMIN_STATUS" = 200 ]; then
        record PASS "admin setup page" "closed (setup/ redirects to the admin app; '$ADMIN_GROUP' has members)"
      else
        record WARN "admin setup page" "undetermined (setup/ -> $SETUP_STATUS $SETUP_LOCATION; admin/ -> $ADMIN_STATUS $ADMIN_LOCATION; SSO in front?)"
      fi
    fi
  fi
fi

# ------------------------------------------------------------------------------------------- actuator health
if [ "$HEALTH_PATH" != none ]; then
  http auth GET "$BASE_URL/${HEALTH_PATH#/}"
  case "$HTTP_STATUS" in
    200) record PASS "health $HEALTH_PATH" "$(json_str "$HTTP_BODY" status)" ;;
    404) record SKIP "health $HEALTH_PATH" "not exposed (404)" ;;
    401|403) record SKIP "health $HEALTH_PATH" "HTTP $HTTP_STATUS (secured)" ;;
    503) record FAIL "health $HEALTH_PATH" "DOWN: $(short "$HTTP_BODY")" ;;
    000) record WARN "health $HEALTH_PATH" "no connection" ;;
    *)   record WARN "health $HEALTH_PATH" "HTTP $HTTP_STATUS" ;;
  esac
fi

# ------------------------------------------------------------------------------------------- write round trip
DEPLOYMENT_ID=""
delete_deployment() {
  [ -z "$DEPLOYMENT_ID" ] && return 0
  http auth DELETE "$REST_URL/deployment/$DEPLOYMENT_ID?cascade=true"
  if [ "$HTTP_STATUS" = 204 ]; then
    http auth GET "$REST_URL/deployment/$DEPLOYMENT_ID"
    if [ "$HTTP_STATUS" = 404 ]; then record PASS "write: delete deployment" "cascade=true, $DEPLOYMENT_ID gone"
    else record FAIL "write: delete deployment" "still there (HTTP $HTTP_STATUS)"; fi
  else
    record FAIL "write: delete deployment" "$(auth_hint) - delete $DEPLOYMENT_ID manually"
  fi
  DEPLOYMENT_ID=""
}

if [ "$WRITE" = 1 ] && [ "$REST_OK" = 0 ]; then
  record SKIP "write round trip" "REST API not usable"
elif [ "$WRITE" = 1 ]; then
  echo
  echo "--write: deploying starterpack-smoke-test (removed again with cascade=true)"
  RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
  BPMN="$TMP_DIR/starterpack-smoke-test.bpmn"
  cat > "$BPMN" <<'BPMN'
<?xml version="1.0" encoding="UTF-8"?>
<bpmn:definitions xmlns:bpmn="http://www.omg.org/spec/BPMN/20100524/MODEL"
                  xmlns:camunda="http://camunda.org/schema/1.0/bpmn"
                  id="StarterPackSmokeTest" targetNamespace="urn:starterpack:smoke-test">
  <bpmn:process id="starterpackSmokeTest" name="Starter pack smoke test" isExecutable="true" camunda:historyTimeToLive="1">
    <bpmn:startEvent id="Start" />
    <bpmn:sequenceFlow id="Flow_1" sourceRef="Start" targetRef="Task_Review" />
    <bpmn:userTask id="Task_Review" name="Smoke test review" />
    <bpmn:sequenceFlow id="Flow_2" sourceRef="Task_Review" targetRef="Task_Mark" />
    <bpmn:serviceTask id="Task_Mark" name="Mark as done" camunda:expression="${execution.setVariable('smokeServiceTaskRan', true)}" />
    <bpmn:sequenceFlow id="Flow_3" sourceRef="Task_Mark" targetRef="End" />
    <bpmn:endEvent id="End" />
  </bpmn:process>
</bpmn:definitions>
BPMN
  trap 'delete_deployment; cleanup_tmp' EXIT

  http auth POST "$REST_URL/deployment/create" \
    -F "deployment-name=starterpack-smoke-test" -F "deployment-source=starterpack-smoke-test" \
    -F "enable-duplicate-filtering=false" -F "data=@$BPMN;filename=starterpack-smoke-test.bpmn;type=application/xml"
  if [ "$HTTP_STATUS" = 200 ]; then
    DEPLOYMENT_ID="$(json_str "$HTTP_BODY" id)"
    record PASS "write: deploy (camunda: namespace)" "deployment $DEPLOYMENT_ID"
  else
    record FAIL "write: deploy (camunda: namespace)" "$(auth_hint)"
  fi

  PD_ID=""; PI_ID=""; TASK_ID=""
  if [ -n "$DEPLOYMENT_ID" ]; then
    http auth GET "$REST_URL/process-definition?deploymentId=$DEPLOYMENT_ID"
    PD_ID="$(json_str "$HTTP_BODY" id)"
    http auth POST "$REST_URL/process-definition/$PD_ID/start" -H 'Content-Type: application/json' \
      -d "{\"businessKey\":\"smoke-$RUN_ID\",\"variables\":{\"smokeRun\":{\"value\":\"$RUN_ID\",\"type\":\"String\"}}}"
    if [ "$HTTP_STATUS" = 200 ]; then
      PI_ID="$(json_str "$HTTP_BODY" id)"
      record PASS "write: start instance" "$PI_ID"
    else
      record FAIL "write: start instance" "$(auth_hint)"
    fi
  fi
  if [ -n "$PI_ID" ]; then
    http auth GET "$REST_URL/task?processInstanceId=$PI_ID"
    TASK_ID="$(json_str "$HTTP_BODY" id)"
    if [ -n "$TASK_ID" ]; then
      http auth POST "$REST_URL/task/$TASK_ID/complete" -H 'Content-Type: application/json' \
        -d '{"variables":{"approved":{"value":true,"type":"Boolean"}}}'
      if [ "$HTTP_STATUS" = 204 ] || [ "$HTTP_STATUS" = 200 ]; then record PASS "write: complete user task" "$TASK_ID"
      else record FAIL "write: complete user task" "$(auth_hint)"; fi
    else
      record FAIL "write: complete user task" "no task found for $PI_ID (authorizations?)"
    fi

    http auth GET "$REST_URL/process-instance/$PI_ID"
    if [ "$HTTP_STATUS" = 404 ]; then record PASS "write: instance ended" "no longer in runtime"
    else record FAIL "write: instance ended" "still running (HTTP $HTTP_STATUS)"; fi

    http auth GET "$REST_URL/history/process-instance/$PI_ID"
    STATE="$(json_str "$HTTP_BODY" state)"
    if [ "$HTTP_STATUS" = 200 ] && [ "$STATE" = COMPLETED ]; then record PASS "write: history" "state COMPLETED"
    elif [ "$HTTP_STATUS" = 404 ]; then record WARN "write: history" "no historic instance (history level none?)"
    else record FAIL "write: history" "state '$STATE' ($(auth_hint))"; fi

    http auth GET "$REST_URL/history/variable-instance?processInstanceId=$PI_ID&variableName=smokeServiceTaskRan"
    VALUE="$(json_num "$HTTP_BODY" value)"
    if [ "$VALUE" = true ]; then record PASS "write: service task ran" "history variable smokeServiceTaskRan = true"
    else record WARN "write: service task ran" "variable not in history (history level < audit?)"; fi
  fi
  delete_deployment
fi

# ------------------------------------------------------------------------------------------- summary
echo
printf '%-4s  %-34s  %s\n' "RES" "CHECK" "DETAIL"
printf '%-4s  %-34s  %s\n' "----" "----------------------------------" "------------------------------------------------------------"
i=0
while [ $i -lt ${#R_NAME[@]} ]; do
  printf '%-4s  %-34s  %s\n' "${R_STATUS[$i]}" "${R_NAME[$i]}" "${R_DETAIL[$i]}"
  i=$((i + 1))
done
echo
if [ "$FAILS" -gt 0 ]; then
  echo "${C_FAIL}SMOKE TEST FAILED${C_OFF}: $FAILS failure(s), $WARNS warning(s)"
  exit 1
fi
echo "${C_PASS}SMOKE TEST PASSED${C_OFF}: 0 failures, $WARNS warning(s)"
exit 0
