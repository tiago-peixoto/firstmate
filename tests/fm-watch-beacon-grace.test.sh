#!/usr/bin/env bash
# A poll round whose steps together outlast the beacon grace must stay alive,
# while one step that hangs past the grace must still read stale.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-beacon-grace)

# Shorter than the grace, long enough that two of them cross it even when
# mtime is whole seconds. A single step of HUNG_SLEEP must cross the grace
# on its own.
GRACE=5
STEP_SLEEP=3
HUNG_SLEEP=6

beacon_age() {  # <beacon>
  local m
  if [ "$(uname)" = Darwin ]; then
    m=$(/usr/bin/stat -f %m "$1")
  else
    m=$(stat -c %Y "$1")
  fi
  echo $(( $(date +%s) - m ))
}

write_probe() {  # <state> <id> <sleep>
  local state=$1 id=$2 sleep_for=$3
  # Sleep and label are fixed into the registered bytes. The watcher runs a
  # snapshot of those bytes, so a later case cannot change this probe.
  cat > "$state/$id.check.sh" <<SH
#!/usr/bin/env bash
set -u
sleep $sleep_for
beacon=\$FM_STATE_OVERRIDE/.last-watcher-beat
if [ "\$(uname)" = Darwin ]; then
  m=\$(/usr/bin/stat -f %m "\$beacon")
else
  m=\$(stat -c %Y "\$beacon")
fi
age=\$(( \$(date +%s) - m ))
printf '%s %s\\n' '$id' "\$age" >> "\$FM_STATE_OVERRIDE/beacon-ages"
SH
  chmod 0700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$REGISTER" "$id" >/dev/null \
    || fail "could not register $id"
}

write_finisher() {  # <state>
  local state=$1
  cat > "$state/z-finish.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'round-finished\n'
SH
  chmod 0700 "$state/z-finish.check.sh"
  FM_STATE_OVERRIDE="$state" "$REGISTER" z-finish >/dev/null \
    || fail "could not register the round finisher"
}

run_one_round() {  # <state> <fakebin> <out>
  local state=$1 fakebin=$2 out=$3
  PATH="$fakebin:$PATH" \
    FM_HOME="$state/.." \
    FM_STATE_OVERRIDE="$state" \
    FM_WATCHER_STALE_GRACE="$GRACE" \
    FM_POLL=30 \
    FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 \
    FM_CHECK_TIMEOUT=30 \
    FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 \
    "$WATCH" > "$out" &
}

age_for() {  # <ages-file> <label>
  awk -v label="$2" '$1 == label { print $2; found=1 } END { if (!found) exit 1 }' "$1"
}

test_progressing_round_keeps_beacon_inside_grace() {
  local dir state fakebin out pid age_a age_b
  dir=$(make_case progressing-round)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  : > "$state/beacon-ages"
  write_probe "$state" slow-a "$STEP_SLEEP"
  write_probe "$state" slow-b "$STEP_SLEEP"
  write_finisher "$state"
  run_one_round "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 600 || fail "progressing round did not finish: $(cat "$out" 2>/dev/null)"
  grep -F 'round-finished' "$out" >/dev/null || fail "progressing round did not run the finisher: $(cat "$out")"
  age_a=$(age_for "$state/beacon-ages" slow-a) || fail "slow-a did not record a beacon age"
  age_b=$(age_for "$state/beacon-ages" slow-b) || fail "slow-b did not record a beacon age"
  [ "$age_a" -lt "$GRACE" ] || fail "beacon went stale during slow-a (age ${age_a}s, grace ${GRACE}s)"
  [ "$age_b" -lt "$GRACE" ] || fail "beacon went stale mid-round during slow-b (age ${age_b}s, grace ${GRACE}s) though each step is ${STEP_SLEEP}s"
  pass "a round whose steps together exceed the beacon grace stays fresh between those steps"
}

test_hung_step_still_goes_stale() {
  local dir state fakebin out pid age
  dir=$(make_case hung-step)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  : > "$state/beacon-ages"
  write_probe "$state" hung "$HUNG_SLEEP"
  write_finisher "$state"
  run_one_round "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 600 || fail "hung-step round did not finish: $(cat "$out" 2>/dev/null)"
  age=$(age_for "$state/beacon-ages" hung) || fail "hung step did not record a beacon age"
  [ "$age" -ge "$GRACE" ] || fail "a step that hangs past the grace stayed fresh (age ${age}s, grace ${GRACE}s)"
  pass "one step that hangs past the beacon grace still reads stale"
}

