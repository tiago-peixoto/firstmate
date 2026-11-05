#!/usr/bin/env bash
# Drive one pending-reply record through request, missed recovery, and escalation
# with the product library, in session token $FM_PENDING_REPLY_SESSION. Prints corr.
# Usage: escalate.sh <repo-root> <home> <summary>
set -u
ROOT=$1 HOME_DIR=$2 SUMMARY=$3 TASK=${4:-mate}
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_HOME=$HOME_DIR
export FM_PENDING_REPLY_SEND_HOOK='true'   # recovery delivery stands in for the mate pane
state="$HOME_DIR/state"
corr=$(FM_PENDING_REPLY_NOW=1000 fm_pending_reply_create "$HOME_DIR" "$state" "$TASK" "$SUMMARY") || exit 1
FM_PENDING_REPLY_NOW=1000 fm_pending_reply_mark_delivered "$state" "$corr"
FM_PENDING_REPLY_NOW=1000 fm_pending_reply_mark_turn_completed "$state" "$corr" request
FM_PENDING_REPLY_NOW=2000 fm_pending_reply_send_recovery "$state" "$corr" || { echo "recovery send failed" >&2; exit 1; }
FM_PENDING_REPLY_NOW=3000 fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
FM_PENDING_REPLY_NOW=4000 fm_pending_reply_maybe_escalate "$state" "$corr" || { echo "escalation did not fire" >&2; exit 1; }
printf '%s\n' "$corr"
