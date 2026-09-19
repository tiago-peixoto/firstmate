#!/usr/bin/env bash
# Live driver for firstmate #4885: real fm-watch.sh, fm-send.sh --resolve-key,
# fm-wake-drain.sh in an isolated home. Usage: drive.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
WATCH="$ROOT/bin/fm-watch.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"; SEND="$ROOT/bin/fm-send.sh"
BASE=$(mktemp -d /tmp/fm4885/run-$LABEL-XXXX)
say() { printf '[%s] %s\n' "$LABEL" "$*"; }

mkfake() {  # <fakebin>
  local fb=$1; mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) shift; lit=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2;; -l) lit=1; shift;; *) break;; esac; done
    [ "$lit" = 1 ] && printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"; exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
echo "${FM_FAKE_CREW_STATE:-state: unknown · source: none · idle worker}"
SH
  chmod +x "$fb/tmux" "$fb/fm-crew-state.sh"
  # The watcher gets a tmux with no live windows (as tests/wake-helpers.sh make_case does),
  # so no stale-pane wake from the static stub pane pollutes the signal path.
  mkdir -p "$fb/watch"
  printf '#!/usr/bin/env bash\n[ "${1:-}" = list-windows ] && exit 0\n[ "${1:-}" = capture-pane ] && exit 1\nexit 1\n' > "$fb/watch/tmux"
  chmod +x "$fb/watch/tmux"
}

setup() {  # <name> -> sets HOME_DIR STATE FB STATUS
  HOME_DIR="$BASE/$1"; STATE="$HOME_DIR/state"; FB="$HOME_DIR/fakebin"
  mkdir -p "$STATE"; mkfake "$FB"
  printf 'window=sess:fm-t1\nkind=ship\n' > "$STATE/t1.meta"
  STATUS="$STATE/t1.status"
}
watch_start() {  # <out>
  PATH="$FB/watch:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$FB/fm-crew-state.sh" \
    FM_POLL=${POLL:-1} FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$1" 2>"$1.err" &
  WPID=$!
}
wait_exit() {  # <secs> -> 0 exited
  local i=0; while [ $i -lt $(( $1 * 10 )) ]; do kill -0 "$WPID" 2>/dev/null || { wait "$WPID" 2>/dev/null; return 0; }; sleep 0.1; i=$((i+1)); done; return 1
}
stop_watch() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
drain_ack() {  # <outfile>
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$1" 2> "$1.err"
  local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation.*$/\1/p' "$1.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$1.err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  return 0
}
answer() {  # <key> <msg>
  env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_SEND_LOG="$HOME_DIR/send.log" \
    FM_SEND_SETTLE=0 "$SEND" t1 --resolve-key "$1" "$2" >/dev/null 2>"$HOME_DIR/send-$1.err"
  local rc=$?
  [ "$rc" -eq 0 ] || say "  !! fm-send --resolve-key $1 failed rc=$rc: $(cat "$HOME_DIR/send-$1.err")"
  return "$rc"
}
queue_rows() { [ -s "$STATE/.wake-queue" ] && wc -l < "$STATE/.wake-queue" || echo 0; }

RES=()
record() { RES+=("$1=$2"); say "RESULT $1: $2"; }

# ---- Scenario 1: supervisor handles a two-decision wake, then answers both back-to-back
setup s1
say "S1 worker opens two keyed decisions"
printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick us-east or eu-west\n' > "$STATUS"
watch_start "$HOME_DIR/w1.out"
wait_exit 15 && say "S1 watcher woke: $(cat "$HOME_DIR/w1.out")" || { say "S1 watcher never woke"; stop_watch; }
drain_ack "$HOME_DIR/d1.out"; say "S1 drain output:"; sed 's/^/    /' "$HOME_DIR/d1.out"
watch_start "$HOME_DIR/w2.out"; sleep 3
say "S1 captain answers api then region (fm-send --resolve-key)"
answer api "go with REST"; say "  send api rc=$?"
answer region "eu-west"; say "  send region rc=$?"
say "S1 status log now:"; sed 's/^/    /' "$STATUS"
if wait_exit 6; then record S1_answers_quiet "FAIL woke: $(cat "$HOME_DIR/w2.out")"; else record S1_answers_quiet "pass (watcher alive 6s, queue rows=$(queue_rows), out='$(cat "$HOME_DIR/w2.out")')"; fi
say "S1 worker appends a real blocker"
printf 'blocked: need staging credentials\n' >> "$STATUS"
if wait_exit 15; then record S1_worker_wakes "pass: $(cat "$HOME_DIR/w2.out")"; else stop_watch; record S1_worker_wakes "FAIL swallowed"; fi
drain_ack "$HOME_DIR/d2.out"; say "S1 drain after blocker:"; sed 's/^/    /' "$HOME_DIR/d2.out"

# ---- Scenario 2: answers land while the watcher is running, one-by-one with watcher polls between
setup s2
printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick us-east or eu-west\n' > "$STATUS"
watch_start "$HOME_DIR/w1.out"; wait_exit 15 || stop_watch
drain_ack "$HOME_DIR/d1.out"
watch_start "$HOME_DIR/w2.out"; sleep 3
answer api "go with REST"
if wait_exit 4; then record S2_first_answer_quiet "FAIL woke: $(cat "$HOME_DIR/w2.out")"; drain_ack "$HOME_DIR/d2.out"; watch_start "$HOME_DIR/w2.out"; sleep 3; else record S2_first_answer_quiet pass; fi
answer region "eu-west"
if wait_exit 4; then record S2_second_answer_quiet "FAIL woke: $(cat "$HOME_DIR/w2.out")"; else record S2_second_answer_quiet "pass (queue rows=$(queue_rows))"; stop_watch; fi

