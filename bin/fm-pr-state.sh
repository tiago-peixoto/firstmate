#!/usr/bin/env bash
# Report the live blockers that keep one GitHub pull request from being ready.
#
# This is a one-shot, read-only command. It reads the current pull request,
# required checks, submitted reviews, and review requests from GitHub at
# invocation time. It never posts, requests, approves, or merges.
# Ready means nothing is left for the author: a pull request that only awaits
# an approval (reviewDecision REVIEW_REQUIRED) is not reported as blocked.
# Advisory checks do not block and are omitted. GitHub's reviewDecision owns
# whether reviews block; review history is printed only to explain
# CHANGES_REQUESTED, naming each reviewer whose latest verdict still requests
# changes and marking it STALE when it was left at a superseded head.
# Unresolved review-thread state is not reported because GitHub's REST API does
# not expose resolution and unattended commands may not use GraphQL.
#
# For fleet-authored Artemis pull requests, readiness also requires at least one
# requested user and one requested team. A user request is satisfied by a
# pending request or by a review a human already submitted; the team check
# reads pending team requests only, because a submitted review does not reveal
# team membership. An Artemis pull request whose branch or body names a ticket
# must carry that same identifier in its title. Those project conventions are
# deliberately local here rather than a new policy.
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
    head=*) HEAD=${row#head=} ;;
    base=*) BASE=${row#base=} ;;
    title=*) TITLE=${row#title=} ;;
    branch_ticket=*) BRANCH_TICKET=${row#branch_ticket=} ;;
    body_ticket=*) BODY_TICKET=${row#body_ticket=} ;;
    author=*) AUTHOR=${row#author=} ;;
    requested_user=*) HAS_REQUESTED_USER=1 ;;
    requested_team=*) HAS_REQUESTED_TEAM=1 ;;
  esac
done <<EOF_CORE
$CORE
EOF_CORE
[ -n "$STATE" ] && [ -n "$DRAFT" ] && [ -n "$HEAD" ] && [ -n "$BASE" ] \
  && [ -n "$TITLE" ] && [ -n "$AUTHOR" ] \
  || die "GitHub returned incomplete pull-request state for $URL"

MERGE_VIEW=$(gh pr view "$URL" --json mergeable,headRefOid,reviewDecision --jq '
  "mergeability=\(if .mergeable == null or .mergeable == "UNKNOWN" then "unknown" else (.mergeable | ascii_downcase) end)",
  "head=\(.headRefOid)",
  "review_decision=\(.reviewDecision // "")"') || die "could not read mergeability and review decision for $URL"
MERGE_HEAD=
REVIEW_DECISION=
while IFS= read -r row; do
  case "$row" in
    mergeability=*) MERGEABILITY=${row#mergeability=} ;;
    head=*) MERGE_HEAD=${row#head=} ;;
    review_decision=*) REVIEW_DECISION=${row#review_decision=} ;;
  esac
done <<EOF_VIEW
$MERGE_VIEW
EOF_VIEW
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

GH_STDERR=$(mktemp "${TMPDIR:-/tmp}/fm-pr-state.XXXXXX") \
  || die "could not create temporary file"
trap 'rm -f "$GH_STDERR"' EXIT INT TERM
if ! REQUIRED=$(gh pr checks "$URL" --required --json name,state,bucket,workflow --jq '
  .[]
  | select(.bucket != "pass" and .bucket != "skipping")
  | "REQUIRED CHECK: \(.name) (\(.state))"' 2>"$GH_STDERR"); then
  grep -Eq "^no (required )?checks reported on the '" "$GH_STDERR" || {
    cat "$GH_STDERR" >&2
    die "could not read required checks for $URL"
  }
  REQUIRED=
fi
[ -z "$REQUIRED" ] || printf '%s\n' "$REQUIRED"

REVIEWS=$(gh api "$ENDPOINT/reviews?per_page=100" --paginate --jq '
  .[]
  | select(.user.login != null and .commit_id != null and .submitted_at != null)
  | [.user.login, .user.type, .state, .commit_id, .submitted_at]
  | @tsv') || die "could not read reviews for $URL"

if [ "$PATH_PART" = monalee-inc/artemis ]; then
  VIEWER=$(gh api user --jq .login) || die "could not identify the authenticated GitHub user"
  if [ "$AUTHOR" = "$VIEWER" ]; then
    HUMAN_REVIEWER=$(printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" '
      NF == 5 && $1 != author && $2 != "Bot" { print $1; exit }')
    [ "$HAS_REQUESTED_USER" -eq 1 ] || [ -n "$HUMAN_REVIEWER" ] \
      || printf 'REQUESTED USER: none\n'
    [ "$HAS_REQUESTED_TEAM" -eq 1 ] || printf 'REQUESTED TEAM: none\n'
  fi
  TICKET=$BRANCH_TICKET
  [ -n "$TICKET" ] || TICKET=$BODY_TICKET
  if [ -n "$TICKET" ] \
    && ! printf '%s\n' "$TITLE" | grep -Eqi -- "(^|[^A-Za-z0-9-])${TICKET}([^0-9]|$)"; then
    printf 'TITLE: missing ticket identifier %s\n' "$TICKET"
  fi
fi

if [ "$REVIEW_DECISION" = CHANGES_REQUESTED ]; then
  printf 'REVIEW DECISION: CHANGES_REQUESTED\n'
  printf '%s\n' "$REVIEWS" | awk -F '\t' -v author="$AUTHOR" -v head="$HEAD" '
    NF == 5 && $1 != author && $3 != "COMMENTED" && (!seen[$1] || $5 >= latest[$1]) {
      seen[$1] = 1
      latest[$1] = $5
      state[$1] = $3
      commit[$1] = $4
    }
    END {
      for (reviewer in state) {
        if (state[reviewer] != "CHANGES_REQUESTED") continue
        if (commit[reviewer] == head)
          printf "REVIEW: %s CHANGES_REQUESTED at %s\n", reviewer, head
        else
          printf "STALE BLOCKING REVIEW: %s CHANGES_REQUESTED at %s; current head %s\n", \
            reviewer, commit[reviewer], head
      }
    }' | LC_ALL=C sort
fi
