#!/usr/bin/env bash
# live-lab-driver.sh <group> - drive bin/fm-watch.sh against a REAL tmux pane in
# a disposable lab home (bin/fm-lab-home.sh), with the real bin/fm-crew-state.sh
# reader. No fake tmux, no fake crew state. Groups:
#   stable        live agent (fake `grok` foreground), idle stable pane, paused:
#   ticking       live agent whose pane prints a clock every 0.3s, paused:
#   held-ticking  same ticking pane, captain-held declaration
#   until-ticking dead agent (shell), ticking pane, paused: ... until <elapsed>
#   until-settle  dead agent (shell), pane changes once and settles, until <elapsed>
#   secondmate    kind=secondmate, idle stable pane, paused:
set -u
ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M6BPZ4RGGQW935JHCHPYWND6
EV=/home/firstmate/.no-mistakes/evidence/01M6BPZ4RGGQW935JHCHPYWND6
GROUP=${1:?group}
LOG=$EV/live-$GROUP.log
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 2; }
TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || { echo "lab tmux-dir failed"; exit 2; }
STATE=$LAB/state
WINDOW=fm-lab:parked
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
FAILS=0

tm() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux "$@"; }
cleanup() {
  tm kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB"
  echo "lab removed: $LAB (exists: $([ -e "$LAB" ] && echo yes || echo no))"
}
trap cleanup EXIT

check() {  # <name> <cmd...>
  local name=$1; shift
  if "$@"; then echo "CHECK PASS: $name"; else echo "CHECK FAIL: $name"; FAILS=$((FAILS + 1)); fi
}
not_grep() { ! grep "$@"; }
stale_wakes() { awk -F '\t' -v w="$WINDOW" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$STATE/.wake-queue" 2>/dev/null || echo 0; }
mtime() { stat -c %Y "$1" 2>/dev/null; }
backdate() { touch -m -d "@$1" "$2"; }

WENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX
  TMUX_TMPDIR="$TMUXDIR" FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
  FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCH_HANDLING_SUCCESSOR=1)

# run_watch <round> <exit|absorb> <resurface-secs>: start the real watcher; in
# `exit` mode wait up to 90s for it to surface and exit, in `absorb` mode wait
# for 4 completed poll cycles (liveness beacon advancing) and then stop it.
run_watch() {
  local round=$1 mode=$2 secs=$3 out pid i=0 beat first now cycles=0
  out=$EV/live-$GROUP-$round.out
  echo "=== round $round ($mode, FM_PAUSE_RESURFACE_SECS=$secs) stale wakes before: $(stale_wakes)"
  beat=$STATE/.last-watcher-beat; rm -f "$beat"
  "${WENV[@]}" FM_PAUSE_RESURFACE_SECS="$secs" "$ROOT/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  pid=$!
  if [ "$mode" = exit ]; then
    while [ "$i" -lt 900 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i + 1)); done
    if kill -0 "$pid" 2>/dev/null; then
      echo "watcher STILL RUNNING after 90s (expected exit) - stopping it"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RESULT=running
    else
      wait "$pid"; echo "watcher exited rc=$?"; RESULT=exited
    fi
  else
    while [ "$cycles" -lt 4 ] && [ "$i" -lt 900 ]; do
      kill -0 "$pid" 2>/dev/null || break
      first=$(mtime "$beat")
      if [ -n "$first" ]; then
        while [ "$i" -lt 900 ]; do
          kill -0 "$pid" 2>/dev/null || break
          now=$(mtime "$beat")
          if [ -n "$now" ] && [ "$now" != "$first" ]; then cycles=$((cycles + 1)); break; fi
          sleep 0.1; i=$((i + 1))
        done
      else
        sleep 0.1; i=$((i + 1))
      fi
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "watcher alive after $cycles completed poll cycles - stopping it"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RESULT=alive
    else
      wait "$pid"; echo "watcher EXITED early rc=$? after $cycles cycles (expected to stay absorbing)"; RESULT=exited
    fi
  fi
  echo "--- watcher stdout ($out):"; cat "$out"
  echo "--- watcher stderr (last 15 lines):"; tail -15 "$out.err"
  echo "--- state markers:"; ls -a "$STATE" | grep -E '^\.(stale|paused|hash|count|seen|wake)' | sed 's/^/    /'
  [ -e "$STATE/.paused-resurfaced-$KEY" ] && echo "    .paused-resurfaced-$KEY = '$(cat "$STATE/.paused-resurfaced-$KEY")'"
  echo "--- triage log tail:"; tail -4 "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/    /'
  echo "--- stale wakes after: $(stale_wakes)"
  echo "--- wake queue:"; sed 's/^/    /' "$STATE/.wake-queue" 2>/dev/null || echo "    (none)"
}

