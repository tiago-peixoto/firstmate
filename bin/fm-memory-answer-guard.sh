#!/usr/bin/env bash
# fm-memory-answer-guard.sh - Claude Stop hook that sends a primary session
# back for a live read when its reply admits answering from memory.
#
# Opt in by creating the home-local config/memory-answer-guard file. Absent
# means off. docs/configuration.md "Memory answer guard" owns that gate.
#
# The hook reads the payload's last_assistant_message, the final reply's text,
# and blocks that turn end once when the reply says it answers from memory or
# without checking, such as "from memory", "if I recall", or "not re-checked".
# A continuation stop (stop_hook_active / stopHookActive true) is never
# blocked, so the reply written after the live read always ends the turn.
#
# The hook prints one Claude block decision, or nothing. Any unreadable
# payload, missing jq, or scope miss exits 0 and prints nothing, so a Stop is
# never stuck on this hook. It is silent for a Cursor payload, for Grok, in a
# marked secondmate home, and outside a plain primary checkout, because a Stop
# block in a secondmate home would leave its parent recording idle while that
# session was still working.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh" || exit 0

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/s/^# \{0,1\}//p' "$0" | sed '$d'; exit 0 ;;
  "") ;;
  *) echo "usage: fm-memory-answer-guard.sh  (Claude Stop payload on stdin)" >&2; exit 2 ;;
esac

[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
[ ! -t 0 ] || exit 0
payload=$(cat || true)
[ -n "$payload" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$payload" || exit 0
[ -z "$(jq -r '.cursor_version // .cursorVersion // empty' <<<"$payload" 2>/dev/null)" ] || exit 0
[ "$(jq -r '(.stop_hook_active // .stopHookActive // false) | tostring' <<<"$payload" 2>/dev/null)" = false ] || exit 0

fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_root_is_secondmate_home "$FM_ROOT" && exit 0
[ -f "$CONFIG/memory-answer-guard" ] || exit 0

reply=$(jq -r '.last_assistant_message // empty | strings' <<<"$payload" 2>/dev/null) || exit 0
admission=$(printf '%s\n' "$reply" | grep -o -i -E -m 1 \
  "(from (my )?memory|from recall|if I (recall|remember)( correctly)?|as (far as )?I (recall|remember)|without (re-?checking|checking|verifying|a live read)|not (re-?checked|verified live)|(haven't|have not|didn't|did not) (re-?checked?|verif(y|ied)) (it |this |that )?live)" \
  | head -1)
[ -n "$admission" ] || exit 0

jq -nc --arg admission "$admission" '{
  decision: "block",
  reason: ("fm-memory-answer-guard: the reply says \"" + $admission + "\". Read the current source live (the status, record, PR, or file it is about), then answer from that read, or say plainly that the live read failed and why.")
}'
exit 0
