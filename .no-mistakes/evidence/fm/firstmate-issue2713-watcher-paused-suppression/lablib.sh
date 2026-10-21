#!/usr/bin/env bash
# Driver helpers for live watcher scenarios, each against its own disposable
# lab home (bin/fm-lab-home.sh) with a private tmux server. Sourced by the
# scenario scripts in this evidence directory. The product under test is the
# real bin/fm-watch.sh, bin/fm-crew-state.sh and bin/fm-wake-drain.sh from
# the run worktree, reading a real tmux pane and a real status file.
set -u
EV=/home/firstmate/.no-mistakes/evidence/01M5ERSMJPYBVC52GHG90GZYEK
WT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5ERSMJPYBVC52GHG90GZYEK
WATCH="$WT/bin/fm-watch.sh"
DRAIN="$WT/bin/fm-wake-drain.sh"
SCENARIO=${SCENARIO:?set SCENARIO}
SCENARIO_LOG="$EV/$SCENARIO.log"
: > "$SCENARIO_LOG"

ts() { date -u '+%H:%M:%S'; }
log() { printf '[%s] %s\n' "$(ts)" "$*" | tee -a "$SCENARIO_LOG"; }
fail() { log "FAIL: $*"; teardown; exit 1; }

lab_create() {
  LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
  "$WT/bin/fm-lab-home.sh" create "$LAB" > /dev/null || exit 1
  mkdir -p "$LAB/tmux" "$LAB/wt" "$LAB/tangle-root"
  git -C "$LAB/wt" init -q
  git -C "$LAB/wt" -c user.email=lab@example.invalid -c user.name=lab commit -q --allow-empty -m init
  git -C "$LAB/wt" checkout -q --detach
  STATE="$LAB/state"
  log "lab home $LAB (private tmux socket dir $LAB/tmux)"
}

ltmux() { env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux "$@"; }

teardown() {
  stop_lab_watchers
  ltmux kill-server 2>/dev/null || true
  sleep 0.5
  rm -rf "$LAB"
  log "lab home removed"
}

# Start the real watcher against the lab home; echoes its pid.
watch_bg() {  # <out> [extra env assignments...]
  local out=$1; shift
  env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/tangle-root" \
    FM_POLL="${LAB_POLL:-1}" FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$WATCH" > "$out" 2> "$out.err" &
  echo $!
}

# Wait up to <secs> for <pid> to exit; 0 if exited, 1 if still alive.
wait_exit() {  # <pid> <secs>
  local pid=$1 limit=$(( ${2:-10} * 10 )) i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

stop_watch() { kill "$1" 2>/dev/null || true; wait_exit "$1" 10 || log "watcher $1 did not stop"; }

stop_lab_watchers() {
  local p
  for p in $(pgrep -f "$WATCH" 2>/dev/null); do
    if tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "FM_HOME=$LAB"; then kill "$p" 2>/dev/null || true; fi
  done
  sleep 0.3
}

# Acknowledge the surfaced wake through the real drain so the next watcher
# starts a clean cycle (mirrors tests/fm-watch-triage.test.sh ack_stopped_cycle).
ack_cycle() {
  local err="$LAB/drain.err" sequence generation
  # The drain trims acked rows from the queue; keep every row for the counts.
  cat "$STATE/.wake-queue" >> "$LAB/all-wakes" 2>/dev/null || true
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/tangle-root" "$DRAIN" > "$LAB/drain.out" 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || { cat "$err" >&2; return 1; }
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/tangle-root" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" > /dev/null
}

all_wakes() { cat "$LAB/all-wakes" "$STATE/.wake-queue" 2>/dev/null | sort -u -t "$(printf '\t')" -k2,2n; }
stale_wakes() {  # <window> -> count of stale wakes queued for it across the scenario
  all_wakes | awk -F '\t' -v w="$1" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }'
}

queue_tail() { tail -n "${1:-1}" "$STATE/.wake-queue" 2>/dev/null | cut -f3- ; }

window_key() { local k=${1//:/_}; k=${k//\//_}; printf '%s' "${k//./_}"; }

# Real liveness verdict of the pane from the product's own backend probe.
agent_state() {  # <window>
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$WT" "$1"
}

crew_state() {  # <task>
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$WT/bin/fm-crew-state.sh" "$1"
}

# Run one watcher round that must exit with a wake within <secs>; logs the
# reason. Sets ROUND_OUT and ROUND_SECS (wall-clock seconds until exit).
round_expect_wake() {  # <label> <secs> [env...]
  local label=$1 secs=$2 pid t0; shift 2
  ROUND_OUT="$LAB/$label.out"
  t0=$(date +%s)
  pid=$(watch_bg "$ROUND_OUT" "$@")
  if wait_exit "$pid" "$secs"; then
    ROUND_SECS=$(( $(date +%s) - t0 ))
    log "$label: watcher exited after ${ROUND_SECS}s with: $(cat "$ROUND_OUT")"
    [ ! -s "$ROUND_OUT.err" ] || log "$label stderr: $(cat "$ROUND_OUT.err")"
    return 0
  fi
  stop_watch "$pid"
  log "$label: watcher still alive after ${secs}s (no wake)"
  return 1
}

# Run one watcher round that must stay alive (absorb) for <secs>; returns 1 if
# it exited with a wake.
round_expect_quiet() {  # <label> <secs> [env...]
  local label=$1 secs=$2 pid; shift 2
  ROUND_OUT="$LAB/$label.out"
  pid=$(watch_bg "$ROUND_OUT" "$@")
  if wait_exit "$pid" "$secs"; then
    log "$label: watcher exited early with: $(cat "$ROUND_OUT")"
    [ ! -s "$ROUND_OUT.err" ] || log "$label stderr: $(cat "$ROUND_OUT.err")"
    return 1
  fi
  stop_watch "$pid"
  log "$label: watcher stayed quiet for ${secs}s"
  return 0
}

# The crew appends its declaration; the watcher's signal scan (upstream
# behaviour, unchanged here) surfaces that new line once; ack it so the stale
# path is what the scenario drives next.
declare_and_ack_signal() {  # <task> <line>
  printf '%s\n' "$2" >> "$STATE/$1.status"
  log "crew appended to $1.status: $2"
  round_expect_wake signal 30 || fail "the new status line was not signalled"
  grep -q "^signal: " "$ROUND_OUT" || fail "expected a signal wake first, got: $(cat "$ROUND_OUT")"
  ack_cycle || fail "could not ack the signal wake"
}
