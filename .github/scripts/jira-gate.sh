#!/usr/bin/env bash
# Jira gate for the scheduled regression run.
#
# 1. Fails if JIRA_EMAIL / JIRA_API_TOKEN are missing.
# 2. Verifies a real login via GET /rest/api/3/myself. Jira Cloud answers
#    searches anonymously (HTTP 200, 0 issues), so a search alone cannot
#    tell "no tickets" from "not logged in".
# 3. Searches tickets via POST /rest/api/3/search/jql and writes them, with
#    links, to the run summary.
# 4. Sets the outputs ticket_count, ticket_keys (JSON array) and
#    run_regression (true when count > 0).
#
# Env: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN, optional JIRA_JQL.
set -euo pipefail
# shellcheck source=jira-lib.sh
source "$(dirname "$0")/jira-lib.sh"

TITLE="Jira gate"
JQL="${JIRA_JQL:-labels = \"api-regression\" AND status = \"Ready for QA\" ORDER BY key ASC}"

require_jira_config "$TITLE"
verify_jira_login "$TITLE"

# --- Search tickets (all pages) ----------------------------------------------
issues='[]'
page_token=''
while :; do
  body="$(jq -nc --arg jql "$JQL" --arg t "$page_token" \
    '{jql: $jql, fields: ["summary", "status"], maxResults: 100}
     + (if $t == "" then {} else {nextPageToken: $t} end)')"
  code="$(jira POST /rest/api/3/search/jql "$body")"
  if [ "$code" != "200" ]; then
    fail "Jira search failed: POST /rest/api/3/search/jql returned HTTP $code. $(jira_error)" "$TITLE"
  fi
  issues="$(jq -c --argjson acc "$issues" '$acc + (.issues // [])' "$JIRA_TMP/body")"
  page_token="$(jq -r '.nextPageToken // empty' "$JIRA_TMP/body")"
  [ -n "$page_token" ] || break
done
count="$(jq 'length' <<<"$issues")"

# --- Run summary and outputs -------------------------------------------------
{
  echo "### Jira gate"
  echo
  echo "- Logged in as: **$JIRA_USER_NAME**"
  echo "- JQL: \`$JQL\`"
  echo "- Tickets found: **$count**"
  echo
  if [ "$count" -gt 0 ]; then
    echo "| Ticket | Summary | Status |"
    echo "|---|---|---|"
    jq -r --arg base "$JIRA_BASE_URL" '.[] |
      "| [\(.key)](\($base)/browse/\(.key)) | \((.fields.summary // "") | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|")) | \(.fields.status.name // "") |"' \
      <<<"$issues"
    echo
    echo "➡️ Regression will run."
  else
    echo "⏭️ No matching tickets: regression is skipped for this run."
  fi
} >> "$SUMMARY"

{
  echo "ticket_count=$count"
  echo "ticket_keys=$(jq -c '[.[].key]' <<<"$issues")"
  if [ "$count" -gt 0 ]; then
    echo "run_regression=true"
  else
    echo "run_regression=false"
  fi
} >> "$OUTPUT"
echo "Found $count ticket(s)."
