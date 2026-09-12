. /tmp/fm-live/common.sh
H=$(mktemp -d /tmp/fm-live/home-s2.XXXXXX)
mkdir -p "$H"/{state,data,projects}
FB=$(make_fakebin "$H")
export PATH="$FB:$PATH"
NOW=1789200000

for id in legacy-task future-task stamped-task malformed-task; do
  write_meta "$H/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$H/projects/p" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
done

hr "a legacy worker (pre-change vocabulary) appends an unstamped event"
printf 'done: report ready\n' > "$H/state/legacy-task.status"
echo "and its status file is given a misleading mtime of 2020-01-01"
touch -t 202001010000 "$H/state/legacy-task.status"
ls -l "$H/state/legacy-task.status" | awk '{print $6, $7, $8, $9}'

hr "a clock-skewed worker stamps an event 200s in the future"
printf 'working [at=%s]: long build running\n' "$((NOW + 200))" > "$H/state/future-task.status"

hr "a current worker stamps an event 100s ago"
printf 'needs-decision [at=%s] [key=api-shape]: choose REST or gRPC\n' "$((NOW - 100))" > "$H/state/stamped-task.status"

hr "a worker writes a malformed time tag (an ISO time, not epoch seconds)"
printf 'blocked [at=2026-09-12T17:05Z]: upstream release slipped\n' > "$H/state/malformed-task.status"

hr "captain snapshot at a fixed observation time of $NOW"
OUT=$(FM_HOME="$H" FM_SNAPSHOT_NOW_EPOCH=$NOW "$BIN/fm-fleet-snapshot.sh" --json)
printf '%s' "$OUT" | jq '[.tasks[]|{id, raw:.paths.status_log.last_event.raw,
  emitted_at_epoch:.paths.status_log.last_event.emitted_at_epoch,
  age_seconds:.paths.status_log.last_event.age_seconds}]'

rc=0
check() { # <id> <expected epoch> <expected age>
  local got_e got_a
  got_e=$(printf '%s' "$OUT" | jq -r ".tasks[]|select(.id==\"$1\")|.paths.status_log.last_event.emitted_at_epoch")
  got_a=$(printf '%s' "$OUT" | jq -r ".tasks[]|select(.id==\"$1\")|.paths.status_log.last_event.age_seconds")
  if [ "$got_e" = "$2" ] && [ "$got_a" = "$3" ]; then
    printf '  ok   %-14s emitted_at_epoch=%s age_seconds=%s\n' "$1" "$got_e" "$got_a"
  else
    printf '  FAIL %-14s expected epoch=%s age=%s, got epoch=%s age=%s\n' "$1" "$2" "$3" "$got_e" "$got_a"; rc=1
  fi
}
hr "verdicts"
check legacy-task null null
check future-task $((NOW + 200)) null
check stamped-task $((NOW - 100)) 100
check malformed-task null null

hr "the stored event bytes are untouched by the read"
cat "$H"/state/*.status
[ "$rc" = 0 ] && echo "RESULT S2: PASS" || echo "RESULT S2: FAIL"
exit $rc
