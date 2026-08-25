#!/usr/bin/env bash
# Record and read which model family BUILT an authored pull request, carrying
# that fact on the forge beside the branch instead of relaying it between homes.
#
# A cross-family review is only independent if the reviewer knows the builder's
# family, and that fact otherwise lives only in the authoring home's task
# metadata. Any other home - a review lane, a second mate, a remote home - can
# reach the forge but not that metadata, so it had to ask and wait. This script
# closes that gap in the one place both sides already share.
#
# Usage: fm-pr-provenance.sh stamp <task-id>
#        fm-pr-provenance.sh show <repo-dir> <commit-ish> [--base <ref>]
#
#   stamp  The worker runs this in its own task after the branch is pushed.
#          It reads harness=, model=, and effort= from state/<task-id>.meta,
#          resolves the harness to its verified family, and publishes the record
#          for the task worktree's current HEAD.
#   show   Any clone of the project resolves the record for one exact head.
#          Prints family=, model=, and effort= on separate lines, and exits 3
#          when the identity cannot be established.
#
# WHERE THE RECORD LIVES, and why. The record is a Git note under
# refs/notes/build-provenance. That ref is pushed to and served by the forge, so
# every home that can reach the forge can read it, but no forge renders it in a
# pull request, a commit view, or a file listing. The project's own readers see
# branches, commit messages, and diffs; provenance belongs to the fleet's review
# machinery, not to them, so it is published where it is reachable by tooling and
# invisible to readers. Nothing fleet-internal - no task id, no branch prefix, no
# role name - is written into the record for the same reason.
#
# WHY A PULL REQUEST'S OWN COMMITS ARE SEARCHED. A validation round pushes fix
# commits after the record is written, so the reviewed head is usually a
# descendant of the stamped commit rather than the stamped commit itself. `show`
# therefore searches every commit the pull request adds to the base and requires
# them to agree: the same worker built all of them. Commits reachable from the
# base are never searched, so a merged branch's record can never be attributed
# to unrelated work.
#
# WHAT REFUSAL MEANS. No record, disagreeing records, an unverified family, or a
# malformed record all exit 3 without printing an identity. A quiet assumption
# here would silently destroy the independence the review depends on, so a
# missing fact is reported rather than filled in.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"

NOTES_REF=refs/notes/build-provenance
# A pull request that adds more commits than this is not silently truncated:
# the walk stops and the identity is reported as unestablished.
MAX_PR_COMMITS=500
PUSH_ATTEMPTS=3

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# Exit 3 is the one "identity not established" outcome every caller keys on.
unestablished() {
  printf 'error: cannot establish builder family for %s: %s\n' "$1" "$2" >&2
  exit 3
}

