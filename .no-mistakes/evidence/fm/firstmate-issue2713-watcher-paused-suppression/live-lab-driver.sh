#!/usr/bin/env bash
# Live drive of bin/fm-watch.sh against a real tmux server on the lab's private
# socket. Every scenario uses real time: no mtime backdating, no fake tmux, no
# fake crew-state. One scenario at a time; the lab state is reset between them.
set -u
ROOT=$1; LAB=$2; EV=$3
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TMUX="$SOCK,0,0" FM_CREW_STATE_NO_FORGE=1
STATE="$LAB/state"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
T="$EV/live-lab-transcript.log"
FAILS=0

log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$T"; }
check() {  # <condition-result> <description>
  if [ "$1" -eq 0 ]; then log "  ok   - $2"; else log "  FAIL - $2"; FAILS=$((FAILS + 1)); fi
}
tm() { tmux "$@"; }
key_of() { printf '%s' "$1" | tr ':/.' '___'; }
beat_mtime() { stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null || true; }

launch() {  # <cadence-secs> <out> -> pid in $PID
  local cadence=$1 out=$2
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_PAUSE_RESURFACE_SECS="$cadence" \
    "$WATCH" > "$out" 2> "$out.err" &
  PID=$!
  log "watcher pid=$PID launched (FM_PAUSE_RESURFACE_SECS=$cadence, FM_POLL=1)"
}
wait_exit() {  # <pid> <secs> -> 0 exited, 1 still alive
  local i=0 n=$(( $2 * 10 ))
  while [ "$i" -lt "$n" ]; do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }; sleep 0.1; i=$((i + 1)); done
  return 1
}
reap() { kill "$1" 2>/dev/null || true; wait_exit "$1" 15 || log "  WARN watcher $1 did not exit after TERM"; }
# Count whole poll cycles (beacon advances at the top of every poll) while the
# watcher stays alive; returns 1 if it exited first.
watch_polls() {  # <pid> <cycles> -> prints wakes seen? no: returns 1 on exit
  local pid=$1 want=$2 seen=0 last="" cur i=0
  while [ "$seen" -lt "$want" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 1; }
    cur=$(beat_mtime)
    if [ -n "$cur" ] && [ "$cur" != "$last" ]; then last=$cur; seen=$((seen + 1)); fi
    sleep 0.1; i=$((i + 1)); [ "$i" -lt 3000 ] || return 2
  done
  return 0
}
ack() {
  local err seq gen
  err=$(mktemp)
  "$DRAIN" > /dev/null 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$seq" ] && [ -n "$gen" ] || { log "  WARN no WAKE_ACK_REQUIRED from drain"; return 1; }
  "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2>&1 \
    && log "acked wake queue through sequence $seq"
}
stale_wakes() {  # <window> [pattern]
  awk -F '\t' -v w="$1" -v p="${2-}" '$3 == "stale" && $4 == w && (p == "" || index($5, p)) { n++ } END { print n + 0 }' "$STATE/.wake-queue" 2>/dev/null
}
queue_tail() { log "  wake-queue:"; sed 's/^/      /' "$STATE/.wake-queue" 2>/dev/null | tee -a "$T" >/dev/null; sed 's/^/      /' "$STATE/.wake-queue" 2>/dev/null; }
markers() {  # <key>
  local k=$1 f
  log "  markers for $k: $(cd "$STATE" && ls -a | grep -E -- "-$k\$" | tr '\n' ' ')"
  for f in .count-$k .paused-resurfaced-$k; do [ -e "$STATE/$f" ] && log "    $f = $(cat "$STATE/$f")"; done
  return 0
}
pane_tail() { log "  pane $1 tail: $(tm capture-pane -p -t "$1" | grep -v '^$' | tail -2 | tr '\n' '|')"; }
reset_lab_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
}
status_age() { echo $(( $(date +%s) - $(stat -c %Y "$STATE/$1.status") )); }
write_crew() {  # <task> <window> <kind> <status-line>
  printf 'window=%s\nkind=%s\nharness=grok\nbackend=tmux\nworktree=%s\n' "$2" "$3" "$LAB/projects/demo-wt" > "$STATE/$1.meta"
  printf '%s\n' "$4" > "$STATE/$1.status"
  log "crew $1: kind=$3 window=$2 status='$4'"
  log "  real crew-state read: $("$ROOT/bin/fm-crew-state.sh" "$1")"
}
# The fresh status line is first a status signal (pre-existing behaviour, not
# under test): let the real watcher surface it, then ack it as a supervisor would.
settle_signal() {  # <task>
  local out="$LAB/signal-$1.out"
  launch 999999 "$out"
  if wait_exit "$PID" 30; then log "  signal wake: $(cat "$out")"; else reap "$PID"; log "  WARN no signal wake"; fi
  ack
  : > "$STATE/.wake-queue"
}
iso_at() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------------------
scenario_S1_stable_pane_first_sight_then_cadence() {
  local w=lab:fm-crew k out age cadence
  k=$(key_of "$w")
  log "=== S1: ordinary crew, idle STABLE pane (dead agent: bash+sleep), paused: declaration"
  reset_lab_state
  write_crew crew1 "$w" ship 'paused: waiting on the upstream release'
  pane_tail "$w"
  settle_signal crew1
  out="$LAB/s1a.out"; launch 999 "$out"
  if wait_exit "$PID" 30; then log "  first sight wake: $(cat "$out")"; else reap "$PID"; log "  no wake in 30s"; fi
  check "$([ "$(stale_wakes "$w")" -eq 1 ]; echo $?)" "exactly one stale wake on first sight"
  check "$(grep -Fxq "stale: $w" "$out"; echo $?)" "first sight is the PLAIN stale wake (no recheck wording)"
  check "$([ ! -e "$STATE/.stale-since-$k" ]; echo $?)" "no wedge timer started"
  check "$([ -e "$STATE/.paused-$k" ] && [ -e "$STATE/.paused-resurfaced-$k" ]; echo $?)" "paused flag and re-surface throttle recorded"
  markers "$k"; queue_tail; ack
  age=$(status_age crew1); cadence=$(( age + 20 ))
  log "status age ${age}s; relaunch with cadence ${cadence}s: expect quiet for ~20s then ONE recheck"
  out="$LAB/s1b.out"; launch "$cadence" "$out"
  if watch_polls "$PID" 8; then log "  alive after 8 polls, wakes so far: $(stale_wakes "$w")"; check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "quiet inside the cadence (8 polls)"; else check 1 "watcher exited inside the cadence: $(cat "$out")"; fi
  if wait_exit "$PID" 60; then log "  cadence wake at status age $(status_age crew1)s: $(cat "$out")"; else reap "$PID"; log "  no wake in 60s"; fi
  check "$([ "$(stale_wakes "$w" 'awaiting external - declared pause')" -eq 1 ]; echo $?)" "one bounded recheck with the external-wait wording once the cadence elapsed"
  check "$([ "$(status_age crew1)" -ge "$cadence" ]; echo $?)" "recheck fired only after the status aged past the cadence"
  check "$(grep -q 'possible wedge' "$STATE/.wake-queue"; [ $? -ne 0 ]; echo $?)" "never labelled a possible wedge"
  queue_tail; ack
}

