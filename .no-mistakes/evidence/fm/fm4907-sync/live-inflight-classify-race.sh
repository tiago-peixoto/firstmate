#!/usr/bin/env bash
# Live reproduction of the failure PR #4907 fixes, driven through the REAL
# watcher process (bin/fm-watch.sh) and the REAL answer command (bin/fm-send.sh).
#
# The race, which happens in ordinary operation: the watcher captures a status
# file's classified endpoint at the top of a poll, then spends real time on its
# "is the crew provably working?" evidence check (a bounded no-mistakes call).
# If the supervisor answers a decision with --resolve-key inside that window,
# the watcher afterwards commits the endpoint it captured BEFORE the answer. The
# watcher's seen marker no longer vouches for the answer's own bytes, so on the
# next poll the supervisor is woken - by nothing but its own bookkeeping close.
#
# This driver forces that window deterministically by making the crew-state
# probe slow, which is exactly what the real probe is (a subprocess call), and
# then asks the only question that matters to a user: does the watcher exit?
set -u

ROOT=${FM_LIVE_ROOT:?set FM_LIVE_ROOT to the checkout under test}
HOLD=${FM_RACE_HOLD:-8}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-race.XXXXXX")
HOMEDIR="$WORK/home"; STATE="$HOMEDIR/state"; FAKEBIN="$WORK/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$WORK/notangle"
STATUS="$STATE/t1.status"
MODE="$WORK/crew-mode"; MARKER="$WORK/crew-held"
FAILED=0
say() { printf '\n=== %s\n' "$*"; }
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    # A live pane: its content changes on every capture, so the unrelated
    # stale-pane supervision layer never fires and this driver observes only
    # the status SIGNAL path, which is the layer the ledger touches.
    n=$(cat "${FM_RACE_PANE_COUNTER:-/dev/null}" 2>/dev/null || printf 0)
    [ -n "${FM_RACE_PANE_COUNTER:-}" ] && printf '%s\n' "$((n + 1))" > "$FM_RACE_PANE_COUNTER"
    printf '╭────╮\n│ %s │\n╰────╯\n' "$((n + 1))"
    exit 0 ;;
  list-windows)
    printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
# The crew-state probe: a real subprocess, deliberately slow in "hold" mode so
# the watcher's evidence check spans the moment the answer is written.
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
mode=$(cat "$FM_RACE_MODE" 2>/dev/null || printf idle)
case "$mode" in
  hold)
    printf 'held\n' >> "$FM_RACE_MARKER"
    /bin/sleep "${FM_RACE_HOLD:-8}"
    printf 'state: working · source: run-step · mid no-mistakes step\n' ;;
  working) printf 'state: working · source: run-step · mid no-mistakes step\n' ;;
  *) printf 'state: unknown · source: none · idle worker\n' ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/wedge-rec"
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fm-crew-state.sh" "$WORK/wedge-rec"
export FM_WEDGE_ALARM_EXEC="$WORK/wedge-rec"
export FM_ROOT_OVERRIDE="$WORK/notangle"
export FM_RACE_MODE="$MODE" FM_RACE_MARKER="$MARKER" FM_RACE_HOLD="$HOLD"

