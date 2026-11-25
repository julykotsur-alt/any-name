#!/usr/bin/env bash
# Jira gate for the scheduled regression run.
#
# 1. Fails if JIRA_EMAIL / JIRA_API_TOKEN are missing.
# 2. Verifies a real login via GET /rest/api/3/myself. Jira Cloud answers
#    searches anonymously (HTTP 200, 0 issues), so a search alone cannot
#    tell "no tickets" from "not logged in".
# 3. Searches tickets via POST /rest/api/3/search/jql and writes them, with
#    links, to the run summary.
# 4. Sets the outputs ticket_count and run_regression (true when count > 0).
#
# Env: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN, optional JIRA_JQL.
set -euo pipefail

JQL="${JIRA_JQL:-labels = \"api-regression\" AND status = \"Ready for QA\" ORDER BY key ASC}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
OUTPUT="${GITHUB_OUTPUT:-/dev/null}"

fail() {
  echo "::error title=Jira gate::$1"
  { echo "### ❌ Jira gate failed"; echo; echo "$1"; } >> "$SUMMARY"
  exit 1
}

[ -n "${JIRA_BASE_URL:-}" ] || fail "JIRA_BASE_URL is not set."
[ -n "${JIRA_EMAIL:-}" ] || fail "Secret JIRA_EMAIL is missing or empty. Add it in Settings → Secrets and variables → Actions."
[ -n "${JIRA_API_TOKEN:-}" ] || fail "Secret JIRA_API_TOKEN is missing or empty. Add it in Settings → Secrets and variables → Actions."
BASE="${JIRA_BASE_URL%/}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# jira METHOD PATH [JSON_BODY] -> prints the HTTP status, body goes to $tmp/body
jira() {
  local args=(-sS -o "$tmp/body" -w '%{http_code}' --max-time 30
    -X "$1" -u "$JIRA_EMAIL:$JIRA_API_TOKEN" -H 'Accept: application/json')
  if [ -n "${3:-}" ]; then
    args+=(-H 'Content-Type: application/json' --data "$3")
  fi
  curl "${args[@]}" "$BASE$2" || true
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- 1. Real login check -----------------------------------------------------
code="$(jira GET /rest/api/3/myself)"
if [ "$code" != "200" ]; then
  fail "Jira login check failed: GET /rest/api/3/myself returned HTTP $code. JIRA_EMAIL must be the Atlassian account email that owns JIRA_API_TOKEN, and the token must be a valid (unscoped) API token."
fi
account_id="$(jq -r '.accountId // empty' "$tmp/body" 2>/dev/null || true)"
account_type="$(jq -r '.accountType // empty' "$tmp/body" 2>/dev/null || true)"
active="$(jq -r '.active // false' "$tmp/body" 2>/dev/null || true)"
email="$(jq -r '.emailAddress // empty' "$tmp/body" 2>/dev/null || true)"
name="$(jq -r '.displayName // "unknown"' "$tmp/body" 2>/dev/null || true)"

[ -n "$account_id" ] || fail "Jira login check failed: /rest/api/3/myself returned no accountId, so the request was anonymous. Check JIRA_EMAIL and JIRA_API_TOKEN."
[ "$account_type" = "atlassian" ] || fail "Jira login check failed: accountType is '${account_type:-none}', expected a real user account ('atlassian')."
[ "$active" = "true" ] || fail "Jira login check failed: the Jira account is not active."
if [ -n "$email" ] && [ "$(lower "$email")" != "$(lower "$JIRA_EMAIL")" ]; then
  fail "Jira login check failed: logged in as a different account than JIRA_EMAIL."
fi
echo "Authenticated in Jira as $name ($account_id)."

# --- 2. Search tickets (all pages) ---------------------------------------------
issues='[]'
page_token=''
while :; do
  body="$(jq -nc --arg jql "$JQL" --arg t "$page_token" \
    '{jql: $jql, fields: ["summary", "status"], maxResults: 100}
     + (if $t == "" then {} else {nextPageToken: $t} end)')"
  code="$(jira POST /rest/api/3/search/jql "$body")"
  if [ "$code" != "200" ]; then
    msg="$(jq -r '[(.errorMessages // [])[], ((.errors // {}) | to_entries[] | "\(.key): \(.value)")] | join("; ")' "$tmp/body" 2>/dev/null || true)"
    fail "Jira search failed: POST /rest/api/3/search/jql returned HTTP $code. ${msg}"
  fi
  issues="$(jq -c --argjson acc "$issues" '$acc + (.issues // [])' "$tmp/body")"
  page_token="$(jq -r '.nextPageToken // empty' "$tmp/body")"
  [ -n "$page_token" ] || break
done
count="$(jq 'length' <<<"$issues")"

# --- 3. Run summary and outputs ---------------------------------------------
{
  echo "### Jira gate"
  echo
  echo "- Logged in as: **$name**"
  echo "- JQL: \`$JQL\`"
  echo "- Tickets found: **$count**"
  echo
  if [ "$count" -gt 0 ]; then
    echo "| Ticket | Summary | Status |"
    echo "|---|---|---|"
    jq -r --arg base "$BASE" '.[] |
      "| [\(.key)](\($base)/browse/\(.key)) | \((.fields.summary // "") | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|")) | \(.fields.status.name // "") |"' \
      <<<"$issues"
    echo
    echo "➡️ Regression will run."
  else
    echo "⏭️ No matching tickets: regression is skipped for this run."
  fi
} >> "$SUMMARY"

echo "ticket_count=$count" >> "$OUTPUT"
if [ "$count" -gt 0 ]; then
  echo "run_regression=true" >> "$OUTPUT"
else
  echo "run_regression=false" >> "$OUTPUT"
fi
echo "Found $count ticket(s)."
