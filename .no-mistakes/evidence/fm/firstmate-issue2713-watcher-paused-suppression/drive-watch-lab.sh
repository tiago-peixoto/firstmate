#!/usr/bin/env bash
# drive-watch-lab.sh <src-root> <case-name> <pane-mode:alive|ambiguous|dead> <status-line> [aged]
# Stands up a disposable lab FM_HOME + private tmux server, one crew window whose
# real foreground process gives the requested liveness, a declared wait status,
# then runs the REAL bin/fm-watch.sh from <src-root> and reports whether it woke.
set -u
SRC=$1 NAME=$2 MODE=$3 STATUS=$4 AGED=${5:-}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/bin"
: # alive pane: exec -a grok gives the foreground process a harness argv0
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
case "$MODE" in
  alive) cmd="bash -c 'exec -a grok sleep 99999'" ;;
  ambiguous) cmd="sleep 99999" ;;
  dead) cmd="env PS1='$ ' bash --norc --noprofile" ;;
esac
tmux -f /dev/null new-session -d -s lab -n fm-held -x 120 -y 30 "$cmd"
sleep 1
STATE="$LAB/state"
printf 'window=lab:fm-held\nkind=ship\nharness=grok\nbackend=tmux\n' > "$STATE/held.meta"
printf '%s\n' "$STATUS" > "$STATE/held.status"
[ -z "$AGED" ] || touch -d "@$(( $(date +%s) - 2000 ))" "$STATE/held.status"
# Prime the status suppressor exactly as a supervisor that already read this line would.
( . "$SRC/bin/fm-classify-lib.sh"
  f="$STATE/held.status"
  printf 'v2\t%s\t%s@%s' "$(status_observed_signature "$f")" "$(LC_ALL=C wc -c < "$f" | tr -d ' ')" "$(_fm_open_decisions_file_ident "$f")" > "$STATE/.seen-held_status" )
. "$SRC/bin/fm-backend.sh"
echo "== case: $NAME  src=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "$SRC")"
echo "pane foreground: $(tmux display -p -t lab:fm-held '#{pane_current_command}')"
echo "fm_backend_agent_state: $(fm_backend_agent_state tmux lab:fm-held)  -> agent_alive: $(fm_backend_agent_alive tmux lab:fm-held)"
echo "status: $STATUS${AGED:+  (declared 2000s ago)}"
env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u NO_MISTAKES_GATE \
  FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_PAUSE_RESURFACE_SECS=999 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  FM_SECONDMATE_LIVENESS_SECS=999999 \
  "$SRC/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
pid=$!
i=0; while [ $i -lt 25 ] && kill -0 $pid 2>/dev/null; do sleep 1; i=$((i+1)); done
if kill -0 $pid 2>/dev/null; then echo "watcher: STILL RUNNING after ${i}s (no wake)"; kill $pid; wait $pid 2>/dev/null
else wait $pid; echo "watcher: EXITED after ${i}s rc=$? -> woke supervisor: $(cat "$LAB/watch.out")"; fi
echo "wake-queue:"; sed 's/^/  /' "$STATE/.wake-queue" 2>/dev/null || echo "  (empty)"
echo "pause markers: $(cd "$STATE" && ls -a | grep -E '^\.paused|^\.stale' | tr '\n' ' ')"
echo "triage log:"; grep -v '^$' "$STATE/.watch-triage.log" 2>/dev/null | grep -i 'stale\|pause\|held' | tail -5 | sed 's/^/  /'
tmux kill-server 2>/dev/null
rm -rf "$LAB"
echo
