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

test_every_jq_program_runs_under_gh_engine
