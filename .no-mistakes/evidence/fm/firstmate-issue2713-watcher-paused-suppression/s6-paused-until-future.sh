#!/usr/bin/env bash
# S6: an ordinary crew (dead agent, stable pane) whose paused: line carries a
# structured `until` 15 minutes ahead. Declared-until handling must be
# unchanged: the first sight is absorbed with no wake, and the until time
# cannot extend the 60s cadence, so one "declared time is beyond the recheck
# cadence" recheck fires once the declaration is 60s old.
SCENARIO=s6-paused-until-future
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-crew -c "$LAB/wt" bash
W=lab:fm-crew; KEY=$(window_key "$W"); T=crew
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 1
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$(agent_state "$W")"
UNTIL=$(date -u -d '+15 minutes' '+%Y-%m-%dT%H:%MZ')

declare_and_ack_signal "$T" "paused: waiting for the nightly build until $UNTIL"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

# The recheck time below proves the unreached until time absorbed the first sight.

round_expect_wake recheck 110 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 110s"
grep -Fq "beyond the recheck cadence" "$ROUND_OUT" || fail "recheck lacks the beyond-cadence wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "recheck mislabeled a wedge"
WAKE_EPOCH=$(tail -n1 "$STATE/.wake-queue" | cut -f1)
log "recheck fired $(( WAKE_EPOCH - STATUS_MTIME ))s after the declaration was written (cadence 60s, until $UNTIL)"
[ $(( WAKE_EPOCH - STATUS_MTIME )) -ge 60 ] || fail "recheck fired inside the cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "expected exactly 1 stale wake, got $(stale_wakes "$W")"
ack_cycle || fail "ack recheck"

round_expect_quiet after-recheck 30 FM_PAUSE_RESURFACE_SECS=60 || fail "re-alarmed inside the next cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "extra stale wakes queued"
log "wake queue (kind, window, reason):"; all_wakes | cut -f3- | tee -a "$SCENARIO_LOG"
log "RESULT: PASS"