ack() {
  local err seq gen
  err=$(mktemp)
  "${WENV[@]}" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || { echo "drain failed: $(cat "$err")"; rm -f "$err"; return 1; }
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$seq" ] && [ -n "$gen" ] || { echo "no WAKE_ACK_REQUIRED line"; return 1; }
  "${WENV[@]}" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  echo "acked wakes through $seq"
}

pane_show() {
  echo "--- pane_current_command: $(tm display-message -p -t "$WINDOW" '#{pane_current_command}')"
  echo "--- pane capture:"; tm capture-pane -p -t "$WINDOW" | grep -v '^[[:space:]]*$' | tail -6 | sed 's/^/    | /'
}

# ----- fixture -----------------------------------------------------------
mkdir -p "$LAB/projects/parked"
# The pane runs bash so `exec -a grok` can give the stand-in agent process the
# harness's name as its argv[0]; tmux reports that as pane_current_command.
IDLE_AGENT="echo 'grok  idle - waiting for input'; exec -a grok sleep 100000"
BUSY_AGENT="echo 'grok  working on the fix'; echo 'Thinking... Ctrl+c:cancel'; exec -a grok sleep 100000"
TICKING_AGENT="exec -a grok bash -c 'echo \"grok  idle - clock\"; while :; do date +%s.%N; sleep 0.3; done'"
env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s fm-lab -n parked -x 120 -y 30 -c "$LAB" \
  env PS1='lab$ ' bash --norc --noprofile
sleep 0.5

KIND=ship
STATUS_LINE='paused: waiting on the validation run to finish'
case "$GROUP" in
  stable)        tm send-keys -t "$WINDOW" "$IDLE_AGENT" Enter ;;
  ticking)       tm send-keys -t "$WINDOW" "$TICKING_AGENT" Enter ;;
  held-ticking)  tm send-keys -t "$WINDOW" "$TICKING_AGENT" Enter
                 STATUS_LINE='captain-held [key=route]: awaiting the captain on the routing call' ;;
  until-ticking) tm send-keys -t "$WINDOW" 'while :; do date +%s.%N; sleep 0.3; done' Enter
                 STATUS_LINE="paused: rate limit until $(date -u -d "@$(( $(date +%s) - 30 ))" +%Y-%m-%dT%H:%M:%SZ)" ;;
  until-settle)  STATUS_LINE="paused: rate limit until $(date -u -d "@$(( $(date +%s) - 30 ))" +%Y-%m-%dT%H:%M:%SZ)" ;;
  secondmate)    KIND=secondmate; tm send-keys -t "$WINDOW" "$IDLE_AGENT" Enter ;;
  busy)          tm send-keys -t "$WINDOW" "$BUSY_AGENT" Enter ;;
  held-away)     tm send-keys -t "$WINDOW" "$TICKING_AGENT" Enter
                 STATUS_LINE='captain-held [key=route]: awaiting the captain on the routing call' ;;
  *) echo "unknown group"; exit 2 ;;
esac
sleep 1
if [ "$KIND" = secondmate ]; then
  printf 'window=%s\nkind=secondmate\n' "$WINDOW" > "$STATE/parked.meta"
else
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$WINDOW" "$LAB/projects/parked" > "$STATE/parked.meta"
fi
printf '%s\n' "$STATUS_LINE" > "$STATE/parked.status"
# The declaration has stood 500s before the watcher first sees it (same aging
# the pause suite uses, so FM_PAUSE_RESURFACE_SECS=999 is inside the cadence
# and 240 is past it).
backdate "$(( $(date +%s) - 500 ))" "$STATE/parked.status"
echo "lab: $LAB  tmux dir: $TMUXDIR  group: $GROUP"
echo "status line: $STATUS_LINE (mtime age $(( $(date +%s) - $(mtime "$STATE/parked.status") ))s)"
echo "meta:"; sed 's/^/    /' "$STATE/parked.meta"
pane_show
echo "--- real fm-crew-state.sh verdict: $("${WENV[@]}" "$ROOT/bin/fm-crew-state.sh" parked 2>&1)"

