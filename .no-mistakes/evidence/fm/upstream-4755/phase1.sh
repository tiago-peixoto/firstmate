#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
say "Session A holds the lab lock; config/pending-reply-resurface is ABSENT"
ls -A "$LAB/config"; token
fm_write_meta "$STATE/mate.meta" "window=primary:fm-mate" "kind=ship" 2>/dev/null || printf 'window=primary:fm-mate\nkind=ship\n' > "$STATE/mate.meta"
corr=$(escalate_new "finish the quarterly report"); echo "$corr" > "$LAB/corr1"
say "Record after escalation (flag absent)"; rec_fields "$corr"
say "Parent status log"; cat "$STATE/mate.status"
say "Flag absent: reminder pass and Bearings input"
: > "$STATE/.wake-queue.before"; cp "$STATE/.wake-queue" "$STATE/.wake-queue.before" 2>/dev/null
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
decisions
say "Opt in mid-session: touch config/pending-reply-resurface (same session A)"
touch "$LAB/config/pending-reply-resurface"; token
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
fm_pending_reply_tick "$STATE"; echo "watcher tick exit $?"
grep -c pending-reply-escalated "$STATE/.wake-queue" | sed 's/^/reminder rows in queue: /'
rec_fields "$corr"
decisions
queue
