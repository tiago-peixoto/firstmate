#!/usr/bin/env bash
# Live driver: real interactive Codex in an isolated tmux server + throwaway FM_HOME/CODEX_HOME.
# Usage: codex-idle-live-driver.sh <owner|foreign|host> <observe-seconds>
set -u
MODE=$1; OBS=${2:-150}
ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M3Q3C9VS7TSGHXXGT8D7FM2W
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); chmod 700 "$LAB"
PROJECT=$LAB/project; H=$LAB/fmhome; CH=$LAB/codex-home; LOG=$LAB/hits; SRC=$LAB/source.sh
SOCK=fm-lab-codex-idle-$MODE-$$
FAKE=''
ts(){ date +%H:%M:%S; }
cleanup(){
  find "$CH" -name "*.jsonl" -path "*sessions*" -exec cp {} "$(dirname "$0")/live-$MODE-rollout.jsonl" \; 2>/dev/null
  [ -f "$LAB/allarm" ] && cp "$LAB/allarm" "$(dirname "$0")/live-$MODE-arm-outputs.txt"
  tmux -L "$SOCK" kill-server 2>/dev/null
  FM_HOME=$H "$ROOT/bin/fm-codex-idle-continuity.sh" --handover >/dev/null 2>&1
  FM_HOME=$H "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
  FM_HOME=$H "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
  [ -n "$FAKE" ] && kill "$FAKE" 2>/dev/null
  rm -rf "$LAB"
}
trap cleanup EXIT
hits(){ [ -f "$LOG" ] && wc -l <"$LOG" | tr -d ' ' || echo 0; }
idle(){ ! tmux -L "$SOCK" capture-pane -p -t s 2>/dev/null | grep -qF 'esc to interrupt'; }
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null; mkdir -p "$H/state" "$H/config" "$CH"; chmod 700 "$H" "$H/state"
git clone -q "$ROOT" "$PROJECT"
cp "$HOME/.codex/auth.json" "$CH/auth.json"
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$(cd "$PROJECT" && pwd -P)" > "$CH/config.toml"
printf '#!/bin/sh\nprintf "x\\n" >> %s\nsleep 20\n' "$LOG" > "$SRC"; chmod +x "$SRC"
if [ "$MODE" = foreign ]; then
  mkdir -p "$LAB/fakebin"; cp "$(command -v sleep)" "$LAB/fakebin/codex"
  "$LAB/fakebin/codex" 3600 & FAKE=$!
  sleep 0.3; printf '%s\n' "$FAKE" > "$H/state/.lock"
  echo "$(ts) foreign live harness-shaped owner pid=$FAKE comm=$(ps -o comm= -p $FAKE) written to state/.lock"
fi
[ "$MODE" = host ] && { touch "$H/config/supervision-host"; echo "$(ts) config/supervision-host created (opted in)"; }
tmux -L "$SOCK" new-session -d -s s -x 160 -y 45 -c "$PROJECT" -- env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  CODEX_HOME="$CH" FM_HOME="$H" FM_POLL=1 codex --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox \
  -c 'model_reasoning_effort="low"' 'Reply with exactly IDLE-OK. Do not call tools.'
CPID=$(tmux -L "$SOCK" display-message -p -t s '#{pane_pid}')
echo "$(ts) codex $(codex --version) pid=$CPID mode=$MODE"
for _ in $(seq 1 180); do idle && tmux -L "$SOCK" capture-pane -p -t s | grep -qE "^. IDLE-OK" && break; sleep 1; done
echo "$(ts) first turn idle; state/.lock=$(head -1 $H/state/.lock 2>/dev/null || echo none)"
FM_HOME=$H "$ROOT/bin/fm-procevent.sh" register lavish shot -- "$SRC" >/dev/null && FM_HOME=$H "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
echo "$(ts) registered ownerless source; hits=$(hits)"
tmux -L "$SOCK" send-keys -t s 'Reply with exactly OK2. Do not retire, register, or modify any process-event source; it is an intentional test fixture. Follow the normal wake drain protocol otherwise.'; sleep 1; tmux -L "$SOCK" send-keys -t s Enter
echo "$(ts) sent prompt OK2 (the only user prompt after startup)"
prev=''
for i in $(seq 1 "$OBS"); do
  kill -0 "$CPID" 2>/dev/null || { echo "$(ts) codex exited"; break; }
  own=$(cat "$H/state/.codex-idle-continuity.lock/owner" 2>/dev/null || echo -)
  sp=$(cat "$H/state/.codex-idle-continuity.lock/pid" 2>/dev/null || echo -)
  st=$(idle && echo idle || echo busy)
  line="turn=$st sup_owner=$own sup_pid=$sp lock=$(head -1 $H/state/.lock 2>/dev/null || echo none) hits=$(hits)"
  [ "$line" != "$prev" ] && echo "$(ts) $line"
  if [ -f "$H/state/.codex-idle-continuity.lock/arm.out" ]; then
    a=$(tail -2 "$H/state/.codex-idle-continuity.lock/arm.out" | tr '\n' '|')
    [ "$a" != "${pa:-}" ] && echo "$(ts)   supervisor arm.out: $a"; pa=$a
    cat "$H/state/.codex-idle-continuity.lock/arm.out" >> "$LAB/allarm" 2>/dev/null
  fi
  prev=$line; sleep 1
done
echo "---- idle-continuity log lines (state) ----"; ls -a "$H/state" | grep -i codex-idle
tmux -L "$SOCK" capture-pane -p -J -S - -t s > "$(dirname "$0")/live-$MODE-scrollback.txt"; echo "queued-into-thread user entries (› check:/signal:/stale:): $(grep -cE "^› (check|signal|stale|heartbeat)" "$(dirname "$0")/live-$MODE-scrollback.txt")"; echo "---- final pane ----"; tmux -L "$SOCK" capture-pane -p -t s | grep '[^[:space:]]' | tail -40
