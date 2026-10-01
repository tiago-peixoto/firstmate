#!/usr/bin/env bash
# drive.sh <repo-root> <mode:alive|dead|unknown> <label>
set -u
REPO=$1 MODE=$2 LABEL=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
T="tmux -L fm-lab"
WORK=$(mktemp -d)
case $MODE in
  alive) CMD="cd $WORK && claude" ;;
  dead) CMD="bash --norc --noprofile" ;;
  unknown) CMD="sleep 99999" ;;
  churn) CMD="watch -n1 date +%T.%N" ;;
esac
$T new-session -d -s lab -n crew -x 160 -y 40 "$CMD"
sleep 8
SOCK=$($T display-message -p '#{socket_path}')
export TMUX="$SOCK,0,0"
WIN=lab:crew
STATE=$LAB/state
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$WIN" > "$STATE/crew.meta"
printf '%s\n' "${STATUS_LINE:-paused: waiting on the upstream validation run}" > "$STATE/crew.status"
echo "## [$LABEL] mode=$MODE window=$WIN agent_alive=$(. $REPO/bin/fm-backend.sh; fm_backend_agent_alive tmux $WIN)"
echo "## pane foreground: $($T display-message -p -t $WIN '#{pane_current_command}')"
run_round() {  # <label> <secs>
  local lbl=$1 secs=$2 pid i=0 before after
  before=$(cat "$STATE/.wake-queue" 2>/dev/null | wc -l || echo 0)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_PAUSE_RESURFACE_SECS=45 FM_STALE_ESCALATE_SECS=900 FM_WATCH_HANDLING_SUCCESSOR=1 \
    "$REPO/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1 &
  pid=$!
  while [ $i -lt $((secs*10)) ] && kill -0 $pid 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  if kill -0 $pid 2>/dev/null; then
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    echo "[$lbl t=$(date +%T)] watcher still running after ${secs}s: NO WAKE (absorbed)"
  else
    wait $pid
    echo "[$lbl t=$(date +%T)] watcher EXITED with wake:"
    tail -n +$((before+1)) "$STATE/.wake-queue" | cut -f3- | sed 's/^/    /'
    # acknowledge like firstmate does
    err=$LAB/drain.err
    FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" >/dev/null 2>"$err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
    gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -n "$seq" ] && FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  fi
}
run_round r1 12
run_round r2 12
run_round r3 12
run_round r4-within-cadence 12
echo "## sleeping until status age and throttle pass FM_PAUSE_RESURFACE_SECS=45"
sleep 30
run_round r5-after-cadence 15
run_round r6-after-resurface 10
echo "## state markers: $(ls -a $STATE | grep -E 'paused|stale' | tr '\n' ' ')"
echo "## triage log tail:"; grep -h 'absorbed stale\|stale' "$STATE"/.triage* 2>/dev/null | tail -8 | sed 's/^/    /'
$T kill-server 2>/dev/null
rm -rf "$LAB" "$WORK"
