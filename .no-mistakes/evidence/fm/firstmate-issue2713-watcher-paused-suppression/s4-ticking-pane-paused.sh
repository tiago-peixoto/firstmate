#!/usr/bin/env bash
# S4: an ordinary crew whose pane never settles (a clock printing every 0.4s,
# so every poll sees a new hash) with a paused: declaration. Expect NO wake
# while the declaration is younger than the 60s cadence, exactly one bounded
# "awaiting external" recheck once it has stood a whole cadence, and silence
# again inside the next cadence. Adversarial for the former suppression: a
# never-stable hash used to hide both alerts.
SCENARIO=s4-ticking-pane-paused
. "$(dirname "$0")/lablib.sh"
lab_create
trap 'teardown' EXIT
ltmux new-session -d -s lab -n fm-crew -c "$LAB/wt" bash -c 'while :; do date +%T.%N; sleep 0.4; done'
W=lab:fm-crew; KEY=$(window_key "$W"); T=crew
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$W" "$LAB/wt" > "$STATE/$T.meta"
sleep 1
log "pane foreground: $(ltmux display-message -p -t "$W" '#{pane_current_command}') ; backend agent_state=$(agent_state "$W")"
A=$(ltmux capture-pane -p -t "$W" | md5sum); sleep 1.5; B=$(ltmux capture-pane -p -t "$W" | md5sum)
[ "$A" != "$B" ] || fail "fixture: pane did not change between captures"
log "pane hash changes between captures: $A -> $B"

declare_and_ack_signal "$T" "paused: waiting on the validation run to finish"
STATUS_MTIME=$(stat -c %Y "$STATE/$T.status")
log "crew-state now: $(crew_state "$T")"

# One round spans the whole first cadence: it must stay quiet until the
# declaration is 60s old, then fire exactly one recheck.
round_expect_wake first-cadence 120 FM_PAUSE_RESURFACE_SECS=60 || fail "no bounded recheck within 120s"
grep -Fq "awaiting external" "$ROUND_OUT" || fail "recheck lacks the external-wait wording"
grep -Fq "rechecked on a long cadence not a wedge" "$ROUND_OUT" || fail "recheck lacks the cadence wording"
grep -Fq "possible wedge" "$ROUND_OUT" && fail "recheck mislabeled a wedge"
WAKE_EPOCH=$(tail -n1 "$STATE/.wake-queue" | cut -f1)
log "recheck fired $(( WAKE_EPOCH - STATUS_MTIME ))s after the declaration was written (cadence 60s)"
[ $(( WAKE_EPOCH - STATUS_MTIME )) -ge 60 ] || fail "recheck fired inside the cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "expected exactly 1 stale wake, got $(stale_wakes "$W")"
[ ! -e "$STATE/.stale-$KEY" ] || log "note: a stale suppressor exists for the unsettled hash"
ack_cycle || fail "ack recheck"

round_expect_quiet next-cadence 40 FM_PAUSE_RESURFACE_SECS=60 || fail "rechecked again inside the cadence"
[ "$(stale_wakes "$W")" -eq 1 ] || fail "extra stale wakes queued"
log "wake queue (kind, window, reason):"; all_wakes | cut -f3- | tee -a "$SCENARIO_LOG"
log "RESULT: PASS"
