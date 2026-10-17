#!/usr/bin/env bash
# Live check for upstream issue 7280: a real Claude worker reads a long-running
# steer, records the scripted read receipt from its generated brief, and stays
# busy for ~4 minutes while the REAL fm-watch.sh daemon polls a disposable lab
# home. A second real Claude worker that is busy and never reads its steer must
# still raise the stuck-busy alarm.
# Usage: live-read-receipt.sh <worktree> <evidence-dir> <positive|negative>
set -u
ROOT=$1 EV=$2 MODE=$3
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
TD=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB") || exit 1
export TMUX_TMPDIR="$TD"
SHIM="$LAB/shim"; mkdir -p "$SHIM"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec %q -L fm-lab "$@"\n' "$REAL_TMUX" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
LOG="$EV/baseline/live-$MODE.log"
: > "$LOG"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
cleanup() {
  [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
  tmux kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
trap cleanup EXIT

TASK=rr-$MODE
FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" arbitrary-project-name --scout >/dev/null || { log "brief scaffold failed"; exit 1; }
BRIEF="$LAB/data/$TASK/brief.md"
# The worker receives the generated inbox section verbatim (generated public output).
awk '/^# Firstmate instruction inbox/{p=1} p&&/^# /&&!/inbox/{exit} p' "$BRIEF" > "$LAB/inbox-section.md"
cp "$LAB/inbox-section.md" "$EV/baseline/live-$MODE-generated-inbox-section.md"
log "generated inbox section:"; sed 's/^/    /' "$LAB/inbox-section.md" | tee -a "$LOG"
{
  echo "You are a firstmate worker in a live test. Follow this section of your brief exactly:"
  echo
  cat "$LAB/inbox-section.md"
  echo
  if [ "$MODE" = negative ]; then
    echo "Your task right now: run exactly the shell command 'timeout 200 tail -f /dev/null; echo waited' with the Bash tool in the foreground (not in the background; timeout 600000 ms), then reply 'waited'."
  else
    echo "There is no other task. Reply 'ready' and wait."
  fi
} > "$LAB/prompt.md"

tmux new-session -d -s lab -x 200 -y 50 -c '/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5598DH6TJ7W4HZVJMJZKJYV'
INBOX="$LAB/state/$TASK.inbox"
printf 'window=lab:fm-%s\nkind=scout\nharness=claude\nbackend=tmux\n' "$TASK" > "$LAB/state/$TASK.meta"
# The busy source fm-spawn.sh wires for a claude crewmate: arm a gen, then real
# Claude hooks apply busy on UserPromptSubmit and idle on Stop/StopFailure/SessionEnd.
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$TASK") || { log "busy arm failed"; exit 1; }
BUSY_PREFIX="'$ROOT/bin/fm-busy-event.sh' apply '$LAB/state' '$TASK'"
SUF="--gen '$GEN' --source claude-hook"
jq -n --arg s "$BUSY_PREFIX busy $SUF --event user-prompt-submit 2>/dev/null || true" \
  --arg st "$BUSY_PREFIX idle $SUF --event stop 2>/dev/null || true" \
  --arg sf "$BUSY_PREFIX idle $SUF --event stop-failure 2>/dev/null || true" \
  --arg se "$BUSY_PREFIX idle $SUF --event session-end 2>/dev/null || true" \
  '{feedbackDrafts:"off",hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:$s}]}],Stop:[{hooks:[{type:"command",command:$st}]}],StopFailure:[{hooks:[{type:"command",command:$sf}]}],SessionEnd:[{hooks:[{type:"command",command:$se}]}]}}' \
  > "$LAB/claude-settings.json"
tmux new-window -d -t lab: -n "fm-$TASK" -c '/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5598DH6TJ7W4HZVJMJZKJYV' -- bash -lc \
  "export FM_TASK_INBOX=$(printf '%q' "$INBOX"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions --settings $(printf '%q' "$LAB/claude-settings.json") \"\$(cat $(printf '%q' "$LAB/prompt.md"))\""
sleep 30
log "worker pane after startup:"; tmux capture-pane -p -t "lab:fm-$TASK" | grep '[^[:space:]]' | tail -8 | sed 's/^/    /' | tee -a "$LOG"

if [ "$MODE" = positive ]; then
  STEER="Long-running instruction: run exactly 'timeout 240 tail -f /dev/null; echo waited' with the Bash tool in the foreground, not in the background (timeout 600000 ms), then run 'touch $LAB/steer-done', then finish the inbox procedure for this message."
else
  STEER="Run 'touch $LAB/steer-done' and finish the inbox procedure."
fi
FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" "$STEER" >>"$LOG" 2>&1 || { log "fm-send failed"; exit 1; }
log "fm-send wrote $(ls "$INBOX")"

export FM_HOME="$LAB" FM_POLL=10 FM_TASK_INBOX_GRACE_SECS=20 FM_TASK_INBOX_BUSY_MAX=2
"$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>"$LAB/watch.err" &
WPID=$!
log "real fm-watch.sh started pid=$WPID (poll 10s, grace 20s, busy max 2 = defaults' shape)"
END=$((SECONDS + 300))
while [ "$SECONDS" -lt "$END" ]; do
  sleep 15
  st="msg=$( [ -f "$INBOX/001.msg" ] && echo pending || echo gone) read=$( [ -f "$INBOX/.read/001.msg" ] && echo yes || echo no) handled=$( [ -f "$INBOX/handled/001.msg" ] && echo yes || echo no) busy-state=$(cat "$INBOX/.busy-state" 2>/dev/null | tr '\t' ':') busy=$(bash -c '. "$1"; fm_busy_record_read "$2" "$3"' _ "$ROOT/bin/fm-busy-lib.sh" "$LAB/state" "$TASK" 2>/dev/null | cut -d' ' -f1-2) watcher=$(kill -0 $WPID 2>/dev/null && echo running || echo exited)"
  log "$st"
  kill -0 $WPID 2>/dev/null || break
  [ "$MODE" = positive ] && [ -f "$INBOX/handled/001.msg" ] && break
done
log "watcher stdout:"; sed 's/^/    /' "$LAB/watch.out" | tee -a "$LOG"
log "wake queue:"; sed 's/^/    /' "$LAB/state/.wake-queue" 2>/dev/null | tee -a "$LOG"
log "watcher stderr tail:"; tail -5 "$LAB/watch.err" | sed 's/^/    /' | tee -a "$LOG"
log "final worker pane:"; tmux capture-pane -p -t "lab:fm-$TASK" | grep '[^[:space:]]' | tail -25 | sed 's/^/    /' | tee -a "$LOG"
