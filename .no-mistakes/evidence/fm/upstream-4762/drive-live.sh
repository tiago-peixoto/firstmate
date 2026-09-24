#!/usr/bin/env bash
# Live driver for #4762: a real idle worker pane in a private tmux server, a real
# FM_HOME, the real fm-send --resolve-key default answer, then the real
# fm-crew-state.sh read and the daemon's stale classification.
# Usage: drive-live.sh <firstmate-root> <label>
set -u
ROOT=$1; LABEL=$2
SOCKET="fm4762-$LABEL-$$"; SESSION=lab
LAB=$(mktemp -d /tmp/fm4762-lab.XXXXXX)
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
mkdir -p "$LAB/shim"; REAL=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL" "$SOCKET" > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
tmux new-session -d -s "$SESSION" -x 200 -y 50 -n fm-waiter bash --norc
unset NO_MISTAKES_GATE
# A real idle Claude worker for the pane-state half of fm-crew-state. The
# answer itself is sent while the meta points at the bare shell window, so the
# doorbell is not typed into Claude and the model never acts on the lab home.
tmux new-window -d -t "$SESSION:" -n fm-claude -c "${FM_LAB_CLAUDE_CWD:-$ROOT}" -- bash -lc \
  'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions'
sleep "${FM_LAB_CLAUDE_BOOT:-20}"
echo "-- idle Claude worker pane (fm-claude), last lines:"
tmux capture-pane -p -t "$SESSION:fm-claude" | grep '[^[:space:]]' | tail -4 | sed 's/^/   # /'
echo
run_case() {  # <task> <status-lines> <send-args...>
  local task=$1 lines=$2; shift 2
  local home="$LAB/home-$task"; mkdir -p "$home/state"
  mkdir -p "$home/wt"; git -C "$home/wt" init -q 2>/dev/null
  printf 'window=%s:fm-waiter\nkind=scout\nharness=%s\nbackend=tmux\nworktree=%s\n' "$SESSION" "${FM_LAB_HARNESS:-claude}" "$home/wt" > "$home/state/$task.meta"
  printf '%s\n' "$lines" > "$home/state/$task.status"
  echo "== [$LABEL] case $task"
  echo "-- status log before:"; sed 's/^/   | /' "$home/state/$task.status"
  if [ "$#" -gt 0 ]; then
    echo "-- \$ fm-send.sh $task $*"
    ( cd "$LAB" && FM_HOME="$home" FM_ROOT_OVERRIDE="$home" "$ROOT/bin/fm-send.sh" "$task" "$@" 2>&1; echo "exit=$?" ) | sed 's/^/   > /'
  fi
  echo "-- status log after:"; sed 's/^/   | /' "$home/state/$task.status"
  echo "-- declared-wait read (supervisor view):"
  ( . "$ROOT/bin/fm-classify-lib.sh"
    if declare -F status_declared_wait_line >/dev/null; then d=$(status_declared_wait_line "$home/state/$task.status")
    else d=$(last_status_line "$home/state/$task.status"); fi
    if status_is_paused_or_captain_held "$d"; then echo "   DECLARED WAIT: $d"; else echo "   NO DECLARED WAIT (line: ${d:-<none>})"; fi )
  echo "-- daemon classify_stale:"
  ( cd "$ROOT"; FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" FM_SUPERVISE_DAEMON_LIB_ONLY=1 \
      bash -c '. bin/fm-supervise-daemon.sh >/dev/null 2>&1; classify_stale "'"$SESSION"':fm-'"$task"'" "'"$home/state"'" "" 1' 2>&1 | sed 's/^/   /' ; echo )
  sed -i "s/^window=.*/window=$SESSION:fm-claude/" "$home/state/$task.meta"
  echo "-- \$ fm-crew-state.sh $task   (meta window now the idle Claude pane)"
  ( cd "$LAB" && FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$task" 2>&1 ) | sed 's/^/   /'
  echo
}
run_case colorwait $'needs-decision: which color\npaused: waiting on the vendor release' --resolve-key default "blue"
run_case selfretract $'paused: waiting on the vendor release\nresolved: the vendor shipped'
run_case legalkey $'needs-decision [key=legal]: which counsel\npaused: waiting on the vendor release' --resolve-key legal "acme llp"
run_case stateddefault $'paused [key=default]: named default wait\nneeds-decision: which color' --resolve-key default "blue"
