#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-state.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-state-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
command -v jq >/dev/null 2>&1 \
  || fail "these tests run the script's own jq programs over API-shaped JSON with the real jq, which was not found"

HEAD=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
OLD_HEAD_1=2710bc5efc936efb70e95b86ca3582e9da7e60f4
OLD_HEAD_2=4dc2291e6969de1bf204fbdb53c9e57a8353d4e2

# The fake gh answers every query with the JSON shape GitHub returns and runs
# the --jq program it received with the real jq, so field selection is what is
# under test. The REST pull-request object always carries the stale
# `mergeable: null` GitHub reports right after a push.
# It evaluates with the local jq, while gh itself embeds gojq, whose Go RE2
# regexes reject lookaround; tests/fm-pr-state-live-e2e.test.sh runs the real
# engine.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e
serve() {
  case "$*" in
    "pr view "*" --json url --jq .url")
      printf '%s\n' '{"url":"https://github.com/monalee-inc/artemis/pull/7"}'
      ;;
    "pr view "*" --json mergeable,headRefOid,reviewDecision --jq "*)
      jq -n --arg mergeable "${FM_TEST_VIEW_MERGEABLE-MERGEABLE}" --arg head "$head" \
        --arg decision "${FM_TEST_VIEW_REVIEW_DECISION-APPROVED}" \
        '{mergeable: (if $mergeable == "null" then null else $mergeable end),
          headRefOid: $head, reviewDecision: $decision}'
      ;;
    "api /repos/monalee-inc/artemis/pulls/7 --jq "*)
      jq -n --arg head "$head" --arg ref "${FM_TEST_HEAD_REF-fm/fixture}" \
        --arg title "${FM_TEST_TITLE-fix(ART-7): fixture}" --arg body "${FM_TEST_BODY-}" \
        --arg users "${FM_TEST_REQUESTED_USERS-alice}" \
        --arg teams "${FM_TEST_REQUESTED_TEAMS-webdev}" \
        '{state: "open", merged_at: null, draft: false, mergeable: null,
          head: {sha: $head, ref: $ref}, base: {ref: "dev"},
          title: $title, body: $body, user: {login: "tiago-peixoto"},
          requested_reviewers: ($users | split(" ") | map(select(. != "") | split(":")
            | {login: .[0], type: (.[1] // "User")})),
          requested_teams: ($teams | split(" ") | map(select(. != "") | {slug: .}))}'
      ;;
    "api /repos/monalee-inc/artemis/pulls/7/reviews?per_page=100 --paginate --jq "*)
      printf '%s\n' "${FM_TEST_REVIEWS:-[]}"
      ;;
    "api user --jq .login")
      printf '%s\n' '{"login":"tiago-peixoto"}'
      ;;
    "pr checks "*" --required --json name,state,bucket,workflow --jq "*)
      if [ -n "${FM_TEST_CHECKS_ERROR-}" ]; then
        printf '%s\n' "$FM_TEST_CHECKS_ERROR" >&2
        exit 1
      fi
      checks='[{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"},{"name":"optional","state":"SKIPPED","bucket":"skipping","workflow":"ci"}]'
      printf '%s\n' "${FM_TEST_REQUIRED_CHECKS:-$checks}"
      ;;
    "pr checks "*)
      printf '%s\n' '[{"name":"browser shard","state":"FAILURE","bucket":"fail","workflow":"ci"}]'
      ;;
    *)
      printf 'unexpected gh call: %s\n' "$*" >&2
      exit 91
      ;;
  esac
}
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
serve "$@" | jq -r "$prog"
SH
chmod +x "$FAKEBIN/gh"

run_state() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" 7
}

# reviews "<login> <type> <state> <commit> <submitted_at>"... prints the JSON
# array GitHub's reviews endpoint returns for those submissions.
reviews() {
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" +"; "")
    | {user: {login: .[0], type: .[1]}, state: .[2], commit_id: .[3], submitted_at: .[4]})'
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

