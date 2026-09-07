#!/usr/bin/env bash
# Credentialed regression for bin/fm-pr-state.sh against gh's own jq engine.
#
# gh evaluates --jq with gojq, whose Go RE2 regex engine rejects syntax the
# local jq accepts (lookaround, for one). The hermetic suite runs the script's
# jq programs through the local jq, so only a real gh invocation proves every
# program compiles and runs where it is actually executed. cli/cli#1 is a
# merged 2019 pull request, so its verdict is stable.
set -u

if [ "${FM_PR_STATE_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PR_STATE_LIVE_E2E=1 to run the credentialed gh jq-engine regression"
  exit 0
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-state.sh"
PR=https://github.com/cli/cli/pull/1

command -v gh >/dev/null 2>&1 || fail "gh not found"
gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"

test_every_jq_program_runs_under_gh_engine() {
  local out status=0
  out=$("$SCRIPT" "$PR" 2>&1) || status=$?
  [ "$status" -eq 0 ] \
    || fail "fm-pr-state.sh refused a readable public pull request (exit $status): $out"
  assert_contains "$out" 'STATE: merged at 2019-10-04T16:01:04Z' \
    "the merged verdict must come from the live REST object"
  pass "every fm-pr-state.sh jq program is accepted by gh's jq engine"
}

# bin/fm-pr-poll.sh composes each of its two readings inside a gh field selector,
# for the same reason: no JSON processor is required on the watcher's PATH. That
# makes each selector's syntax and output shape a live fact - a hermetic fake gh
# can only replay a shape someone already assumed.
#
# The scalar reading is proven through the program that owns it: cli/cli#1 is a
# merged 2019 pull request, and the poll prints the merged token only once its
# own selector compiled and its own shape validation accepted the result.
test_poll_merge_terminal_runs_under_gh_engine() {
  local out
  out=$("$ROOT/bin/fm-pr-poll.sh" --validated github "$PR" github.com cli/cli 1 2>&1)
  [ "$out" = merged ] \
    || fail "the PR poll no longer reports the live merged pull request as merged: $out"
  pass "the PR poll's merge terminal compiles under gh's jq engine against a live merged pull request"
}

# The activity reading is unreachable through a merged pull request, because the
# merge terminal returns before it, so this program is asserted directly. It is
# the REST pull-request object rather than gh's pull-request view because
# .comments and .review_comments there are totals rather than the length of a
# single collection page; the totals themselves are not stable, so only the
# shape the poll validates is asserted.
test_poll_activity_selector_runs_under_gh_engine() {
  local line
  line=$(gh api /repos/cli/cli/pulls/1 \
    --jq '"comments=\(.comments) review_comments=\(.review_comments) updated=\(.updated_at)"' \
    2>&1) || fail "gh rejected the poll's activity jq program: $line"
  [[ $line =~ ^comments=[0-9]+\ review_comments=[0-9]+\ updated=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || fail "the poll's activity read no longer composes the shape the poll validates: $line"
  pass "the PR poll's activity read compiles under gh's jq engine and composes the shape it validates"
}

test_every_jq_program_runs_under_gh_engine
test_poll_merge_terminal_runs_under_gh_engine
test_poll_activity_selector_runs_under_gh_engine
