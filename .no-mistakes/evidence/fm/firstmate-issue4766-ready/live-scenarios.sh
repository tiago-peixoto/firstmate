# Scenarios for live-harness.sh (sourced). Each prints a transcript.

# Issue 4766's headline: a held lane whose last line is `paused:` keeps hitting
# the declared-wait recheck cadence while the captain is away. The worker has
# stopped (bare shell in its pane).
scenario_away_paused_held() {
  export FM_PAUSE_RESURFACE_SECS=5
  LANE_AGE=60 add_lane sample-held ship dead \
    "working: implementing the sample" \
    "paused: waiting on the sample upstream release"
  captain hold sample-held --reason "operator review pending"
  show_status sample-held
  away_on
  say "supervising for 30s (declared-wait recheck cadence FM_PAUSE_RESURFACE_SECS=5)"
  supervise 30
  say "RESULT: wakes naming the held lane while away: $(wake_count 'sample-held')"
  triage_tail fm-sample-held 2
}

# Always-on posture: the held lane's recheck names the captain, and once the
# captain answers with --release (worker still stopped), the lane stops asking
# for an answer and reads as the worker's own pause again.
scenario_release_stopped_paused() {
  export FM_PAUSE_RESURFACE_SECS=5
  LANE_AGE=60 add_lane sample-parked ship dead \
    "paused: waiting on the sample upstream release"
  captain hold sample-parked --reason "operator review pending"
  show_status sample-parked
  say "supervising for 14s while held (always-on, cadence 5s)"
  supervise 14
  printf 'Proceed as planned.\n' > "$SCR/go.txt"
  captain answer sample-parked --decision-file "$SCR/go.txt" --release
  show_status sample-parked
  : > "$SCR/wakes-before"; cp "$WAKES" "$SCR/wakes-before"; : > "$WAKES"
  say "supervising for 14s after the release (worker never came back)"
  supervise 14
  say "RESULT held phase: $(grep -cF 'answer the held decision' "$SCR/wakes-before") wake(s) asking for the captain's answer, $(grep -cF 'awaiting external' "$SCR/wakes-before") wake(s) calling it an external wait"
  say "RESULT released phase: $(wake_count 'answer the held decision') wake(s) asking for the captain's answer, $(wake_count 'awaiting external') wake(s) calling it an external wait"
}

# The issue's "leftover hold-status line": the skill's order is hold the work
# item, then `complete` transfers the worker's open question to it, which
# leaves `captain-held [key=route]: tracked by <id>` on the stopped worker's
# log. After the captain answers, nothing the worker writes can retract it.
scenario_transfer_leftover_stopped() {
  export FM_PAUSE_RESURFACE_SECS=5
  LANE_AGE=60 add_lane sample-scout scout dead \
    "done: report ready" \
    "needs-decision [key=route]: choose route north or route south"
  captain hold sample-scout --reason "route choice pending"
  captain complete sample-scout sample-scout
  show_status sample-scout
  say "supervising for 12s while the call is open (always-on, cadence 5s)"
  supervise 12
  printf 'Take route north.\n' > "$SCR/north.txt"
  captain answer sample-scout --decision-file "$SCR/north.txt"
  show_status sample-scout
  cp "$WAKES" "$SCR/wakes-before"; : > "$WAKES"
  say "supervising for 18s after the captain answered (worker never came back)"
  supervise 18
  say "RESULT open phase: $(grep -cF 'answer the held decision' "$SCR/wakes-before") wake(s) asking for the captain's answer"
  say "RESULT answered phase: $(wake_count 'answer the held decision') wake(s) still asking for the captain's answer"
}

