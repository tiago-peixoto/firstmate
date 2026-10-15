#!/usr/bin/env bash
# Live driver: real tmux server (private TMUX_TMPDIR), real fm-watch.sh, real fm-crew-state.sh.
set -u
WT=$1; EVID=$2
cd "$WT"
. tests/wake-helpers.sh >/dev/null 2>&1 || true
. bin/fm-classify-lib.sh
WATCH="$WT/bin/fm-watch.sh"; DRAIN="$WT/bin/fm-wake-drain.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
export TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB
STATE=$LAB/state
LOG=$EVID/live-transcript.txt; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() { tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
size_of() { LC_ALL=C wc -c < "$1" | tr -d "[:space:]"; }
set_mtime() { touch -d "@$1" "$2"; }
seen_sig() { printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$1")" "$(size_of "$1")" "$(_fm_open_decisions_file_ident "$1")"; }
ack() {
  local err=$STATE/.ack.err seq gen
  "$DRAIN" >/dev/null 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
mkdir -p "$LAB/agentbin"
printf '#!/usr/bin/env bash\nexec python3 -c "import ctypes,time; ctypes.CDLL(None).prctl(15, b\x27grok\x27, 0, 0, 0); time.sleep(99999)"\n' > "$LAB/agentbin/grok"; chmod +x "$LAB/agentbin/grok"
tmux new-session -d -s fmlab -n idle 'sleep 99999'
# <task> <pane-cmd> <status-line> <status-age-secs>
crew() {
  local task=$1 cmd=$2 line=$3 age=$4 sf=$STATE/$1.status
  tmux new-window -d -t fmlab: -n "$task" "$cmd"
  git init -q -b "fm/$task" "$LAB/projects/$task"
  printf 'window=fmlab:%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$task" "$LAB/projects/$task" > "$STATE/$task.meta"
  printf '%s\n' "$line" > "$sf"
  set_mtime "$(( $(date +%s) - age ))" "$sf"
  seen_sig "$sf" > "$STATE/.seen-${task}_status"
}
liveness() { ( . bin/fm-backend.sh; fm_backend_agent_alive tmux "fmlab:$1" ); }
# round <label> <resurface-secs> <max-secs>: run the real watcher; report exit vs survive.
round() {
  local label=$1 rs=$2 max=$3 out=$STATE/.round.out pid i=0
  : > "$out"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_PAUSE_RESURFACE_SECS=$rs "$WATCH" > "$out" 2>>"$STATE/.watch.err" &
  pid=$!
  while [ $i -lt $((max*10)) ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then kill $pid; wait $pid 2>/dev/null; say "[$label] watcher stayed running ${max}s (no wake)"; RES=survived
  else wait $pid; say "[$label] watcher exited with wake: $(tr '\n' ' ' < "$out")"; RES=exited; ack || say "  (ack failed)"; fi
}
only() { for f in "$STATE"/*.meta; do t=$(basename "$f" .meta); [ "$t" = "$1" ] || mv "$f" "$f.off"; done; [ -e "$STATE/$1.meta.off" ] && mv "$STATE/$1.meta.off" "$STATE/$1.meta"; }
key() { printf 'fmlab:%s' "$1" | tr ':/.' '___'; }
SC=$3
case "$SC" in
  alive|dead|unknown)
    case "$SC" in alive) cmd="$LAB/agentbin/grok" ;; dead) cmd="bash --norc --noprofile" ;; unknown) cmd="sleep 99999" ;; esac
    crew parked "$cmd" "paused: waiting on the upstream tool release" 30
    sleep 1
    say "=== scenario: ordinary crew, paused: declaration, agent liveness=$(liveness parked) (pane cmd: ${cmd##*/}), crew-state: $(bin/fm-crew-state.sh parked 2>&1) ==="
    round "first sight" 60 20
    k=$(key parked); say "  markers: $(cd "$STATE"; ls -a | grep -E "^\.(paused|stale)" | grep "$k" | tr '\n' ' ')"
    round "later sight inside cadence" 60 10
    set_mtime "$(( $(date +%s) - 120 ))" "$STATE/.paused-resurfaced-$k"
    say "  (backdated .paused-resurfaced-$k by 120s, cadence FM_PAUSE_RESURFACE_SECS=60)"
    round "sight after cadence elapsed" 60 20
    round "next sight inside new cadence" 60 10
    say "  wake-queue stale entries:"; [ -e "$STATE/.wake-queue" ] && awk -F '\t' '$3=="stale"{print "   ", $4, "|", $5}' "$STATE/.wake-queue" | tee -a "$LOG"
    ;;
  clock-fresh|clock-aged|clock-held-aged)
    line="paused: waiting on the validation run to finish"; age=30
    case "$SC" in clock-aged) age=500 ;; clock-held-aged) age=500; line="captain-held [key=route]: awaiting the captain on the routing call" ;; esac
    crew ticking "bash -c 'while :; do date +%H:%M:%S.%N; sleep 0.4; done'" "$line" "$age"
    sleep 1
    say "=== scenario: never-settling (clock) pane, status age ${age}s, line '$line', liveness=$(liveness ticking) ==="
    say "  pane sample 1: $(tmux capture-pane -p -t fmlab:ticking | grep . | tail -1)"; sleep 1
    say "  pane sample 2: $(tmux capture-pane -p -t fmlab:ticking | grep . | tail -1)"
    round "inside cadence (FM_PAUSE_RESURFACE_SECS=999)" 999 10
    if [ "$SC" != clock-fresh ]; then
      round "declaration has stood the cadence (FM_PAUSE_RESURFACE_SECS=240)" 240 20
      round "pane keeps ticking right after recheck" 240 10
    fi
    say "  wake-queue stale entries:"; [ -e "$STATE/.wake-queue" ] && awk -F '\t' '$3=="stale"{print "   ", $4, "|", $5}' "$STATE/.wake-queue" 2>/dev/null | tee -a "$LOG"
    ;;
  working)
    crew busy "bash -c 'printf \"thinking...  Ctrl+c:cancel\\n\"; exec $LAB/agentbin/grok'" "paused: waiting on the upstream tool release" 30
    sleep 1
    say "=== scenario: paused: declaration but pane shows grok busy signature, crew-state: $(FM_HOME=$LAB bin/fm-crew-state.sh busy 2>&1) ==="
    round "busy pane with standing pause" 60 12
    round "busy pane, next round" 60 12
    ;;
esac