# Record values stay to an unambiguous, shell-safe alphabet. A forge ref is
# writable by anyone who can push, so a record is untrusted input until it
# parses.
value_valid() {  # <value>
  case "${1-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    [!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

meta_field() {  # <meta-file> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# --- stamp ------------------------------------------------------------------

cmd_stamp() {
  local id=$1 meta harness model effort worktree family record sha attempt fetched notes_err

  case "$id" in
    ''|*/*|.*|*[!A-Za-z0-9._-]*) die "invalid task id" ;;
  esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no task metadata for $id at $meta"

  harness=$(meta_field "$meta" harness)
  [ -n "$harness" ] || die "task metadata for $id records no harness"
  family=$(fm_control_harness_family "$harness") \
    || die "harness '$harness' is not a verified adapter, so its builder family cannot be recorded"

  model=$(meta_field "$meta" model)
  effort=$(meta_field "$meta" effort)
  worktree=$(meta_field "$meta" worktree)
  [ -n "$worktree" ] || die "task metadata for $id records no worktree"
  [ -d "$worktree" ] || die "task worktree is missing: $worktree"

  record="family=$family"
  if [ -n "$model" ]; then
    value_valid "$model" || die "recorded model '$model' is not a usable value"
    record="$record"$'\n'"model=$model"
  fi
  if [ -n "$effort" ]; then
    value_valid "$effort" || die "recorded effort '$effort' is not a usable value"
    record="$record"$'\n'"effort=$effort"
  fi

  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "task worktree is not a git work tree: $worktree"
  sha=$(git -C "$worktree" rev-parse --verify HEAD 2>/dev/null) \
    || die "task worktree has no commit to record: $worktree"
  git -C "$worktree" remote get-url origin >/dev/null 2>&1 \
    || die "task worktree has no origin remote, so nothing can be published"

  # A record for a commit the forge does not have is unreadable by every other
  # home, which is exactly the silence this exists to remove.
  fetched=1
  git -C "$worktree" fetch -q origin 2>/dev/null || fetched=0
  if [ -n "$(git -C "$worktree" rev-list --max-count=1 "$sha" --not --remotes=origin 2>/dev/null)" ]; then
    if [ "$fetched" = 0 ]; then
      die "could not confirm commit $sha is on the forge: the fetch from origin failed"
    fi
    die "commit $sha is not on the forge yet; push the branch before recording it"
  fi

  # Every branch shares one notes ref, so a concurrent push can reject this one.
  # Re-reading the forge's ref before re-applying keeps other branches' records
  # intact instead of overwriting them.
  attempt=0
  while :; do
    git -C "$worktree" fetch -q origin "+$NOTES_REF:$NOTES_REF" 2>/dev/null || true
    # -f makes re-stamping idempotent; its "Overwriting existing notes" chatter
    # is held back so only a real failure reaches the caller.
    if ! notes_err=$(git -C "$worktree" notes --ref="$NOTES_REF" add -f -m "$record" "$sha" 2>&1 >/dev/null); then
      printf '%s\n' "$notes_err" >&2
      die "could not write the build record for $sha"
    fi
    if git -C "$worktree" push -q origin "$NOTES_REF" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge "$PUSH_ATTEMPTS" ]; then
      die "could not publish the build record for $sha to the forge"
    fi
  done

  printf 'recorded: %s %s\n' "$sha" "$(printf '%s' "$record" | tr '\n' ' ')"
}

# --- show -------------------------------------------------------------------

# Print a validated record, or nothing when the note is absent or unusable.
read_record() {  # <repo> <commit>
  local repo=$1 commit=$2 note line key family='' seen=' ' out=''
  note=$(git -C "$repo" notes --ref="$NOTES_REF" show "$commit" 2>/dev/null) || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%=*}
    case "$line" in
      family=*|model=*|effort=*) ;;
      *) return 1 ;;
    esac
    # A repeated key is two answers to one question, which is a guess either way.
    case "$seen" in
      *" $key "*) return 1 ;;
    esac
    seen="$seen$key "
    value_valid "${line#*=}" || return 1
    if [ "$key" = family ]; then
      # A family only counts when it is one the fleet actually verifies.
      family=$(fm_control_harness_family "${line#family=}") || return 1
      [ "$family" = "${line#family=}" ] || return 1
    fi
    if [ -z "$out" ]; then
      out=$line
    else
      out="$out"$'\n'"$line"
    fi
  done <<EOF
$note
EOF
  [ -n "$family" ] || return 1
  printf '%s\n' "$out"
}

default_base() {  # <repo>
  local repo=$1 ref branch
  ref=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "$ref"
    return 0
  fi
  for branch in origin/main origin/master main master; do
    if git -C "$repo" rev-parse --verify --quiet "$branch^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

cmd_show() {
  local repo=$1 want=$2 base=${3-} sha commit commits found='' record count=0

  [ -d "$repo" ] || die "no such directory: $repo"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git work tree: $repo"

  sha=$(git -C "$repo" rev-parse --verify --quiet "$want^{commit}" 2>/dev/null || true)
  if [ -z "$sha" ]; then
    git -C "$repo" fetch -q origin "$want" 2>/dev/null || true
    sha=$(git -C "$repo" rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null || true)
  fi
  [ -n "$sha" ] || die "cannot resolve $want in $repo"

  if [ -z "$base" ]; then
    base=$(default_base "$repo") \
      || die "cannot determine the base branch for $repo; pass --base"
  fi
  git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1 \
    || die "cannot resolve base $base in $repo"

  git -C "$repo" fetch -q origin "+$NOTES_REF:$NOTES_REF" 2>/dev/null || true

  # The pull request's own commits, newest first. An empty range means the head
  # is already contained in the base, so only the head itself is considered.
  commits=$(git -C "$repo" rev-list --max-count=$((MAX_PR_COMMITS + 1)) "$base..$sha" 2>/dev/null || true)
  [ -n "$commits" ] || commits=$sha

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_PR_COMMITS" ]; then
      unestablished "$sha" "the change carries more than $MAX_PR_COMMITS commits to search"
    fi
    record=$(read_record "$repo" "$commit") || continue
    if [ -z "$found" ]; then
      found=$record
    elif [ "$found" != "$record" ]; then
      unestablished "$sha" "conflicting build records inside the same change"
    fi
  done <<EOF
$commits
EOF

  [ -n "$found" ] || unestablished "$sha" "no build record was published for this change"
  printf '%s\n' "$found"
}

# --- entry ------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

VERB=${1:-}
shift || true
case "$VERB" in
  stamp)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    cmd_stamp "$1"
    ;;
  show)
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    SHOW_REPO=$1
    SHOW_WANT=$2
    shift 2
    SHOW_BASE=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --base)
          [ "$#" -ge 2 ] || { usage >&2; exit 2; }
          SHOW_BASE=$2
          shift 2
          ;;
        *) usage >&2; exit 2 ;;
      esac
    done
    cmd_show "$SHOW_REPO" "$SHOW_WANT" "$SHOW_BASE"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