scenario_S2_clock_pane_paused() {  # also S3 via args: <name> <status-line> <wording>
  local name=$1 status=$2 wording=$3 w=lab:fm-tick k out age cadence
  k=$(key_of "$w")
  log "=== $name: ordinary crew, pane whose display CHANGES EVERY POLL (real clock), '$status'"
  reset_lab_state
  write_crew crew2 "$w" ship "$status"
  pane_tail "$w"
  settle_signal crew2
  age=$(status_age crew2); cadence=$(( age + 20 ))
  log "status age ${age}s; launch with cadence ${cadence}s: expect NO wake while inside the cadence"
  out="$LAB/${name}a.out"; launch "$cadence" "$out"
  if watch_polls "$PID" 10; then
    check 0 "alive after 10 polls on a churning pane"
    check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "no wake queued inside the cadence"
    check "$([ ! -e "$STATE/.stale-$k" ]; echo $?)" "an unsettled hash keeps no stale suppressor"
    log "  .count-$k now: $(cat "$STATE/.count-$k" 2>/dev/null) (0 = hash changed again this poll)"
    pane_tail "$w"
  else
    check 1 "watcher exited inside the cadence: $(cat "$out")"
  fi
  if wait_exit "$PID" 60; then log "  cadence wake at status age $(status_age crew2)s: $(cat "$out")"; else reap "$PID"; log "  no wake in 60s"; fi
  check "$([ "$(stale_wakes "$w")" -eq 1 ]; echo $?)" "exactly one stale wake once the declaration stood a whole cadence"
  check "$([ "$(stale_wakes "$w" "$wording")" -eq 1 ]; echo $?)" "the recheck carries the '$wording' wording"
  check "$(grep -q 'possible wedge' "$STATE/.wake-queue"; [ $? -ne 0 ]; echo $?)" "never labelled a possible wedge"
  check "$([ "$(status_age crew2)" -ge "$cadence" ]; echo $?)" "recheck fired only after the status aged past the cadence"
  markers "$k"; queue_tail; ack
  log "relaunch, same cadence: the recheck just fired must hold the next cadence"
  out="$LAB/${name}b.out"; launch "$cadence" "$out"
  if watch_polls "$PID" 8; then check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "quiet for 8 more polls after the recheck"; else check 1 "rechecked again inside the cadence: $(cat "$out")"; fi
  reap "$PID"
}

