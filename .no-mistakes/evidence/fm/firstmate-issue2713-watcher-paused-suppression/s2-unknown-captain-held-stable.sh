#!/usr/bin/env bash
# S2: an ordinary crew whose pane foreground is neither a shell nor a known
# agent (bash running sleep), so the backend liveness verdict is ambiguous
# (unknown). It carries a captain-held declaration on a stable idle pane.
# Expect one plain first-sight stale wake, then a bounded "awaiting the
# captain" recheck once the 60s cadence has elapsed, then silence.
SCENARIO=s2-unknown-captain-held-stable
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-crew -c "$LAB/wt" bash -c 'echo waiting on the routing call; sleep 100000'
W=lab:fm-crew; KEY=$(window_key "$W"); T=crew
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 1
AS=$(agent_state "$W")
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$AS"
case "$AS" in alive|dead|missing) fail "fixture: expected an unknown-class liveness verdict, got $AS" ;; esac

declare_and_ack_signal "$T" "captain-held [key=route]: awaiting the captain on the routing call"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

round_expect_wake first-sight 30 FM_PAUSE_RESURFACE_SECS=60 || fail "no first-sight wake"
grep -Fxq "stale: $W" "$ROUND_OUT" || fail "first sight is not the plain stale wake"
[ -e "$STATE/.paused-resurfaced-$KEY" ] || fail "re-surface throttle missing after first sight"
[ ! -e "$STATE/.stale-since-$KEY" ] || fail "wedge timer started for a captain-held crew"
ack_cycle || fail "ack first sight"

round_expect_wake recheck 110 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 110s"
grep -Fq "awaiting the captain" "$ROUND_OUT" || fail "recheck lacks the captain-held wording"
grep -Fq "awaiting external" "$ROUND_OUT" && fail "captain-held recheck used the external-wait wording"
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
