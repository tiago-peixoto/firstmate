#!/usr/bin/env bash
# S1: an ordinary crew whose agent has EXITED (bare shell left in the pane)
# declares paused: on a stable idle pane. Expect one plain first-sight stale
# wake, silence inside the cadence, a bounded "awaiting external" recheck once
# FM_PAUSE_RESURFACE_SECS (60s here) has elapsed, then silence again.
SCENARIO=s1-dead-paused-stable
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-crew -c "$LAB/wt" bash
W=lab:fm-crew; KEY=$(window_key "$W"); T=crew
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 1
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$(agent_state "$W")"
[ "$(agent_state "$W")" = dead ] || fail "fixture: expected a dead agent verdict"

declare_and_ack_signal "$T" "paused: waiting on the upstream tool release"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

round_expect_wake first-sight 30 FM_PAUSE_RESURFACE_SECS=60 || fail "no first-sight wake"
grep -Fxq "stale: $W" "$ROUND_OUT" || fail "first sight is not the plain stale wake"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "first sight mislabeled a wedge"
[ -e "$STATE/.paused-$KEY" ] || fail "paused flag missing after first sight"
[ -e "$STATE/.paused-resurfaced-$KEY" ] || fail "re-surface throttle missing after first sight"
[ ! -e "$STATE/.stale-since-$KEY" ] || fail "wedge timer started for a declared pause"
log "markers after first sight: $(cd "$STATE" && ls -1 .paused-* .stale-* 2>/dev/null | tr '\n' ' ')"
ack_cycle || fail "ack first sight"

round_expect_wake recheck 110 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 110s"
grep -Fq "awaiting external" "$ROUND_OUT" || fail "recheck lacks the external-wait wording"
grep -Fq "rechecked on a long cadence not a wedge" "$ROUND_OUT" || fail "recheck lacks the cadence wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "recheck mislabeled a wedge"
WAKE_EPOCH=$(tail -n1 "$STATE/.wake-queue" | cut -f1)
log "recheck fired $(( WAKE_EPOCH - STATUS_MTIME ))s after the declaration was written (cadence 60s)"
[ $(( WAKE_EPOCH - STATUS_MTIME )) -ge 60 ] || fail "recheck fired inside the cadence"
[ "$(stale_wakes "$W")" -eq 2 ] || fail "expected exactly 2 stale wakes, got $(stale_wakes "$W")"
ack_cycle || fail "ack recheck"

round_expect_quiet after-recheck 30 FM_PAUSE_RESURFACE_SECS=60 || fail "re-alarmed inside the next cadence"
[ "$(stale_wakes "$W")" -eq 2 ] || fail "extra stale wakes queued"
log "wake queue (kind, window, reason):"; all_wakes | cut -f3- | tee -a "$SCENARIO_LOG"
log "RESULT: PASS"