DRAIN="$ROOT/bin/fm-wake-drain.sh"; WATCH="$ROOT/bin/fm-watch.sh"; SEND="$ROOT/bin/fm-send.sh"
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
classified_offset() {
  FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' \
    _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATUS"
}
ack_cycle() {
  local err seq gen; err="$WORK/ack.err"
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" >/dev/null 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"
}
watch_bg() {
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_RACE_PANE_COUNTER="$WORK/pane-counter" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$1" 2>"$1.err" &
}
wait_for_exit() { local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done
  return 1; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
send() {
  env -u NO_MISTAKES_GATE PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    FM_ROOT_OVERRIDE="$HOMEDIR" FM_HOME="$HOMEDIR" FM_SEND_LOG="$WORK/send.log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key "$1" "$2"
}

printf 'checkout under test: %s\n' "$ROOT"
printf 'throwaway FM_HOME:   %s\n' "$HOMEDIR"
printf 'crew-probe hold:     %ss\n' "$HOLD"

printf idle > "$MODE"
printf 'window=sess:fm-t1\nkind=ship\n' > "$STATE/t1.meta"
printf 'needs-decision [key=budget]: approve the $400 spend?\n' > "$STATUS"

say "step 1: the worker's decision wakes the supervisor (the legitimate wake)"
watch_bg "$WORK/w1.out"; W1=$!
wait_for_exit "$W1" 150 && grep -qF "signal: $STATUS" "$WORK/w1.out" \
  && ok "woken: $(cat "$WORK/w1.out")" || bad "the decision never woke the supervisor"
reap "$W1"
ack_cycle && ok "wake acknowledged" || bad "could not acknowledge the wake"

say "step 2: the worker keeps working (routine growth the watcher will classify)"
printf 'working: still refactoring the adapter\n' >> "$STATUS"
SIZE2=$(size_of "$STATUS")
printf 'status size before the answer: %s bytes\n' "$SIZE2"

say "step 3: the watcher enters its slow crew-evidence check"
printf hold > "$MODE"
watch_bg "$WORK/w2.out"; W2=$!
i=0; while [ "$i" -lt 300 ] && [ ! -s "$MARKER" ]; do sleep 0.1; i=$((i+1)); done
[ -s "$MARKER" ] && ok "watcher is inside the crew-state probe with its endpoint already captured" \
  || bad "the watcher never reached the crew-evidence check"

say "step 4: the supervisor answers the decision INSIDE that window"
send budget "approved, go ahead" && ok "answer sent while the watcher was mid-check" || bad "the --resolve-key send failed"
printf 'status size after the answer: %s bytes\n' "$(size_of "$STATUS")"

say "step 5: the watcher commits the endpoint it captured before the answer"
printf working > "$MODE"
i=0
while [ "$i" -lt $(( (HOLD + 12) * 10 )) ]; do
  [ "$(classified_offset)" = "$SIZE2" ] && break
  kill -0 "$W2" 2>/dev/null || break
  sleep 0.1; i=$((i+1))
done
if [ "$(classified_offset)" = "$SIZE2" ]; then
  ok "watcher's classified offset regressed to $SIZE2, behind the answer's bytes - the race reproduced"
else
  bad "the race did not reproduce (classified offset is $(classified_offset), wanted $SIZE2); raise FM_RACE_HOLD and retry"
fi

say "step 6 (the question): is the supervisor woken by its own answer?"
printf idle > "$MODE"
if wait_for_exit "$W2" 200; then
  bad "the supervisor was WOKEN by its own --resolve-key answer: $(cat "$WORK/w2.out")"
else
  ok "the watcher stayed asleep: this home's own answer did not wake it"
fi

say "step 7 (guard): the worker's turn ends - the owned close must still be annotated"
# The wake is suppressed, but presentation must not be. A turn-ended wake row is
# the captain-facing surface the owned-append ledger is forbidden to touch.
if kill -0 "$W2" 2>/dev/null; then
  : > "$STATE/t1.turn-ended"
  if wait_for_exit "$W2" 200; then
    ok "the worker's turn end woke the supervisor: $(grep -F 'signal:' "$WORK/w2.out" | tail -n 1)"
  else
    bad "the turn-end marker did not wake the supervisor"
  fi
  reap "$W2"
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$WORK/drain-turnend.out" 2>"$WORK/drain-turnend.err" || true
  cat "$WORK/drain-turnend.out"
  grep -qF 'resolved [key=budget]: answered: approved, go ahead' "$WORK/drain-turnend.out" \
    && ok "the turn-ended annotation still presents this home's own close" \
    || bad "the ledger hid the owned close from the turn-ended annotation"
  ack_cycle >/dev/null 2>&1 || true
else
  bad "the watcher was already gone before the turn-end guard"
fi

say "step 8 (adversarial): a real worker line must still wake"
printf 'blocked: need staging credentials to continue\n' >> "$STATUS"
watch_bg "$WORK/w3.out"; W3=$!
wait_for_exit "$W3" 250 && grep -qF "signal: $STATUS" "$WORK/w3.out" \
  && ok "the worker's blocked: line woke the supervisor: $(grep -F 'signal:' "$WORK/w3.out" | tail -n 1)" \
  || bad "a real worker line after the owned answer was swallowed: $(cat "$WORK/w3.out")"
reap "$W3" 2>/dev/null || true

say "step 9 (guard): the answer is still on the captain-facing surface"
FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$WORK/drain.out" 2>"$WORK/drain.err" || true
cat "$WORK/drain.out"
grep -qF 'blocked: need staging credentials' "$WORK/drain.out" \
  && ok "the worker's blocker is presented to the captain" \
  || bad "the worker's blocker was not presented"

printf '\n===========================\n'
[ "$FAILED" -eq 0 ] && printf 'RESULT: all live scenarios passed\n' || printf 'RESULT: at least one live scenario FAILED\n'
exit "$FAILED"
