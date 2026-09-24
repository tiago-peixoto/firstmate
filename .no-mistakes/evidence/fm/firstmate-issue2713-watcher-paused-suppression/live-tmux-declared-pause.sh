#!/usr/bin/env bash
# Live drive: real bin/fm-watch.sh against a real tmux pane (private TMUX_TMPDIR
# server) whose foreground process is named "claude", so the tmux backend's
# real liveness probe reports the agent ALIVE. The task declares `paused:`.
# Usage: live-tmux-declared-pause.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
W=$(mktemp -d /tmp/fmlive.XXXXXX); export TMUX_TMPDIR=$W/tmux; mkdir -p $TMUX_TMPDIR
STATE=$W/state; mkdir -p $STATE
tmux new-session -d -s lab -n fm-held -x 120 -y 30 "exec -a ${AGENT:-claude} sleep 600"
sleep 1
echo "== [$LABEL] pane foreground: $(tmux display -p -t lab:fm-held '#{pane_current_command}')"
( source "$ROOT/bin/fm-backend.sh"; echo "== [$LABEL] fm_backend_agent_alive tmux lab:fm-held -> $(fm_backend_agent_alive tmux lab:fm-held)" )
printf 'window=lab:fm-held\nkind=ship\nharness=claude\nbackend=tmux\n' > $STATE/held.meta
printf 'paused: holding for the upstream tool release\n' > $STATE/held.status
ack() {
  local err=$W/drain.err seq gen
  FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>$err
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' $err)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' $err)
  [ -n "$seq" ] && FM_STATE_OVERRIDE=$STATE "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
# Each watcher invocation exits on the first wake it surfaces; firstmate would
# then drain+ack and re-arm. Repeat for ~60s of wall time and record every wake.
end=$(( $(date +%s) + 60 ))
while [ "$(date +%s)" -lt "$end" ]; do
  FM_STATE_OVERRIDE=$STATE FM_PAUSE_RESURFACE_SECS=${RESURFACE:-999} FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout $(( end - $(date +%s) + 1 )) "$ROOT/bin/fm-watch.sh" > $W/out 2>>$W/err
  rc=$?
  [ -s $W/out ] && echo "== [$LABEL] t+$(( 60 - (end - $(date +%s)) ))s WAKE: $(cat $W/out)"
  [ "$rc" = 124 ] && break
  ack
done
echo "== [$LABEL] watcher still silent at end of window (rc=$rc; 124 = timed out polling, no further wake)"
echo "== [$LABEL] triage log tail:"; tail -n 15 $STATE/.watch-triage.log
echo "== [$LABEL] pause markers:"; ls -a $STATE | grep -E '^\.(paused|stale)' || echo none
tmux kill-server; rm -rf $W
