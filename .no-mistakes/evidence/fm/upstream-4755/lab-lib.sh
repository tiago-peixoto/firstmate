#!/usr/bin/env bash
# Shared helpers for the live lab drive of the pending-reply re-surface change.
# Sourced by the phase scripts. Everything runs the worktree's own bin/ scripts
# against the disposable lab home named in /tmp/fm-lab-4755.path.
ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M3ZSZ7NW8V6V6X4SV5WHY3TZ
LAB=$(cat /tmp/fm-lab-4755.path)
STATE="$LAB/state"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
export FM_PENDING_REPLY_GRACE_SECS=0
# The recovery nudge would type into a mate pane; the lab has no mate harness.
export FM_PENDING_REPLY_SEND_HOOK=true

. "$ROOT/bin/fm-wake-lib.sh"
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"

say() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

# Drive a request through request turn, recovery turn, and escalation.
escalate_new() {  # <summary> -> corr
  local corr
  corr=$(fm_pending_reply_create "$LAB" "$STATE" mate "$1") || return 1
  fm_pending_reply_mark_delivered "$STATE" "$corr"
  fm_pending_reply_mark_turn_completed "$STATE" "$corr" request
  fm_pending_reply_send_recovery "$STATE" "$corr" >&2 || return 1
  fm_pending_reply_mark_turn_completed "$STATE" "$corr" recovery
  fm_pending_reply_maybe_escalate "$STATE" "$corr" >&2 || return 1
  printf '%s\n' "$corr"
}

rec_fields() {  # <corr>
  grep -E '^(corr_id|phase|surfaced_session|escalation_dismissed_epoch|escalation_dismiss_scan|resolved_via)=' \
    "$(fm_pending_reply_path "$STATE" "$1")"
}
queue() { printf 'wake queue:\n'; cat "$STATE/.wake-queue" 2>/dev/null | sed 's/^/  /'; [ -s "$STATE/.wake-queue" ] || echo '  (empty)'; }
token() { printf 'live session token: %s\n' "$("$ROOT/bin/fm-pending-reply-remind.sh" --token "$STATE")"; }
decisions() { printf 'remind --decisions: '; "$ROOT/bin/fm-pending-reply-remind.sh" --decisions "$STATE"; echo; }
