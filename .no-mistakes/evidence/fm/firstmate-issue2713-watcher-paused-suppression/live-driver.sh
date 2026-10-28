#!/usr/bin/env bash
# Live driver: runs the real bin/fm-watch.sh against a real tmux pane on a
# private socket inside a disposable lab home. Every round starts the watcher
# the way bin/fm-watch-arm.sh would (same env knobs), waits for it to either
# wake (print a reason and exit) or survive whole poll cycles, and dumps the
# wake queue plus the pause markers so the transcript shows what happened.
set -u
ROOT=$1; LAB=$2; WINDOW=$3; RESURFACE=$4; MODE=$5; LABEL=$6
STATE="$LAB/state"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
out="$LAB/watch-round.out"; : > "$out"
beat="$STATE/.last-watcher-beat"; rm -f "$beat"
rows_before=$( [ -e "$STATE/.wake-queue" ] && wc -l < "$STATE/.wake-queue" || echo 0 )
echo "=== ROUND [$LABEL] mode=$MODE FM_PAUSE_RESURFACE_SECS=$RESURFACE status_age=$(( $(date +%s) - $(stat -c %Y "$STATE"/*.status) ))s"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
  FM_PAUSE_RESURFACE_SECS="$RESURFACE" "$ROOT/bin/fm-watch.sh" > "$out" 2> "$LAB/watch-round.err" &
pid=$!
result=
if [ "$MODE" = exit ]; then
  for _ in $(seq 1 200); do kill -0 "$pid" 2>/dev/null || { result=exited; break; }; sleep 0.1; done
  [ -n "$result" ] || { result=STILL-ALIVE-after-20s; kill "$pid" 2>/dev/null; }
else
  # absorb: require >= 3 beacon advances (3 completed poll cycles) with the watcher alive
  adv=0; first=; i=0
  while [ "$i" -lt 300 ] && [ "$adv" -lt 3 ]; do
    kill -0 "$pid" 2>/dev/null || { result="EXITED-early(after $adv cycles)"; break; }
    now=$(stat -c %Y "$beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$first" ]; then first=$now; adv=$((adv + 1)); fi
    sleep 0.1; i=$((i + 1))
  done
  [ -n "$result" ] || result="alive-through-$adv-poll-cycles"
  kill "$pid" 2>/dev/null
fi
wait "$pid" 2>/dev/null; rc=$?
echo "watcher: $result rc=$rc"
echo "stdout: $(cat "$out")"
[ -s "$LAB/watch-round.err" ] && echo "stderr: $(head -3 "$LAB/watch-round.err")"
rows_after=$( [ -e "$STATE/.wake-queue" ] && wc -l < "$STATE/.wake-queue" || echo 0 )
echo "wake-queue rows added: $(( rows_after - rows_before ))"
[ "$rows_after" -gt "$rows_before" ] && tail -n "$(( rows_after - rows_before ))" "$STATE/.wake-queue" | sed 's/^/  queue> /'
echo "markers: $(cd "$STATE" && ls -a | grep -E "^\.(stale|paused|wedge|stale-since|hash|count)-" | tr '\n' ' ')"
[ -e "$STATE/.stale-$KEY" ] && echo "  .stale-$KEY = $(cat "$STATE/.stale-$KEY")"
[ -e "$STATE/.paused-resurfaced-$KEY" ] && echo "  .paused-resurfaced-$KEY age=$(( $(date +%s) - $(stat -c %Y "$STATE/.paused-resurfaced-$KEY") ))s content=$(cat "$STATE/.paused-resurfaced-$KEY")"
echo
