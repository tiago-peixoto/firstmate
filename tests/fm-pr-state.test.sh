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
  "pr view "*" --json mergeable,headRefOid --jq "*)
    printf '%s\n' \
      "mergeability=${FM_TEST_VIEW_MERGEABILITY:-mergeable}" \
      'head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e'
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
      "branch_ticket=${FM_TEST_BRANCH_TICKET:-}" \
      "body_ticket=${FM_TEST_BODY_TICKET:-}" \
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

test_stale_blocking_reviews_survive_a_later_review() {
  local out old_head_1 old_head_2 current_head
  old_head_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
  old_head_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2
  current_head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
  out=$(FM_TEST_REVIEWS=$'coderabbitai[bot]\tCHANGES_REQUESTED\t'"$old_head_1"$'\t2026-09-01T00:15:44Z\ncoderabbitai[bot]\tCHANGES_REQUESTED\t'"$old_head_2"$'\t2026-09-01T23:02:13Z\ncoderabbitai[bot]\tCHANGES_REQUESTED\t'"$current_head"$'\t2026-09-02T13:53:41Z\ncoderabbitai[bot]\tAPPROVED\t'"$current_head"$'\t2026-09-02T14:05:42Z\nLipemenezes\tCOMMENTED\t'"$old_head_2"$'\t2026-09-01T23:10:00Z\nalice\tAPPROVED\t'"$old_head_2"$'\t2026-09-01T23:11:00Z' run_state) \
    || fail "voided-review fixture was refused"
  assert_contains "$out" "STALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $old_head_1; current head $current_head" \
    "the first stale changes-requested verdict was hidden by a later review"
  assert_contains "$out" "STALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $old_head_2; current head $current_head" \
    "the second stale changes-requested verdict was hidden by a later review"
  assert_contains "$out" "VOIDED APPROVAL (informational): alice at $old_head_2; current head $current_head" \
    "a stale approval must be distinguished from a blocking verdict"
  assert_not_contains "$out" 'Lipemenezes' \
    "a stale COMMENTED review is informational noise"
  ! printf '%s\n' "$out" | grep -q '^REVIEW: coderabbitai\[bot\]' \
    || fail "a later current-head approval must supersede the earlier current-head changes request"
  pass "all stale blocking verdicts survive later reviews without COMMENTED noise"
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

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED='REQUIRED CHECK: CI Status (FAILURE)' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  pass "required failure blocks readiness"
}

test_help_discloses_unavailable_thread_resolution() {
  local out
  out=$("$SCRIPT" --help) || fail "help was refused"
  assert_contains "$out" 'Unresolved review-thread state is not reported' \
    "help must disclose the REST-only thread-resolution limit"
  pass "help discloses the unavailable REST thread-resolution signal"
}

test_unknown_mergeability_and_missing_ticket_are_blockers() {
  local out
  out=$(FM_TEST_MERGEABILITY=unknown FM_TEST_VIEW_MERGEABILITY=unknown FM_TEST_TITLE='fix: fixture' FM_TEST_BODY_TICKET=ART-7 run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"
  assert_contains "$out" 'TITLE: missing ticket identifier' \
    "Artemis-style title without a ticket must be reported"
  pass "unknown mergeability and missing ticket identifier block readiness"
}

test_ticketless_pr_does_not_require_title_identifier() {
  local out
  out=$(FM_TEST_TITLE='Require Linear IDs in linked PR titles' run_state) \
    || fail "ticketless fixture was refused"
  assert_not_contains "$out" 'TITLE: missing ticket identifier' \
    "a PR with no ART reference in its body or branch is outside the title convention"
  pass "ticketless PR does not require a title identifier"
}

test_mergeability_uses_current_pr_view_value_without_retry() {
  local out
  out=$(FM_TEST_MERGEABILITY=unknown FM_TEST_VIEW_MERGEABILITY=mergeable run_state) \
    || fail "current-mergeability fixture was refused"
  assert_not_contains "$out" 'MERGEABILITY: unknown' \
    "a current MERGEABLE view must win over the REST object's stale null"
  pass "mergeability uses the current pull-request view value"
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
test_stale_blocking_reviews_survive_a_later_review
test_current_changes_requested_review_is_a_blocker
test_required_failure_is_a_blocker
test_help_discloses_unavailable_thread_resolution
test_unknown_mergeability_and_missing_ticket_are_blockers
test_ticketless_pr_does_not_require_title_identifier
test_mergeability_uses_current_pr_view_value_without_retry
test_refusals_exit_nonzero
