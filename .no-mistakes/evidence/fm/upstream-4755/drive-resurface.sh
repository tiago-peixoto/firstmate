#!/usr/bin/env bash
# Live drive of the pending-reply re-surface opt-in against a disposable lab home.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
STATE=$LAB/state
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_SEND_HOOK=true
escalate() {  # <summary> -> corr (escalated in session $FM_PENDING_REPLY_SESSION)
  local corr
  corr=$(FM_PENDING_REPLY_NOW=1000 fm_pending_reply_create "$LAB" "$STATE" mate "$1")
  fm_pending_reply_mark_delivered "$STATE" "$corr"
  FM_PENDING_REPLY_NOW=1000 fm_pending_reply_mark_turn_completed "$STATE" "$corr" request
  FM_PENDING_REPLY_NOW=2000 fm_pending_reply_send_recovery "$STATE" "$corr" >/dev/null
  FM_PENDING_REPLY_NOW=3000 fm_pending_reply_mark_turn_completed "$STATE" "$corr" recovery
  FM_PENDING_REPLY_NOW=4000 fm_pending_reply_maybe_escalate "$STATE" "$corr" >/dev/null
  printf '%s' "$corr"
}
reminders() { grep -c $'\tcheck\tpending-reply-escalated\t' "$STATE/.wake-queue" 2>/dev/null || echo 0; }
rows() { FM_HOME=$LAB "$ROOT/bin/fm-pending-reply-remind.sh" --decisions "$STATE"; }
remind() { FM_PENDING_REPLY_SESSION=$1 FM_HOME=$LAB "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"; }
say() { printf '\n== %s\n' "$*"; }

say "SCENARIO 1: flag ABSENT (default home) - escalation surfaced once only"
export FM_PENDING_REPLY_SESSION=s1
c1=$(escalate "finish the report")
echo "record phase: $(fm_pending_reply_get "$(fm_pending_reply_path "$STATE" "$c1")" phase)"
echo "escalation status lines in parent log: $(grep -Fc "blocked [key=pending-reply-$c1]" "$STATE/mate.status")"
remind s2; remind s3
echo "reminder wakes queued after later sessions s2,s3: $(reminders)"
echo "Bearings --decisions rows: $(rows)"
FM_PENDING_REPLY_SESSION=s4 fm_pending_reply_tick "$STATE" 2>/dev/null
echo "reminder wakes after watcher tick in s4: $(reminders)"

say "SCENARIO 2: flag PRESENT - one reminder per later live session"
: > "$LAB/config/pending-reply-resurface"
rm -f "$STATE"/pending-replies/* "$STATE/mate.status" "$STATE/.wake-queue"
export FM_PENDING_REPLY_SESSION=s1
c2=$(escalate "ship the parser fix")
r2=$(fm_pending_reply_path "$STATE" "$c2")
echo "escalated in s1, surfaced_session=$(fm_pending_reply_get "$r2" surfaced_session)"
remind s1; echo "same session s1 reminder wakes: $(reminders)"
remind s2; echo "later session s2 reminder wakes: $(reminders)"
echo "queued wake row:"; grep pending-reply-escalated "$STATE/.wake-queue" | cut -f2-
remind s2; echo "repeat poll in s2 reminder wakes: $(reminders)"
: > "$STATE/.wake-queue"
remind s2; echo "after drain, s2 again: $(reminders)"
FM_PENDING_REPLY_SESSION=s3 fm_pending_reply_tick "$STATE" 2>/dev/null
echo "watcher tick in new session s3 reminder wakes: $(reminders)"
echo "escalation status lines in parent log (no re-injection): $(grep -Fc "blocked [key=pending-reply-$c2]" "$STATE/mate.status")"
echo "Bearings --decisions rows: $(rows)"

say "SCENARIO 3: correlated reply arrives - reminder and row stop"
printf 'done [corr=%s]: parser fix shipped\n' "$c2" >> "$STATE/mate.status"
FM_PENDING_REPLY_SESSION=s4 fm_pending_reply_tick "$STATE" 2>/dev/null
: > "$STATE/.wake-queue"
echo "phase now: $(fm_pending_reply_get "$r2" phase)"
remind s5; echo "session s5 reminder wakes: $(reminders)"
echo "Bearings --decisions rows: $(rows)"

say "SCENARIO 4 (adversarial): operator keyed close vs unkeyed resolved"
export FM_PENDING_REPLY_SESSION=s1
c3=$(escalate "rebase the docs branch")
r3=$(fm_pending_reply_path "$STATE" "$c3")
printf 'resolved: looked at it\n' >> "$STATE/mate.status"
remind s2; echo "after UNKEYED resolved, s2 reminder wakes: $(reminders) rows: $(rows | jq length)"
: > "$STATE/.wake-queue"
printf 'resolved [key=pending-reply-%s]: pending-reply-resolved: task=mate pending-reply-id=%s via=operator-resolve-key\n' "$c3" "$c3" >> "$STATE/mate.status"
remind s3; echo "after KEYED operator close, s3 reminder wakes: $(reminders)"
echo "escalation_dismissed_epoch set: $( [ -n "$(fm_pending_reply_get "$r3" escalation_dismissed_epoch)" ] && echo yes || echo no)"
echo "Bearings --decisions rows: $(rows)"
FM_PENDING_REPLY_SESSION=s6 fm_pending_reply_tick "$STATE" 2>/dev/null
echo "watcher tick s6 reminder wakes: $(reminders)"