scenario_S4_clock_pane_elapsed_until() {
  local w=lab:fm-tick k out until
  k=$(key_of "$w")
  until=$(iso_at $(( $(date +%s) - 30 )))
  log "=== S4: ordinary crew, clock pane, paused: with an ELAPSED until ($until), cadence 999"
  reset_lab_state
  write_crew crew3 "$w" ship "paused: rate limit until $until"
  settle_signal crew3
  out="$LAB/s4a.out"; launch 999 "$out"
  if wait_exit "$PID" 30; then log "  due recheck at status age $(status_age crew3)s: $(cat "$out")"; else reap "$PID"; log "  no wake in 30s"; fi
  check "$([ "$(stale_wakes "$w")" -eq 1 ]; echo $?)" "exactly one wake, well inside the 999s cadence"
  check "$([ "$(stale_wakes "$w" 'declared clearing time has passed')" -eq 1 ]; echo $?)" "it is the elapsed-until recheck"
  case "$(cat "$STATE/.paused-resurfaced-$k" 2>/dev/null)" in *:due) check 0 "throttle recorded as :due";; *) check 1 "throttle not :due";; esac
  markers "$k"; queue_tail; ack
  log "relaunch: once per declaration, the ticking pane must stay quiet"
  out="$LAB/s4b.out"; launch 999 "$out"
  if watch_polls "$PID" 8; then check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "no repeat of the due recheck across 8 polls"; else check 1 "due recheck repeated: $(cat "$out")"; fi
  reap "$PID"
}

scenario_S5_pane_changes_once_then_settles() {
  local w=lab:fm-once k out until c i=0 changed=0 observed
  k=$(key_of "$w")
  until=$(iso_at $(( $(date +%s) - 30 )))
  log "=== S5: ordinary crew, pane that changes ONCE then settles, paused: with an ELAPSED until ($until)"
  reset_lab_state
  write_crew crew4 "$w" ship "paused: rate limit until $until"
  pane_tail "$w"
  settle_signal crew4
  out="$LAB/s5.out"; launch 999 "$out"
  # Change the pane exactly once, after its first hash was seen once (count 1,
  # not yet stable), mirroring a pane that changes once on its way to settling.
  while [ "$i" -lt 300 ]; do
    c=$(cat "$STATE/.count-$k" 2>/dev/null || echo none)
    if [ "$c" = 1 ] && [ "$changed" -eq 0 ]; then
      tm send-keys -t "$w" -l 'echo "still waiting on the rate limit"'; tm send-keys -t "$w" Enter
      changed=1; log "  pane changed once at .count=$c"
    fi
    kill -0 "$PID" 2>/dev/null || break
    sleep 0.05; i=$((i + 1))
  done
  if wait_exit "$PID" 30; then log "  wake at status age $(status_age crew4)s: $(cat "$out")"; else reap "$PID"; log "  no wake in 30s"; fi
  observed=$(tm capture-pane -p -t "$w" | grep -c 'still waiting')
  check "$([ "$changed" -eq 1 ] && [ "$observed" -ge 1 ]; echo $?)" "the pane changed exactly once before the stale sight (echo visible: $observed)"
  check "$([ "$(stale_wakes "$w")" -eq 1 ]; echo $?)" "exactly one wake"
  check "$(grep -Fxq "stale: $w" "$out"; echo $?)" "it is the PLAIN first sight, not the elapsed-until recheck wording"
  check "$([ "$(cat "$STATE/.stale-$k")" = "$(cat "$STATE/.hash-$k")" ]; echo $?)" "the sight is of the settled (post-change) hash"
  case "$(cat "$STATE/.paused-resurfaced-$k" 2>/dev/null)" in *:due) check 0 "throttle recorded as :due";; *) check 1 "throttle not :due";; esac
  pane_tail "$w"; markers "$k"; queue_tail; ack
}

