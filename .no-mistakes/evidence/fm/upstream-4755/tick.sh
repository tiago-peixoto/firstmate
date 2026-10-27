#!/usr/bin/env bash
# One watcher pass over the lab's pending-reply records: the same
# fm_pending_reply_tick call bin/fm-watch.sh makes on every cycle.
set -u
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
fm_pending_reply_tick "$1"
