#!/usr/bin/env bash
# Drive bin/fm-watch.sh against a real tmux server on a private socket inside a
# disposable lab home. Usage: lab-run.sh <phase> ; the lab path is kept in
# $EV/lab.path between phases and removed by the teardown phase.
set -u
ROOT=${LAB_ROOT:-/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5MRX3KG4WRKZ0G9F3GJYVGR}
EV=/home/firstmate/.no-mistakes/evidence/01M5MRX3KG4WRKZ0G9F3GJYVGR
cd "$ROOT" || exit 2
phase=$1
WINDOW=fmlab:crew
KEY=fmlab_crew
TASK=parked

lab() { cat "$EV/lab.path"; }
tm() { env -u TMUX TMUX_TMPDIR="$(lab)/tmux" tmux -L fm-lab "$@"; }
sock() { printf '%s/tmux/tmux-%s/fm-lab' "$(lab)" "$(id -u)"; }
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }
seen_sig() { printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$1")" "$(size_of "$1")" "$(_fm_open_decisions_file_ident "$1")"; }
backdate() { touch -m -d "@$1" "$2"; }

watch_env() {  # prints nothing; runs the watcher with lab-scoped env, extra assignments as args
  exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$(lab)/tmux" TMUX="$(sock),0,0" FM_HOME="$(lab)" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$ROOT/bin/fm-watch.sh"
}
# Run the watcher for up to <secs>; print "exited rc=<n> after <t>s" or "alive after <secs>s" and stop it.
run_watch() {  # <label> <secs> [env...]
  local label=$1 secs=$2; shift 2
  local out="$EV/lab-$label.out" err="$EV/lab-$label.err" pid i=0 rc
  watch_env "$@" > "$out" 2> "$err" &
  pid=$!
  while [ "$i" -lt "$((secs * 10))" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; echo "watcher[$label]: exited rc=$rc after $((i / 10))s"; return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  echo "watcher[$label]: still alive after ${secs}s (absorbing); stopping it"
  kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  i=0; while [ -e "$(state)/.watch.lock" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$(state)/.watch.lock" ] && echo "watcher[$label]: lock still held after stop"
  return 1
}
state() { printf '%s/state' "$(lab)"; }
show_state() {
  echo "--- state markers for $KEY"
  for f in .stale-$KEY .paused-$KEY .paused-resurfaced-$KEY .paused-rechecked-$KEY .stale-since-$KEY .wedge-escalations-$KEY .hash-$KEY .count-$KEY; do
    if [ -e "$(state)/$f" ]; then printf '%s = %q (age %ss)\n' "$f" "$(cat "$(state)/$f")" "$(( $(date +%s) - $(stat -c %Y "$(state)/$f") ))"; else echo "$f absent"; fi
  done
  echo "--- wake queue"; cat "$(state)/.wake-queue" 2>/dev/null || echo "(empty)"
  echo "--- triage log tail"; tail -n 8 "$(state)/.watch-triage.log" 2>/dev/null || ls "$(state)" | grep -i triage
}
ack() {  # acknowledge the stopped cycle so the next watcher does not re-announce it
  local err seq gen
  err=$(mktemp)
  FM_HOME="$(lab)" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$seq" ] && [ -n "$gen" ] || { echo "ack: nothing to acknowledge"; return 1; }
  FM_HOME="$(lab)" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" && echo "ack: through $seq"
}
declare_status() {  # <line> ; writes the status, ages it 500s, primes the seen marker
  printf '%s\n' "$1" > "$(state)/$TASK.status"
  backdate "$(( $(date +%s) - 500 ))" "$(state)/$TASK.status"
  seen_sig "$(state)/$TASK.status" > "$(state)/.seen-${TASK}_status"
  printf '%s' "$(seen_sig "$(state)/$TASK.status")" > "$(state)/.seen-${TASK}_status"
}

case "$phase" in
  setup)
    LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
    "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
    mkdir -p "$LAB/tmux"
    printf '%s' "$LAB" > "$EV/lab.path"
    tm new-session -d -s fmlab -n crew -x 100 -y 24 -c "$LAB" bash || exit 1
    sleep 1
    tm send-keys -t "$WINDOW" 'PS1="lab$ "; clear; echo "idle, holding for the upstream tool release"' Enter
    sleep 1
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$WINDOW" > "$LAB/state/$TASK.meta"
    declare_status 'paused: holding for the upstream tool release'
    echo "lab=$LAB"
    echo "--- real pane (tmux capture-pane on the private socket)"; tm capture-pane -p -t "$WINDOW" | sed '/^$/d'
    echo "--- pane_current_command: $(tm display-message -p -t "$WINDOW" '#{pane_current_command}')"
    echo "--- agent liveness as the backend sees it:"
    ( . "$ROOT/bin/fm-backend.sh" 2>/dev/null; env -u TMUX TMUX_TMPDIR="$LAB/tmux" TMUX="$(sock),0,0" bash -c '. "'"$ROOT"'/bin/fm-backend.sh"; fm_backend_agent_alive tmux "'"$WINDOW"'"; echo' )
    echo "--- real fm-crew-state.sh verdict:"
    env -u NO_MISTAKES_GATE TMUX_TMPDIR="$LAB/tmux" TMUX="$(sock),0,0" FM_HOME="$LAB" "$ROOT/bin/fm-crew-state.sh" "$TASK"
    ;;
  phase-a)   # first sight of the standing declaration on a stable pane, dead agent
    run_watch a 60 FM_PAUSE_RESURFACE_SECS=999
    echo "--- watcher stdout"; cat "$EV/lab-a.out"; echo "--- watcher stderr"; cat "$EV/lab-a.err"
    show_state
    ;;
  phase-b)   # same pane, same declaration: bounded recheck once the throttle has aged a whole cadence
    ack || exit 1
    backdate "$(( $(date +%s) - 500 ))" "$(state)/.paused-resurfaced-$KEY"
    echo "--- real pane unchanged:"; tm capture-pane -p -t "$WINDOW" | sed '/^$/d'
    run_watch b 60 FM_PAUSE_RESURFACE_SECS=240
    echo "--- watcher stdout"; cat "$EV/lab-b.out"; echo "--- watcher stderr"; cat "$EV/lab-b.err"
    show_state
    ;;
  phase-b2)  # same pane again inside the cadence: no second wake
    ack || exit 1
    run_watch b2 12 FM_PAUSE_RESURFACE_SECS=240
    echo "--- watcher stdout"; cat "$EV/lab-b2.out"; echo "--- watcher stderr"; cat "$EV/lab-b2.err"
    show_state
    ;;
  phase-c)   # dead agent, until a year away: absorbed inside the cadence, rechecked once past it
    ack >/dev/null 2>&1 || true
    rm -f "$(state)"/.paused-$KEY "$(state)"/.paused-resurfaced-$KEY "$(state)"/.paused-rechecked-$KEY "$(state)"/.stale-$KEY "$(state)"/.hash-$KEY "$(state)"/.count-$KEY "$(state)"/.wake-queue
    declare_status 'paused: provider rate limit, resume until 2027-10-23T00:00Z'
    echo "--- declaration: $(cat "$(state)/$TASK.status") (status age $(( $(date +%s) - $(stat -c %Y "$(state)/$TASK.status") ))s)"
    run_watch c1 12 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=999
    echo "--- inside the cadence: stdout"; cat "$EV/lab-c1.out"; echo "--- stderr"; cat "$EV/lab-c1.err"
    show_state
    run_watch c2 60 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=240
    echo "--- past the cadence: stdout"; cat "$EV/lab-c2.out"; echo "--- stderr"; cat "$EV/lab-c2.err"
    show_state
    ;;
  phase-d)   # a pane whose hash changes every poll (a clock): quiet inside the cadence, one recheck past it
    ack >/dev/null 2>&1 || true
    rm -f "$(state)"/.paused-$KEY "$(state)"/.paused-resurfaced-$KEY "$(state)"/.paused-rechecked-$KEY "$(state)"/.stale-$KEY "$(state)"/.hash-$KEY "$(state)"/.count-$KEY "$(state)"/.wake-queue
    declare_status 'paused: waiting on the validation run to finish'
    tm send-keys -t "$WINDOW" 'clear; while :; do date +%T.%N; sleep 0.3; done' Enter
    sleep 1
    echo "--- real pane now ticks:"; tm capture-pane -p -t "$WINDOW" | sed '/^$/d' | tail -3
    echo "--- pane_current_command: $(tm display-message -p -t "$WINDOW" '#{pane_current_command}')"
    # count real crew-state reads through a logging wrapper around the real helper
    cat > "$(lab)/crew-state-counted.sh" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FM_LAB_CREW_STATE_LOG"
