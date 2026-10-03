#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
say "Session D (new real claude primary) ran bin/fm-session-start.sh after the reply resolved the record"
show "$ROOT/bin/fm-lock.sh" status; token; queue
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
for c in corr1 corr2; do rec_fields "$(cat "$LAB/$c")"; echo; done
say "Reminder pass and watcher tick in session D"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
say "Bearings decisions_open"
"$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '.decisions_open'
