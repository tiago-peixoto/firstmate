#!/usr/bin/env bash
# Live drive: the real bin/fm-watch.sh sees a worker append a stamped status
# line (the exact shape the new briefs instruct). With a legacy-style captain
# override FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:' and a crew that
# is provably working (the case where a non-relevant signal is silently
# absorbed), a stamped terminal line must still wake the captain, and a stamped
# working line must still be absorbed.
# Usage: drive-watcher-stamped-wake.sh <firstmate-checkout>
set -u
. "$1/tests/lib.sh"          # ROOT, sandbox gate bypass, fixtures
. "$1/tests/wake-helpers.sh" # make_case (fake tmux + fake fm-crew-state), wait_for_exit
TMP_ROOT=$(fm_test_tmproot fm-3746-watch)
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
export FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
fails=0
run_case() {  # <name> <status-line> <expect: wake|absorb>
  local dir state fb out pid now line
  dir=$(make_case "$1"); state=$dir/state; fb=$dir/fakebin; out=$dir/watch.out
  now=$(date +%s); line=${2//NOW/$now}
  printf '%s\n' "$line" > "$state/task.status"
  echo "--- case $1: state/task.status = $line"
  PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fb/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
  pid=$!
  if [ "$3" = wake ]; then
    if wait_for_exit "$pid" 150; then
      echo "watcher output:"; sed 's/^/  /' "$out"
      FM_STATE_OVERRIDE="$state" "$DRAIN" 2>/dev/null | sed 's/^/  drain: /'
      grep -Fq "signal: $state/task.status" "$out" && echo "PASS: $1 woke the captain" \
        || { echo "FAIL: $1 exited without the status signal"; fails=$((fails + 1)); }
    else
      echo "FAIL: $1 stamped terminal event was absorbed (watcher never woke)"; fails=$((fails + 1))
    fi
  else
    if wait_for_exit "$pid" 60; then
      echo "FAIL: $1 woke for a routine stamped working line: $(cat "$out")"; fails=$((fails + 1))
    else
      echo "PASS: $1 absorbed (no wake after 6s, queue empty=$([ -s "$state/.wake-queue" ] && echo no || echo yes))"
    fi
  fi
}
run_case stamped-done 'done [at=NOW]: PR https://example.test/o/r/pull/9 checks green' wake
run_case stamped-needs-decision 'needs-decision [at=NOW]: REST or gRPC?' wake
run_case stamped-working 'working [at=NOW]: compiling step 2' absorb
# Parity: this override never matched a KEYED line ("needs-decision [key=..]:"
# has no literal "needs-decision:"), before or after this change. The stamp must
# not change that verdict in either direction.
run_case legacy-keyed-needs-decision 'needs-decision [key=api]: REST or gRPC?' absorb
run_case stamped-keyed-needs-decision 'needs-decision [key=api] [at=NOW]: REST or gRPC?' absorb
echo "=== same stamped lines with the DEFAULT vocabulary (no FM_CAPTAIN_RE) ==="
unset FM_CAPTAIN_RE
run_case default-stamped-keyed-needs-decision 'needs-decision [key=api] [at=NOW]: REST or gRPC?' wake
run_case default-stamped-failed 'failed [at=NOW]: build broke on main' wake
run_case default-stamped-working 'working [at=NOW]: compiling step 3' absorb
rm -rf "$TMP_ROOT"
[ "$fails" -eq 0 ] && echo "RESULT: all watcher checks passed" || echo "RESULT: $fails watcher checks FAILED"
exit "$fails"