# The mirror lines are firstmate's own bookkeeping: recording a hold or its
# release must not wake the session that recorded it - including the hold that
# creates a lane's first status log. Control: a real worker append to the same
# log does wake the same watcher.
scenario_no_self_wake() {
  export FM_PAUSE_RESURFACE_SECS=999
  local tick="bash --noprofile --norc -c 'while :; do date +%s; sleep 1; done'"
  add_lane sample-quiet ship dead "working: implementing the sample"
  tmux respawn-window -k -t firstmate:fm-sample-quiet "$tick"
  add_lane sample-fresh ship dead
  tmux respawn-window -k -t firstmate:fm-sample-fresh "$tick"
  [ -e "$STATE/sample-fresh.status" ] || say "sample-fresh has no status log yet"
  "$CODE/bin/fm-watch-arm.sh" > "$SCR/arm.out" 2>&1 &
  ARM_PID=$!
  sleep 5
  say "watcher armed: $(head -1 "$SCR/arm.out")"
  captain hold sample-quiet --reason "operator review pending"
  captain hold sample-fresh --reason "operator review pending"
  show_status sample-quiet; show_status sample-fresh
  sleep 6
  kill -0 "$ARM_PID" 2>/dev/null && say "after both holds: watcher still armed, no wake ($(sed -n '2,$p' "$SCR/arm.out" | wc -l | tr -d ' ') extra output lines)" \
    || say "after both holds: WATCHER WOKE: $(cat "$SCR/arm.out")"
  printf 'Proceed.\n' > "$SCR/go.txt"
  captain answer sample-quiet --decision-file "$SCR/go.txt" --release
  captain answer sample-fresh --decision-file "$SCR/go.txt" --release
  show_status sample-quiet; show_status sample-fresh
  sleep 6
  kill -0 "$ARM_PID" 2>/dev/null && say "after both releases: watcher still armed, no wake" \
    || say "after both releases: WATCHER WOKE: $(cat "$SCR/arm.out")"
  say "control: the worker itself appends a needs-decision line to sample-quiet"
  printf 'needs-decision [key=scope]: pick the sample scope\n' >> "$STATE/sample-quiet.status"
  local i=0
  while kill -0 "$ARM_PID" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.5; i=$((i + 1)); done
  wait "$ARM_PID" 2>/dev/null
  say "control wake: $(sed -n '2,$p' "$SCR/arm.out")"
  ARM_PID=
}

# A delivered lane (live agent, idle pane) is held for merge approval and then
# released: after the release it must stay inert - no re-surface and no
# possible-wedge escalation.
scenario_delivered_hold_release() {
  export FM_STALE_ESCALATE_SECS=3 FM_PAUSE_RESURFACE_SECS=999
  LANE_HARNESS=grok add_lane sample-delivered ship live "done: PR https://example.test/pull/1 checks green"
  say "supervising 8s: the delivery's first terminal stale surfaces once"
  supervise 8
  captain hold sample-delivered --reason "merge approval"
  say "supervising 8s while held"
  supervise 8
  printf 'Merge it.\n' > "$SCR/merge.txt"
  captain answer sample-delivered --decision-file "$SCR/merge.txt" --release
  show_status sample-delivered
  cp "$WAKES" "$SCR/wakes-before"; : > "$WAKES"
  say "supervising 20s after the release (FM_STALE_ESCALATE_SECS=3)"
  supervise 20
  say "RESULT before release: $(grep -cF 'fm-sample-delivered' "$SCR/wakes-before") wake(s)"
  say "RESULT after release: $(wake_count 'fm-sample-delivered') wake(s), $(wake_count 'possible wedge') possible-wedge escalation(s)"
}

# Crew state reads the worker's own state, never the hold command's lines.
scenario_crew_state() {
  LANE_HARNESS=grok add_lane sample-report scout live "done: report ready"
  say "crew state before hold: $("$CODE/bin/fm-crew-state.sh" sample-report 2>&1)"
  captain hold sample-report --reason "report review pending"
  show_status sample-report
  say "crew state while held: $("$CODE/bin/fm-crew-state.sh" sample-report 2>&1)"
  printf 'Accepted.\n' > "$SCR/ok.txt"
  captain answer sample-report --decision-file "$SCR/ok.txt" --release
  show_status sample-report
  say "crew state after release: $("$CODE/bin/fm-crew-state.sh" sample-report 2>&1)"
}

