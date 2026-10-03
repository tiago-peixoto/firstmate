#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
kept=$(cat "$LAB/corr2")
say "Session C: the mate's correlated reply arrives on the parent status log"
printf 'done [corr=%s]: the migration plan review is in\n' "$kept" >> "$STATE/mate.status"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
rec_fields "$kept"
tail -2 "$STATE/mate.status"
"$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1; : > "$STATE/.wake-queue"