exec "$FM_LAB_REAL_CREW_STATE" "$@"
SH
    chmod +x "$(lab)/crew-state-counted.sh"
    : > "$(lab)/crew-state.calls"
    run_watch d1 15 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=999 FM_CREW_STATE_BIN="$(lab)/crew-state-counted.sh" FM_LAB_CREW_STATE_LOG="$(lab)/crew-state.calls" FM_LAB_REAL_CREW_STATE="$ROOT/bin/fm-crew-state.sh"
    echo "--- inside the cadence: stdout"; cat "$EV/lab-d1.out"; echo "--- stderr"; cat "$EV/lab-d1.err"
    echo "--- polls completed (beacon) vs crew-state reads: reads=$(wc -l < "$(lab)/crew-state.calls")"
    show_state
    run_watch d2 60 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=240
    echo "--- past the cadence: stdout"; cat "$EV/lab-d2.out"; echo "--- stderr"; cat "$EV/lab-d2.err"
    show_state
    ack || exit 1
    run_watch d3 15 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=240
    echo "--- after the recheck, still ticking: stdout"; cat "$EV/lab-d3.out"; echo "--- stderr"; cat "$EV/lab-d3.err"
    show_state
    tm send-keys -t "$WINDOW" C-c
    ;;
  phase-d1)  # ticking pane inside the cadence only: count real crew-state reads per poll (LAB_ROOT selects the tree)
    ack >/dev/null 2>&1 || true
    rm -f "$(state)"/.paused-$KEY "$(state)"/.paused-resurfaced-$KEY "$(state)"/.paused-rechecked-$KEY "$(state)"/.stale-$KEY "$(state)"/.hash-$KEY "$(state)"/.count-$KEY "$(state)"/.wake-queue "$(state)"/.watch-triage.log
    declare_status 'paused: waiting on the validation run to finish'
    tm send-keys -t "$WINDOW" 'clear; while :; do date +%T.%N; sleep 0.3; done' Enter
    sleep 1
    cat > "$(lab)/crew-state-counted.sh" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FM_LAB_CREW_STATE_LOG"
