#!/usr/bin/env bash
# Live: a local secondmate publishes on its parent channel (report helper and
# ledger-first child delivery). New events are stamped once, retries do not
# duplicate, and the parent's snapshot projects the event time for the mate.
. "$(dirname "$0")/live-common.sh"
trap cleanup_tmux EXIT
MAIN=$(make_home main)
MATE=$(make_home mate)
: > "$MATE/AGENTS.md"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
tmux new-session -d -s firstmate -n fm-mate 'cat'
tmux new-window -t firstmate -n fm-child 'cat'
write_meta "$MAIN/state/mate.meta" "window=firstmate:fm-mate" "worktree=$MATE" "project=$MATE" \
  "harness=codex" "kind=secondmate" "mode=secondmate" "home=$MATE" "projects=alpha"
printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
mkdir -p "$MATE/projects/child"
write_meta "$MATE/state/child.meta" "window=firstmate:fm-child" "worktree=$MATE/projects/child" \
  "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "spawn_gen=s1.1" "pr=https://example.test/owner/repo/pull/1"

say "C1. Secondmate answers a marked request with the report helper"
before=$(date +%s)
run env FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" done 0123456789abcdef "audit clean"
after=$(date +%s)
line=$(tail -1 "$MAIN/state/mate.status"); printf 'parent state/mate.status tail: %s\n' "$line"
epoch=$(bash -c '. "$1"; status_line_at_epoch "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$line")
check "report helper stamps the new parent event at append time" between "${epoch:-0}" "$before" "$after"

say "C2. Parent snapshot projects the mate's event time into secondmate_current"
out=$(FM_HOME="$MAIN" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
jq '{last_event: (.tasks[] | select(.id=="mate") | .paths.status_log.last_event),
     parent_event: (.secondmate_current.records[] | select(.id=="mate") | .parent_event | {raw, emitted_at_epoch, age_seconds})}' <<<"$out"
check "task last_event carries the stamp" jq -e --argjson e "$epoch" \
  '.tasks[] | select(.id=="mate") | .paths.status_log.last_event.emitted_at_epoch == $e' <<<"$out"
check "secondmate parent_event uses the same event time and age" jq -e --argjson e "$epoch" '
  (.tasks[] | select(.id=="mate") | .paths.status_log.last_event.age_seconds) as $a
  | .secondmate_current.records[] | select(.id=="mate")
  | .parent_event.emitted_at_epoch == $e and .parent_event.age_seconds == $a and ($a | type) == "number"' <<<"$out"

say "C3. Legacy parent event: backdated mtime must not become parent_event age"
printf 'working: legacy line from before the change\n' >> "$MAIN/state/mate.status"
touch -t 202001010000 "$MAIN/state/mate.status"
out=$(FM_HOME="$MAIN" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
jq -c '.secondmate_current.records[] | select(.id=="mate") | .parent_event | {raw, emitted_at_epoch, age_seconds}' <<<"$out"
check "legacy parent event keeps unknown time and age" jq -e '
  .secondmate_current.records[] | select(.id=="mate")
  | .parent_event.emitted_at_epoch == null and .parent_event.age_seconds == null' <<<"$out"

say "C4. Ledger-first child delivery is stamped once; a retry adds nothing"
printf 'working: building\ndone: PR https://example.test/owner/repo/pull/1 checks green\n' > "$MATE/state/child.status"
: > "$MATE/state/child.turn-ended"
for i in 1 2 3; do
  printf '$ fm-inactive-reconcile.sh report child   # attempt %s\n' "$i"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
    FM_CONFIG_OVERRIDE="$MATE/config" "$ROOT/bin/fm-inactive-reconcile.sh" report child; echo "rc=$?"
done
printf 'parent state/mate.status:\n'; cat "$MAIN/state/mate.status"
n=$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")
check "exactly one delivered child outcome after 3 attempts (got $n)" [ "$n" = 1 ]
line=$(grep 'child-outcome-child-done-' "$MAIN/state/mate.status")
check "delivered child outcome carries an emission time" \
  bash -c '. "$1"; status_line_at_epoch "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$line"
check "stamp sits in the head, key and note intact" \
  bash -c '. "$1"; [ "$(status_line_verb "$2")" = done ] && _fm_decision_key "$2" | grep -q "^child-outcome-child-done-" && status_line_note "$2" | grep -q "^child child done: PR https://example.test/owner/repo/pull/1 checks green"' \
  _ "$ROOT/bin/fm-classify-lib.sh" "$line"

say "C5. Crash after append, before receipt: retry must not re-publish (dedup ignores the time tag)"
ls "$MATE/state/terminal-outcomes/"
rm -f "$MATE/state/terminal-outcomes/"*.reported
sleep 1
FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" \
  FM_CONFIG_OVERRIDE="$MATE/config" "$ROOT/bin/fm-inactive-reconcile.sh" report child; echo "rc=$?"
grep 'child-outcome-child-done-' "$MAIN/state/mate.status"
n=$(grep -c 'child-outcome-child-done-' "$MAIN/state/mate.status")
check "receipt-less retry a second later still leaves one line, original time kept (got $n)" \
  [ "$n" = 1 -a "$(grep 'child-outcome-child-done-' "$MAIN/state/mate.status")" = "$line" ]
printf '\nFAILS=%s\n' "$FAILS"
