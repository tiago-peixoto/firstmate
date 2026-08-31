#!/usr/bin/env bash
# Read one validated GitHub pull request for review and comment activity.
# Usage: fm-pr-review-poll.sh --snapshot <provider> <url> <host> <path> <number>
#        fm-pr-review-poll.sh --validated <provider> <url> <host> <path> <number> <prior-updated>
# Output uses the typed protocol owned by fm_pr_poll_observation_parse in
# fm-pr-lib.sh.
# Snapshot mode reads the PR summary and every page of review, issue-comment,
# and review-comment IDs, then reports each exact decimal maximum or zero when
# that collection is empty.
# Validated mode skips those detail lookups when the summary timestamp matches
# prior-updated, but still reports the current requested-user and requested-team
# total in its unchanged record.
# Both modes stop at the summary for a merged PR.
# Invalid arguments or a mismatched identity are silent and never call GitHub.
# After identity validation, a failed or malformed lookup reports unavailable
# rather than looking unchanged.
set -u
LC_ALL=C
export LC_ALL

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

mode=
prior_updated=
if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  mode=validated
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  prior_updated=$7
elif [ "$#" -eq 6 ] && [ "$1" = --snapshot ]; then
  mode=snapshot
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
else
  exit 0
fi

fm_pr_url_parse "$url" || exit 0
[ "$provider" = github ] && [ "$provider" = "$FM_PR_PROVIDER" ] || exit 0
[ "$host" = "$FM_PR_HOST" ] && [ "$path" = "$FM_PR_PATH" ] \
  && [ "$number" = "$FM_PR_NUMBER" ] || exit 0

decimal_greater_than() {
  local left=$1 right=$2 left_rest=$1 right_rest=$2
  while [ -n "$left_rest" ] && [ -n "$right_rest" ]; do
    left_rest=${left_rest:1}
    right_rest=${right_rest:1}
  done
  if [ -n "$left_rest" ]; then
    return 0
  fi
  [ -z "$right_rest" ] || return 1
  [[ "$left" > "$right" ]]
}

numeric_max() {
  local raw=$1 value normalized max=0
  while IFS= read -r value || [ -n "$value" ]; do
    [ -n "$value" ] || continue
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    normalized=$value
    while [ "${normalized#0}" != "$normalized" ] && [ "$normalized" != 0 ]; do
      normalized=${normalized#0}
    done
    if decimal_greater_than "$normalized" "$max"; then
      max=$normalized
    fi
  done <<EOF
$raw
EOF
  printf '%s\n' "$max"
}

github_ids() {
  local endpoint=$1 raw
  raw=$(gh api --paginate "$endpoint" --jq '.[].id' 2>/dev/null) || return 1
  numeric_max "$raw"
}

summary=$(gh api "/repos/$path/pulls/$number" \
  --jq '[if .merged_at != null then "merged" else .state end, ((.requested_reviewers | length) + (.requested_teams | length)), .updated_at] | @tsv' \
  2>/dev/null) || { printf '%s\n' 'unavailable github'; exit 0; }
IFS=$(printf '\t') read -r state requested updated extra <<EOF
$summary
EOF
[ -z "${extra:-}" ] || { printf '%s\n' 'unavailable github'; exit 0; }
case "$requested" in ''|*[!0-9]*) printf '%s\n' 'unavailable github'; exit 0 ;; esac
fm_pr_poll_updated_valid "$updated" \
  || { printf '%s\n' 'unavailable github'; exit 0; }
case "$state" in
  merged) printf '%s\n' merged; exit 0 ;;
  open|closed) ;;
  *) printf '%s\n' 'unavailable github'; exit 0 ;;
esac
if [ "$mode" = validated ] && [ "$updated" = "$prior_updated" ]; then
  printf 'unchanged %s %s\n' "$updated" "$requested"
  exit 0
fi

reviews=$(github_ids "/repos/$path/pulls/$number/reviews?per_page=100") \
  || { printf '%s\n' 'unavailable github'; exit 0; }
issue_comments=$(github_ids "/repos/$path/issues/$number/comments?per_page=100") \
  || { printf '%s\n' 'unavailable github'; exit 0; }
review_comments=$(github_ids "/repos/$path/pulls/$number/comments?per_page=100") \
  || { printf '%s\n' 'unavailable github'; exit 0; }
printf 'observed %s %s %s %s %s\n' \
  "$updated" "$reviews" "$issue_comments" "$review_comments" "$requested"