scenario_S6_secondmate_stable_pane() {
  local w=lab:fm-crew k out age cadence
  k=$(key_of "$w")
  log "=== S6: SECONDMATE on the stable pane, paused: declaration - no first sight, cadence only"
  reset_lab_state
  write_crew mate1 "$w" secondmate 'paused: waiting on the upstream release'
  settle_signal mate1
  age=$(status_age mate1); cadence=$(( age + 15 ))
  out="$LAB/s6.out"; launch "$cadence" "$out"
  if watch_polls "$PID" 8; then
    check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "no plain first sight for a secondmate (8 polls quiet)"
    check "$([ -e "$STATE/.paused-$k" ] && [ -e "$STATE/.stale-$k" ]; echo $?)" "absorbed from first sight under the pause cadence"
  else check 1 "secondmate surfaced inside the cadence: $(cat "$out")"; fi
  if wait_exit "$PID" 60; then log "  cadence wake at status age $(status_age mate1)s: $(cat "$out")"; else reap "$PID"; log "  no wake in 60s"; fi
  check "$([ "$(stale_wakes "$w" 'awaiting external - declared pause')" -eq 1 ]; echo $?)" "one bounded recheck once the cadence elapsed"
  queue_tail; ack
}

scenario_S7_busy_pane_not_surfaced() {
  local w=lab:fm-busy k out
  k=$(key_of "$w")
  log "=== S7: ordinary crew on a BUSY pane (grok busy footer 'Ctrl+c:cancel', ticking), paused: aged past a 5s cadence"
  reset_lab_state
  write_crew crew5 "$w" ship 'paused: waiting on the validation run to finish'
  pane_tail "$w"
  settle_signal crew5
  sleep 6
  log "status age $(status_age crew5)s, cadence 5s: a busy pane must not take the stale path at all"
  out="$LAB/s7.out"; launch 5 "$out"
  if watch_polls "$PID" 10; then
    check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "no stale wake across 10 polls of a busy pane"
    check "$([ ! -e "$STATE/.paused-$k" ] && [ ! -e "$STATE/.stale-$k" ]; echo $?)" "no pause or stale bookkeeping for a busy pane"
  else check 1 "busy pane surfaced: $(cat "$out")"; fi
  reap "$PID"
}

scenario_S8_captain_held_clock_pane_under_away_record() {
  local w=lab:fm-tick k out
  k=$(key_of "$w")
  log "=== S8: captain-held on the clock pane while the AWAY-POSTURE record exists: never rechecked"
  reset_lab_state
  write_crew crew6 "$w" ship 'captain-held [key=route]: awaiting the captain on the routing call'
  settle_signal crew6
  "$ROOT/bin/fm-afk-contract.sh" enter > /dev/null 2>&1 && log "  away record written: $(ls "$STATE" | grep -c afk-contract) file(s)"
  sleep 6
  out="$LAB/s8.out"; launch 5 "$out"
  if watch_polls "$PID" 10; then check "$([ "$(stale_wakes "$w")" -eq 0 ]; echo $?)" "no recheck across 10 polls past the cadence under the away record"; else check 1 "surfaced under the away record: $(cat "$out")"; fi
  reap "$PID"
  "$ROOT/bin/fm-afk-contract.sh" archive > /dev/null 2>&1 && log "  away record archived"
}

case "${4:-all}" in
  S1) scenario_S1_stable_pane_first_sight_then_cadence ;;
  S2) scenario_S2_clock_pane_paused S2 'paused: waiting on the validation run to finish' 'awaiting external - declared pause' ;;
  S3) scenario_S2_clock_pane_paused S3 'captain-held [key=route]: awaiting the captain on the routing call' 'awaiting the captain' ;;
  S4) scenario_S4_clock_pane_elapsed_until ;;
  S5) scenario_S5_pane_changes_once_then_settles ;;
  S6) scenario_S6_secondmate_stable_pane ;;
  S7) scenario_S7_busy_pane_not_surfaced ;;
  S8) scenario_S8_captain_held_clock_pane_under_away_record ;;
esac
log "scenario ${4:-all} finished with $FAILS failed check(s)"
exit "$FAILS"
