#!/usr/bin/env bash
# Refuse to let the validation pipeline open a pull request anywhere except this
# home's configured push target.
#
# Usage:
#   fm-nm-pr-target.sh check [<repo>]
#       Read only. Print the configured push target and the repository the
#       pipeline would open a pull request against, and exit 0 only when they are
#       the same place. Exits 4 on a mismatch or on anything unreadable.
#   fm-nm-pr-target.sh install [<repo>]
#       Idempotently install the pre-push guard into <repo>'s hook directory, so
#       a pipeline run cannot start while the targets disagree. Prints one line
#       saying whether it installed, repaired, or found the guard current.
#       Refuses to replace a foreign pre-push hook it did not write.
#   fm-nm-pr-target.sh installed [<repo>]
#       Read only. Exit 0 when the current guard is installed, 1 when it is
#       absent or stale, 4 when a foreign hook occupies the slot.
#   fm-nm-pr-target.sh hook <remote-name> <remote-url>
#       The pre-push hook body. Allows every push that is not entering the
#       pipeline; for a gate push, refuses unless the targets agree.
#
# WHY A PRE-PUSH HOOK. bin/fm-nm-pr-target-lib.sh's header owns the full
# rationale. In short: `no-mistakes axi run` enters the pipeline with a real
# `git push <gate> HEAD:refs/heads/<branch>` and no `--no-verify`, the tool's
# rerun fallback is gated on that push having succeeded, and Git runs the hook
# before the push is offered to the gate. Refusing there is what makes the wrong
# pull-request target unreachable instead of merely reported. A pull request
# cannot be un-sent, so a check that fires after the PR exists is too late.
#
# The guard never refuses an ordinary push. `git push origin`, a fork push, and
# any other remote are untouched; only a push entering the validation pipeline is
# checked. `git push --no-verify` bypasses hooks by design and is a deliberate
# operator act, not a path the pipeline itself can take.
#
# SCOPE OF ONE INSTALL. Hooks live in the repository's common Git directory, so
# one install covers the primary checkout and every linked task worktree - which
# is exactly the population that runs the pipeline. A separate clone (the private
# fork-integration clone, a project clone) has its own hook directory and is
# guarded by its own install; bin/fm-bootstrap.sh installs this home's.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-nm-pr-target-lib.sh
. "$SCRIPT_DIR/fm-nm-pr-target-lib.sh"

# Bumped whenever the installed shim's bytes change, so `install` can recognize
# and repair its own older copy while still refusing a hook it did not write.
FM_NM_TARGET_HOOK_VERSION=1
FM_NM_TARGET_HOOK_MARKER='fm-nm-pr-target guard'

usage() {
  sed -n '2,/^set -eu$/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() {
  printf 'fm-nm-pr-target: %s\n' "$*" >&2
  exit 2
}

repo_real() {
  [ -d "$1" ] || return 1
  (cd "$1" && pwd -P)
}