# Round 0: the crew's fresh declaration is a status signal the watcher surfaces
# and firstmate acknowledges; this primes the seen marker exactly as production
# does, so later rounds exercise only the stale path.
if [ "$GROUP" = busy ]; then
  # A provably-busy pane is the one proof that absorbs a routine paused: signal.
  run_watch r0-signal absorb 999
  check "r0: fresh declaration under a busy pane is absorbed as a benign signal (watcher keeps polling)" [ "$RESULT" = alive ]
  check "r0: triage log records the benign-signal absorb" grep -Fq 'absorbed benign signal' "$STATE/.watch-triage.log"
  check "r0: no stale wake" [ "$(stale_wakes)" -eq 0 ]
else
  run_watch r0-signal exit 999
  check "r0: watcher surfaced the fresh declaration signal and exited" [ "$RESULT" = exited ]
  check "r0: no stale wake yet" [ "$(stale_wakes)" -eq 0 ]
  ack || FAILS=$((FAILS + 1))
fi

case "$GROUP" in
stable|secondmate)
  if [ "$GROUP" = stable ]; then
    run_watch r1-first-sight exit 999
    check "r1: first stable sight of the idle declaration is ONE plain stale wake" grep -Fxq "stale: $WINDOW" "$EV/live-$GROUP-r1-first-sight.out"
    check "r1: exactly one stale wake queued" [ "$(stale_wakes)" -eq 1 ]
    check "r1: not labelled a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r1-first-sight.out"
    check "r1: paused flag recorded" [ -e "$STATE/.paused-$KEY" ]
    check "r1: resurface throttle recorded" [ -e "$STATE/.paused-resurfaced-$KEY" ]
    check "r1: wedge timer not started" [ ! -e "$STATE/.stale-since-$KEY" ]
    ack || FAILS=$((FAILS + 1))
  else
    run_watch r1-no-first-sight absorb 999
    check "r1: a secondmate's standing declaration is absorbed from first sight (no plain wake)" [ "$RESULT" = alive ]
    check "r1: zero stale wakes" [ "$(stale_wakes)" -eq 0 ]
  fi
  tm send-keys -t "$WINDOW" 'x'  # a typed stray char echoes once, then the pane settles
  sleep 0.3
  pane_show
  run_watch r2-inside-cadence absorb 999
  check "r2: pane changed once and settled inside the cadence: watcher keeps absorbing" [ "$RESULT" = alive ]
  check "r2: no new stale wake inside the cadence" [ "$(stale_wakes)" -eq 0 ]
  [ -e "$STATE/.paused-resurfaced-$KEY" ] && backdate "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY"
  run_watch r3-cadence-recheck exit 240
  check "r3: declaration standing a whole cadence: bounded recheck fires" [ "$RESULT" = exited ]
  check "r3: exactly one recheck wake" [ "$(stale_wakes)" -eq 1 ]
  check "r3: recheck names the declared wait ('awaiting external')" grep -Fq 'awaiting external' "$EV/live-$GROUP-r3-cadence-recheck.out"
  check "r3: recheck says 'rechecked on a long cadence not a wedge'" grep -Fq 'rechecked on a long cadence not a wedge' "$EV/live-$GROUP-r3-cadence-recheck.out"
  check "r3: not a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r3-cadence-recheck.out"
  check "r3: wedge timer not started" [ ! -e "$STATE/.stale-since-$KEY" ]
  ack || FAILS=$((FAILS + 1))
  run_watch r4-cadence-holds absorb 240
  check "r4: the recheck just fired holds the next cadence (absorbing)" [ "$RESULT" = alive ]
  check "r4: no further wake" [ "$(stale_wakes)" -eq 0 ]
  ;;
ticking|held-ticking)
  pane_show
  run_watch r1-inside-cadence absorb 999
  check "r1: never-settling pane inside the cadence: watcher keeps absorbing" [ "$RESULT" = alive ]
  check "r1: zero stale wakes inside the cadence" [ "$(stale_wakes)" -eq 0 ]
  check "r1: unsettled hash kept no stale suppressor" [ ! -e "$STATE/.stale-$KEY" ]
  check "r1: wedge timer not started" [ ! -e "$STATE/.stale-since-$KEY" ]
  run_watch r2-cadence-recheck exit 240
  check "r2: declaration standing a whole cadence: bounded recheck fires on the ticking pane" [ "$RESULT" = exited ]
  check "r2: exactly one recheck wake" [ "$(stale_wakes)" -eq 1 ]
  if [ "$GROUP" = held-ticking ]; then
    check "r2: recheck names the captain ('awaiting the captain')" grep -Fq 'awaiting the captain' "$EV/live-$GROUP-r2-cadence-recheck.out"
  else
    check "r2: recheck names the declared wait ('awaiting external')" grep -Fq 'awaiting external' "$EV/live-$GROUP-r2-cadence-recheck.out"
  fi
  check "r2: not a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r2-cadence-recheck.out"
  ack || FAILS=$((FAILS + 1))
  pane_show
  run_watch r3-cadence-holds absorb 240
  check "r3: ticking pane after the recheck holds the next cadence (absorbing)" [ "$RESULT" = alive ]
  check "r3: no further wake" [ "$(stale_wakes)" -eq 0 ]
  ;;
