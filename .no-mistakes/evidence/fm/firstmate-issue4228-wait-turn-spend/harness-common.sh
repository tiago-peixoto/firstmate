LIVE=/tmp/fm-live-4228
WT=/Users/tiago/.no-mistakes/worktrees/762e4773438f/01M2V4TQ3YJ4WXR8NT34T0G6TD
export PATH=$LIVE/shim:$PATH
H=$LIVE/home
export FM_HOME=$H FM_ROOT_OVERRIDE=$H FM_GATE_REFUSE_BYPASS=1
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
turns() { printf -- '--- stand-in agent turns (%s) ---\n' "$1"; cat "$LIVE/$1.turns" 2>/dev/null || echo '(none)'; }
pane() { printf -- '--- real tmux pane %s (capture-pane) ---\n' "$1"; tmux capture-pane -p -t "$1" | grep -v '^\s*$'; }
inbox() { printf -- '--- inbox %s ---\n' "$1"; (cd "$H/state/$1.inbox" 2>/dev/null && find . -type f | sort) || echo '(no inbox)'; }
# Firstmate's own watcher cycle: arm -> (wake) -> drain -> ack -> re-arm.
ARM_OUT=
arm() { ARM_OUT=$(mktemp $LIVE/arm.XXXX); FM_STATE_OVERRIDE=$FM_HOME/state $WT/bin/fm-watch-arm.sh > $ARM_OUT 2>&1 & APID=$!; sleep 2; echo "[$(date +%H:%M:%S)] armed: $(grep -m1 '^watcher:' $ARM_OUT)"; }
awake() { kill -0 $APID 2>/dev/null && return 1; wait $APID; return 0; }
drain_ack() {
  local out ack
  out=$($WT/bin/fm-wake-drain.sh 2>&1 | grep -v '^●')
  ack=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
  printf '%s\n' "$out" | grep -E '^(wake|signal|check|stale|OPEN DECISIONS|  )' | grep -v '^  *$' | head -12 | sed 's/^/    drain| /'
  [ -z "$ack" ] || $WT/bin/fm-wake-drain.sh $ack >/dev/null 2>&1
}
# Report whether the watcher woke firstmate; if so, handle it like firstmate and re-arm.
check_watch() {
  if awake; then
    echo "[$(date +%H:%M:%S)] watcher woke firstmate: $(grep -v '^watcher:' $ARM_OUT | grep -v '^●' | head -3 | tr '\n' ' ')"
    drain_ack; arm
  else
    echo "[$(date +%H:%M:%S)] watcher still supervising (no wake)"
  fi
}
disarm() { kill -TERM $APID 2>/dev/null; wait $APID 2>/dev/null; drain_ack >/dev/null; }
