#!/usr/bin/env bash
# S3: an ordinary crew whose pane runs the REAL claude CLI (alive agent, left
# parked at its workspace-trust dialog so no trust setting is written) with a
# paused: declaration on a stable idle pane. Expect the same one first-sight
# stale wake, then the bounded "awaiting external" recheck after the 60s
# cadence, then silence - liveness alive does not change the cadence.
SCENARIO=s3-alive-claude-paused-stable
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-crew -c "$LAB/wt" -e FM_HOME="$LAB" claude
W=lab:fm-crew; KEY=$(window_key "$W"); T=crew
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 12
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$(agent_state "$W")"
[ "$(agent_state "$W")" = alive ] || fail "fixture: expected an alive agent verdict"
ltmux capture-pane -p -t "$W" | grep -v '^[[:space:]]*$' > "$EV/$SCENARIO.pane.txt"
log "pane capture saved to $SCENARIO.pane.txt"

declare_and_ack_signal "$T" "paused: waiting on the upstream tool release"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

round_expect_wake first-sight 30 FM_PAUSE_RESURFACE_SECS=60 || fail "no first-sight wake"
grep -Fq "stale: $W" "$ROUND_OUT" || fail "first sight is not a stale wake"
grep -Fq "awaiting external" "$ROUND_OUT" && fail "first sight already used the recheck wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "first sight mislabeled a wedge"
[ -e "$STATE/.paused-resurfaced-$KEY" ] || fail "re-surface throttle missing after first sight"
[ ! -e "$STATE/.stale-since-$KEY" ] || fail "wedge timer started for a declared pause"
ack_cycle || fail "ack first sight"

round_expect_wake recheck 110 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 110s"
grep -Fq "awaiting external" "$ROUND_OUT" || fail "recheck lacks the external-wait wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "recheck mislabeled a wedge"
WAKE_EPOCH=$(tail -n1 "$STATE/.wake-queue" | cut -f1)
log "recheck fired $(( WAKE_EPOCH - STATUS_MTIME ))s after the declaration was written (cadence 60s)"
[ $(( WAKE_EPOCH - STATUS_MTIME )) -ge 60 ] || fail "recheck fired inside the cadence"
[ "$(stale_wakes "$W")" -eq 2 ] || fail "expected exactly 2 stale wakes, got $(stale_wakes "$W")"
ack_cycle || fail "ack recheck"

round_expect_quiet after-recheck 30 FM_PAUSE_RESURFACE_SECS=60 || fail "re-alarmed inside the next cadence"
[ "$(stale_wakes "$W")" -eq 2 ] || fail "extra stale wakes queued"
log "agent still alive at the end: $(agent_state "$W")"
log "wake queue (kind, window, reason):"; all_wakes | cut -f3- | tee -a "$SCENARIO_LOG"
log "RESULT: PASS"
