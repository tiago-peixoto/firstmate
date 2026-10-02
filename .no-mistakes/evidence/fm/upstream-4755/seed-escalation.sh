#!/usr/bin/env bash
# seed-escalation.sh <worktree> <lab-home> <task> <summary> : drive a real pending-reply record to escalation through the library
set -eu
ROOT=$1 LAB=$2 TASK=$3 SUMMARY=$4
export FM_HOME=$LAB FM_PENDING_REPLY_SEND_HOOK=true FM_PENDING_REPLY_SESSION=previous-session
. "$ROOT/bin/fm-pending-reply-lib.sh"
state=$LAB/state
corr=$(fm_pending_reply_create "$LAB" "$state" "$TASK" "$SUMMARY")
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_mark_turn_completed "$state" "$corr" request
t=$(date +%s)
FM_PENDING_REPLY_NOW=$((t+1000)) fm_pending_reply_send_recovery "$state" "$corr"
FM_PENDING_REPLY_NOW=$((t+2000)) fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
FM_PENDING_REPLY_NOW=$((t+3000)) fm_pending_reply_maybe_escalate "$state" "$corr"
printf '%s\n' "$corr"
