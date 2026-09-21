#!/usr/bin/env bash
# Live drive: real fm-watch-checkpoint.sh against a real, isolated tmux server
# (private TMUX_TMPDIR) hosting a stand-in `pi` secondmate process.
# Usage: live-drive.sh <repo-root> <scenario: drains|ignores|busy|unknown> <workdir>
set -u
ROOT=$1 SCEN=$2 W=$3
rm -rf "$W"; mkdir -p "$W/state" "$W/mate/state" "$W/agentbin" "$W/tmux"
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$W/tmux"
state="$W/state" sub="$W/mate"
printf 'mate\n' > "$sub/.fm-secondmate-home"
printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=pi\nbackend=tmux\nhome=%s\n' "$sub" > "$state/mate.meta"
printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
cp "$sub/state/.wake-queue" "$W/foreign-before"
# Stand-in agent: comm is "pi" (direct #!/bin/bash, so the kernel names the
# process after the script). On each submitted line it logs the line and, in
# the drains scenario, runs its wake-handling turn: empties its own home's queue.
cat > "$W/agentbin/pi" <<AG
#!/bin/bash
printf 'pi (stand-in) - model kimi-coding/k3 - idle\n'
while IFS= read -r line; do
  printf '%s\n' "\$line" >> "$W/agent-received.log"
  if [ "$SCEN" = drains ]; then : > "$sub/state/.wake-queue"; echo "drained wake queue"; fi
done
AG
chmod +x "$W/agentbin/pi"
tmux new-session -d -s firstmate -n fm-mate -x 160 -y 40 "$W/agentbin/pi"
sleep 0.5
echo "pane_current_command=$(tmux display-message -p -t firstmate:fm-mate '#{pane_current_command}')"
[ "$SCEN" = unknown ] || "$ROOT/bin/fm-busy-event.sh" arm "$state" mate >/dev/null
if [ "$SCEN" = drains ] || [ "$SCEN" = ignores ]; then
  "$ROOT/bin/fm-busy-event.sh" apply "$state" mate idle --current-gen --source pi-ext --event agent_settled >/dev/null || echo "busy apply failed"
fi
# Fresh supervision beacon + empty instruction inbox, as in the incident.
mkdir -p "$state/mate.inbox"
run() { FM_HOME="$W" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" \
  FM_SECONDMATE_WAKE_STALL_SECS=3 FM_POLL=1 FM_SIGNAL_GRACE=0 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$1" > "$W/watch-$2.out" 2> "$W/watch-$2.err"; echo "checkpoint $2 rc=$?"; }
run 12 pass1
echo "--- watcher output pass1:"; cat "$W/watch-pass1.out"
if [ "$SCEN" = ignores ]; then run 12 pass2; echo "--- watcher output pass2:"; cat "$W/watch-pass2.out"; fi
echo "--- parent wake queue:"; cat "$state/.wake-queue" 2>/dev/null || echo "(none)"
echo "--- child wake queue now:"; cat "$sub/state/.wake-queue"; echo "(eof)"
cmp -s "$W/foreign-before" "$sub/state/.wake-queue" && echo "child queue byte-identical to before" || echo "child queue changed"
echo "--- ring marker: $(cat "$state/.secondmate-wake-ring-mate" 2>/dev/null || echo none)"
echo "--- inbox records:"; for f in "$state/mate.inbox/"*.msg "$state/mate.inbox/handled/"*.msg; do [ -f "$f" ] && { echo "# $f"; cat -A "$f" | head -20; }; done
echo "--- text the agent received in its pane:"; cat "$W/agent-received.log" 2>/dev/null || echo "(nothing typed)"
echo "--- pane capture:"; tmux capture-pane -p -t firstmate:fm-mate | sed '/^$/d'
echo "--- busy record: $(cat "$state/mate.busy-state" 2>/dev/null || echo none)"
tmux kill-server 2>/dev/null
