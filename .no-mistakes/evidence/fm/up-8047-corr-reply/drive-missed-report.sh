#!/usr/bin/env bash
# Live driver: unanswered request -> recovery -> escalation stay unchanged; a late helper reply still resolves it.
set -u
ROOT=$PWD; LAB=$1; EV=$2
PARENT="$LAB/parent"; MATE="$LAB/mate"; STATE="$PARENT/state"; STATUS="$STATE/kid.status"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
hook_log="$EV/recovery-send-hook.log"; : > "$hook_log"
recovery_hook() { printf 'RECOVERY SENT TO MATE PANE: %s\t%s\n' "$1" "$2" >> "$hook_log"; }
export -f recovery_hook; export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
pstate() { local rec; rec=$(fm_pending_reply_path "$STATE" "$1"); printf 'record: phase=%s reply_child_id=%s reply_child_state=%s escalated_epoch=%s\n' "$(fm_pending_reply_get "$rec" phase)" "$(fm_pending_reply_get "$rec" reply_child_id)" "$(fm_pending_reply_get "$rec" reply_child_state)" "$(fm_pending_reply_get "$rec" escalated_epoch)"; }
step() { printf '\n### %s\n' "$*"; }
: > "$STATUS"; FM_HOME="$PARENT" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1

step "E1. request delivered, mate's turn completes with no report"
corr=$(fm_pending_reply_create "$PARENT" "$STATE" kid "how far is the repacking"); echo "corr=$corr"
fm_pending_reply_mark_delivered "$STATE" "$corr"
fm_pending_reply_observe_busy "$STATE" "$corr" busy; fm_pending_reply_observe_busy "$STATE" "$corr" idle
pstate "$corr"
step "E2. recovery fires once"
fm_pending_reply_send_recovery "$STATE" "$corr" && echo "recovery sent"; pstate "$corr"; cat "$hook_log"
fm_pending_reply_send_recovery "$STATE" "$corr" 2>/dev/null && echo "BUG: second recovery sent" || echo "second recovery refused (ok)"
step "E3. recovery turn completes with no report -> escalation"
fm_pending_reply_mark_turn_completed "$STATE" "$corr" recovery
fm_pending_reply_maybe_escalate "$STATE" "$corr"; echo "maybe_escalate exit=$?"; pstate "$corr"
echo "parent status lines mentioning the corr:"; grep -rn "$corr" "$STATE"/*.status 2>/dev/null | sed "s|$STATE/||"
step "E4. late reply through the helper with --task resolves the escalated request and shows the verdict"
FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" --task repack done "$corr" "finally reporting"; echo "helper exit=$?"
FM_HOME="$PARENT" bash -c '. "$1"; fm_wake_append signal kid.status "signal: kid.status"' _ "$ROOT/bin/fm-wake-lib.sh"
FM_HOME="$PARENT" "$ROOT/bin/fm-wake-drain.sh" | grep -v '^WAKE_ACK'
pstate "$corr"
