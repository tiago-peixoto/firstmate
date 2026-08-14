#!/usr/bin/env bash
# Behavior tests for the argument boundaries of the blessed GitHub wrappers.
set -eu

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTH="$ROOT/bin/fm-gh-auth-status.sh"
STATE="$ROOT/bin/fm-gh-pr-state.sh"
HEAD="$ROOT/bin/fm-gh-pr-head.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-wrappers)
MARKER="$TMP_ROOT/injected"

assert_usage_failure() {
  local script=$1
  shift
  local rc
  set +e
  /bin/sh "$script" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "$(basename "$script") accepted unsafe arguments: $* (rc=$rc)"
}

assert_usage_failure "$AUTH" unexpected

for wrapper in "$STATE" "$HEAD"; do
  assert_usage_failure "$wrapper"
  assert_usage_failure "$wrapper" owner repo
  assert_usage_failure "$wrapper" owner repo 1 extra

  # shellcheck disable=SC2016 # Literal shell metacharacters are adversarial inputs.
  for owner in '-owner' 'owner-' 'owner--name' 'owner/name' 'owner$bad' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; do
    assert_usage_failure "$wrapper" "$owner" repo 1
  done
  # shellcheck disable=SC2016 # Literal shell metacharacters are adversarial inputs.
  for repo in '.' '..' 'repo/name' 'repo+name' 'repo$bad'; do
    assert_usage_failure "$wrapper" owner "$repo" 1
  done
  for number in '' 0 01 -1 +1 1.0 1e2 '1;touch injected'; do
    assert_usage_failure "$wrapper" owner repo "$number"
  done

  assert_usage_failure "$wrapper" "owner;touch $MARKER" repo 1
  assert_usage_failure "$wrapper" owner "repo;touch $MARKER" 1
done

[ ! -e "$MARKER" ] || fail "an invalid wrapper argument executed as shell input"

pass "blessed GitHub wrappers reject commands, options, URLs, and malformed resource identifiers"
