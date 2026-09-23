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

test_progressing_round_keeps_beacon_inside_grace
test_hung_step_still_goes_stale
