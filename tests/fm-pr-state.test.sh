#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
requested_users=${FM_TEST_REQUESTED_USERS-alice}
requested_teams=${FM_TEST_REQUESTED_TEAMS-webdev}
case "$*" in
  "pr view "*" --json url --jq .url")
    printf '%s\n' 'https://github.com/monalee-inc/artemis/pull/7'
    ;;
  "api /repos/monalee-inc/artemis/pulls/7 --jq "*)
    printf '%s\n' \
      'state=open' \
      'merged_at=' \
      'draft=false' \
      "mergeability=${FM_TEST_MERGEABILITY:-mergeable}" \
      'head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e' \
      'base=dev' \
      "title=${FM_TEST_TITLE:-fix(ART-7): fixture}" \
      'author=tiago-peixoto'
    [ -z "$requested_users" ] || printf 'requested_user=%s\n' "$requested_users"
    [ -z "$requested_teams" ] || printf 'requested_team=%s\n' "$requested_teams"
    ;;
  "api /repos/monalee-inc/artemis/pulls/7/reviews?per_page=100 --paginate --jq "*)
    [ -z "${FM_TEST_REVIEWS:-}" ] || printf '%b\n' "$FM_TEST_REVIEWS"
    ;;
  "api user --jq .login")
    printf '%s\n' 'tiago-peixoto'
    ;;
  "api graphql "*)
    [ -z "${FM_TEST_THREADS:-}" ] || printf '%s\n' "$FM_TEST_THREADS"
    ;;
  "pr checks "*" --required --json name,state,bucket,workflow --jq "*)
    [ -z "${FM_TEST_REQUIRED:-}" ] || printf '%s\n' "$FM_TEST_REQUIRED"
    ;;
  "pr checks "*)
    printf '%s\n' 'ADVISORY CHECK: browser shard (FAILURE)'
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" 7
}

test_clean_pr_is_silent_and_ignores_advisory_failures() {
  local out
  out=$(run_state) || fail "clean fixture was refused"
  [ -z "$out" ] || fail "clean fixture should be silent, got: $out"
  pass "clean PR is silent and advisory failures do not block"
}

test_requested_users_and_teams_are_evaluated_separately() {
  local out
  out=$(FM_TEST_REQUESTED_USERS='' FM_TEST_REQUESTED_TEAMS=webdev run_state) \
    || fail "team-only fixture was refused"
  assert_contains "$out" 'REQUESTED USER: none' \
    "a team request must not hide a missing user request"
  assert_not_contains "$out" 'REQUESTED TEAM: none' \
    "the present team request must stay visible to its own check"

  out=$(FM_TEST_REQUESTED_USERS=alice FM_TEST_REQUESTED_TEAMS='' run_state) \
    || fail "user-only fixture was refused"
  assert_contains "$out" 'REQUESTED TEAM: none' \
    "a user request must not hide a missing team request"
  assert_not_contains "$out" 'REQUESTED USER: none' \
    "the present user request must stay visible to its own check"
  pass "requested users and teams are separate readiness facts"
}

test_superseded_review_reports_both_heads() {
  local out old_head current_head
  old_head=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2
  current_head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
  out=$(FM_TEST_REVIEWS="coderabbitai[bot]\tCHANGES_REQUESTED\t$old_head\t2026-09-01T23:02:13Z" run_state) \
    || fail "voided-review fixture was refused"
  assert_contains "$out" "VOIDED REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $old_head; current head $current_head" \
    "a superseded review must name both the reviewed and current heads"
  pass "superseded review is reported as voided with both heads"
}

test_current_changes_requested_review_is_a_blocker() {
  local out current_head
  current_head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
  out=$(FM_TEST_REVIEWS="coderabbitai[bot]\tCHANGES_REQUESTED\t$current_head\t2026-09-02T13:53:41Z" run_state) \
    || fail "current-review fixture was refused"
  assert_contains "$out" "REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $current_head" \
    "a current changes-requested review must block readiness"
  pass "current changes-requested review blocks readiness"
}

test_required_failure_and_unresolved_thread_are_blockers() {
  local out
  out=$(FM_TEST_REQUIRED='REQUIRED CHECK: CI Status (FAILURE)' \
    FM_TEST_THREADS='UNRESOLVED THREAD: alice https://github.com/monalee-inc/artemis/pull/7#discussion_r1' \
    run_state) || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_contains "$out" 'UNRESOLVED THREAD: alice https://github.com/monalee-inc/artemis/pull/7#discussion_r1' \
    "unresolved thread was not reported"
  pass "required failures and unresolved threads block readiness"
}

test_unknown_mergeability_and_missing_ticket_are_blockers() {
  local out
  out=$(FM_TEST_MERGEABILITY=unknown FM_TEST_TITLE='fix: fixture' run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"
  assert_contains "$out" 'TITLE: missing ticket identifier' \
    "Artemis-style title without a ticket must be reported"
  pass "unknown mergeability and missing ticket identifier block readiness"
}

test_refusals_exit_nonzero() {
  local status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "missing argument refusal exited zero"

  status=0
  PATH="$FAKEBIN:$PATH" "$SCRIPT" not-a-pr >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "lookup refusal exited zero"
  pass "argument and lookup refusals exit nonzero"
}

test_clean_pr_is_silent_and_ignores_advisory_failures
test_requested_users_and_teams_are_evaluated_separately
test_superseded_review_reports_both_heads
test_current_changes_requested_review_is_a_blocker
test_required_failure_and_unresolved_thread_are_blockers
test_unknown_mergeability_and_missing_ticket_are_blockers
test_refusals_exit_nonzero
