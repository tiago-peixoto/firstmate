#!/usr/bin/env bash
# Run the real watcher in the lab home for up to <secs>; acknowledge (as firstmate would) any wake it surfaces and restart it.
LAB=$1; WT=$2; SECS=$3
export TMUX_TMPDIR="$LAB/tmux" TMUX="$LAB/tmux/tmux-1000/fm-lab,0,0" FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
end=$(( $(date +%s) + SECS ))
while [ "$(date +%s)" -lt "$end" ]; do
  left=$(( end - $(date +%s) ))
  out=$(FM_POLL=5 FM_SIGNAL_GRACE=1 FM_TASK_INBOX_GRACE_SECS=5 timeout "$left" "$WT/bin/fm-watch.sh" 2>&1); rc=$?
  [ -n "$out" ] && echo "watcher wake: $out"
  [ "$rc" = 124 ] && break
  ack=$("$WT/bin/fm-wake-drain.sh" 2>&1 | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p')
  [ -n "$ack" ] && { eval "\"$WT/bin/fm-wake-drain.sh\" $ack" >/dev/null 2>&1; echo "  (acked wake: $ack)"; }
done
