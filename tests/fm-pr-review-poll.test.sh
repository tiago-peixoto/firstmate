#!/usr/bin/env bash
# Behavioral contract for the GitHub PR review observation reader.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

READER="$ROOT/bin/fm-pr-review-poll.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-review-poll)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
case " $* " in
  *" /repos/o/r/pulls/7/reviews?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    printf '%b' "${FM_TEST_REVIEW_IDS:-10\\n}"
    ;;
  *" /repos/o/r/issues/7/comments?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    printf '%b' "${FM_TEST_ISSUE_COMMENT_IDS:-20\\n}"
    ;;
  *" /repos/o/r/pulls/7/comments?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    printf '%b' "${FM_TEST_REVIEW_COMMENT_IDS:-30\\n}"
    ;;
  *" /repos/o/r/pulls/7 "*)
    [ "${FM_TEST_SUMMARY_FAIL:-0}" = 0 ] || exit 1
    printf '%s\t%s\t%s\n' "${FM_TEST_STATE:-open}" \
      "${FM_TEST_REQUESTED:-1}" "${FM_TEST_UPDATED:-2026-08-31T03:00:00Z}"
    ;;
  *)
    exit 2
    ;;
esac
SH
  chmod 0700 "$fakebin/gh"
  : > "$dir/gh.log"
  printf '%s\n' "$dir"
}

run_reader() {
  local dir=$1
  shift
  FM_TEST_GH_LOG="$dir/gh.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$READER" "$@"
}

assert_summary_only() {
  local log=$1
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] \
    || fail "reader made detail requests when the summary was decisive"
  grep -q ' /repos/o/r/pulls/7 ' "$log" \
    || fail "reader did not query the PR summary"
}

test_snapshot_reports_maximum_activity_ids() {
  local dir out
  dir=$(make_case snapshot)
  out=$(FM_TEST_REVIEW_IDS='0009\n12\n0010\n' \
    FM_TEST_ISSUE_COMMENT_IDS='3\n2\n' \
    FM_TEST_REVIEW_COMMENT_IDS='44\n41\n' \
    FM_TEST_REQUESTED=2 run_reader "$dir" --snapshot github \
      https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "snapshot reader failed"
  [ "$out" = 'observed 2026-08-31T03:00:00Z 12 3 44 2' ] \
    || fail "snapshot observation lost activity maxima: $out"
}

test_unchanged_summary_skips_detail_requests() {
  local dir out
  dir=$(make_case unchanged)
  out=$(FM_TEST_REQUESTED=0 run_reader "$dir" --validated github \
    https://github.com/o/r/pull/7 github.com o/r 7 2026-08-31T03:00:00Z) \
    || fail "unchanged reader failed"
  [ "$out" = 'unchanged 2026-08-31T03:00:00Z 0' ] \
    || fail "unchanged observation was not stable: $out"
  assert_summary_only "$dir/gh.log"
}

test_merged_summary_stops_before_detail_requests() {
  local dir out
  dir=$(make_case merged)
  out=$(FM_TEST_STATE=merged run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "merged reader failed"
  [ "$out" = merged ] || fail "merged PR did not return the merged protocol: $out"
  assert_summary_only "$dir/gh.log"
}

test_summary_failure_is_explicitly_unavailable() {
  local dir out
  dir=$(make_case summary-failure)
  out=$(FM_TEST_SUMMARY_FAIL=1 run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "summary failure changed the reader exit contract"
  [ "$out" = 'unavailable github' ] \
    || fail "summary failure looked quiet instead of unavailable: $out"
}

test_detail_failure_is_explicitly_unavailable() {
  local dir out
  dir=$(make_case detail-failure)
  out=$(FM_TEST_DETAIL_FAIL=1 run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "detail failure changed the reader exit contract"
  [ "$out" = 'unavailable github' ] \
    || fail "detail failure looked quiet instead of unavailable: $out"
}

test_malformed_activity_id_is_explicitly_unavailable() {
  local dir out
  dir=$(make_case malformed-id)
  out=$(FM_TEST_REVIEW_IDS='10\nnot-an-id\n' run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "malformed detail changed the reader exit contract"
  [ "$out" = 'unavailable github' ] \
    || fail "malformed detail looked like valid activity: $out"
}

test_invalid_identity_is_silent_without_github_access() {
  local dir out
  dir=$(make_case invalid-identity)
  out=$(run_reader "$dir" --snapshot github \
    https://github.com/o/other/pull/7 github.com o/r 7) \
    || fail "invalid identity changed the reader exit contract"
  [ -z "$out" ] || fail "invalid identity produced output: $out"
  [ ! -s "$dir/gh.log" ] || fail "invalid identity reached GitHub"
}

test_protocol_parser_accepts_only_typed_observations() {
  local parsed
  parsed=$(bash -c '
    . "$1"
    fm_pr_poll_observation_parse "$2" || exit 1
    printf "%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_PR_OBSERVATION_KIND" "$FM_PR_OBSERVATION_PROVIDER" \
      "$FM_PR_OBSERVATION_UPDATED" "$FM_PR_OBSERVATION_REVIEWS" \
      "$FM_PR_OBSERVATION_ISSUE_COMMENTS" \
      "$FM_PR_OBSERVATION_REVIEW_COMMENTS" \
      "$FM_PR_OBSERVATION_REQUESTED"
  ' _ "$ROOT/bin/fm-pr-lib.sh" \
    'observed 2026-08-31T03:00:00Z 12 3 44 2') \
    || fail "parser rejected a valid observed protocol line"
  [ "$parsed" = 'observed||2026-08-31T03:00:00Z|12|3|44|2' ] \
    || fail "parser returned the wrong observed fields: $parsed"

  parsed=$(bash -c '
    . "$1"
    fm_pr_poll_observation_parse "$2" || exit 1
    printf "%s|%s\n" "$FM_PR_OBSERVATION_KIND" "$FM_PR_OBSERVATION_PROVIDER"
  ' _ "$ROOT/bin/fm-pr-lib.sh" 'unavailable github') \
    || fail "parser rejected an unavailable protocol line"
  [ "$parsed" = 'unavailable|github' ] \
    || fail "parser returned the wrong unavailable fields: $parsed"

  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" 'observed 2026-08-31T03:00:00Z 12 nope 44 2'; then
    fail "parser accepted a malformed numeric field"
  fi
}

run_one() {
  local name=$1
  if ("$name"); then
    pass "$name"
    return 0
  fi
  return 1
}

failures=0
for test_name in \
  test_snapshot_reports_maximum_activity_ids \
  test_unchanged_summary_skips_detail_requests \
  test_merged_summary_stops_before_detail_requests \
  test_summary_failure_is_explicitly_unavailable \
  test_detail_failure_is_explicitly_unavailable \
  test_malformed_activity_id_is_explicitly_unavailable \
  test_invalid_identity_is_silent_without_github_access \
  test_protocol_parser_accepts_only_typed_observations; do
  run_one "$test_name" || failures=$((failures + 1))
done

[ "$failures" -eq 0 ] || exit 1