until-ticking)
  pane_show
  run_watch r1-due-recheck exit 999
  check "r1: elapsed until on a never-settling pane is rechecked before the cadence" [ "$RESULT" = exited ]
  check "r1: exactly one wake" [ "$(stale_wakes)" -eq 1 ]
  check "r1: the wake says the declared clearing time has passed" grep -Fq 'declared clearing time has passed' "$EV/live-$GROUP-r1-due-recheck.out"
  check "r1: not a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r1-due-recheck.out"
  check "r1: recorded as the due recheck (:due)" sh -c "case \"\$(cat '$STATE/.paused-resurfaced-$KEY' 2>/dev/null)\" in *:due) exit 0;; *) exit 1;; esac"
  ack || FAILS=$((FAILS + 1))
  run_watch r2-once-per-declaration absorb 999
  check "r2: the same elapsed declaration does not recheck again (absorbing)" [ "$RESULT" = alive ]
  check "r2: no further wake" [ "$(stale_wakes)" -eq 0 ]
  ;;
until-settle)
  # The pane changes ONCE (a typed character) and then settles: the first sight
  # must stay the plain stale wake, not the due recheck.
  tm send-keys -t "$WINDOW" 'x'
  sleep 0.2
  pane_show
  run_watch r1-first-sight exit 999
  check "r1: pane that changed once and settled: plain first-sight wake" grep -Fxq "stale: $WINDOW" "$EV/live-$GROUP-r1-first-sight.out"
  check "r1: exactly one wake" [ "$(stale_wakes)" -eq 1 ]
  check "r1: the first sight is NOT the due recheck" not_grep -Fq 'declared clearing time has passed' "$EV/live-$GROUP-r1-first-sight.out"
  check "r1: not a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r1-first-sight.out"
  ack || FAILS=$((FAILS + 1))
  run_watch r2-after-first-sight exit 999
  echo "observational: after the plain first sight, the stable pane's elapsed until -> $(grep -c 'declared clearing time has passed' "$EV/live-$GROUP-r2-after-first-sight.out") due recheck line(s), result=$RESULT"
  ;;
busy)
  pane_show
  run_watch r1-busy-past-cadence absorb 240
  check "r1: a busy pane under a standing declaration never enters the stale path (absorbing)" [ "$RESULT" = alive ]
  check "r1: zero stale wakes even past the cadence" [ "$(stale_wakes)" -eq 0 ]
  check "r1: no pause tracking recorded for a busy pane" [ ! -e "$STATE/.paused-$KEY" ]
  check "r1: no stale suppressor recorded for a busy pane" [ ! -e "$STATE/.stale-$KEY" ]
  ;;
held-away)
  "${WENV[@]}" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null 2>&1; echo "away-posture record entered rc=$? ($(ls "$STATE" | grep -c afk) afk file(s))"
  pane_show
  run_watch r1-held-under-away absorb 240
  check "r1: captain-held under the away-posture record: never rechecked even past the cadence" [ "$RESULT" = alive ]
  check "r1: zero stale wakes" [ "$(stale_wakes)" -eq 0 ]
  "${WENV[@]}" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1; echo "away-posture record archived rc=$?"
  run_watch r2-held-after-archive exit 240
  check "r2: archiving the record restores the bounded recheck" [ "$RESULT" = exited ]
  check "r2: exactly one recheck wake" [ "$(stale_wakes)" -eq 1 ]
  check "r2: recheck names the captain" grep -Fq 'awaiting the captain' "$EV/live-$GROUP-r2-held-after-archive.out"
  check "r2: not a possible wedge" not_grep -Fq 'possible wedge' "$EV/live-$GROUP-r2-held-after-archive.out"
  ;;
esac

echo "=== GROUP $GROUP DONE: $FAILS check failure(s)"
exit "$FAILS"
