#!/usr/bin/env bash
# Live drive: real bin/fm-watch.sh + real fm-crew-state.sh + real tmux server (isolated TMUX_TMPDIR).
# Usage: live-drive.sh <code-root> <label> <agent-comm|none> <status line> <resurface secs> <observe secs>
# Round 1 consumes the status-change signal wake (acked via real fm-wake-drain.sh),
# round 2 is one long-lived watcher: we record whether/when it wakes on the stale parked pane.
set -u
W=$1 label=$2 comm=$3 line=$4 resurf=$5 observe=$6
root=$(mktemp -d /tmp/fmlive.XXXX); state=$root/state; mkdir -p "$state"
export TMUX_TMPDIR=$root/tmuxsock; mkdir -p "$TMUX_TMPDIR"; unset TMUX
if [ "$comm" != none ]; then printf "int main(){for(;;)pause();}" > "$root/a.c"; cc -include unistd.h -o "$root/$comm" "$root/a.c"; cmd="$root/$comm"; else cmd="/bin/zsh -f"; fi
tmux new-session -d -s lab -n fm-held -x 120 -y 30 "$cmd"
sleep 1
echo "# [$label] code=$(git -C "$W" rev-parse --short HEAD 2>/dev/null || echo "$W") pane_current_command=$(tmux display -p -t lab:fm-held '#{pane_current_command}') status='$line' FM_PAUSE_RESURFACE_SECS=$resurf"
printf 'window=lab:fm-held\nkind=ship\nharness=grok\nbackend=tmux\n' > "$state/held.meta"
printf '%s\n' "$line" > "$state/held.status"
run() { FM_STATE_OVERRIDE="$state" FM_PAUSE_RESURFACE_SECS=$resurf FM_POLL=1 FM_SIGNAL_GRACE=1 \
        FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout "$1" "$W/bin/fm-watch.sh" 2>/dev/null; }
ack() { local err seq; err=$(FM_STATE_OVERRIDE="$state" "$W/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s' "$err" | sed -n 's/.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\).*/\1 \2/p')
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$state" "$W/bin/fm-wake-drain.sh" --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1; }
start=$(date +%s)
echo "t+0s round 1 (status signal): $(run 30)"; ack
s2=$(date +%s)
out=$(run "$observe"); rc=$?
t=$(( $(date +%s) - s2 ))
if [ -n "$out" ]; then echo "round 2: WAKE after ${t}s (status age ~$(( $(date +%s) - start ))s): $out"
else echo "round 2: no wake during ${t}s of polling (rc=$rc)"; fi
echo "# watcher triage log (pause decisions):"; grep -i -E "paus|stale|held|recheck" "$state/.watch-triage.log" 2>/dev/null | tail -8
tmux kill-server; rm -rf "$root"
