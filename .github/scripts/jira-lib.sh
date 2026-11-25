# Shared helpers for the Jira scripts. Source it, do not run it.
# Needs: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN. Uses curl and jq.

SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
JIRA_TMP="$(mktemp -d)"
trap 'rm -rf "$JIRA_TMP"' EXIT

# fail MESSAGE [TITLE]: annotate, add to the run summary and exit 1.
fail() {
  local title="${2:-Jira}"
  echo "::error title=$title::$1"
  { echo "### ❌ $title failed"; echo; echo "$1"; } >> "$SUMMARY"
  exit 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# require_jira_config TITLE: fail when the base URL or a secret is missing.
require_jira_config() {
  [ -n "${JIRA_BASE_URL:-}" ] || fail "JIRA_BASE_URL is not set." "$1"
  [ -n "${JIRA_EMAIL:-}" ] || fail "Secret JIRA_EMAIL is missing or empty. Add it in Settings → Secrets and variables → Actions." "$1"
  [ -n "${JIRA_API_TOKEN:-}" ] || fail "Secret JIRA_API_TOKEN is missing or empty. Add it in Settings → Secrets and variables → Actions." "$1"
  JIRA_BASE_URL="${JIRA_BASE_URL%/}"
}

# jira METHOD PATH [JSON_BODY]: prints the HTTP status; the body goes to $JIRA_TMP/body.
jira() {
  local args=(-sS -o "$JIRA_TMP/body" -w '%{http_code}' --max-time 30
    -X "$1" -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H 'Accept: application/json')
  if [ -n "${3:-}" ]; then
    args+=(-H 'Content-Type: application/json' --data "$3")
  fi
  curl "${args[@]}" "$JIRA_BASE_URL$2" || true
}

# jira_error: a short error text from the last response body.
jira_error() {
  jq -r '[(.errorMessages // [])[], ((.errors // {}) | to_entries[] | "\(.key): \(.value)")] | join("; ")' \
    "$JIRA_TMP/body" 2>/dev/null || true
}

# verify_jira_login TITLE: fail unless GET /myself proves a real, active user login.
# Jira Cloud answers many requests anonymously, so a 200 elsewhere proves nothing.
# Sets JIRA_USER_NAME and JIRA_ACCOUNT_ID.
verify_jira_login() {
  local title="$1" code account_type active email
  code="$(jira GET /rest/api/3/myself)"
  if [ "$code" != "200" ]; then
    fail "Jira login check failed: GET /rest/api/3/myself returned HTTP $code. JIRA_EMAIL must be the Atlassian account email that owns JIRA_API_TOKEN, and the token must be a valid (unscoped) API token." "$title"
  fi
  JIRA_ACCOUNT_ID="$(jq -r '.accountId // empty' "$JIRA_TMP/body" 2>/dev/null || true)"
  account_type="$(jq -r '.accountType // empty' "$JIRA_TMP/body" 2>/dev/null || true)"
  active="$(jq -r '.active // false' "$JIRA_TMP/body" 2>/dev/null || true)"
  email="$(jq -r '.emailAddress // empty' "$JIRA_TMP/body" 2>/dev/null || true)"
  JIRA_USER_NAME="$(jq -r '.displayName // "unknown"' "$JIRA_TMP/body" 2>/dev/null || true)"

  [ -n "$JIRA_ACCOUNT_ID" ] || fail "Jira login check failed: /rest/api/3/myself returned no accountId, so the request was anonymous. Check JIRA_EMAIL and JIRA_API_TOKEN." "$title"
  [ "$account_type" = "atlassian" ] || fail "Jira login check failed: accountType is '${account_type:-none}', expected a real user account ('atlassian')." "$title"
  [ "$active" = "true" ] || fail "Jira login check failed: the Jira account is not active." "$title"
  if [ -n "$email" ] && [ "$(lower "$email")" != "$(lower "$JIRA_EMAIL")" ]; then
    fail "Jira login check failed: logged in as a different account than JIRA_EMAIL." "$title"
  fi
  echo "Authenticated in Jira as $JIRA_USER_NAME ($JIRA_ACCOUNT_ID)."
}