# ---- Scenario 3: decisions folded by a drain (e.g. branch actor) before the watcher classifies; answers come first
setup s3
printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick us-east or eu-west\n' > "$STATUS"
FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$HOME_DIR/fold.out" 2>/dev/null
answer api "go with REST"; answer region "eu-west"
wakes=0
watch_start "$HOME_DIR/w1.out"
if wait_exit 15; then wakes=$((wakes+1)); say "S3 wake #1: $(cat "$HOME_DIR/w1.out")"; drain_ack "$HOME_DIR/d1.out"; else stop_watch; fi
watch_start "$HOME_DIR/w2.out"
if wait_exit 6; then wakes=$((wakes+1)); say "S3 wake #2: $(cat "$HOME_DIR/w2.out")"; drain_ack "$HOME_DIR/d2.out"; watch_start "$HOME_DIR/w2.out"; fi
record S3_wake_count "wakes=$wakes (expect 1: worker decisions only, not one per answer)"
printf 'blocked: need staging credentials\n' >> "$STATUS"
if wait_exit 15; then record S3_worker_wakes "pass: $(cat "$HOME_DIR/w2.out")"; else stop_watch; record S3_worker_wakes "FAIL swallowed"; fi

# ---- Scenario 4 (adversarial): fresh worker decision folded by some drain, no home append -> must still wake
setup s4
printf 'working: building\n' > "$STATUS"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATUS"
printf 'needs-decision [key=k3]: pick a region\n' >> "$STATUS"
FM_STATE_OVERRIDE="$STATE" "$DRAIN" > "$HOME_DIR/fold.out" 2>/dev/null
watch_start "$HOME_DIR/w1.out"
if wait_exit 15; then record S4_folded_worker_decision_wakes "pass: $(cat "$HOME_DIR/w1.out")"; else stop_watch; record S4_folded_worker_decision_wakes "FAIL swallowed"; fi

# ---- Scenario 5 (adversarial): worker writes its own 'resolved' (not this home's) after answers -> must wake
setup s5
printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick\n' > "$STATUS"
watch_start "$HOME_DIR/w1.out"; wait_exit 15 || stop_watch; drain_ack "$HOME_DIR/d1.out"
watch_start "$HOME_DIR/w2.out"; sleep 3
answer api "REST"
printf 'resolved [key=region]: picked eu-west myself\n' >> "$STATUS"
if wait_exit 15; then record S5_worker_resolved_wakes "pass: $(cat "$HOME_DIR/w2.out")"; else stop_watch; record S5_worker_resolved_wakes "FAIL swallowed"; fi


# ---- Scenario 6: busy worker keeps writing absorbed working: notes; each answer lands right after one, before the watcher polls
setup s6
printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick us-east or eu-west\n' > "$STATUS"
watch_start "$HOME_DIR/w1.out"; wait_exit 15 || stop_watch; drain_ack "$HOME_DIR/d1.out"
export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
POLL=3 watch_start "$HOME_DIR/w2.out"; sleep 4
wakes6=0
for pair in "api:go with REST" "region:eu-west"; do
  printf 'working: applying feedback before %s\n' "${pair%%:*}" >> "$STATUS"
  answer "${pair%%:*}" "${pair#*:}"; say "  S6 answer ${pair%%:*} rc=$?"
  if wait_exit 8; then wakes6=$((wakes6+1)); say "  S6 wake after ${pair%%:*}: $(cat "$HOME_DIR/w2.out")"; drain_ack "$HOME_DIR/d6-${pair%%:*}.out"; say "  S6 drain:"; sed 's/^/      /' "$HOME_DIR/d6-${pair%%:*}.out"; POLL=3 watch_start "$HOME_DIR/w2.out"; sleep 4; fi
done
record S6_answers_after_absorbed_notes "wakes=$wakes6 (expect 0)"
say "S6 status log:"; sed 's/^/    /' "$STATUS"
printf 'blocked: need staging credentials\n' >> "$STATUS"
if wait_exit 15; then record S6_worker_blocker_wakes "pass: $(cat "$HOME_DIR/w2.out")"; else stop_watch; record S6_worker_blocker_wakes "FAIL swallowed"; fi
unset FM_FAKE_CREW_STATE

# ---- Scenario 7: captain fires both --resolve-key answers in rapid succession (concurrently); worker idle awaiting answers
woke7=0; trials7=${TRIALS7:-6}
for trial in $(seq 1 "$trials7"); do
  setup "s7-$trial"
  printf 'needs-decision [key=api]: pick REST or RPC\nneeds-decision [key=region]: pick us-east or eu-west\n' > "$STATUS"
  watch_start "$HOME_DIR/w1.out"; wait_exit 15 || stop_watch; drain_ack "$HOME_DIR/d1.out"
  watch_start "$HOME_DIR/w2.out"; sleep 3
  answer api "go with REST" & a1=$!
  answer region "eu-west" & a2=$!
  wait $a1; r1=$?; wait $a2; r2=$?
  if wait_exit 6; then woke7=$((woke7+1)); say "  S7 trial $trial (send rc $r1/$r2) WOKE: $(cat "$HOME_DIR/w2.out")"; drain_ack "$HOME_DIR/d7.out"; say "  S7 drain after that wake:"; sed 's/^/      /' "$HOME_DIR/d7.out"
  else say "  S7 trial $trial (send rc $r1/$r2) quiet; queue rows=$(queue_rows)"; stop_watch; fi
  say "  S7 trial $trial ledger: $(tr '\n' ' ' < "$STATE/.t1.home-appends" 2>/dev/null)"
done
record S7_concurrent_answers "woke in $woke7/$trials7 trials (expect 0)"

say "SUMMARY"; for r in "${RES[@]}"; do say "  $r"; done
