#!/usr/bin/env bash
# Drive the real bin/fm-watch.sh against an isolated state dir for each status
# log, with a crew whose run-step is running (provably working), and report
# whether the watcher woke the captain (SURFACED) or swallowed the signal (ABSORBED).
# Usage: drive-watcher.sh <repo-root>
set -u
ROOT=$1
TMP=$(mktemp -d /tmp/fm-drive.XXXX)
fakebin="$TMP/fakebin"; mkdir -p "$fakebin"
printf '#!/usr/bin/env bash\n[ "${1:-}" = list-windows ] && exit 0\nexit 1\n' > "$fakebin/tmux"
cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · x}"
SH
chmod +x "$fakebin"/*
export FM_ROOT_OVERRIDE="$TMP/root"; mkdir -p "$FM_ROOT_OVERRIDE"
export FM_WEDGE_ALARM_EXEC=/bin/true
n=0
drive() {  # <label> <crew-state> <status-content>
  local label=$1 crew=$2 content=$3 state out pid i verdict
  n=$((n+1)); state="$TMP/case$n/state"; mkdir -p "$state"; out="$TMP/case$n/out"
  printf '%s' "$content" > "$state/task.status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$TMP/case$n/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE="$crew" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$out" 2>/dev/null &
  pid=$!; verdict=TIMEOUT
  for i in $(seq 1 100); do
    if ! kill -0 $pid 2>/dev/null; then verdict=SURFACED; break; fi
    if grep -q 'absorbed' "$state/.watch-triage.log" 2>/dev/null; then verdict=ABSORBED; break; fi
    sleep 0.1
  done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  printf '== %s\n   status log:\n' "$label"; sed 's/^/     | /' "$state/task.status"
  printf '   watcher verdict: %s\n' "$verdict"
  [ -s "$out" ] && sed 's/^/   stdout: /' "$out" | sed "s#$state#<state>#g"
  [ -s "$state/.watch-triage.log" ] && tail -n 2 "$state/.watch-triage.log" | sed 's/^/   triage: /' | sed "s#$state#<state>#g"
}
W='state: working · source: run-step · validating (running)'
drive "parked: after working: (issue #4763 core)" "$W" $'working: still on it\nparked: waiting for upstream release\n'
drive "holding: after working:" "$W" $'working: still on it\nholding: for captain review\n'
drive "done with mismatched corr token after working:" "$W" $'working: still on it\ndone corr=deadbeef: shipped PR #12\n'
drive "needs-decision with missing corr token" "$W" $'working: still on it\nneeds-decision corr=: choose A or B\n'
drive "control: plain working: note (recognized, nonterminal)" "$W" $'working: step 1\nworking: step 2\n'
drive "control: done: (recognized terminal)" "$W" $'working: step 1\ndone: shipped\n'
for c in 'https://github.com/o/r/pull/12' 'Reason: upstream is slow' 'Note: see above' 'e.g.: the release notes' '10:30 retry scheduled' 'More detail: still waiting.'; do
  drive "adversarial: working: + continuation '$c'" "$W" "working: opened PR"$'\n'"$c"$'\n'
done
rm -rf "$TMP"
