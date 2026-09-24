#!/usr/bin/env bash
# Drives the real bin/fm-watch.sh against a scratch state dir for #4763.
# Usage: drive-watcher.sh <checkout-root>
set -u
ROOT=$(cd "$1" && pwd)
. "$ROOT/tests/wake-helpers.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(mktemp -d /tmp/fm-4763-drive.XXXXXX)
fail() { printf 'FAIL - %s\n' "$1"; }
watch_bg() {
  local state=$1 fakebin=$2 out=$3; shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" &
}
# scenario <name> <crew-state verdict> <baseline> <appended lines...>
scenario() {
  local name=$1 verdict=$2 base=$3; shift 3
  local dir state fakebin out pid i=0
  dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf '%s\n' "$base" > "$state/task.status"
  prime_status_seen "$state" "$state/task.status"
  export FM_FAKE_CREW_STATE="$verdict"
  watch_bg "$state" "$fakebin" "$out"; pid=$!
  sleep 2
  printf '%s\n' "$@" >> "$state/task.status"
  while [ $i -lt 80 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  printf '=== %s\n--- crew verdict: %s\n--- status file:\n' "$name" "$verdict"
  sed 's/^/    /' "$state/task.status"
  if kill -0 "$pid" 2>/dev/null; then
    printf -- '--- watcher: STILL BLOCKING after 8s (wake absorbed, captain not woken)\n'
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  else
    printf -- '--- watcher: EXITED and woke the captain with:\n'
    sed 's/^/    /' "$out"
  fi
  printf -- '--- durable wake queue: %s\n\n' "$( [ -s "$state/.wake-queue" ] && echo 'has entry' || echo empty)"
}
BUSY='state: working · source: pane · harness busy'
IDLE='state: unknown · source: none · idle worker'
scenario parked-while-busy "$BUSY" 'working: still on it' 'parked: waiting for upstream'
scenario holding-while-busy "$BUSY" 'working: still on it' 'holding: for review'
scenario bad-token-done-while-busy "$BUSY" 'working: still on it' 'done corr=deadbeef: shipped'
scenario working-while-busy-control "$BUSY" 'working: still on it' 'working: step 2'
scenario done-while-busy-control "$BUSY" 'working: still on it' 'done: shipped'
n=0
for c in 'https://github.com/o/r/pull/12' 'Reason: upstream is slow' 'Note: see above' 'e.g.: the release notes' '10:30 retry scheduled'; do
  n=$((n+1))
  scenario "paused-then-continuation-$n" "$BUSY" 'working: still on it' 'paused: waiting on upstream release' "$c"
  scenario "working-then-continuation-$n" "$BUSY" 'working: still on it' 'working: opened PR' "$c"
done
rm -rf "$TMP_ROOT"