test_submitted_human_review_satisfies_the_user_request_only() {
  local out history
  history=$(reviews "alice User APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_REQUESTED_USERS='' FM_TEST_REQUESTED_TEAMS='' FM_TEST_REVIEWS=$history run_state) \
    || fail "reviewed fixture was refused"
  assert_not_contains "$out" 'REQUESTED USER: none' \
    "a user who already reviewed leaves requested_reviewers but still counts"
  assert_contains "$out" 'REQUESTED TEAM: none' \
    "a submitted review does not reveal team membership, so the team check stays on pending requests"

  history=$(reviews "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_REQUESTED_USERS='' FM_TEST_REVIEWS=$history run_state) \
    || fail "bot-reviewed fixture was refused"
  assert_contains "$out" 'REQUESTED USER: none' \
    "a bot review is not a requested human user"

  out=$(FM_TEST_REQUESTED_USERS='Copilot:Bot' run_state) \
    || fail "bot-requested fixture was refused"
  assert_contains "$out" 'REQUESTED USER: none' \
    "a pending Bot reviewer request is not a requested human user"
  pass "a submitted human review satisfies the user request but not the team request"
}

test_stale_blocking_reviews_explain_a_blocking_decision() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "Lipemenezes User COMMENTED $OLD_HEAD_2 2026-09-01T23:10:00Z" \
    "alice User APPROVED $OLD_HEAD_2 2026-09-01T23:11:00Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "voided-review fixture was refused"
  assert_contains "$out" 'REVIEW DECISION: CHANGES_REQUESTED' \
    "GitHub's blocking decision must be printed"
  assert_contains "$out" "STALE BLOCKING REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $OLD_HEAD_2; current head $HEAD" \
    "the reviewer's latest stale changes-requested verdict was not shown with both SHAs"
  assert_not_contains "$out" "$OLD_HEAD_1" \
    "a verdict the same reviewer later superseded is history, not a blocker"
  assert_not_contains "$out" 'Lipemenezes' \
    "a stale COMMENTED review is informational noise"
  assert_not_contains "$out" 'alice' \
    "a stale approval is not a concrete blocker"
  pass "stale changes-requested verdicts explain a blocking review decision"
}

test_approved_pr_with_only_stale_changes_requested_is_silent() {
  local out history
  history=$(reviews \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_1 2026-09-01T00:15:44Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $OLD_HEAD_2 2026-09-01T23:02:13Z" \
    "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "coderabbitai[bot] Bot APPROVED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=APPROVED FM_TEST_REVIEWS=$history run_state) \
    || fail "approved stale-review fixture was refused"
  [ -z "$out" ] || fail "an approved PR with only stale review history should be silent, got: $out"
  pass "approved PR ignores stale changes-requested history"
}

test_current_changes_requested_review_is_a_blocker() {
  local out history
  history=$(reviews "coderabbitai[bot] Bot CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "current-review fixture was refused"
  assert_contains "$out" "REVIEW: coderabbitai[bot] CHANGES_REQUESTED at $HEAD" \
    "a current changes-requested review must block readiness"
  pass "current changes-requested review blocks readiness"
}

test_changes_requested_decision_is_never_silent() {
  local out history
  history=$(reviews \
    "bob User CHANGES_REQUESTED $HEAD 2026-09-02T13:53:41Z" \
    "bob User COMMENTED $HEAD 2026-09-02T14:05:42Z")
  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED FM_TEST_REVIEWS=$history run_state) \
    || fail "comment-after-changes fixture was refused"
  assert_contains "$out" "REVIEW: bob CHANGES_REQUESTED at $HEAD" \
    "a later COMMENTED review does not clear the reviewer's change request"

  out=$(FM_TEST_VIEW_REVIEW_DECISION=CHANGES_REQUESTED run_state) \
    || fail "decision-only fixture was refused"
  [ "$out" = 'REVIEW DECISION: CHANGES_REQUESTED' ] \
    || fail "GitHub's blocking decision must be printed even without an explaining review, got: $out"
  pass "a CHANGES_REQUESTED decision is always reported"
}

test_pending_approval_is_not_a_blocker() {
  local out
  out=$(FM_TEST_VIEW_REVIEW_DECISION=REVIEW_REQUIRED run_state) \
    || fail "review-required fixture was refused"
  [ -z "$out" ] || fail "awaiting approval leaves nothing for the author, got: $out"
  pass "a pending approval is not reported as a blocker"
}

test_required_failure_is_a_blocker() {
  local out
  out=$(FM_TEST_REQUIRED_CHECKS='[{"name":"CI Status","state":"FAILURE","bucket":"fail","workflow":"ci"},{"name":"lint","state":"SUCCESS","bucket":"pass","workflow":"ci"}]' run_state) \
    || fail "blocked fixture was refused"
  assert_contains "$out" 'REQUIRED CHECK: CI Status (FAILURE)' \
    "required failure was not reported"
  assert_not_contains "$out" 'lint' \
    "a passing required check is not a blocker"
  pass "required failure blocks readiness"
}

test_no_required_checks_is_silent() {
  local out status
  out=$(FM_TEST_CHECKS_ERROR="no required checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a base without required checks was refused"
  [ -z "$out" ] || fail "a base without required checks has no check blocker, got: $out"

  status=0
  FM_TEST_CHECKS_ERROR='HTTP 502: Bad Gateway' run_state >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "a real check lookup failure must still refuse"
  pass "a base without required checks is silent, other check lookup failures refuse"
}

test_no_reported_checks_is_unverified() {
  local out
  out=$(FM_TEST_CHECKS_ERROR="no checks reported on the 'fm/fixture' branch" run_state) \
    || fail "a head without reported checks was refused"
  [ "$out" = "CHECKS: none reported yet on ${HEAD:0:7}" ] \
    || fail "a head with no reported checks must read as unverified, not ready, got: $out"
  pass "a head with no reported checks is unverified rather than ready"
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
  out=$(FM_TEST_VIEW_MERGEABLE=null FM_TEST_TITLE='fix: fixture' FM_TEST_BODY='Closes art-7' run_state) \
    || fail "unknown-mergeability fixture was refused"
  assert_contains "$out" 'MERGEABILITY: unknown' \
    "null mergeability must not be treated as clean"
  assert_contains "$out" 'TITLE: missing ticket identifier ART-7' \
    "Artemis-style title without the body's ticket must be reported"
  pass "unknown mergeability and missing ticket identifier block readiness"
}

test_ticket_identifier_must_match_as_a_whole_token() {
  local out
  out=$(FM_TEST_HEAD_REF='feat/art-7-fixture' FM_TEST_TITLE='fix(ART-70): fixture' run_state) \
    || fail "near-miss ticket fixture was refused"
  assert_contains "$out" 'TITLE: missing ticket identifier ART-7' \
    "ART-70 in the title must not satisfy the branch's ART-7"

  out=$(FM_TEST_HEAD_REF='feat/art-7-fixture' FM_TEST_TITLE='fix(ART-7): fixture' run_state) \
    || fail "matching ticket fixture was refused"
  assert_not_contains "$out" 'TITLE:' \
    "a title carrying the branch's own ticket is compliant"
  pass "ticket identifiers match as whole tokens"
}

test_ticketless_pr_does_not_require_title_identifier() {
  local out
  out=$(FM_TEST_TITLE='Require Linear IDs in linked PR titles' run_state) \
    || fail "ticketless fixture was refused"
  assert_not_contains "$out" 'TITLE: missing ticket identifier' \
    "a PR with no ART reference in its body or branch is outside the title convention"

  out=$(FM_TEST_HEAD_REF='feat/part-2-checkout' FM_TEST_BODY='see part-1 of the chart-12 legend' \
    FM_TEST_TITLE='Split the checkout chart' run_state) \
    || fail "art-suffixed word fixture was refused"
  assert_not_contains "$out" 'TITLE:' \
    "a word that merely ends in art followed by digits is not a ticket"
  pass "ticketless PR does not require a title identifier"
}

test_mergeability_uses_current_pr_view_value_without_retry() {
  local out
  out=$(FM_TEST_VIEW_MERGEABLE=MERGEABLE run_state) \
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
test_submitted_human_review_satisfies_the_user_request_only
test_stale_blocking_reviews_explain_a_blocking_decision
test_approved_pr_with_only_stale_changes_requested_is_silent
test_current_changes_requested_review_is_a_blocker
test_changes_requested_decision_is_never_silent
test_pending_approval_is_not_a_blocker
test_required_failure_is_a_blocker
test_no_required_checks_is_silent
test_no_reported_checks_is_unverified
test_help_discloses_unavailable_thread_resolution
test_unknown_mergeability_and_missing_ticket_are_blockers
test_ticket_identifier_must_match_as_a_whole_token
test_ticketless_pr_does_not_require_title_identifier
test_mergeability_uses_current_pr_view_value_without_retry
test_refusals_exit_nonzero
