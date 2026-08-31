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
api_host=${GH_HOST:-github.com}
expect_hostname=0
include=0
for arg in "$@"; do
  if [ "$expect_hostname" -eq 1 ]; then
    api_host=$arg
    expect_hostname=0
    continue
  fi
  case "$arg" in
    --hostname) expect_hostname=1 ;;
    --hostname=*) api_host=${arg#--hostname=} ;;
    --include) include=1 ;;
  esac
done
foreign=0
if [ "$api_host" != github.com ]; then
  foreign=1
fi
case " $* " in
  *" /repos/o/r/pulls/7/reviews?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    if [ "$foreign" -eq 1 ]; then
      printf '901\n'
    else
      printf '%b' "${FM_TEST_REVIEW_IDS:-10\\n}"
    fi
    ;;
  *" /repos/o/r/issues/7/comments?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    if [ "$foreign" -eq 1 ]; then
      printf '902\n'
    else
      printf '%b' "${FM_TEST_ISSUE_COMMENT_IDS:-20\\n}"
    fi
    ;;
  *" /repos/o/r/pulls/7/comments?per_page=100 "*)
    [ "${FM_TEST_DETAIL_FAIL:-0}" = 0 ] || exit 1
    if [ "$foreign" -eq 1 ]; then
      printf '903\n'
    else
      printf '%b' "${FM_TEST_REVIEW_COMMENT_IDS:-30\\n}"
    fi
    ;;
  *" /repos/o/r/pulls/7 "*)
    [ "${FM_TEST_SUMMARY_FAIL:-0}" = 0 ] || exit 1
    if [ "$include" -eq 1 ]; then
      printf 'HTTP/2.0 200 OK\nDate: %s\r\n\r\n' \
        "${FM_TEST_READ_AT_RFC1123:-Mon, 31 Aug 2026 03:00:01 GMT}"
    fi
    if [ "$foreign" -eq 1 ]; then
      printf 'open\t9\t2026-08-31T03:00:00Z\n'
    else
      printf '%s\t%s\t%s\n' "${FM_TEST_STATE:-open}" \
        "${FM_TEST_REQUESTED:-1}" "${FM_TEST_UPDATED:-2026-08-31T03:00:00Z}"
    fi
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
  [ "$out" = 'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 12 3 44 2' ] \
    || fail "snapshot observation lost activity maxima: $out"
}

