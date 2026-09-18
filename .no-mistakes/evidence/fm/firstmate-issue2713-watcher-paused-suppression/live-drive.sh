#!/usr/bin/env bash
# live-drive.sh - drive the real bin/fm-watch.sh (and the real fm-crew-state.sh,
# fm-wake-drain.sh) against a real, isolated tmux server for issue 2713.
#
# Usage: live-drive.sh <tree-root> <case-label> <tmux-window> <status-line> \
#          <pause-resurface-secs> <observe-secs> [pre-observe-hook]
#
# Flow (what firstmate itself does):
#   1. The crew record points at a real tmux window; its status log ends in the
#      given declaration (paused: / captain-held / ...).
#   2. Arm the watcher. The fresh status line surfaces as a signal wake; drain
#      and ack it exactly as firstmate would, then re-arm.
#   3. Observe the re-armed watcher for <observe-secs>. Either it exits with a
#      wake reason (surfaced) or it keeps supervising (absorbed).
set -u
TREE=$1 LABEL=$2 WINDOW=$3 STATUS_LINE=$4 RESURFACE=$5 OBSERVE=$6 HOOK=${7:-}
RUN=$(cat /tmp/fmlive-run-path)
export TMUX_TMPDIR="$RUN/tmux"
unset TMUX
CASE="$RUN/cases/$LABEL"
rm -rf "$CASE"
STATE="$CASE/state"
mkdir -p "$STATE" "$CASE/home" "$CASE/worktree" "$RUN/fmroot"
TASK=parked
TARGET="fmlive:$WINDOW"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$TARGET" "$CASE/worktree" > "$STATE/$TASK.meta"
printf '%s\n' "$STATUS_LINE" > "$STATE/$TASK.status"

watch_env() {
  env FM_STATE_OVERRIDE="$STATE" FM_HOME="$CASE/home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_CREW_STATE_NO_FORGE=1 \
    FM_PAUSE_RESURFACE_SECS="$RESURFACE" "$@"
}
drain_ack() {
  local err="$CASE/drain.err" seq gen
  FM_ROOT_OVERRIDE="$RUN/fmroot" FM_STATE_OVERRIDE="$STATE" "$TREE/bin/fm-wake-drain.sh" > "$CASE/drain.out" 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_ROOT_OVERRIDE="$RUN/fmroot" FM_STATE_OVERRIDE="$STATE" "$TREE/bin/fm-wake-drain.sh" \
    --ack-through "$seq" --recovery-generation "$gen" > /dev/null 2>&1
}
# run_round <secs>: arm the watcher; print "EXIT <reason>" or "ALIVE".
run_round() {
  local secs=$1 out="$CASE/round.out" pid i=0
  watch_env "$TREE/bin/fm-watch.sh" > "$out" 2>> "$CASE/watch.err" &
  pid=$!
  while [ "$i" -lt "$((secs * 10))" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null
      printf 'EXIT %s\n' "$(tr '\n' ' ' < "$out")"
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf 'ALIVE\n'
}

echo "== case $LABEL  tree=$(basename "$TREE")  window=$TARGET"
echo "   status: $STATUS_LINE"
echo "   liveness (real backend): $(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$TREE" "$TARGET")"
echo "   crew-state (real):       $(FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_NO_FORGE=1 "$TREE/bin/fm-crew-state.sh" "$TASK" 2>/dev/null)"
r1=$(run_round 15)
echo "   round 1 (fresh status line): $r1"
if [ "${r1%% *}" = EXIT ]; then
  drain_ack && echo "   firstmate drained + acked round 1" || echo "   (nothing to ack)"
fi
[ -z "$HOOK" ] || { eval "$HOOK"; echo "   hook: $HOOK"; }
r2=$(run_round "$OBSERVE")
echo "   round 2 (re-armed, observed ${OBSERVE}s): $r2"
echo "   wake queue after round 2:"
awk -F '\t' '{ printf "     kind=%s key=%s payload=%s\n", $3, $4, $5 }' "$STATE/.wake-queue" 2>/dev/null | tail -3
echo "   triage log (stale lines):"
grep -i 'stale\|paused\|recheck' "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/     /' | tail -4
echo "   pause flag present: $([ -e "$STATE/.paused-fmlive_$WINDOW" ] && echo yes || echo no)"

# Optional third round: ROUND3_SECS=<n> [ROUND3_HOOK=<shell>] - ack whatever
# round 2 surfaced (as firstmate would), apply the hook, re-arm, observe.
if [ -n "${ROUND3_SECS:-}" ]; then
  if [ "${r2%% *}" = EXIT ]; then
    drain_ack && echo "   firstmate drained + acked round 2"
  fi
  [ -z "${ROUND3_HOOK:-}" ] || { eval "$ROUND3_HOOK"; echo "   hook before round 3: $ROUND3_HOOK"; }
  # Firstmate handles each non-stale wake (the downtime this driver caused by
  # killing round 2, or the new status line itself) by acking and re-arming.
  tries=0
  while :; do
    r3=$(run_round "$ROUND3_SECS")
    case "$r3" in
      "EXIT stale:"*|ALIVE) break ;;
    esac
    tries=$((tries + 1))
    [ "$tries" -le 3 ] || break
    echo "   round 3 surfaced a non-stale wake first ($r3); firstmate acks and re-arms"
    drain_ack
  done
  echo "   round 3 (re-armed, observed ${ROUND3_SECS}s): $r3"
  echo "   wake queue after round 3:"
  awk -F '\t' '{ printf "     kind=%s key=%s payload=%s\n", $3, $4, $5 }' "$STATE/.wake-queue" 2>/dev/null | tail -3
  echo "   triage log (last lines):"
  tail -3 "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/     /'
fi
