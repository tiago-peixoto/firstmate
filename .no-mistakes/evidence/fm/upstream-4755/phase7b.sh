#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
c=$(cat "$LAB/corr3")
say "Session E (new real claude primary) ran bin/fm-session-start.sh with the flag ABSENT"
show "$ROOT/bin/fm-lock.sh" status; token; queue
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
rec_fields "$c"
printf 'Bearings pending-reply rows: '; "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-"))]'
grep -c "blocked \[key=pending-reply-$c\]" "$STATE/mate.status" | sed 's/^/blocked status lines for this escalation (the single surface): /'
say "Session E opts in: this is a later session than the one that received the escalation, so it is reminded once"
touch "$LAB/config/pending-reply-resurface"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
queue; rec_fields "$c" | grep surfaced
printf 'Bearings pending-reply rows: '; "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-")) | .key]'
