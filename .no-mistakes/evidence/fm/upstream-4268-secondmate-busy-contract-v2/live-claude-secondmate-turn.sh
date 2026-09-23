#!/usr/bin/env bash
# Live lab: a REAL Claude secondmate on a private tmux server, spawned through
# bin/fm-spawn.sh --secondmate, running real model turns. Samples the parent
# home's busy record through fm_busy_classify_meta (the same call the watcher's
# window_is_busy / secondmate_in_active_turn gate makes) while the mate works.
#
# Usage: live-claude-secondmate-turn.sh <root> <label> <guard-mode: current|old>
set -u
ROOT=$1 LABEL=$2 GUARD=$3
EVID=$(cd "$(dirname "$0")" && pwd)
LOG="$EVID/$LABEL.log"
SOCK="fm-lab-smbusy-$LABEL-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-smbusy.XXXXXX")
REAL_TMUX=$(command -v tmux)
: > "$LOG"
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

PRIMARY="$LAB/primary" SM="$LAB/sm" ID="sm-live"
mkdir -p "$PRIMARY"/{data,projects,state,config} "$LAB/shim"
touch "$PRIMARY/state/.last-watcher-beat"
printf 'claude\n' > "$PRIMARY/config/crew-harness"

# Secondmate home: the tracked guard + libs, the tracked Stop guard wiring only
# (no SessionStart / auto-arm, to keep the live turns small), a marker, a charter.
mkdir -p "$SM"/{data,state,config,projects,.claude}
cp -a "$ROOT/bin" "$SM/bin"
if [ "$GUARD" = old ]; then
  git -C "$ROOT" show 39f4c2af3a73d282b69ce5d7fde3dbb838f3494c:bin/fm-turnend-guard.sh > "$SM/bin/fm-turnend-guard.sh"
fi
jq '{hooks:{Stop:[{hooks:[.hooks.Stop[0].hooks[0]]}]}}' "$ROOT/.claude/settings.json" > "$SM/.claude/settings.json"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
printf "# Firstmate\nLab secondmate home.\n" > "$SM/AGENTS.md"
cat > "$SM/CLAUDE.md" <<'EOF'
# Lab secondmate
This is a throwaway test home. Keep every reply to one short line. Use tools only when a message explicitly asks for one.
EOF
cat > "$SM/data/charter.md" <<'EOF'
Reply with exactly the single word READY. Do not use any tools.
EOF
printf 'state/\n.fm-secondmate-home\n' > "$SM/.gitignore"
git -C "$SM" init -q -b main && git -C "$SM" add -A && \
  git -C "$SM" -c user.name=lab -c user.email=lab@example.invalid commit -qm seed

cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$LAB/shim/tmux"

# Private tmux server with a clean env and the real HOME (the real claude
# credentials). The parent session is created by fm-spawn itself.
env -i HOME="$HOME" USER="$USER" PATH="$PATH" TERM=xterm-256color LANG=C.UTF-8 \
  "$REAL_TMUX" -L "$SOCK" -f /dev/null new-session -d -s lab-scratch -x 200 -y 50

say "spawn: fm-spawn.sh $ID $SM claude --model haiku --secondmate (guard=$GUARD)"
env -u TMUX -u TMUX_PANE -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
  -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
  FM_BACKEND=tmux FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$PRIMARY" \
  FM_STATE_OVERRIDE="$PRIMARY/state" FM_DATA_OVERRIDE="$PRIMARY/data" \
  FM_PROJECTS_OVERRIDE="$PRIMARY/projects" FM_CONFIG_OVERRIDE="$PRIMARY/config" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 PATH="$LAB/shim:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SM" claude --model haiku --secondmate >>"$LOG" 2>&1
rc=$?; say "spawn rc=$rc"; [ "$rc" -eq 0 ] || exit 1

STATE="$PRIMARY/state"
META="$STATE/$ID.meta"
say "meta: $(tr '\n' ' ' < "$META")"
say "busy-gen: $(cat "$STATE/$ID.busy-gen" 2>/dev/null || echo MISSING)"
say "home .fm-busy-stop: $( [ -f "$SM/.fm-busy-stop" ] && tr '\n' ' ' < "$SM/.fm-busy-stop" || echo ABSENT)"
say "home settings.local.json hook events: $(jq -c '.hooks|keys' "$SM/.claude/settings.local.json")"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
TARGET=$(fm_backend_target_of_meta "$META")

sample() {  # <seconds> <tag>
  local n=0 verdict rec tail last=''
  while [ "$n" -lt "$1" ]; do
    tail=$(PATH="$LAB/shim:$PATH" fm_backend_capture tmux "$TARGET" 40 2>/dev/null || true)
    verdict=$(PATH="$LAB/shim:$PATH" fm_busy_classify_meta "$META" "$ID" "$STATE" "$tail")
    rec=$(tr "\n" " " 2>/dev/null < "$STATE/$ID.busy-state")
    if [ "$verdict|$rec" != "$last" ]; then
      say "[$2] gate verdict='$verdict' record='$rec' turn-ended=$( [ -e "$STATE/$ID.turn-ended" ] && echo PRESENT || echo absent)"
      last="$verdict|$rec"
    fi
    sleep 1
    n=$((n + 1))
  done
}
snap() { "$REAL_TMUX" -L "$SOCK" capture-pane -p -t "$TARGET" -S -25 > "$EVID/$LABEL-$1.pane.txt" 2>/dev/null; }

sample 75 turn1-launch-brief
snap after-turn1
say "send turn 2 (tmux send-keys): run sleep 20 via Bash"
"$REAL_TMUX" -L "$SOCK" send-keys -t "$TARGET" -l 'Use the Bash tool to run exactly: sleep 20 ; then reply DONE.'
sleep 1
"$REAL_TMUX" -L "$SOCK" send-keys -t "$TARGET" Enter
sample 12 turn2-early
snap mid-turn2
sample 60 turn2
snap after-turn2
say "final gate verdict: $(PATH="$LAB/shim:$PATH" fm_busy_classify_meta "$META" "$ID" "$STATE" "$(PATH="$LAB/shim:$PATH" fm_backend_capture tmux "$TARGET" 40)")"
say "parent turn-ended marker: $( [ -e "$STATE/$ID.turn-ended" ] && echo PRESENT || echo absent)"
