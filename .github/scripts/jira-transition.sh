#!/usr/bin/env bash
# After a gated regression run: report the result to each ticket the Jira gate
# found and, only if the run passed, move the ticket to the target status.
#
# - Numbers come from the Newman JSON report of this run.
# - PASSED = Newman ran assertions and nothing failed (requests, scripts,
#   assertions, run failures).
# - A ticket is moved only if it is still in EXPECTED_STATUS; the transition is
#   looked up by target status name, not by a fixed id.
# - On FAILED the status is left as is; the comment says what failed.
# - Exits 1 if a transition or comment fails.
#
# Env: JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN, TICKET_KEYS (JSON array),
#      NEWMAN_REPORT (path), TARGET_STATUS, EXPECTED_STATUS, RUN_URL,
#      optional REPORT_URL, GIT_REF, GIT_SHA.
set -euo pipefail
# shellcheck source=jira-lib.sh
source "$(dirname "$0")/jira-lib.sh"

TITLE="Jira status update"
TARGET_STATUS="${TARGET_STATUS:-Done}"
EXPECTED_STATUS="${EXPECTED_STATUS:-Ready for QA}"
: "${RUN_URL:?RUN_URL is not set}"
REPORT_URL="${REPORT_URL:-}"
GIT_REF="${GIT_REF:-unknown}"
GIT_SHA="${GIT_SHA:-unknown}"

[ -n "${TICKET_KEYS:-}" ] || fail "TICKET_KEYS is empty: the Jira gate passed no tickets." "$TITLE"
jq -e 'type == "array"' <<<"$TICKET_KEYS" >/dev/null 2>&1 || fail "TICKET_KEYS is not a JSON array: $TICKET_KEYS" "$TITLE"
[ -f "${NEWMAN_REPORT:-}" ] || fail "Newman JSON report not found at '${NEWMAN_REPORT:-}'." "$TITLE"

# --- Run result from the Newman report ---------------------------------------
stats="$(jq -c '{
  requests:    .run.stats.requests,
  testScripts: .run.stats.testScripts,
  assertions:  .run.stats.assertions,
  prerequestScripts: .run.stats.prerequestScripts,
  failures:    (.run.failures | length),
  started:     .run.timings.started
}' "$NEWMAN_REPORT")" || fail "Cannot read stats from the Newman report." "$TITLE"

