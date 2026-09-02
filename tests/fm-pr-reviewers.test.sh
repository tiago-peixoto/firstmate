#!/usr/bin/env bash
# Behavioral tests for bin/fm-pr-reviewers.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-pr-reviewers.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-reviewers-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "pr view "*" --json url --jq .url")
    printf '%s\n' 'https://github.com/o/r/pull/7'
    ;;
  "api /repos/o/r/pulls/7 --jq "*)
    printf '%s\n' 'author=tiago-peixoto' 'base=base123'
    ;;
  "api /repos/o/r/pulls/7/files?per_page=100 --paginate --jq .[].filename")
    printf '%s\n' 'a.ts' 'dir/b.ts'
    ;;
  "api --method GET /repos/o/r/commits -F sha=base123 -F path=a.ts -F per_page=100 --jq "*)
    if [ "${FM_TEST_ONLY_AUTHOR:-0}" = 1 ]; then
      printf '%s\n' $'own1\ttiago-peixoto'
    else
      printf '%s\n' \
        $'pedro1\tpedromuller-del' \
        $'alice1\talice' \
        $'own1\ttiago-peixoto' \
        $'unmapped1\t'
    fi
    ;;
  "api --method GET /repos/o/r/commits -F sha=base123 -F path=dir/b.ts -F per_page=100 --jq "*)
    if [ "${FM_TEST_ONLY_AUTHOR:-0}" = 1 ]; then
      printf '%s\n' $'own2\ttiago-peixoto'
    else
      printf '%s\n' \
        $'pedro1\tpedromuller-del' \
        $'pedro2\tpedromuller-del'
    fi
    ;;
  *)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_reviewers() {
  PATH="$FAKEBIN:$PATH" "$SCRIPT" 7
}

test_candidates_use_api_logins_and_unique_commit_counts() {
  local out
  out=$(run_reviewers) || fail "reviewer fixture was refused"
  assert_contains "$out" $'pedromuller-del\t2 recent commits' \
    "Pedro's API-resolved login or deduplicated count is wrong"
  assert_contains "$out" $'alice\t1 recent commit' \
    "Alice's mapped authorship evidence is missing"
  assert_not_contains "$out" 'tiago-peixoto' \
    "the PR author must not be a reviewer candidate"
  pass "reviewer candidates use API-resolved logins and unique commits"
}

test_only_author_evidence_says_no_candidates() {
  local out
  out=$(FM_TEST_ONLY_AUTHOR=1 run_reviewers) || fail "author-only fixture was refused"
  [ "$out" = 'NO CANDIDATES: recent authorship names only the PR author' ] \
    || fail "author-only evidence was not explained plainly: $out"
  pass "author-only evidence produces no candidate and says why"
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

test_candidates_use_api_logins_and_unique_commit_counts
test_only_author_evidence_says_no_candidates
test_refusals_exit_nonzero