# Guards: repeated hold, decision-only hold, worker moved on after the hold,
# replayed settlement, divergence guard.
scenario_adversarial() {
  add_lane sample-guard ship dead "paused: waiting on the sample upstream release"
  captain hold sample-guard --reason "operator review pending"
  captain hold sample-guard --reason "operator review pending"
  say "captain-held lines after two identical holds: $(grep -c '^captain-held ' "$STATE/sample-guard.status")"
  captain hold sample-question --title "Pick a sample flavor" --reason "flavor choice pending"
  [ -e "$STATE/sample-question.status" ] && say "decision-only hold CREATED state/sample-question.status" \
    || say "decision-only hold created no status log (no lane to own it)"
  say "worker resumes on its own after the hold and appends a newer line"
  printf 'working: resumed after the upstream release landed\n' >> "$STATE/sample-guard.status"
  printf 'Proceed.\n' > "$SCR/go.txt"
  captain answer sample-guard --decision-file "$SCR/go.txt" --release
  show_status sample-guard
  say "resolved lines appended over the worker's newer line: $(grep -c '^resolved ' "$STATE/sample-guard.status")"
  add_lane sample-replay ship dead "paused: waiting on the sample review"
  captain hold sample-replay --reason "operator review pending"
  printf 'Ship it.\n' > "$SCR/ship.txt"
  captain answer sample-replay --decision-file "$SCR/ship.txt"
  captain answer sample-replay --decision-file "$SCR/ship.txt"
  show_status sample-replay
  say "retraction lines after a replayed answer: $(grep -c '^resolved ' "$STATE/sample-replay.status")"
  say "divergence guard output: [$("$CODE/bin/fm-captain-hold.sh" diverged 2>&1)]"
}

# Away mode proper: state/.afk present, fm-supervise-daemon.sh owns triage and
# buffers escalations for the captain's return digest.
scenario_daemon_away() {
  export FM_PAUSE_RESURFACE_SECS=5 FM_HOUSEKEEPING_TICK=1 FM_ESCALATE_BATCH_SECS=9999 \
    FM_MAX_DEFER_SECS=0 FM_WEDGE_ALARM_EXEC=discard FM_HEARTBEAT_SCAN_SECS=9999 \
    FM_SUPERVISOR_TARGET=firstmate:supervisor FM_SUPERVISOR_BACKEND=tmux
  LANE_AGE=60 add_lane sample-away ship dead "paused: waiting on the sample upstream release"
  captain hold sample-away --reason "operator review pending"
  show_status sample-away
  away_on
  date +%s > "$STATE/.afk"
  say "starting fm-supervise-daemon.sh (away mode) for 30s"
  "$CODE/bin/fm-supervise-daemon.sh" > "$SCR/daemon.out" 2>&1 &
  local dpid=$!
  sleep 30
  kill "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null
  local wpid; wpid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null); [ -n "$wpid" ] && kill "$wpid" 2>/dev/null
  say "daemon escalation buffer (state/.subsuper-escalations) for the captain:"
  sed 's/^/    | /' "$STATE/.subsuper-escalations" 2>/dev/null || echo "    (empty)"
  say "daemon log lines naming the lane:"
  grep -h 'sample-away' "$STATE"/.subsuper*.log "$STATE"/*.log 2>/dev/null | tail -4 | sed 's/^/    /'
  say "RESULT: rechecks escalated for the held lane while away: $(grep -c 'sample-away' "$STATE/.subsuper-escalations" 2>/dev/null || echo 0)"
}

# The captain returns from away mode after a failed lane was held and then
# released: the return brief must still list the failure the worker reported.
scenario_return_brief_failed() {
  add_lane sample-broken ship dead "failed: sample build broke on the upstream API change"
  away_on
  date +%s > "$STATE/.afk"
  captain hold sample-broken --reason "retry or abandon the sample"
  printf 'Retry after the upstream fix.\n' > "$SCR/retry.txt"
  captain answer sample-broken --decision-file "$SCR/retry.txt" --release
  show_status sample-broken
  say "\$ fm-afk-return.sh begin (captain is back)"
  "$CODE/bin/fm-afk-return.sh" begin > "$SCR/brief.txt" 2>&1
  say "return brief (rc=$?), failed/tried section:"
  awk '/tried and failed|could not be fixed/ { p = 1 } /^Handled while away/ { p = 0 } p' "$SCR/brief.txt" | sed 's/^/    | /'
}
