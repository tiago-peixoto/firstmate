#!/usr/bin/env bash
# Live end-to-end driver for firstmate issue #4885.
# Drives the REAL bin/fm-watch.sh watcher, the REAL bin/fm-send.sh --resolve-key
# answer path, and the REAL bin/fm-wake-drain.sh presentation against a throwaway
# FM_HOME. Usage: e2e.sh <repo-root> <work-dir>
set -u
ROOT=$1
WORK=$2
rm -rf "$WORK"; mkdir -p "$WORK"
HOME_DIR="$WORK/home"; STATE="$HOME_DIR/state"; FB="$WORK/fakebin"
mkdir -p "$STATE" "$FB"
WATCH="$ROOT/bin/fm-watch.sh"; SEND="$ROOT/bin/fm-send.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
STATUS="$STATE/t1.status"
FAIL=0
say() { printf '\n=== %s\n' "$*"; }
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAIL=1; }

# --- harness seams -----------------------------------------------------------
# tmux stub: the only thing standing in for a real terminal multiplexer.
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf '\n'; exit 0 ;;
  capture-pane) printf '(idle)\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"
# fm-crew-state seam (FM_CREW_STATE_BIN): the watcher calls this to decide whether
# a crew is provably working. The real one makes a bounded no-mistakes call that
# takes real time; FM_FAKE_CREW_SLEEP reproduces that latency so the answers can
# land inside the watcher's real classify-then-commit window.
cat > "$FB/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${1:-}" >> "${FM_CREW_STATE_LOG:-/dev/null}"
[ -n "${FM_FAKE_CREW_SLEEP:-}" ] && sleep "$FM_FAKE_CREW_SLEEP"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · idle worker}"
exit 0
SH
chmod +x "$FB/fm-crew-state.sh"

printf 'window=sess:fm-t1\nkind=ship\n' > "$STATE/t1.meta"

watch_bg() {  # <out> [extra env assignments...]
  local out=$1; shift
  env PATH="$FB:$PATH" FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_CREW_STATE_BIN="$FB/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" 2>>"$WORK/watch.err" &
}
wait_exit() { local pid=$1 n=${2:-150} i=0
  while [ $i -lt $n ]; do kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }; sleep 0.1; i=$((i+1)); done
  return 1; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
poll_cycle() {  # <pid>: wait for one full watcher poll cycle; 1 if it exited
  local pid=$1 beat="$STATE/.last-watcher-beat" first now i=0
  rm -f "$beat"
  while [ $i -lt 300 ]; do kill -0 "$pid" 2>/dev/null || return 1
    first=$(stat -c %Y "$beat" 2>/dev/null); [ -n "$first" ] && break; sleep 0.1; i=$((i+1)); done
  while [ $i -lt 300 ]; do kill -0 "$pid" 2>/dev/null || return 1
    now=$(stat -c %Y "$beat" 2>/dev/null)
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i+1)); done
  return 1; }
