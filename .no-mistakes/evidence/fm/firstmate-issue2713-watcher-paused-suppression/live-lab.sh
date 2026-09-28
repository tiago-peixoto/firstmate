#!/usr/bin/env bash
# Live lab: real bin/fm-watch.sh + real fm-crew-state.sh + real tmux backend
# liveness probe, on a disposable lab FM_HOME and a private tmux server.
# Usage: live-lab.sh <repo> <scenario> <window-kind:ship|secondmate> <pane: alive|unknown|dead> <verb-line> [resurface-secs]
set -u
REPO=$1 SCEN=$2 KIND=$3 PANE=$4 VERB=$5 RS=${6:-25}
cd "$REPO"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
mkdir -p "$LAB/bin"
printf '#!/bin/bash\nwhile :; do read -r -t 3600 _ || true; done\n' > "$LAB/bin/grok"; chmod +x "$LAB/bin/grok"   # foreground comm 'grok' => agent alive
printf '#!/bin/bash\nn=0; while :; do n=$((n+1)); printf "grok idle, parked on external wait (tick %%s)\\n" "$n"; read -r -t 2 _ || true; done\n' > "$LAB/bin/grok-tick"; chmod +x "$LAB/bin/grok-tick"
T() { env -u TMUX TMUX_TMPDIR="$TD" tmux "$@"; }
cleanup() { T kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
case "$PANE" in
  alive)   cmd="printf 'grok idle, parked on external wait\n'; exec $LAB/bin/grok 99999" ;;
  unknown) cmd="printf 'something idle, parked on external wait\n'; exec tail -f /dev/null" ;;
  churn)   cmd="exec $LAB/bin/grok-tick" ;;
  dead)    cmd="printf 'agent exited; shell left\n'; exec bash --norc -i" ;;
esac
T new-session -d -s lab -n crew -x 120 -y 30 "bash -c \"$cmd\""
W=lab:crew
case "$KIND" in secondmate) h=claude ;; *) h=grok ;; esac
printf 'window=%s\nkind=%s\nharness=%s\nbackend=tmux\n' "$W" "$KIND" "$h" > "$LAB/state/t1.meta"
sleep 1
. bin/fm-backend.sh 2>/dev/null
echo "== scenario: $SCEN  kind=$KIND pane=$PANE resurface=${RS}s"
echo "== backend liveness probe: $(env -u TMUX TMUX_TMPDIR="$TD" bash -c ". bin/fm-backend.sh; fm_backend_agent_alive tmux $W")"
printf '%s\n' "$VERB" > "$LAB/state/t1.status"
DECL=$(date +%s)
echo "== t=0 appended status: $VERB"
run_watch() {  # keep one real watcher armed until <deadline>; log each wake and re-arm like the supervisor
  local deadline=$1 out="$LAB/watch.out" pid=
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -z "$pid" ]; then
      : > "$out"
      env -u TMUX -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
        TMUX_TMPDIR="$TD" FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
        FM_SECONDMATE_LIVENESS_SECS=99999999 FM_PAUSE_RESURFACE_SECS=$RS bin/fm-watch.sh > "$out" 2>"$LAB/watch.err" &
      pid=$!
    fi
    sleep 0.2
    if [ -n "${REPLACE_AT:-}" ] && [ -z "${replaced:-}" ] && [ $(( $(date +%s)-DECL )) -ge "$REPLACE_AT" ]; then
      printf '%s\n' "$REPLACE_LINE" >> "$LAB/state/t1.status"; replaced=1
      echo "   [t=$(( $(date +%s)-DECL ))s] appended replacement declaration: $REPLACE_LINE"
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      echo "   [t=$(( $(date +%s)-DECL ))s] WAKE: $(tr '\n' ' ' < "$out")"
      ack; pid=
    fi
  done
  [ -n "$pid" ] && { kill "$pid"; wait "$pid" 2>/dev/null; }
  echo "   [t=$(( $(date +%s)-DECL ))s] observation window closed"
  echo "== watcher triage log (absorb decisions):"
  cat "$LAB/state/.watch-triage.log" 2>/dev/null | grep -E "stale" | sed 's/^/   /' | awk '!seen[$0]++' | tail -8
}
ack() {
  local err="$LAB/drain.err" seq gen
  FM_HOME="$LAB" bin/fm-wake-drain.sh >/dev/null 2>"$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
echo "== pane:"; T capture-pane -p -t "$W" | sed '/^$/d;s/^/   | /'
run_watch $((DECL+RS+12))
echo "== end"
