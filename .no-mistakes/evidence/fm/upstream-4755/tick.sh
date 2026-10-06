#!/usr/bin/env bash
# Run the pending-reply step of one watcher poll (the call bin/fm-watch.sh makes).
# Usage: tick.sh <lab-home>
set -u
ROOT=$(pwd)
export FM_HOME=$1
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
fm_pending_reply_tick "$FM_HOME/state"
