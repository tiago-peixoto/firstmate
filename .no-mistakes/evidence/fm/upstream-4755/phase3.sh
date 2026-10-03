#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
corr=$(cat "$LAB/corr1")
export TMUX="$(cat "$LAB/sock"),0,0"
say "Session B: a second request escalates and is left open"
kept=$(escalate_new "review the migration plan"); echo "$kept" > "$LAB/corr2"
rec_fields "$kept"
say "Pad the status log with 4000 unrelated lines so the close sits far from the escalation"
for i in $(seq 1 4000); do printf 'note: progress line %s\n' "$i"; done >> "$STATE/mate.status"
wc -l "$STATE/mate.status"
say "Operator closes the first escalation with fm-send --resolve-key"
show "$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$corr" "ack, handled out of band"
grep -n "key=pending-reply-$corr" "$STATE/mate.status"
for i in $(seq 1 2000); do printf 'note: later line %s\n' "$i"; done >> "$STATE/mate.status"
say "Same session B reminder pass records the close"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"
rec_fields "$corr"; queue
say "Bearings: only the open escalation keeps a row"
"$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '.decisions_open[] | {key,verb,owner}'
