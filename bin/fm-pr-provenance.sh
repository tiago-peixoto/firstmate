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
# Git carries `refs/notes/*` under no default refspec, so neither side happens by
# accident: `stamp` pushes the ref explicitly and `show` fetches it explicitly.
# Every transient fetch and note edit uses a process-private local ref because
# linked worktrees share refs inside one clone. `stamp` re-reads the forge before
# every push attempt and confirms its exact record after a successful push.
# `show` refreshes the requested head, authoritative base, and notes ref without
# trusting FETCH_HEAD or a pooled clone's remote-tracking refs.
# That is also why a local fixture cannot prove this works - a note that never
# left the machine reads back identically. docs/verification/build-provenance.md
# holds the dated evidence against a real forge and the commands that refresh it.
#
# WHY A PULL REQUEST'S OWN COMMITS ARE SEARCHED. A validation round pushes fix
# commits after the record is written, so the reviewed head is usually a
# descendant of the stamped commit rather than the stamped commit itself. `show`
# therefore searches every commit the pull request adds to the base and requires
# them to agree: the same worker built all of them. Commits reachable from the
# base are never searched, so a merged branch's record can never be attributed
# to unrelated work.
#
# WHAT REFUSAL MEANS. An unresolvable head, an unrefreshable base or notes ref,
# no record, disagreeing records, an unverified family, or a malformed record all
# exit 3 without printing an identity. A quiet assumption here would silently
# destroy the independence the review depends on, so a missing fact is reported
# rather than filled in.
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
PRIVATE_REPO=
PRIVATE_REFS=

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

cleanup_private_refs() {
  local ref
  [ -n "$PRIVATE_REPO" ] || return 0
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    git -C "$PRIVATE_REPO" update-ref -d "$ref" >/dev/null 2>&1 || true
  done <<EOF
$PRIVATE_REFS
EOF
  return 0
}

register_private_ref() {  # <repo> <ref>
  local repo=$1 ref=$2
  if [ -n "$PRIVATE_REPO" ] && [ "$PRIVATE_REPO" != "$repo" ]; then
    die "cannot prepare private refs in more than one repository"
  fi
  PRIVATE_REPO=$repo
  git -C "$repo" update-ref -d "$ref" >/dev/null 2>&1 \
    || die "could not prepare private ref $ref"
  if [ -z "$PRIVATE_REFS" ]; then
    PRIVATE_REFS=$ref
  else
    PRIVATE_REFS="$PRIVATE_REFS"$'\n'"$ref"
  fi
}

trap cleanup_private_refs EXIT

