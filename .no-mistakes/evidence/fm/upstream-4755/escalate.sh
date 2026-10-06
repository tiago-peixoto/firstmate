#!/usr/bin/env bash
# Drive one new pending reply through a missed recovery to its escalation,
# using the real library entry points the watcher tick calls.
# Usage: escalate.sh <lab-home> <task> <summary>
set -u
ROOT=$(pwd)
export FM_HOME=$1
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
state="$FM_HOME/state"
export FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_SEND_HOOK=true
corr=$(fm_pending_reply_create "$FM_HOME" "$state" "$2" "$3") || exit 1
fm_pending_reply_mark_delivered "$state" "$corr" || exit 1
fm_pending_reply_mark_turn_completed "$state" "$corr" request || exit 1
fm_pending_reply_send_recovery "$state" "$corr" || exit 1
fm_pending_reply_mark_turn_completed "$state" "$corr" recovery || exit 1
fm_pending_reply_maybe_escalate "$state" "$corr" || exit 1
printf '%s\n' "$corr"
