#!/usr/bin/env bash
# Read one validated GitHub pull request for review and comment activity.
# Usage: fm-pr-review-poll.sh --snapshot <provider> <url> <host> <path> <number>
#        fm-pr-review-poll.sh --validated <provider> <url> <host> <path> <number> <prior-updated>
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

numeric_max() {
  local raw=$1 value normalized candidate max=0
  while IFS= read -r value || [ -n "$value" ]; do
    [ -n "$value" ] || continue
    case "$value" in *[!0-9]*) return 1 ;; esac
    normalized=$value
    while [ "${normalized#0}" != "$normalized" ] && [ "$normalized" != 0 ]; do
      normalized=${normalized#0}
    done
    candidate=$(printf '%s\n%s\n' "$max" "$normalized" | sort -n | tail -n 1) || return 1
    [ "$candidate" != "$normalized" ] || max=$normalized
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
