#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It reports what actually moved on a pull request and stays silent otherwise,
# including on every error, so a failed lookup can never be read as movement.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# Two output shapes, and the difference is load-bearing:
#   merged        - the exact terminal token, unchanged, which the watcher
#                   routes through merge-outcome publication and poll retirement.
#   moved <state> - the pull request's current observable state, printed for
#                   every non-merged reading. It is a FINGERPRINT, not an event:
#                   this program is a pure function of the pull request and
#                   keeps no memory between runs, so an unchanged reading prints
#                   the same line every poll. Deciding what changed, and waking
#                   only then, belongs to the caller holding the previous
#                   reading (bin/fm-pr-lib.sh's observed-state marker).
#
# Only the GitHub branch reports movement. Reading GitLab's fields would need
# either a JSON processor firstmate does not require or an unverified reading of
# glab's rendered layout, so a GitLab merge request still reports its merge
# alone - and fm_pr_poll_covers_wait refuses to silence a timed recheck for one.
set -u
LC_ALL=C
export LC_ALL

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
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
    # One authenticated read covers every condition that voids a declared wait
    # on a pull request: both terminals through state, leaving draft through
    # isDraft, a rewritten or advanced branch through headRefOid, and a
    # maintainer acting on it through the submitted-review, issue-comment, and
    # review-decision counters. gh's own field selector composes the line, so
    # this needs no JSON processor on PATH. reviewDecision is the empty string,
    # not null, on a pull request nobody has reviewed, so `//` alone would leave
    # the field blank and every such reading would fail validation below and go
    # silent; tests/fm-pr-state-live-e2e.test.sh is what proves that against a
    # real pull request, since a hermetic fake gh can only replay an assumption.
    fingerprint=$(gh pr view "$url" \
      --json state,isDraft,headRefOid,reviewDecision,reviews,comments \
      -q '"state=\(.state) draft=\(.isDraft) head=\(.headRefOid[0:12]) reviews=\(.reviews|length) comments=\(.comments|length) decision=\(if (.reviewDecision // "") == "" then "NONE" else .reviewDecision end)"' \
      2>/dev/null) || exit 0
    # Revalidated against the exact shape this program promises, before either
    # token is printed. A truncated, reformatted, or partially-resolved reading
    # is silence, so no degraded output can be read as a merge or as movement.
    gh_shape='^state=(OPEN|CLOSED|MERGED) draft=(true|false) head=[0-9a-f]{12} reviews=[0-9]+ comments=[0-9]+ decision=[A-Z_]+$'
    [[ $fingerprint =~ $gh_shape ]] || exit 0
    case "$fingerprint" in
      'state=MERGED '*) printf '%s\n' merged ;;
      *) printf 'moved %s\n' "$fingerprint" ;;
    esac
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
