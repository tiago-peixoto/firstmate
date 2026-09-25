#!/usr/bin/env bash
# Drive the real bin/fm-watch.sh from <tree> against isolated state dirs, one
# status log per scenario, and print whether the watcher surfaced or absorbed.
set -u
TREE=$1
. "$TREE/tests/wake-helpers.sh"
. "$ROOT/bin/fm-classify-lib.sh"
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-drive-4763)
file_mtime() { stat -c %Y "$1" 2>/dev/null; }
run() {  # <name> <crew-state> <status-content>
  local name=$1 crew=$2 content=$3 dir state fakebin out pid i beat first now verdict
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf '%s' "$content" > "$state/task.status"
  FM_FAKE_CREW_STATE="$crew" PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  beat="$state/.last-watcher-beat"; first=''; i=0
  while [ $i -lt 150 ] && kill -0 $pid 2>/dev/null; do
    now=$(file_mtime "$beat")
    if [ -n "$now" ]; then [ -z "$first" ] && first=$now; [ "$now" != "$first" ] && break; fi
    sleep 0.1; i=$((i+1))
  done
  if kill -0 $pid 2>/dev/null; then verdict="ABSORBED (watcher kept blocking, no wake)"; kill $pid; wait $pid 2>/dev/null
  else wait $pid 2>/dev/null; verdict="SURFACED: $(tr '\n' ' ' < "$out" | sed "s#$state/##g")"; fi
  printf '%-34s latest=%-42s -> %s\n' "$name" "'$(last_status_line "$state/task.status")'" "$verdict"
}
W='state: working · source: run-step · validating (running)'
P='state: paused · source: status-log · waiting on upstream'
run parked-after-working   "$W" $'working: still on it\nparked: waiting for upstream\n'
run holding-after-working  "$W" $'working: still on it\nholding: for review\n'
run bad-corr-done          "$W" $'working: still on it\ndone corr=deadbeef: shipped\n'
run stamped-parked         "$W" $'working [at=1]: still on it\nparked [at=17:00]: waiting upstream\n'
run stamped-bad-corr-done  "$W" $'working [at=1]: still on it\ndone corr=deadbeef [at=17:00]: shipped\n'
run control-done           "$W" $'working: still on it\ndone: shipped\n'
run control-working        "$W" $'working: still on it\n'
for c in 'https://github.com/o/r/pull/12' 'Reason: upstream is slow' 'Note: see above' 'e.g.: the notes' '10:30 retry scheduled'; do
  run "paused+ '$c'"  "$P" "paused: waiting on upstream release"$'\n'"$c"$'\n'
  run "working+ '$c'" "$W" "working: opened PR"$'\n'"$c"$'\n'
done
rm -rf "$TMP_ROOT"