drain_ack() {  # [<out-file>]
  local out=${1:-/dev/null} err="$WORK/ack.err" seq gen
  FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$HOME_DIR" "$DRAIN" >"$out" 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 0
  FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$HOME_DIR" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
send_answer() {  # <key> <text>
  env PATH="$FB:$PATH" FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    FM_SEND_LOG="$WORK/send.log" FM_SEND_SETTLE=0 "$SEND" t1 --resolve-key "$1" "$2" >>"$WORK/send.out" 2>>"$WORK/send.err"
}

# --- scenario ---------------------------------------------------------------
say "S1  worker opens two keyed decisions -> the supervisor is woken"
{ printf 'needs-decision [key=k1]: pick REST or RPC\n'
  printf 'needs-decision [key=k2]: pick us-east or eu-west\n'; } > "$STATUS"
watch_bg "$WORK/w1.out"; pid=$!
if wait_exit "$pid" && grep -qF "signal: $STATUS" "$WORK/w1.out"; then
  ok "watcher surfaced the worker's decisions: $(grep -m1 signal: "$WORK/w1.out")"
else reap "$pid"; bad "watcher never surfaced the worker's two decisions"; fi
drain_ack || bad "could not drain+ack the decisions wake"
printf '%s\n' "--- OPEN DECISIONS as the captain sees them ---"
FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$HOME_DIR" "$DRAIN" 2>/dev/null | sed -n '/OPEN DECISIONS/,$p'

say "S2  the supervisor answers BOTH keys in one handling turn, while the"
say "    watcher's classification for an unrelated worker note is in flight"
printf 'working: still building\n' >> "$STATUS"
: > "$WORK/crew.log"
watch_bg "$WORK/w2.out" FM_CREW_STATE_LOG="$WORK/crew.log" FM_FAKE_CREW_SLEEP=6
pid=$!
i=0; while [ $i -lt 200 ]; do [ -s "$WORK/crew.log" ] && break; sleep 0.1; i=$((i+1)); done
[ -s "$WORK/crew.log" ] || bad "the watcher never reached its crew-state evidence call"
send_answer k1 "go with REST"  || bad "the first --resolve-key answer failed"
send_answer k2 "use eu-west"   || bad "the second --resolve-key answer failed"
wait_exit "$pid" 200 || { reap "$pid"; bad "the watcher did not finish its in-flight cycle"; }
drain_ack "$WORK/drain-after-answers.out" || bad "could not drain+ack the in-flight cycle"
sed -E 's/ \[at=[0-9]+\]//' "$STATUS" | sed 's/^/    status| /'
printf '    classified-offset=%s file-size=%s\n' \
  "$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATUS")" \
  "$(wc -c < "$STATUS" | tr -d ' ')"
printf '    home-appends ledger: %s\n' "$(cat "$STATE/.t1.home-appends" 2>/dev/null | tr '\n' ' ' || echo '(none)')"

say "S3  the two answers alone must NOT wake the supervisor again"
: > "$WORK/w3.out"
watch_bg "$WORK/w3.out"; pid=$!
if poll_cycle "$pid"; then
  if [ -s "$WORK/w3.out" ]; then bad "the answers re-woke the supervisor: $(cat "$WORK/w3.out")"
  elif [ -s "$STATE/.wake-queue" ]; then bad "the answers enqueued a durable wake: $(cat "$STATE/.wake-queue")"
  else ok "a full watcher poll cycle passed with no wake over this home's own answers"; fi
else bad "the answers woke the watcher (it exited): $(cat "$WORK/w3.out")"; fi

say "S4  a worker-authored line after the answers must still wake"
printf 'blocked: need staging credentials\n' >> "$STATUS"
if wait_exit "$pid" 200 && grep -qF "signal: $STATUS" "$WORK/w3.out"; then
  ok "watcher surfaced the worker's blocked line: $(grep -m1 signal: "$WORK/w3.out")"
else reap "$pid"; bad "the worker's blocked line was swallowed: $(cat "$WORK/w3.out")"; fi

say "S5  the answers are still presented to the captain (never hidden)"
out="$WORK/drain-after-answers.out"
sed -E 's/ \[at=[0-9]+\]//' "$out" | sed 's/^/    drain| /'
if sed -E 's/ \[at=[0-9]+\]//' "$out" | grep -qF 'resolved [key=k1]: answered: go with REST' \
  && sed -E 's/ \[at=[0-9]+\]//' "$out" | grep -qF 'resolved [key=k2]: answered: use eu-west'; then
  ok "both owned answers still appear in the captain-facing status presentation"
else bad "an owned answer was hidden from the captain-facing presentation"; fi
final="$WORK/drain-final.out"
FM_STATE_OVERRIDE="$STATE" FM_ROOT_OVERRIDE="$HOME_DIR" "$DRAIN" > "$final" 2>/dev/null
sed -E 's/ \[at=[0-9]+\]//' "$final" | sed 's/^/    final| /'
if sed -E 's/ \[at=[0-9]+\]//' "$final" | grep -qF 'blocked: need staging credentials'; then
  ok "the worker's blocked line is presented too"
else bad "the worker's blocked line was not presented"; fi

printf '\n===== RESULT: %s =====\n' "$([ $FAIL -eq 0 ] && echo ALL-SCENARIOS-PASS || echo SCENARIO-FAILURE)"
exit $FAIL