# Record values stay to an unambiguous, shell-safe alphabet. A forge ref is
# writable by anyone who can push, so a record is untrusted input until it
# parses.
value_valid() {  # <value>
  case "${1-}" in
    '') return 1 ;;
    *[!A-Za-z0-9._/-]*) return 1 ;;
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
  local private_ref remote_notes published

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

  private_ref="refs/notes/fm-pr-provenance-stamp-$$"
  register_private_ref "$worktree" "$private_ref"
  attempt=0
  while :; do
    remote_notes=$(git -C "$worktree" ls-remote origin "$NOTES_REF" 2>/dev/null) \
      || die "could not publish the build record for $sha: existing forge records could not be read"
    if [ -n "$remote_notes" ]; then
      git -C "$worktree" fetch -q origin "+$NOTES_REF:$private_ref" 2>/dev/null \
        || die "could not publish the build record for $sha: existing forge records could not be fetched"
    else
      git -C "$worktree" update-ref -d "$private_ref" >/dev/null 2>&1 \
        || die "could not prepare the build record for $sha"
    fi
    # -f makes re-stamping idempotent; its "Overwriting existing notes" chatter
    # is held back so only a real failure reaches the caller.
    if ! notes_err=$(git -C "$worktree" notes --ref="$private_ref" add -f -m "$record" "$sha" 2>&1 >/dev/null); then
      printf '%s\n' "$notes_err" >&2
      die "could not write the build record for $sha"
    fi
    if git -C "$worktree" push -q origin "$private_ref:$NOTES_REF" 2>/dev/null; then
      remote_notes=$(git -C "$worktree" ls-remote origin "$NOTES_REF" 2>/dev/null) \
        || die "could not verify the published build record for $sha on the forge"
      [ -n "$remote_notes" ] \
        || die "could not verify the published build record for $sha on the forge"
      git -C "$worktree" fetch -q origin "+$NOTES_REF:$private_ref" 2>/dev/null \
        || die "could not verify the published build record for $sha on the forge"
      published=$(git -C "$worktree" notes --ref="$private_ref" show "$sha" 2>/dev/null) \
        || die "could not verify the published build record for $sha on the forge"
      [ "$published" = "$record" ] \
        || die "could not verify the published build record for $sha on the forge"
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
read_record() {  # <repo> <commit> <notes-ref>
  local repo=$1 commit=$2 notes_ref=$3 note line key family='' seen=' ' out=''
  note=$(git -C "$repo" notes --ref="$notes_ref" show "$commit" 2>/dev/null) || return 1
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

refresh_base() {  # <repo> <base> <private-ref>
  local repo=$1 base=$2 private_ref=$3 source resolved
  case "$base" in
    *[!0-9A-Fa-f]*) ;;
    *)
      if [ "${#base}" -eq 40 ]; then
        resolved=$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null) \
          || return 1
        printf '%s\n' "$resolved"
        return 0
      fi
      ;;
  esac
  case "$base" in
    origin/HEAD|refs/remotes/origin/HEAD) source=HEAD ;;
    origin/*) source="refs/heads/${base#origin/}" ;;
    refs/remotes/origin/*) source="refs/heads/${base#refs/remotes/origin/}" ;;
    refs/*) source=$base ;;
    *) source="refs/heads/$base" ;;
  esac
  git -C "$repo" fetch -q origin "+$source:$private_ref" 2>/dev/null || return 1
  resolved=$(git -C "$repo" rev-parse --verify --quiet "$private_ref^{commit}" 2>/dev/null) \
    || return 1
  [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

cmd_show() {
  local repo=$1 want=$2 base=${3-} sha commit commits found='' record count=0
  local head_ref base_ref notes_ref base_sha remote_notes head_source

  [ -d "$repo" ] || die "no such directory: $repo"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a git work tree: $repo"

  head_ref="refs/fm-pr-provenance/show-head-$$"
  base_ref="refs/fm-pr-provenance/show-base-$$"
  notes_ref="refs/notes/fm-pr-provenance-show-$$"
  register_private_ref "$repo" "$head_ref"
  register_private_ref "$repo" "$base_ref"
  register_private_ref "$repo" "$notes_ref"

  sha=$(git -C "$repo" rev-parse --verify --quiet "$want^{commit}" 2>/dev/null || true)
  if [ -z "$sha" ]; then
    case "$want" in
      origin/*) head_source="refs/heads/${want#origin/}" ;;
      refs/remotes/origin/*) head_source="refs/heads/${want#refs/remotes/origin/}" ;;
      *) head_source=$want ;;
    esac
    git -C "$repo" fetch -q origin "+$head_source:$head_ref" 2>/dev/null \
      || unestablished "$want" "the requested head could not be fetched from origin"
    sha=$(git -C "$repo" rev-parse --verify --quiet "$head_ref^{commit}" 2>/dev/null || true)
  fi
  [ -n "$sha" ] \
    || unestablished "$want" "the requested head did not resolve to a commit"

  if [ -z "$base" ]; then
    base=$(default_base "$repo") \
      || unestablished "$sha" "the authoritative base could not be determined; pass --base"
  fi
  base_sha=$(refresh_base "$repo" "$base" "$base_ref") \
    || unestablished "$sha" "the authoritative base $base could not be refreshed from origin"

  remote_notes=$(git -C "$repo" ls-remote origin "$NOTES_REF" 2>/dev/null) \
    || unestablished "$sha" "the build records could not be read from origin"
  [ -n "$remote_notes" ] \
    || unestablished "$sha" "no build record was published for this change"
  git -C "$repo" fetch -q origin "+$NOTES_REF:$notes_ref" 2>/dev/null \
    || unestablished "$sha" "the build records could not be refreshed from origin"

  # The pull request's own commits, newest first.
  commits=$(git -C "$repo" rev-list --max-count=$((MAX_PR_COMMITS + 1)) "$base_sha..$sha" 2>/dev/null || true)
  [ -n "$commits" ] \
    || unestablished "$sha" "the requested head adds no commits to the authoritative base"

  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    count=$((count + 1))
    if [ "$count" -gt "$MAX_PR_COMMITS" ]; then
      unestablished "$sha" "the change carries more than $MAX_PR_COMMITS commits to search"
    fi
    record=$(read_record "$repo" "$commit" "$notes_ref") || continue
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
