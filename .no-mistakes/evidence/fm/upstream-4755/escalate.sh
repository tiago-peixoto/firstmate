#!/usr/bin/env bash
# Drive one delivered pending-reply record through its missed recovery to the
# product's own escalation (the same library calls bin/fm-watch.sh's tick makes
# when it observes the mate's turns complete without a correlated report).
# Usage: escalate.sh <state-dir> <corr> <base-epoch>
set -u
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-meta-lib.sh"; . "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
state=$1 corr=$2 t0=$3
FM_PENDING_REPLY_NOW=$t0 fm_pending_reply_mark_turn_completed "$state" "$corr" request || { echo "mark request turn failed"; exit 1; }
FM_PENDING_REPLY_NOW=$((t0+200)) fm_pending_reply_send_recovery "$state" "$corr" >/dev/null 2>&1 || { echo "recovery send failed"; exit 1; }
echo "recovery phase: $(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" phase)"
FM_PENDING_REPLY_NOW=$((t0+200)) fm_pending_reply_mark_turn_completed "$state" "$corr" recovery || { echo "mark recovery turn failed"; exit 1; }
FM_PENDING_REPLY_NOW=$((t0+400)) fm_pending_reply_maybe_escalate "$state" "$corr" || { echo "escalation did not fire"; exit 1; }
echo "escalated: $corr"
