#!/usr/bin/env bash
# Report the live blockers that keep one GitHub pull request from being ready.
#
# This is a one-shot, read-only command. It reads the current pull request,
# required checks, submitted reviews, review requests, and review threads from
# GitHub at invocation time. It never posts, requests, approves, or merges.
# Advisory checks do not block and are omitted. Reviews apply only to the exact
# head they read; the latest review from each non-author reviewer is reported as
# VOIDED when its commit differs from the current head. GitHub exposes resolved
# review-thread state only through GraphQL, so this attended command must not be
# installed as an unattended monitor.
#
# For fleet-authored Artemis pull requests, readiness also requires at least one
# requested user and one requested team, and the title must carry a ticket such
# as ART-123. Those project conventions are deliberately local here rather than
# a new configuration or policy layer.
#
# Usage: fm-pr-state.sh <pr-url-or-number>
#   Prints one line per concrete blocker and nothing when none are found.
#   Blockers do not change the successful exit status; lookup or usage refusal
#   exits non-zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

die() {
  printf 'fm-pr-state: %s\n' "$*" >&2
  exit 2
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  usage
  exit 0
fi
[ "$#" -eq 1 ] || die "usage: fm-pr-state.sh <pr-url-or-number>"
command -v gh >/dev/null 2>&1 || die "gh is required"

INPUT=$1
if [[ "$INPUT" =~ ^[1-9][0-9]*$ ]]; then
  URL=$(gh pr view "$INPUT" --json url --jq .url) \
    || die "could not read pull request $INPUT"
else
  URL=$INPUT
fi
if ! fm_pr_url_parse "$URL" || [ "$FM_PR_PROVIDER" != github ]; then
  die "expected a GitHub pull-request URL or positive pull-request number"
fi

PATH_PART=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER
ENDPOINT="/repos/$PATH_PART/pulls/$NUMBER"

CORE=$(gh api "$ENDPOINT" --jq '
  "state=\(.state)",
  "merged_at=\(.merged_at // "")",
  "draft=\(.draft)",
  "mergeability=\(if .mergeable == null then "unknown" elif .mergeable then "mergeable" else "conflicting" end)",
  "head=\(.head.sha)",
  "base=\(.base.ref)",
  "title=\(.title)",
  "author=\(.user.login)",
  (.requested_reviewers[]? | "requested_user=\(.login)"),
  (.requested_teams[]? | "requested_team=\(.slug)")') || die "could not read $URL"

STATE=
MERGED_AT=
DRAFT=
MERGEABILITY=
HEAD=
BASE=
TITLE=
AUTHOR=
HAS_REQUESTED_USER=0
HAS_REQUESTED_TEAM=0
while IFS= read -r row; do
  case "$row" in
    state=*) STATE=${row#state=} ;;
    merged_at=*) MERGED_AT=${row#merged_at=} ;;
    draft=*) DRAFT=${row#draft=} ;;
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    head=*) HEAD=${row#head=} ;;
    base=*) BASE=${row#base=} ;;
    title=*) TITLE=${row#title=} ;;
    author=*) AUTHOR=${row#author=} ;;
    requested_user=*) HAS_REQUESTED_USER=1 ;;
    requested_team=*) HAS_REQUESTED_TEAM=1 ;;
  esac
done <<EOF
$CORE
EOF
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$MERGEABILITY" ] \
  && [ -n "$HEAD" ] && [ -n "$BASE" ] && [ -n "$TITLE" ] && [ -n "$AUTHOR" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

if [ -n "$MERGED_AT" ]; then
  printf 'STATE: merged at %s\n' "$MERGED_AT"
elif [ "$STATE" != open ]; then
  printf 'STATE: %s\n' "$STATE"
fi
[ "$DRAFT" = false ] || printf 'DRAFT: pull request is not ready for review\n'
case "$MERGEABILITY" in
  mergeable) ;;
  unknown) printf 'MERGEABILITY: unknown\n' ;;
  conflicting) printf 'MERGEABILITY: conflicting\n' ;;
  *) die "GitHub returned invalid mergeability for $URL" ;;
esac

REQUIRED=$(gh pr checks "$URL" --required --json name,state,bucket,workflow --jq '
  .[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"') \
  || die "could not read required checks for $URL"
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

if [ "$PATH_PART" = monalee-inc/artemis ]; then
  VIEWER=$(gh api user --jq .login) || die "could not identify the authenticated GitHub user"
  if [ "$AUTHOR" = "$VIEWER" ]; then
    [ "$HAS_REQUESTED_USER" -eq 1 ] || printf 'REQUESTED USER: none\n'
    [ "$HAS_REQUESTED_TEAM" -eq 1 ] || printf 'REQUESTED TEAM: none\n'
  fi
  [[ "$TITLE" =~ [A-Z][A-Z0-9]+-[0-9]+ ]] \
    || printf 'TITLE: missing ticket identifier\n'
fi

REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
  .[]
  | select(.user.login != null and .commit_id != null and .submitted_at != null)
  | [.user.login, .state, .commit_id, .submitted_at]
  | @tsv') || die "could not read reviews for $URL"
if [ -n "$REVIEWS" ]; then
  LATEST_REVIEWS=$(printf '%s\n' "$REVIEWS" | awk -F '\t' '
    !seen[$1] || $4 > latest[$1] { seen[$1] = 1; latest[$1] = $4; row[$1] = $0 }
    END { for (reviewer in row) print row[reviewer] }
  ' | LC_ALL=C sort)
  while IFS=$'\t' read -r reviewer review_state review_head _submitted_at; do
    [ "$reviewer" != "$AUTHOR" ] || continue
    case "$review_state" in
      APPROVED|CHANGES_REQUESTED|COMMENTED)
        if [ "$review_head" != "$HEAD" ]; then
          printf 'VOIDED REVIEW: %s %s at %s; current head %s\n' \
            "$reviewer" "$review_state" "$review_head" "$HEAD"
        elif [ "$review_state" = CHANGES_REQUESTED ]; then
          printf 'REVIEW: %s CHANGES_REQUESTED at %s\n' "$reviewer" "$HEAD"
        fi
        ;;
    esac
  done <<EOF
$LATEST_REVIEWS
EOF
fi

# GraphQL variable names must reach gh literally.
# shellcheck disable=SC2016
THREADS=$(gh api graphql --paginate \
  -F owner="$FM_PR_OWNER" \
  -F name="$FM_PR_REPO" \
  -F number="$NUMBER" \
  -f query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved comments(first:1){nodes{author{login}url}}}pageInfo{hasNextPage endCursor}}}}}' \
  --jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)
    | "UNRESOLVED THREAD: \(.comments.nodes[0].author.login // "unknown") \(.comments.nodes[0].url // "unknown")"') \
  || die "could not read review threads for $URL"
[ -z "$THREADS" ] || printf '%s\n' "$THREADS"
