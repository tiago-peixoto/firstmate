#!/usr/bin/env bash
# Live drive of the real bin/fm-watch.sh against a real private tmux lab server and
# lab FM_HOME. Usage: live-paused-watch.sh <liveness: dead|unknown|alive> [captain]
set -u
WT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M3K11ZY0HRKNK3B53BC8TCS1
MODE=$1; VERB=${2:-paused}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux" "$LAB/work"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
case "$MODE" in
  dead) CMD="env -i PS1='held\$ ' bash --norc --noprofile"; HARN=claude ;;
  unknown) CMD="sleep 100000"; HARN=claude ;;
  alive) CMD="claude"; HARN=claude ;;
esac
T new-session -d -s crew -n fm-held -c "$LAB/work" -x 120 -y 40 "$CMD"
sleep 3
SOCK=$(T display -p '#{socket_path}')
STATE="$LAB/state"; W="crew:fm-held"; KEY=crew_fm-held
printf 'window=%s\nkind=ship\nharness=%s\nbackend=tmux\n' "$W" "$HARN" > "$STATE/held.meta"
if [ "$VERB" = captain ]; then
  printf 'captain-held: needs captain sign-off on the release plan\n' > "$STATE/held.status"
else
  printf 'paused: waiting on upstream tool release\n' > "$STATE/held.status"
fi
echo "== lab=$LAB mode=$MODE verb=$VERB pane_cmd=$(T display -p -t "$W" '#{pane_current_command}')"
echo "== pane:"; T capture-pane -p -t "$W" | sed '/^$/d' | head -8
ack_queue() {
  if [ -s "$STATE/.wake-queue" ]; then
    local err="$LAB/d.err"
    env -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" > "$LAB/d.out" 2>"$err"
    sed 's/^/    queued: /' "$LAB/d.out"
    seq=$(sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation.*/\1/p' "$err"); gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -n "$seq" ] && env -u FM_STATE_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  fi
}
st() { echo "    t+$(( $(date +%s)-T0 ))s state: paused=$([ -e "$STATE/.paused-$KEY" ] && echo y || echo n) resurfaced=$([ -e "$STATE/.paused-resurfaced-$KEY" ] && echo y || echo n) wedge-timer(.stale-since)=$([ -e "$STATE/.stale-since-$KEY" ] && echo y || echo n)"; }
start_watch() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX="$SOCK,0,0" FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STALE_ESCALATE_SECS=6 FM_PAUSE_RESURFACE_SECS=25 ${EXTRA_ENV:-} \
    "$WT/bin/fm-watch.sh" > "$LAB/w.out" 2>"$LAB/w.err" &
  WPID=$!
}
# Run the real watcher for <secs>, re-arming after each wake exactly as firstmate does.
timeline() {  # <secs>
  local end=$(( $(date +%s) + $1 )) last=0
  start_watch
  while [ "$(date +%s)" -lt "$end" ]; do
    if ! kill -0 $WPID 2>/dev/null; then
      wait $WPID 2>/dev/null
      echo "[t+$(( $(date +%s)-T0 ))s] WAKE: $(tr '\n' ' ' < "$LAB/w.out")"
      ack_queue; st
      start_watch
    fi
    if [ $(( $(date +%s) - last )) -ge 5 ]; then st; last=$(date +%s); fi
    sleep 0.2
  done
  kill $WPID 2>/dev/null; wait $WPID 2>/dev/null
}
T0=$(date +%s)
if [ "${RESUME_WORK:-0}" = 1 ]; then
  timeline 40
  echo "== [t+$(( $(date +%s)-T0 ))s] crew resumes provable work (new pane output; crew-state reports working via run-step), no new status line"
  T send-keys -t "$W" 'echo running no-mistakes validation' Enter
  printf '#!/bin/sh\necho "state: working · source: run-step · validating (running)"\n' > "$LAB/cs.sh"; chmod +x "$LAB/cs.sh"
  rm -f "$STATE/.last-watcher-beat"
  EXTRA_ENV="FM_CREW_STATE_BIN=$LAB/cs.sh" timeline 12
  exit 0
fi
timeline ${DURATION:-70}
