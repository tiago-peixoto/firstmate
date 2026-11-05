#!/usr/bin/env bash
# Run the watcher's pending-reply tick (what bin/fm-watch.sh calls each poll) in <home>.
set -u
ROOT=$1 HOME_DIR=$2
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_HOME=$HOME_DIR
fm_pending_reply_tick "$HOME_DIR/state"