exec "$FM_LAB_REAL_CREW_STATE" "$@"
SH
    chmod +x "$(lab)/crew-state-counted.sh"
    : > "$(lab)/crew-state.calls"
    run_watch "d1-${LAB_TAG:-target}" 20 FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=999 FM_CREW_STATE_BIN="$(lab)/crew-state-counted.sh" FM_LAB_CREW_STATE_LOG="$(lab)/crew-state.calls" FM_LAB_REAL_CREW_STATE="$ROOT/bin/fm-crew-state.sh"
    echo "--- tree: $ROOT"; echo "--- stdout"; cat "$EV/lab-d1-${LAB_TAG:-target}.out"; echo "--- stderr"; cat "$EV/lab-d1-${LAB_TAG:-target}.err"
    echo "--- polls (triage-log absorb lines): $(grep -c 'absorbed' "$(state)/.watch-triage.log" 2>/dev/null) ; crew-state reads: $(wc -l < "$(lab)/crew-state.calls")"
    show_state
    tm send-keys -t "$WINDOW" C-c
    ;;
  teardown)
    tm kill-server 2>/dev/null
    rm -rf "$(lab)"
    rm -f "$EV/lab.path"
    echo "lab removed"
    ;;
  *) echo "unknown phase $phase"; exit 2 ;;
esac