passed="$(jq -r '
  (.assertions.total > 0)
  and .assertions.failed == 0 and .requests.failed == 0
  and .testScripts.failed == 0 and ((.prerequestScripts.failed // 0) == 0)
  and .failures == 0' <<<"$stats")"
if [ "$passed" = "true" ]; then result="PASSED"; else result="FAILED"; fi
started_utc="$(jq -r '(.started / 1000 | floor | strftime("%Y-%m-%d %H:%M UTC"))' <<<"$stats")"
echo "Run result: $result $(jq -c '{requests, testScripts, assertions, failures}' <<<"$stats")"

require_jira_config "$TITLE"
verify_jira_login "$TITLE"

# --- Comment body (Atlassian Document Format) ---------------------------------
# adf_comment STATUS_LINE -> JSON body for POST /issue/{key}/comment
adf_comment() {
  jq -nc \
    --arg result "$result" --arg ref "$GIT_REF" --arg sha "${GIT_SHA:0:7}" \
    --arg started "$started_utc" --arg run "$RUN_URL" --arg report "$REPORT_URL" \
    --arg statusLine "$1" --argjson s "$stats" '
    def t($x): {type: "text", text: ($x | tostring)};
    def strong($x): {type: "text", text: $x, marks: [{type: "strong"}]};
    def link($label; $url): {type: "text", text: $url, marks: [{type: "link", attrs: {href: $url}}]};
    def p($c): {type: "paragraph", content: $c};
    # ADF does not allow empty text nodes, so an empty cell gets an empty paragraph.
    def cell($kind; $x): {type: $kind, content: [(if ($x | tostring) == "" then {type: "paragraph"} else p([t($x)]) end)]};
    def row($kind; $a; $b; $c): {type: "tableRow", content: [cell($kind; $a), cell($kind; $b), cell($kind; $c)]};
    def li($c): {type: "listItem", content: [p($c)]};
    {body: {type: "doc", version: 1, content: [
      p([strong("API regression run (Newman): " + $result + (if $result == "PASSED" then " ✅" else " ❌" end))]),
      p([t("Petstore v3 pet CRUD regression (Create → Get → Update → Get → Delete → Verify deletion), GitHub Actions run on " + $ref + ", commit " + $sha + ", " + $started + ".")]),
      {type: "table", attrs: {isNumberColumnEnabled: false, layout: "default"}, content: [
        row("tableHeader"; ""; "executed"; "failed"),
        row("tableCell"; "requests"; $s.requests.total; $s.requests.failed),
        row("tableCell"; "test-scripts"; $s.testScripts.total; $s.testScripts.failed),
        row("tableCell"; "assertions"; $s.assertions.total; $s.assertions.failed)
      ]},
      p([{type: "text", text: "Numbers are taken from the Newman JSON report of this run.", marks: [{type: "em"}]}]),
      {type: "bulletList", content: (
        [li([t("Run: "), link("Run"; $run)])]
        + (if $report != "" then [li([t("HTML report: "), link("HTML report"; $report)])] else [] end)
      )},
      p([strong($statusLine)])
    ]}}'
}

# --- Process each ticket ----------------------------------------------------
errors=0
rows=()
for key in $(jq -r '.[]' <<<"$TICKET_KEYS"); do
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*-[0-9]+$ ]] || { echo "::warning::Skipping invalid key '$key'"; continue; }
  link="[$key]($JIRA_BASE_URL/browse/$key)"

  code="$(jira GET "/rest/api/3/issue/$key?fields=status")"
  if [ "$code" != "200" ]; then
    echo "::error title=$TITLE::$key: cannot read status (HTTP $code). $(jira_error)"
    rows+=("| $link | $result | ❌ cannot read status (HTTP $code) |"); errors=$((errors + 1)); continue
  fi
  current="$(jq -r '.fields.status.name // ""' "$JIRA_TMP/body")"

  if [ "$result" != "PASSED" ]; then
    status_line="Status not changed: the run failed, ticket stays in $current."
    action="status kept ($current)"
  elif [ "$(lower "$current")" != "$(lower "$EXPECTED_STATUS")" ]; then
    status_line="Status not changed: ticket is in $current, not $EXPECTED_STATUS."
    action="⏭️ skipped: now in $current"
  else
    code="$(jira GET "/rest/api/3/issue/$key/transitions")"
    tid=""
    if [ "$code" = "200" ]; then
      tid="$(jq -r --arg t "$(lower "$TARGET_STATUS")" \
        '[.transitions[] | select((.to.name | ascii_downcase) == $t and (.isAvailable // true))][0].id // empty' \
        "$JIRA_TMP/body")"
    fi
    if [ -z "$tid" ]; then
      echo "::error title=$TITLE::$key: no available transition to '$TARGET_STATUS' (HTTP $code). $(jira_error)"
      status_line="Status not changed: no available transition to $TARGET_STATUS."
      action="❌ no transition to $TARGET_STATUS"; errors=$((errors + 1))
    else
      code="$(jira POST "/rest/api/3/issue/$key/transitions" "$(jq -nc --arg id "$tid" '{transition: {id: $id}}')")"
      if [ "$code" = "204" ]; then
        status_line="Status changed: $current → $TARGET_STATUS."
        action="✅ $current → $TARGET_STATUS"
      else
        echo "::error title=$TITLE::$key: transition to '$TARGET_STATUS' failed (HTTP $code). $(jira_error)"
        status_line="Status not changed: transition to $TARGET_STATUS failed (HTTP $code)."
        action="❌ transition failed (HTTP $code)"; errors=$((errors + 1))
      fi
    fi
  fi

  code="$(jira POST "/rest/api/3/issue/$key/comment" "$(adf_comment "$status_line")")"
  if [ "$code" != "201" ]; then
    echo "::error title=$TITLE::$key: adding the comment failed (HTTP $code). $(jira_error)"
    action="$action; ❌ comment failed (HTTP $code)"; errors=$((errors + 1))
  else
    action="$action; 💬 comment added"
  fi
  rows+=("| $link | $result | $action |")
  echo "$key: $action"
done

{
  echo "### Jira status update"
  echo
  echo "- Run result: **$result** (assertions $(jq -r '"\(.assertions.total) executed, \(.assertions.failed) failed"' <<<"$stats"))"
  echo "- Rule: on PASSED move **$EXPECTED_STATUS → $TARGET_STATUS**; on FAILED keep the status"
  echo
  echo "| Ticket | Run | Action |"
  echo "|---|---|---|"
  if [ "${#rows[@]}" -gt 0 ]; then printf '%s\n' "${rows[@]}"; fi
} >> "$SUMMARY"

[ "$errors" -eq 0 ] || fail "$errors Jira update(s) failed; see the table above." "$TITLE"
