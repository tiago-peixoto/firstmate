. /tmp/fm-live/common.sh
H=$(mktemp -d /tmp/fm-live/home-s9.XXXXXX)
mkdir -p "$H"/{state,data,projects} "$H/projects/p"
FB=$(make_fakebin "$H")
export PATH="$FB:$PATH"
rc=0
NOW=1789200000

hr "a worker is provably busy, and its newest event is a stamped done from an hour ago"
write_meta "$H/state/busy-task.meta" "window=firstmate:fm-busy-task" "worktree=$H/projects/p" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
printf 'done [at=%s]: PR https://example.test/owner/repo/pull/1 checks green\n' "$((NOW - 3600))" \
  > "$H/state/busy-task.status"
GEN=$("$BIN/fm-busy-event.sh" arm "$H/state" busy-task)
"$BIN/fm-busy-event.sh" apply "$H/state" busy-task busy --gen "$GEN" --source claude-hook --event user-prompt-submit >/dev/null
cat "$H/state/busy-task.status"

hr "snapshot: current state comes from the crew record, the stamp only ages the event"
OUT=$(FM_HOME="$H" FM_SNAPSHOT_NOW_EPOCH=$NOW "$BIN/fm-fleet-snapshot.sh" --json)
printf '%s' "$OUT" | jq '.tasks[]|select(.id=="busy-task")|{current_state, last_event:.paths.status_log.last_event}'
STATE=$(printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="busy-task")|.current_state.state')
AGE=$(printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="busy-task")|.paths.status_log.last_event.age_seconds')
KIND=$(printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="busy-task")|.paths.status_log.kind')
if [ "$STATE" = working ] && [ "$AGE" = 3600 ] && [ "$KIND" = event_history ]; then
  echo "  ok   current_state=$STATE (crew record) while the event log reports age ${AGE}s as event_history"
else
  echo "  FAIL state=$STATE age=$AGE kind=$KIND"; rc=1
fi

hr "human fleet view (bin/fm-fleet-view.sh)"
FM_HOME="$H" FM_SNAPSHOT_NOW_EPOCH=$NOW "$BIN/fm-fleet-view.sh"
[ "$rc" = 0 ] && echo "RESULT S9: PASS" || echo "RESULT S9: FAIL"
exit $rc
