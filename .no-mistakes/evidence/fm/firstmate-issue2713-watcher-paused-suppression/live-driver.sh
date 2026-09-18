#!/usr/bin/env bash
# Live driver: real fm-watch.sh + real fm-crew-state.sh + real isolated tmux server.
set -u
S=$1; BIN=$2; LABEL=$3; WIN=$4; STATUS=$5; AGE=${6:-0}; RESURFACE=${7:-999}; OBSERVE=${8:-12}; ARM3=${9:-}
export TMUX_TMPDIR=$S/tmux; unset TMUX
C=$S/cases/$LABEL; rm -rf "$C"; mkdir -p "$C/state" "$C/home/config"
st=$C/state; task=parked
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$WIN" "$S/wt" > "$st/$task.meta"
printf '%s\n' "$STATUS" > "$st/$task.status"
if [ "$AGE" -gt 0 ]; then touch -t "$(date -r $(( $(date +%s) - AGE )) +%Y%m%d%H%M.%S)" "$st/$task.status"; fi
envs=(FM_HOME="$C/home" FM_STATE_OVERRIDE="$st" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS="$RESURFACE")
run_watch() {  # <limit-secs> <outfile> -> prints exited|running
  local limit=$1 out=$2 pid i=0
  env "${envs[@]}" "$BIN/fm-watch.sh" > "$out" 2>>"$C/watch.err" &
  pid=$!
  while [ "$i" -lt $((limit * 10)) ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; echo exited; return; }
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; echo running
}
ack() {
  local err=$C/drain.err seq gen
  FM_STATE_OVERRIDE="$st" "$BIN/fm-wake-drain.sh" > "$C/drain.out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$st" "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
echo "=== [$LABEL] code=$(basename "$(dirname "$BIN")") window=$WIN liveness=$(cd "$BIN/.." && bash -c ". bin/fm-backend.sh; fm_backend_agent_alive tmux '$WIN'")"
echo "    pane foreground command: $(tmux display-message -p -t "$WIN" '#{pane_current_command}')"
echo "    last status line: $(tail -1 "$st/$task.status")  (status age ${AGE}s, FM_PAUSE_RESURFACE_SECS=$RESURFACE)"
r=$(run_watch 20 "$C/arm1.out")
echo "--- arm 1 (worker just declared the wait): watcher $r; printed: $(tr '\n' ' ' < "$C/arm1.out")"
drained=$(FM_STATE_OVERRIDE="$st" "$BIN/fm-wake-drain.sh" 2>/dev/null | tr '\n' ' '); ack
echo "    firstmate drained + acked: $drained"
r=$(run_watch "$OBSERVE" "$C/arm2.out")
echo "--- arm 2 (re-armed, pane left idle ${OBSERVE}s): watcher $r; printed: $(tr '\n' ' ' < "$C/arm2.out")"
echo "    wake queue rows: $(awk -F '\t' '{print $3" | "$5}' "$st/.wake-queue" 2>/dev/null | tr '\n' ';')"
echo "    triage log (stale lines):"; grep -i 'stale' "$st/.watch-triage.log" 2>/dev/null | sed 's/^/      /' | tail -5
key=$(printf '%s' "$WIN" | tr ':/.' '___')
echo "    pause flag .paused-$key: $([ -e "$st/.paused-$key" ] && echo present || echo absent); wedge timer .stale-since: $([ -e "$st/.stale-since-$key" ] && echo present || echo absent)"
if [ -n "$ARM3" ]; then
  ack; : > "$C/q.before"; cp "$st/.wake-queue" "$C/q.before" 2>/dev/null
  tmux send-keys -t "$WIN" -l "x" 2>/dev/null; sleep 1
  r=$(run_watch "$ARM3" "$C/arm3.out")
  echo "--- arm 3 (recheck acked, pane churned, re-armed ${ARM3}s): watcher $r; printed: $(tr '\n' ' ' < "$C/arm3.out")"
  echo "    wake queue rows now: $(awk -F '\t' '{print $3" | "$5}' "$st/.wake-queue" 2>/dev/null | tr '\n' ';')"
  echo "    pane after churn: $(tmux capture-pane -p -t "$WIN" | tr -s '\n' ' ')"
  echo "    triage log (last stale lines):"; grep -i 'stale' "$st/.watch-triage.log" 2>/dev/null | sed 's/^/      /' | tail -3
fi
[ -s "$C/watch.err" ] && { echo "    watcher stderr:"; sed 's/^/      /' "$C/watch.err" | tail -5; }
true
