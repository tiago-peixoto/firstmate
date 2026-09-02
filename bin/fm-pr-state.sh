#!/usr/bin/env bash
# Report the live blockers that keep one GitHub pull request from being ready.
#
# This is a one-shot, read-only command. It reads the current pull request,
# required checks, submitted reviews, and review requests from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# Advisory checks do not block and are omitted. Reviews apply only to the exact
# head they read. Every stale CHANGES_REQUESTED verdict is reported as blocking,
# stale approvals are labeled informational, and stale COMMENTED reviews are
# omitted as noise. Unresolved review-thread state is not reported because
# GitHub's REST API does not expose resolution and unattended commands may not
# use GraphQL.
#
# For fleet-authored Artemis pull requests, readiness also requires at least one
# requested user and one requested team. An Artemis pull request whose branch or
# body names a ticket must carry that same identifier in its title. Those
# project conventions are deliberately local here rather than a new policy.
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
  "head=\(.head.sha)",
  "base=\(.base.ref)",
  "title=\(.title)",
  "branch_ticket=\(([.head.ref | scan("ART-[0-9]+"; "i")][0] // "") | ascii_upcase)",
  "body_ticket=\(([.body // "" | scan("ART-[0-9]+"; "i")][0] // "") | ascii_upcase)",
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
BRANCH_TICKET=
BODY_TICKET=
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
    branch_ticket=*) BRANCH_TICKET=${row#branch_ticket=} ;;
    body_ticket=*) BODY_TICKET=${row#body_ticket=} ;;
    author=*) AUTHOR=${row#author=} ;;
    requested_user=*) HAS_REQUESTED_USER=1 ;;
    requested_team=*) HAS_REQUESTED_TEAM=1 ;;
  esac
done <<EOF
$CORE
EOF
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$BASE" ] \
  && [ -n "$TITLE" ] && [ -n "$AUTHOR" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

MERGE_VIEW=$(gh pr view "$URL" --json mergeable,headRefOid --jq '
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "head=\(.headRefOid)"') || die "could not read mergeability for $URL"
MERGE_HEAD=
while IFS= read -r row; do
  case "$row" in
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    head=*) MERGE_HEAD=${row#head=} ;;
  esac
done <<EOF
$MERGE_VIEW
EOF
[ -n "$MERGEABILITY" ] && [ -n "$MERGE_HEAD" ] \
  || die "GitHub returned incomplete mergeability for $URL"
[ "$MERGE_HEAD" = "$HEAD" ] \
  || die "pull-request head changed while reading $URL"

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
  TICKET=$BRANCH_TICKET
  [ -n "$TICKET" ] || TICKET=$BODY_TICKET
  if [ -n "$TICKET" ] && ! printf '%s\n' "$TITLE" | grep -Fqi -- "$TICKET"; then
    printf 'TITLE: missing ticket identifier %s\n' "$TICKET"
  fi
fi

REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
  .[]
  | select(.user.login != null and .commit_id != null and .submitted_at != null)
  | [.user.login, .state, .commit_id, .submitted_at]
  | @tsv') || die "could not read reviews for $URL"
if [ -n "$REVIEWS" ]; then
  while IFS=$'\t' read -r reviewer review_state review_head _submitted_at; do
    [ "$reviewer" != "$AUTHOR" ] || continue
    [ "$review_head" != "$HEAD" ] || continue
    case "$review_state" in
      CHANGES_REQUESTED)
        printf 'STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s; current head %s\n' \
          "$reviewer" "$review_head" "$HEAD"
        ;;
      APPROVED)
        printf 'VOIDED APPROVAL (informational): %s at %s; current head %s\n' \
          "$reviewer" "$review_head" "$HEAD"
        ;;
    esac
  done <<EOF
$REVIEWS
EOF

  CURRENT_LATEST=$(printf '%s\n' "$REVIEWS" | awk -F '\t' -v head="$HEAD" '
    $3 == head && (!seen[$1] || $4 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $4
      row[$1] = $0
    }
    END { for (reviewer in row) print row[reviewer] }
  ')
  while IFS=$'\t' read -r reviewer review_state _review_head _submitted_at; do
    [ "$reviewer" != "$AUTHOR" ] || continue
    [ "$review_state" != CHANGES_REQUESTED ] \
      || printf 'REVIEW: %s CHANGES_REQUESTED at %s\n' "$reviewer" "$HEAD"
  done <<EOF
$CURRENT_LATEST
EOF
fi
