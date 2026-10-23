#!/usr/bin/env bash
# Runs the intent-targeted cases of tests/fm-watch-triage.test.sh one at a time
# through the file's FM_TEST_ONLY selector. Each case drives a real
# bin/fm-watch.sh subprocess against a disposable state dir.
set -u
cd "$1" || exit 2
EV=$2
tests=(
  test_nonterminal_stale_paused_absorbed_then_resurfaced
  test_exited_declared_pause_is_bounded_but_live_gate_surfaces
  test_own_work_wait_keeps_first_alert_then_long_cadence
  test_live_declared_wait_churn_honors_the_resurface_throttle
  test_absorbed_replacement_wait_does_not_inherit_the_old_throttle
  test_declared_wait_on_a_never_settling_pane_keeps_the_bounded_recheck
  test_paused_authoritative_working_preserves_wedge_timer
  test_nonterminal_paused_rechecks_authoritative_state
  test_nonterminal_stale_pause_transitions_reclassify_unchanged_hash
  test_wedge_threshold_defers_to_a_declared_wait_under_a_working_verdict
  test_secondmate_paused_resurfaces_in_normal_mode
  test_secondmate_captain_held_resurfaces_in_normal_mode
  test_secondmate_nonpaused_stale_remains_suppressed
  test_secondmate_unpause_clears_pause_tracking
  test_busy_declared_pause_is_rechecked_not_wedge_escalated
  test_afk_busy_declared_pause_ticking_pane_hands_off_once
  test_live_paused_until_controls_recheck_time
  test_paused_until_near_future_is_quiet_before_the_cadence
  test_paused_until_wrong_year_is_bounded_by_the_cadence
  test_paused_until_that_passed_is_rechecked_before_the_cadence
  test_live_captain_held_first_sight_silenced_by_away_record
  test_captain_held_never_rechecked_while_away_record_exists
  test_captain_held_rechecked_under_a_quiet_record
  test_afk_paused_changed_pane_hands_off_plain_stale
  test_wedge_threshold_validating_run_is_off_until_armed
  test_wedge_threshold_defers_to_an_executing_validation_run
)
summary="$EV/targeted-triage-summary.txt"
: > "$summary"
overall=0
for t in "${tests[@]}"; do
  start=$(date +%s)
  if FM_TEST_ONLY="$t" nice -n 10 bash tests/fm-watch-triage.test.sh > "$EV/case-$t.log" 2>&1; then
    rc=0
  else
    rc=$?; overall=1
  fi
  printf '%s\trc=%s\t%ss\t%s\n' "$t" "$rc" "$(( $(date +%s) - start ))" "$(grep -E '^(PASS|FAIL|ok|not ok)' "$EV/case-$t.log" | tail -1)" >> "$summary"
done
echo "overall_rc=$overall" >> "$summary"
exit "$overall"
