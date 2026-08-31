#!/usr/bin/env bash
# Read one validated GitHub pull request for review and comment activity.
# Machine observations are consumed by bin/fm-watch.sh.
set -u
LC_ALL=C
export LC_ALL

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

[ "$provider" = github ] || exit 0
[ "$host" = github.com ] || exit 0
case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

owner=${path%%/*}
repo=${path#*/}
[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
case "$owner" in
  *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
esac
[ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0

numeric_max() {
  local raw=$1 value normalized max=0
  while IFS= read -r value || [ -n "$value" ]; do
    [ -n "$value" ] || continue
    case "$value" in *[!0-9]*) return 1 ;; esac
    normalized=$value
    while [ "${#normalized}" -gt 1 ] && [ "${normalized#0}" != "$normalized" ]; do
      normalized=${normalized#0}
    done
    if [ "${#normalized}" -gt "${#max}" ] \
      || { [ "${#normalized}" -eq "${#max}" ] && [ "$normalized" -gt "$max" ]; }; then
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
[[ "$updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
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
