#!/usr/bin/env bash
# Live ADVERSARIAL driver for firstmate issue #4885: actively tries to make the
# owned-append ledger swallow something it must never swallow.
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

# --- adversarial scenarios ---------------------------------------------------
# Shared setup: the supervisor has handled the worker's open decisions once, so
# the watcher's classified offset sits at the end of them.
open_decisions_and_handle() {  # <lines...>
  printf '%s\n' "$@" > "$STATUS"
  watch_bg "$WORK/w0.out"; pid=$!
  wait_exit "$pid" || { reap "$pid"; bad "setup: watcher never surfaced the worker's decisions"; }
  drain_ack "$WORK/drain0.out" || bad "setup: could not drain+ack"
}
# Answer keys while the watcher's classification for an unrelated worker note is
# in flight, optionally running <hook> between the answers.
answer_during_inflight() {  # <hook-or-:> <key> <text> [<key> <text>...]
  local hook=$1; shift
  printf 'working: still building\n' >> "$STATUS"
  : > "$WORK/crew.log"
  watch_bg "$WORK/w1.out" FM_CREW_STATE_LOG="$WORK/crew.log" FM_FAKE_CREW_SLEEP=8
  ipid=$!
  local i=0; while [ $i -lt 200 ]; do [ -s "$WORK/crew.log" ] && break; sleep 0.1; i=$((i+1)); done
  [ -s "$WORK/crew.log" ] || bad "the watcher never reached its crew-state evidence call"
  send_answer "$1" "$2" || bad "answer $1 failed"; shift 2
  "$hook"
  while [ $# -gt 1 ]; do send_answer "$1" "$2" || bad "answer $1 failed"; shift 2; done
  wait_exit "$ipid" 250 || { reap "$ipid"; bad "the in-flight watcher cycle never finished"; }
  drain_ack "$WORK/drain1.out" || bad "could not drain+ack the in-flight cycle"
}
# Start a watcher and require a status-file signal wake. A watcher that was
# killed (not exited) leaves a downtime marker, so the next one legitimately
# wakes once with "check: rearm-resurface" first; acknowledge that and retry.
expect_signal_wake() {  # <out> <label>
  local out=$1 label=$2 try=0 pid
  while [ $try -lt 3 ]; do
    : > "$out"; watch_bg "$out"; pid=$!
    if ! wait_exit "$pid" 250; then reap "$pid"; bad "$label: the watcher never woke"; return 1; fi
    if grep -qF "signal: $STATUS" "$out"; then ok "$label"; return 0; fi
    printf '    (watcher woke with: %s - acknowledging and re-checking)\n' "$(tr '\n' ' ' < "$out")"
    drain_ack "$WORK/resurface.out" || true
    try=$((try + 1))
  done
  bad "$label: the status change never surfaced as a signal"
  return 1
}

show_state() {
  sed -E 's/ \[at=[0-9]+\]//' "$STATUS" | sed 's/^/    status| /'
  printf '    classified-offset=%s file-size=%s ledger=[%s]\n' \
    "$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATUS")" \
    "$(wc -c < "$STATUS" | tr -d ' ')" \
    "$(tail -n +3 "$STATE/.t1.home-appends" 2>/dev/null | tr '\n' ' ')"
}

case "${3:-interleave}" in
interleave)
  say "A1  a worker line landing BETWEEN two owned answers must still wake"
  open_decisions_and_handle 'needs-decision [key=k1]: pick REST or RPC' \
    'needs-decision [key=k2]: pick us-east or eu-west'
  worker_writes() { printf 'blocked: need staging credentials\n' >> "$STATUS"; }
  answer_during_inflight worker_writes k1 "go with REST" k2 "use eu-west"
  show_state
  expect_signal_wake "$WORK/w2.out" "the interleaved worker blocker still woke the supervisor"
  sed -E 's/ \[at=[0-9]+\]//' "$WORK/drain1.out" | sed 's/^/    drain| /'
  grep -qF 'blocked: need staging credentials' "$WORK/drain1.out" \
    && ok "the interleaved worker blocker is presented to the captain" \
    || bad "the interleaved worker blocker never reached the captain-facing presentation"
  ;;
rotate)
  say "A2  a rotated status file (new identity, same bytes) must not reuse the ledger"
  open_decisions_and_handle 'needs-decision [key=k1]: pick REST or RPC' \
    'needs-decision [key=k2]: pick us-east or eu-west'
  answer_during_inflight : k1 "go with REST" k2 "use eu-west"
  show_state
  : > "$WORK/w2.out"; watch_bg "$WORK/w2.out"; pid=$!
  poll_cycle "$pid" && ok "baseline: the owned answers alone stay quiet" \
    || bad "baseline: the owned answers woke the watcher"
  reap "$pid"
  cp "$STATUS" "$WORK/rot"; rm -f "$STATUS"; mv "$WORK/rot" "$STATUS"
  printf '    rotated the status log onto a new inode, byte-identical content\n'
  show_state
  expect_signal_wake "$WORK/w3.out" "the rotated log wakes: the ledger is not replayed against a new identity"
  ;;
unreadable)
  say "A3  an unreadable status log after owned growth must still wake"
  if [ "$(id -u)" -eq 0 ]; then ok "skipped: running as root, mode-000 is still readable"; exit 0; fi
  open_decisions_and_handle 'needs-decision [key=k1]: pick REST or RPC' \
    'needs-decision [key=k2]: pick us-east or eu-west'
  answer_during_inflight : k1 "go with REST" k2 "use eu-west"
  show_state
  : > "$WORK/w2.out"; watch_bg "$WORK/w2.out"; pid=$!
  poll_cycle "$pid" && ok "baseline: the owned answers alone stay quiet" \
    || bad "baseline: the owned answers woke the watcher"
  reap "$pid"
  chmod 000 "$STATUS"
  printf '    the status log is now mode 000 (unreadable)\n'
  expect_signal_wake "$WORK/w3.out" "the unreadable log surfaces instead of being absorbed as owned"
  chmod 600 "$STATUS"
  ;;
esac

printf '\n===== RESULT: %s =====\n' "$([ $FAIL -eq 0 ] && echo ADVERSARIAL-PASS || echo ADVERSARIAL-FAILURE)"
exit $FAIL