test_snapshot_preserves_huge_ids_without_sort() {
  local dir out
  dir=$(make_case huge-ids-without-sort)
  cat > "$dir/fakebin/sort" <<'SH'
#!/usr/bin/env bash
exit 91
SH
  chmod 0700 "$dir/fakebin/sort"
  out=$(FM_TEST_REVIEW_IDS='999999999999999999999999999999999999\n1000000000000000000000000000000000000\n' \
    FM_TEST_ISSUE_COMMENT_IDS='000184467440737095516160\n184467440737095516159\n' \
    FM_TEST_REVIEW_COMMENT_IDS='42\n0000000000000000000000000000000000043\n' \
    run_reader "$dir" --snapshot github \
      https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "huge-ID snapshot failed without sort"
  [ "$out" = 'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 1000000000000000000000000000000000000 184467440737095516160 43 1' ] \
    || fail "huge-ID snapshot lost exact maxima without sort: $out"
}

test_unchanged_summary_skips_detail_requests() {
  local dir out
  dir=$(make_case unchanged)
  out=$(FM_TEST_REQUESTED=0 run_reader "$dir" --validated github \
    https://github.com/o/r/pull/7 github.com o/r 7 \
      2026-08-31T03:00:00Z 2026-08-31T03:00:01Z) \
    || fail "unchanged reader failed"
  [ "$out" = 'unchanged 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 0' ] \
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

test_reader_rejects_missing_live_timestamp() {
  local dir out
  dir=$(make_case missing-live-timestamp)
  out=$(FM_TEST_UPDATED=- run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "missing timestamp changed the reader exit contract"
  [ "$out" = 'unavailable github' ] \
    || fail "missing timestamp became a live observation: $out"
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

test_reader_pins_every_request_to_validated_host() {
  local dir out
  dir=$(make_case pinned-host)
  out=$(GH_HOST=ghe.example run_reader "$dir" --snapshot github \
    https://github.com/o/r/pull/7 github.com o/r 7) \
    || fail "host-pinned reader failed"
  [ "$out" = 'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 10 20 30 1' ] \
    || fail "reader observed the ambient GitHub host: $out"
}

test_same_second_review_forces_one_detail_refresh() {
  local dir out
  dir=$(make_case same-second-review)
  cat > "$dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '2026-08-31T03:00:02Z\n'
SH
  chmod 0700 "$dir/fakebin/date"

  out=$(FM_TEST_READ_AT_RFC1123='Mon, 31 Aug 2026 03:00:01 GMT' \
    FM_TEST_REVIEW_IDS='11\n' run_reader "$dir" --validated github \
      https://github.com/o/r/pull/7 github.com o/r 7 2026-08-31T03:00:00Z) \
    || fail "legacy same-second baseline changed the reader exit contract"
  [ "$out" = 'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 11 20 30 1' ] \
    || fail "same-second review was permanently suppressed as unchanged: $out"

  : > "$dir/gh.log"
  out=$(FM_TEST_READ_AT_RFC1123='Mon, 31 Aug 2026 03:00:01 GMT' \
    FM_TEST_REVIEW_IDS='11\n' run_reader "$dir" --validated github \
      https://github.com/o/r/pull/7 github.com o/r 7 \
      2026-08-31T03:00:00Z 2026-08-31T03:00:00Z) \
    || fail "same-second snapshot baseline changed the reader exit contract"
  [ "$out" = 'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 11 20 30 1' ] \
    || fail "same-second snapshot missed the later review: $out"
  [ "$(wc -l < "$dir/gh.log" | tr -d ' ')" = 4 ] \
    || fail "same-second snapshot did not refresh all detail collections"
}

test_protocol_parser_accepts_only_typed_observations() {
  local parsed
  parsed=$(bash -c '
    . "$1"
    fm_pr_poll_observation_parse "$2" || exit 1
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_PR_OBSERVATION_KIND" "$FM_PR_OBSERVATION_PROVIDER" \
      "$FM_PR_OBSERVATION_UPDATED" "$FM_PR_OBSERVATION_READ_AT" \
      "$FM_PR_OBSERVATION_REVIEWS" \
      "$FM_PR_OBSERVATION_ISSUE_COMMENTS" \
      "$FM_PR_OBSERVATION_REVIEW_COMMENTS" \
      "$FM_PR_OBSERVATION_REQUESTED"
  ' _ "$ROOT/bin/fm-pr-lib.sh" \
    'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 12 3 44 2') \
    || fail "parser rejected a valid observed protocol line"
  [ "$parsed" = 'observed||2026-08-31T03:00:00Z|2026-08-31T03:00:01Z|12|3|44|2' ] \
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
    "$ROOT/bin/fm-pr-lib.sh" \
      'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 12 nope 44 2'; then
    fail "parser accepted a malformed numeric field"
  fi
}

test_protocol_parser_rejects_observed_sentinel_timestamp() {
  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" \
      'observed - 2026-08-31T03:00:01Z 12 3 44 2'; then
    fail "parser accepted a sentinel timestamp in an observed record"
  fi
}

test_protocol_parser_rejects_unchanged_sentinel_timestamp() {
  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" 'unchanged - 2026-08-31T03:00:01Z 2'; then
    fail "parser accepted a sentinel timestamp in an unchanged record"
  fi
}

test_protocol_parser_rejects_missing_read_timestamp() {
  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" \
      'observed 2026-08-31T03:00:00Z - 12 3 44 2'; then
    fail "parser accepted a missing snapshot read timestamp"
  fi
}

test_protocol_parser_rejects_multiline_record() {
  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" $'merged\njunk'; then
    fail "parser accepted a second protocol record"
  fi
}

test_protocol_parser_rejects_carriage_return() {
  if bash -c '. "$1"; fm_pr_poll_observation_parse "$2"' _ \
    "$ROOT/bin/fm-pr-lib.sh" $'merged\r'; then
    fail "parser accepted a carriage return"
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
  test_snapshot_preserves_huge_ids_without_sort \
  test_unchanged_summary_skips_detail_requests \
  test_merged_summary_stops_before_detail_requests \
  test_summary_failure_is_explicitly_unavailable \
  test_reader_rejects_missing_live_timestamp \
  test_detail_failure_is_explicitly_unavailable \
  test_malformed_activity_id_is_explicitly_unavailable \
  test_invalid_identity_is_silent_without_github_access \
  test_reader_pins_every_request_to_validated_host \
  test_same_second_review_forces_one_detail_refresh \
  test_protocol_parser_accepts_only_typed_observations \
  test_protocol_parser_rejects_observed_sentinel_timestamp \
  test_protocol_parser_rejects_unchanged_sentinel_timestamp \
  test_protocol_parser_rejects_missing_read_timestamp \
  test_protocol_parser_rejects_multiline_record \
  test_protocol_parser_rejects_carriage_return; do
  run_one "$test_name" || failures=$((failures + 1))
done

[ "$failures" -eq 0 ] || exit 1
