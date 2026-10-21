#!/usr/bin/env bash
# S5: a kind=secondmate task with a paused: declaration on a stable idle pane
# (bare shell). Secondmate handling must be unchanged: no plain first-sight
# stale wake, the bounded "awaiting external" recheck once the 60s cadence
# has elapsed, then silence.
SCENARIO=s5-secondmate-paused
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-mate -c "$LAB/wt" bash
W=lab:fm-mate; KEY=$(window_key "$W"); T=mate
printf 'window=%s\nkind=secondmate\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 1
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$(agent_state "$W")"

declare_and_ack_signal "$T" "paused: waiting on the parent home to answer"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

# No first-sight wake for a mate: the recheck time below proves the first sight was absorbed.

round_expect_wake recheck 110 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 110s"
grep -Fq "awaiting external" "$ROUND_OUT" || fail "recheck lacks the external-wait wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "recheck mislabeled a wedge"
WAKE_EPOCH=$(tail -n1 "$STATE/.wake-queue" | cut -f1)
log "recheck fired $(( WAKE_EPOCH - STATUS_MTIME ))s after the declaration was written (cadence 60s)"
[ $(( WAKE_EPOCH - STATUS_MTIME )) -ge 60 ] || fail "recheck fired inside the cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "expected exactly 1 stale wake, got $(stale_wakes "$W")"
ack_cycle || fail "ack recheck"

round_expect_quiet after-recheck 30 FM_PAUSE_RESURFACE_SECS=60 || fail "re-alarmed inside the next cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "extra stale wakes queued"
log "wake queue (kind, window, reason):"; all_wakes | cut -f3- | tee -a "$SCENARIO_LOG"
log "RESULT: PASS"
