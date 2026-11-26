#!/usr/bin/env bash
# fm-forge-state.sh - read the current forge state of pull requests and issues.
#
# A summary that says "checks passed" or "merged" is history once it is
# recorded, so a presenter that repeats it puts this read beside it. This is
# a one-shot, read-only command: it never posts, approves, or merges.
#
# Usage: fm-forge-state.sh <url>...
#   Prints one "<url>: <state>" line per URL, in argument order:
#     GitHub pull request: "open|closed|merged[ at <mergedAt>]; checks: <n> passed,
#       <n> failing, <n> pending" (or "checks: none reported").
#     GitHub issue: "open" or "closed at <closedAt>".
#   A read that fails or exceeds its 10-second bound prints
#   "unknown (the forge read failed)", and a URL of any other forge prints
#   "unknown (no live read for this forge)", so a missing read is never shown
#   as an unchanged state. Exits 0 once every URL has its line.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'; exit 0 ;;
esac

# shellcheck disable=SC2016 # jq programs, not shell expansions
PR_STATE='[.statusCheckRollup[]? | (.conclusion // .state // "" | ascii_upcase)] as $c
  | "\(.state | ascii_downcase)\(if .mergedAt then " at \(.mergedAt)" else "" end); checks: "
    + (if ($c | length) == 0 then "none reported" else
        "\($c | map(select(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")) | length) passed, \($c | map(select(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")) | length) failing, \($c | map(select(. == "" or . == "PENDING" or . == "QUEUED" or . == "IN_PROGRESS" or . == "WAITING" or . == "REQUESTED" or . == "EXPECTED")) | length) pending" end)'
# shellcheck disable=SC2016
ISSUE_STATE='"\(.state | ascii_downcase)\(if .closedAt then " at \(.closedAt)" else "" end)"'

for url in "$@"; do
  case "$url" in
    https://*/pull/[0-9]*) kind=pr fields=state,mergedAt,statusCheckRollup program=$PR_STATE ;;
    https://*/issues/[0-9]*) kind=issue fields=state,closedAt program=$ISSUE_STATE ;;
    *) printf '%s: unknown (no live read for this forge)\n' "$url"; continue ;;
  esac
  if json=$(fm_run_timed 10 gh "$kind" view "$url" --json "$fields" 2>/dev/null </dev/null) \
    && state=$(printf '%s' "$json" | jq -r "$program" 2>/dev/null) && [ -n "$state" ]; then
    printf '%s: %s\n' "$url" "$state"
  else
    printf '%s: unknown (the forge read failed)\n' "$url"
  fi
done