# The pane scan reads every recorded window in turn. A pane seen stable for the
# first time costs a current-state read, which can take its whole no-mistakes
# bound, so these windows stand in for that read with a slow fake that records
# the beacon age when it returns and then reports the crew working.
# A window's own capture and classification plus whole-second mtimes add up to
# a second around its read, so these cases leave more headroom under their grace
# than the check cases above. Two reads still cross it, and one hung read alone.
PANE_GRACE=7
PANE_READ_SLEEP=4
PANE_HUNG_SLEEP=8

write_slow_crew_state() {  # <fakebin>
  cat > "$1/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
sleep "$FM_TEST_READ_SLEEP"
beacon=$FM_STATE_OVERRIDE/.last-watcher-beat
if [ "$(uname)" = Darwin ]; then
  m=$(/usr/bin/stat -f %m "$beacon")
else
  m=$(stat -c %Y "$beacon")
fi
printf '%s %s\n' "$id" "$(( $(date +%s) - m ))" >> "$FM_STATE_OVERRIDE/beacon-ages"
printf 'state: working · source: run-step · validating (running)\n'
SH
  chmod +x "$1/fm-crew-state.sh"
}

# Record <id>'s window as already seen once at the capture's hash, so the next
# scan treats it as stable for the first time and reads its crew state.
record_stable_window() {  # <state> <id> <capture>
  local state=$1 id=$2 key
  printf 'window=test:fm-%s\nkind=ship\n' "$id" > "$state/$id.meta"
  key="test_fm-$id"
  printf '%s' "$(hash_text "$(cat "$3")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

# Run one watcher until every <id> has recorded a beacon age, then stop it.
run_pane_round() {  # <state> <fakebin> <capture> <windows> <read-sleep> <id>...
  local state=$1 fakebin=$2 capture=$3 windows=$4 read_sleep=$5 pid id i=0 missing
  shift 5
  PATH="$fakebin:$PATH" \
    FM_HOME="$state/.." \
    FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_TEST_READ_SLEEP="$read_sleep" \
    FM_FAKE_TMUX_WINDOWS="$windows" \
    FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_WATCHER_STALE_GRACE="$PANE_GRACE" \
    FM_POLL=1 \
    FM_SIGNAL_GRACE=0 \
    FM_STALE_ESCALATE_SECS=999999 \
    FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$state/../watch.out" &
  pid=$!
  while [ "$i" -lt 600 ]; do
    missing=0
    for id in "$@"; do
      age_for "$state/beacon-ages" "$id" >/dev/null 2>&1 || missing=1
    done
    [ "$missing" -eq 0 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 100 >/dev/null 2>&1 || true
  [ "$missing" -eq 0 ] || fail "pane round did not read every window: $(cat "$state/../watch.out" 2>/dev/null)"
}

test_pane_scan_keeps_beacon_inside_grace_between_windows() {
  local dir state fakebin capture age_a age_b
  dir=$(make_case pane-scan-round)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  : > "$state/beacon-ages"
  printf 'idle pane' > "$capture"
  write_slow_crew_state "$fakebin"
  record_stable_window "$state" a "$capture"
  record_stable_window "$state" b "$capture"
  run_pane_round "$state" "$fakebin" "$capture" "$(printf 'fm-a\nfm-b')" "$PANE_READ_SLEEP" a b
  age_a=$(age_for "$state/beacon-ages" a)
  age_b=$(age_for "$state/beacon-ages" b)
  [ "$age_a" -lt "$PANE_GRACE" ] || fail "beacon went stale during window a (age ${age_a}s, grace ${PANE_GRACE}s)"
  [ "$age_b" -lt "$PANE_GRACE" ] || fail "beacon went stale mid-scan during window b (age ${age_b}s, grace ${PANE_GRACE}s) though each window takes ${PANE_READ_SLEEP}s"
  pass "a pane scan whose windows together exceed the beacon grace stays fresh between windows"
}

test_hung_pane_window_still_goes_stale() {
  local dir state fakebin capture age
  dir=$(make_case pane-scan-hung)
  state="$dir/state"
  fakebin="$dir/fakebin"
  capture="$dir/pane.txt"
  : > "$state/beacon-ages"
  printf 'idle pane' > "$capture"
  write_slow_crew_state "$fakebin"
  record_stable_window "$state" hung "$capture"
  run_pane_round "$state" "$fakebin" "$capture" fm-hung "$PANE_HUNG_SLEEP" hung
  age=$(age_for "$state/beacon-ages" hung)
  [ "$age" -ge "$PANE_GRACE" ] || fail "a window whose read hangs past the grace stayed fresh (age ${age}s, grace ${PANE_GRACE}s)"
  pass "one window whose read hangs past the beacon grace still reads stale"
}

test_progressing_round_keeps_beacon_inside_grace
test_hung_step_still_goes_stale
test_pane_scan_keeps_beacon_inside_grace_between_windows
test_hung_pane_window_still_goes_stale
