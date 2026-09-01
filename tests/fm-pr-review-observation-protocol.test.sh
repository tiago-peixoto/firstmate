#!/usr/bin/env bash
# Behavioral tests for the typed PR-review observation protocol exposed by
# bin/fm-pr-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB=${FM_PR_REVIEW_OBSERVATION_LIB:-$ROOT/bin/fm-pr-lib.sh}

assert_parser_rejects() {
  local observation=$1 message=$2 status=0
  bash -c '. "$1"; fm_pr_review_observation_parse "$2"' _ \
    "$LIB" "$observation" || status=$?
  [ "$status" -eq 1 ] || fail "$message (parser exit $status)"
}

parse_observation() {
  bash -c '
    . "$1"
    fm_pr_review_observation_parse "$2" || exit 1
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_PR_REVIEW_OBSERVATION_KIND" \
      "$FM_PR_REVIEW_OBSERVATION_PROVIDER" \
      "$FM_PR_REVIEW_OBSERVATION_UPDATED" \
      "$FM_PR_REVIEW_OBSERVATION_READ_AT" \
      "$FM_PR_REVIEW_OBSERVATION_REVIEWS" \
      "$FM_PR_REVIEW_OBSERVATION_ISSUE_COMMENTS" \
      "$FM_PR_REVIEW_OBSERVATION_REVIEW_COMMENTS" \
      "$FM_PR_REVIEW_OBSERVATION_REQUESTED"
  ' _ "$LIB" "$1"
}

test_parser_accepts_typed_observations() {
  local parsed
  parsed=$(parse_observation \
    'observed 2024-02-29T23:59:59Z 2024-03-01T00:00:00Z 12 3 44 2') \
    || fail "parser rejected a valid observed protocol line"
  [ "$parsed" = 'observed||2024-02-29T23:59:59Z|2024-03-01T00:00:00Z|12|3|44|2' ] \
    || fail "parser returned the wrong observed fields: $parsed"

  parsed=$(parse_observation 'unavailable github') \
    || fail "parser rejected an unavailable protocol line"
  [ "$parsed" = 'unavailable|github||||||' ] \
    || fail "parser returned the wrong unavailable fields: $parsed"

  parsed=$(parse_observation 'unavailable gitlab') \
    || fail "parser rejected a supported unavailable provider"
  [ "$parsed" = 'unavailable|gitlab||||||' ] \
    || fail "parser returned the wrong unavailable provider: $parsed"

  parsed=$(parse_observation \
    'unchanged 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 2') \
    || fail "parser rejected a valid unchanged protocol line"
  [ "$parsed" = 'unchanged||2026-08-31T03:00:00Z|2026-08-31T03:00:01Z||||2' ] \
    || fail "parser returned the wrong unchanged fields: $parsed"

  parsed=$(parse_observation merged) || fail "parser rejected a valid merged protocol line"
  [ "$parsed" = 'merged|||||||' ] || fail "parser returned the wrong merged fields: $parsed"

  assert_parser_rejects \
    'observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 12 nope 44 2' \
    "parser accepted a malformed numeric field"

  parsed=$(bash -c '
    . "$1"
    fm_pr_review_observation_parse \
      "observed 2026-08-31T03:00:00Z 2026-08-31T03:00:01Z 12 3 44 2" \
      || exit 1
    fm_pr_review_observation_parse "merged extra" && exit 1
    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
      "$FM_PR_REVIEW_OBSERVATION_KIND" \
      "$FM_PR_REVIEW_OBSERVATION_PROVIDER" \
      "$FM_PR_REVIEW_OBSERVATION_UPDATED" \
      "$FM_PR_REVIEW_OBSERVATION_READ_AT" \
      "$FM_PR_REVIEW_OBSERVATION_REVIEWS" \
      "$FM_PR_REVIEW_OBSERVATION_ISSUE_COMMENTS" \
      "$FM_PR_REVIEW_OBSERVATION_REVIEW_COMMENTS" \
      "$FM_PR_REVIEW_OBSERVATION_REQUESTED"
  ' _ "$LIB") || fail "parser did not reject an extra field"
  [ "$parsed" = '|||||||' ] \
    || fail "parser retained exposed fields after rejecting input: $parsed"
}

test_parser_rejects_invalid_observed_timestamp() {
  assert_parser_rejects \
    'observed - 2026-08-31T03:00:01Z 12 3 44 2' \
    "parser accepted a sentinel timestamp in an observed record"
  assert_parser_rejects \
    'observed 2026-02-29T03:00:00Z 2026-08-31T03:00:01Z 12 3 44 2' \
    "parser accepted a calendar-impossible UTC timestamp"
  assert_parser_rejects \
    'observed 2026-08-31T03:00:00Z 2026-02-29T03:00:01Z 12 3 44 2' \
    "parser accepted a calendar-impossible UTC read timestamp"
}

test_parser_rejects_unchanged_sentinel_timestamp() {
  assert_parser_rejects \
    'unchanged - 2026-08-31T03:00:01Z 2' \
    "parser accepted a sentinel timestamp in an unchanged record"
}

test_parser_rejects_missing_read_timestamp() {
  assert_parser_rejects \
    'observed 2026-08-31T03:00:00Z - 12 3 44 2' \
    "parser accepted a missing snapshot read timestamp"
}

test_parser_rejects_multiline_record() {
  assert_parser_rejects $'merged\njunk' \
    "parser accepted a second protocol record"
}

test_parser_rejects_noncanonical_record_forms() {
  assert_parser_rejects $'merged\r' \
    "parser accepted a carriage return"
  assert_parser_rejects ' merged' \
    "parser accepted a leading space"
  assert_parser_rejects 'merged ' \
    "parser accepted a trailing space"
  assert_parser_rejects \
    'observed 2026-08-31T03:00:00Z  2026-08-31T03:00:01Z 12 3 44 2' \
    "parser accepted repeated spaces"
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
  test_parser_accepts_typed_observations \
  test_parser_rejects_invalid_observed_timestamp \
  test_parser_rejects_unchanged_sentinel_timestamp \
  test_parser_rejects_missing_read_timestamp \
  test_parser_rejects_multiline_record \
  test_parser_rejects_noncanonical_record_forms; do
  run_one "$test_name" || failures=$((failures + 1))
done

[ "$failures" -eq 0 ] || exit 1