hooks_dir() { # <repo>
  local repo=$1 configured common
  # An explicit core.hooksPath wins, exactly as Git resolves it: absolute is
  # used as-is, relative is taken from the working-tree root.
  configured=$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)
  if [ -n "$configured" ]; then
    case "$configured" in
      /*) printf '%s\n' "$configured" ;;
      *) printf '%s/%s\n' "$(git -C "$repo" rev-parse --show-toplevel)" "$configured" ;;
    esac
    return 0
  fi
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  printf '%s/hooks\n' "$common"
}

# The installed shim stays a thin forwarder: the guard's logic lives in this
# tracked script, so landing a change to it takes effect without reinstalling.
hook_body() {
  cat <<EOF
#!/usr/bin/env bash
# $FM_NM_TARGET_HOOK_MARKER v$FM_NM_TARGET_HOOK_VERSION - installed by bin/fm-nm-pr-target.sh.
# Forwards to the tracked guard so its logic can change without a reinstall.
# Remove with: git config --unset core.hooksPath (if set) and delete this file.
#
# The recorded path is where the guard lived at install time. If the checkout was
# moved since, fall back to this worktree's own copy rather than turning every
# ordinary push into collateral damage; a relocated home repairs the recorded
# path at its next session start anyway. If NEITHER exists, exec fails and the
# push is refused, which is the right direction for a checkout that has lost its
# own guard.
set -eu
guard=$(printf '%q' "$FM_ROOT/bin/fm-nm-pr-target.sh")
if [ ! -x "\$guard" ]; then
  top=\$(git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "\$top" ] && [ -x "\$top/bin/fm-nm-pr-target.sh" ]; then
    guard="\$top/bin/fm-nm-pr-target.sh"
  else
    echo "REFUSED: the pull-request target guard is installed but its script is missing (\$guard); reinstall it with fm-nm-pr-target.sh install, and do not push around it." >&2
    exit $FM_NM_TARGET_EXIT
  fi
fi
exec "\$guard" hook "\$@"
EOF
}

hook_state() { # <hook-path> -> echoes current|stale|foreign|absent
  local path=$1
  if [ ! -e "$path" ]; then
    printf 'absent\n'
    return 0
  fi
  if ! grep -q "$FM_NM_TARGET_HOOK_MARKER" "$path" 2>/dev/null; then
    printf 'foreign\n'
    return 0
  fi
  if [ -f "$path" ] && [ ! -L "$path" ] && hook_body | cmp -s - "$path"; then
    printf 'current\n'
    return 0
  fi
  printf 'stale\n'
}

cmd_check() {
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  local repo
  repo=$(repo_real "${1:-$FM_ROOT}") || die "not a directory: ${1:-$FM_ROOT}"
  if fm_nm_target_assert "$repo"; then
    printf 'pr-target: ok push-target=%s pr-base=%s\n' \
      "$FM_NM_TARGET_CONFIGURED" "$FM_NM_TARGET_REGISTERED"
    return 0
  fi
  printf 'pr-target: REFUSED %s\n' "$FM_NM_TARGET_REASON" >&2
  exit "$FM_NM_TARGET_EXIT"
}

cmd_install() {
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  local repo dir path state tmp
  repo=$(repo_real "${1:-$FM_ROOT}") || die "not a directory: ${1:-$FM_ROOT}"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a Git worktree: $repo"
  dir=$(hooks_dir "$repo") || die "cannot resolve the hook directory for $repo"
  path="$dir/pre-push"
  state=$(hook_state "$path")
  case "$state" in
    current)
      printf 'pr-target-guard: current %s\n' "$path"
      return 0 ;;
    foreign)
      # Never clobber a hook someone else owns; say what is in the way instead.
      printf 'pr-target-guard: refused %s (a pre-push hook this guard did not write already exists)\n' "$path" >&2
      exit "$FM_NM_TARGET_EXIT" ;;
  esac
  mkdir -p "$dir" || die "cannot create the hook directory: $dir"
  tmp=$(mktemp "$dir/.pre-push.XXXXXX") || die "cannot write into the hook directory: $dir"
  hook_body > "$tmp" || { rm -f "$tmp"; die "cannot write the hook body"; }
  chmod 0755 "$tmp" || { rm -f "$tmp"; die "cannot make the hook executable"; }
  # Replace atomically so a concurrent push never sees a half-written hook.
  mv -f "$tmp" "$path" || { rm -f "$tmp"; die "cannot install the hook at $path"; }
  if [ "$state" = stale ]; then
    printf 'pr-target-guard: repaired %s\n' "$path"
  else
    printf 'pr-target-guard: installed %s\n' "$path"
  fi
}

cmd_installed() {
  [ "$#" -le 1 ] || { usage >&2; exit 2; }
  local repo dir path state
  repo=$(repo_real "${1:-$FM_ROOT}") || die "not a directory: ${1:-$FM_ROOT}"
  dir=$(hooks_dir "$repo") || die "cannot resolve the hook directory for $repo"
  path="$dir/pre-push"
  state=$(hook_state "$path")
  printf '%s %s\n' "$state" "$path"
  case "$state" in
    current) return 0 ;;
    foreign) exit "$FM_NM_TARGET_EXIT" ;;
    *) exit 1 ;;
  esac
}

cmd_hook() {
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  local remote_name=$1 remote_url=${2:-} repo
  # An ordinary push is none of this guard's business.
  fm_nm_target_is_gate_push "$remote_name" "$remote_url" || exit 0
  # Git runs a hook from the working-tree root of the pushing worktree.
  repo=$(pwd -P)
  if fm_nm_target_assert "$repo"; then
    exit 0
  fi
  {
    printf '\n'
    printf 'REFUSED: the validation pipeline may only open a pull request against this\n'
    printf '         repository'"'"'s own push target, and right now it would not.\n'
    printf '\n'
    printf '  %s\n' "$FM_NM_TARGET_REASON"
    printf '\n'
    printf '  Nothing was pushed and no validation run was started, so no pull request\n'
    printf '  can be opened until this is settled.\n'
    printf '\n'
    printf '  Inspect it with: %s check %s\n' "$FM_ROOT/bin/fm-nm-pr-target.sh" "$repo"
    printf '  Correct the pull-request base by re-registering the pipeline against the\n'
    printf '  repository this home pushes to; do not reach for --no-verify.\n'
    printf '\n'
  } >&2
  exit "$FM_NM_TARGET_EXIT"
}

MODE=${1:-}
[ "$#" -eq 0 ] || shift
case "$MODE" in
  check) cmd_check "$@" ;;
  install) cmd_install "$@" ;;
  installed) cmd_installed "$@" ;;
  hook) cmd_hook "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
