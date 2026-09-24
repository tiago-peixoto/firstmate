#!/usr/bin/env bash
# Live wedge-ladder driver for #4762: the real fm-watch.sh polls a real idle
# worker pane in a private tmux server whose status log ends in the answer the
# real fm-send --resolve-key default wrote after a keyless pause.
# Usage: drive-watch-live.sh <firstmate-root> <label> <scenario: answered|selfretract> [secs]
set -u
ROOT=$1; LABEL=$2; SCEN=$3; SECS=${4:-40}
SOCKET="fm4762w-$LABEL-$$"; SESSION=lab
LAB=$(mktemp -d /tmp/fm4762-watch.XXXXXX)
WPID=
cleanup() { [ -n "$WPID" ] && kill "$WPID" 2>/dev/null; tmux -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/wt" "$LAB/config"; REAL=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL" "$SOCKET" > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
printf "#!/usr/bin/env bash\nexec -a grok bash -c \"while :; do sleep 3600; done\"\n" > "$LAB/shim/grok"; chmod +x "$LAB/shim/grok"
export PATH="$LAB/shim:$PATH"
unset NO_MISTAKES_GATE
git -C "$LAB/home/wt" init -q
# The worker: a pane whose foreground process is named like a harness and that
# sits idle on a fixed screen, as a waiting worker does.
tmux new-session -d -s "$SESSION" -x 200 -y 50 -n fm-waiter "printf 'waiting on the vendor release\n'; exec $LAB/shim/grok"
task=waiter; state="$LAB/home/state"
printf 'window=%s:fm-waiter\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$SESSION" "$LAB/home/wt" > "$state/$task.meta"
if [ "$SCEN" = answered ]; then
  printf 'needs-decision: which color\npaused: waiting on the vendor release\n' > "$state/$task.status"
  ( cd "$LAB" && FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" "$ROOT/bin/fm-send.sh" "$task" --resolve-key default "blue" >/dev/null 2>&1 ) \
    || echo "fm-send failed"
else
  printf 'paused: waiting on the vendor release\nresolved: the vendor shipped\n' > "$state/$task.status"
fi
touch -d '-10 minutes' "$state/$task.status"
echo "== [$LABEL/$SCEN] status log fed to the watcher:"; sed 's/^/   | /' "$state/$task.status"
echo "-- worker pane: pane_current_command=$(tmux display -p -t "$SESSION:fm-waiter" '#{pane_current_command}')"
# Like the daemon, restart the watcher each time it exits on a wake, so the run
# covers the first signal wake and then the stale/wedge ladder that follows.
start=$(date +%s); runs=0
while [ $(( $(date +%s) - start )) -lt "$SECS" ]; do
  runs=$((runs+1))
  ( cd "$LAB" && FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$LAB/home" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$LAB/config" FM_WATCH_HANDLING_SUCCESSOR=1 FM_CREW_STATE_NO_FORGE=1 \
    FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 exec "$ROOT/bin/fm-watch.sh" ) >> "$LAB/watch.out" 2>&1 &
  WPID=$!
  while kill -0 "$WPID" 2>/dev/null && [ $(( $(date +%s) - start )) -lt "$SECS" ]; do sleep 1; done
  kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=
done
echo "-- watcher polled for ${SECS}s across $runs watcher run(s)"
echo "-- watcher stdout (wake lines):"; sed 's/^/   > /' "$LAB/watch.out" | head -20
echo "-- queued wakes:"; cut -f3- "$state/.wake-queue" 2>/dev/null | sed 's/^/   q /' || echo "   (none)"
echo "-- wedge escalation counter: $(cat "$state"/.wedge-escalations-* 2>/dev/null || echo none)"
echo "-- watcher triage log:"; cat "$state"/*triage*.log "$state"/.triage* 2>/dev/null | sed "s/^/   t /"
echo "-- pause / stale / wedge markers:"; ls -a "$state" | grep -E '^\.(paused|stale|wedge)' | sed 's/^/   marker /'
