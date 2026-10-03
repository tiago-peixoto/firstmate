#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
corr=$(cat "$LAB/corr1")
say "Session B (real claude primary on the lab tmux socket) ran bin/fm-session-start.sh"
show "$ROOT/bin/fm-lock.sh" status; token
rec_fields "$corr"; queue
grep -c "blocked \[key=pending-reply-$corr\]" "$STATE/mate.status" | sed 's/^/blocked status lines for this escalation: /'
say "Same session B polls again (reminder script and watcher tick)"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
say "Session B acknowledges the wake, then polls again"
: > "$STATE/.wake-queue"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
queue
grep -c "blocked \[key=pending-reply-$corr\]" "$STATE/mate.status" | sed 's/^/blocked status lines for this escalation: /'
rec_fields "$corr" | grep phase
