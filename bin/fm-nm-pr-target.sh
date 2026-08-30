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
#       Idempotently install the pre-push guard and its executable payload into
#       <repo>'s hook directory, so every linked worktree can enforce the target
#       without reading the checkout that installed it. Prints one line saying
#       whether it installed, repaired, or found the guard current. Refuses to
#       replace a foreign pre-push hook or payload it did not write.
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
# SCOPE OF ONE INSTALL. Hooks and this guard's executable payload live in the
# repository's common Git directory, so one install covers the primary checkout
# and every linked task worktree without executing a script from another working
# copy. A separate clone (the private fork-integration clone, a project clone)
# has its own hook directory and is guarded by its own install;
# bin/fm-bootstrap.sh installs this home's.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-nm-pr-target-lib.sh
. "$SCRIPT_DIR/fm-nm-pr-target-lib.sh"

# Bumped whenever the installed shim's bytes change, so `install` can recognize
# and repair its own older copy while still refusing a hook it did not write.
FM_NM_TARGET_HOOK_VERSION=2
FM_NM_TARGET_HOOK_MARKER='fm-nm-pr-target guard'
FM_NM_TARGET_PAYLOAD_SCRIPT='.fm-nm-pr-target.sh'
FM_NM_TARGET_PAYLOAD_LIB='fm-nm-pr-target-lib.sh'

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

# The installed shim stays a thin forwarder to a payload in the clone's common
# hook directory. Session start or the fork-integration provisioning owner
# repairs that payload from the current trusted code before work begins. A
# disposable worktree therefore executes the guard carried by its own clone,
# never a script under the primary home's working copy and never its unvalidated
# topic-branch copy.
hook_body() {
  cat <<EOF
#!/usr/bin/env bash
# $FM_NM_TARGET_HOOK_MARKER v$FM_NM_TARGET_HOOK_VERSION - installed by bin/fm-nm-pr-target.sh.
# Forwards to the clone-local payload beside this hook.
set -eu
hook_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" 2>/dev/null && pwd -P) || {
  echo "REFUSED: the pull-request target guard cannot resolve its clone-local hook directory; reinstall it with fm-nm-pr-target.sh install, and do not push around it." >&2
  exit $FM_NM_TARGET_EXIT
}
guard="\$hook_dir/$FM_NM_TARGET_PAYLOAD_SCRIPT"
if [ ! -f "\$guard" ] || [ -L "\$guard" ] || [ ! -x "\$guard" ]; then
  echo "REFUSED: the pull-request target guard's clone-local payload is missing or unsafe (\$guard); reinstall it with fm-nm-pr-target.sh install, and do not push around it." >&2
  exit $FM_NM_TARGET_EXIT
fi
exec "\$guard" hook "\$@"
EOF
}

payload_state() { # <hook-path> -> echoes current|stale|foreign|absent
  local hook=$1 dir script lib
  dir=$(dirname "$hook")
  script="$dir/$FM_NM_TARGET_PAYLOAD_SCRIPT"
  lib="$dir/$FM_NM_TARGET_PAYLOAD_LIB"
  if [ ! -e "$script" ] && [ ! -L "$script" ] && [ ! -e "$lib" ] && [ ! -L "$lib" ]; then
    printf 'absent\n'
    return 0
  fi
  if [ -L "$script" ] || [ -L "$lib" ] \
     || { [ -e "$script" ] && [ ! -f "$script" ]; } \
     || { [ -e "$lib" ] && [ ! -f "$lib" ]; }; then
    printf 'foreign\n'
    return 0
  fi
  if [ -f "$script" ] && ! grep -q "$FM_NM_TARGET_HOOK_MARKER" "$script" 2>/dev/null; then
    printf 'foreign\n'
    return 0
  fi
  if [ ! -f "$script" ] || [ ! -f "$lib" ]; then
    if [ -f "$hook" ] && grep -q "$FM_NM_TARGET_HOOK_MARKER" "$hook" 2>/dev/null; then
      printf 'stale\n'
    else
      printf 'foreign\n'
    fi
    return 0
  fi
  if cmp -s "$SCRIPT_DIR/fm-nm-pr-target.sh" "$script" \
     && cmp -s "$SCRIPT_DIR/fm-nm-pr-target-lib.sh" "$lib" \
     && [ -x "$script" ]; then
    printf 'current\n'
    return 0
  fi
  printf 'stale\n'
}

hook_state() { # <hook-path> -> echoes current|stale|foreign|absent
  local path=$1 payload
  if [ ! -e "$path" ]; then
    printf 'absent\n'
    return 0
  fi
  if ! grep -q "$FM_NM_TARGET_HOOK_MARKER" "$path" 2>/dev/null; then
    printf 'foreign\n'
    return 0
  fi
  payload=$(payload_state "$path")
  if [ -f "$path" ] && [ ! -L "$path" ] && hook_body | cmp -s - "$path" \
     && [ "$payload" = current ]; then
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
  local repo dir path state payload script lib script_tmp lib_tmp tmp
  repo=$(repo_real "${1:-$FM_ROOT}") || die "not a directory: ${1:-$FM_ROOT}"
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || die "not a Git worktree: $repo"
  dir=$(hooks_dir "$repo") || die "cannot resolve the hook directory for $repo"
  path="$dir/pre-push"
  state=$(hook_state "$path")
  payload=$(payload_state "$path")
  case "$state" in
    current)
      printf 'pr-target-guard: current %s\n' "$path"
      return 0 ;;
    foreign)
      # Never clobber a hook someone else owns; say what is in the way instead.
      printf 'pr-target-guard: refused %s (a pre-push hook this guard did not write already exists)\n' "$path" >&2
      exit "$FM_NM_TARGET_EXIT" ;;
  esac
  if [ "$payload" = foreign ]; then
    printf 'pr-target-guard: refused %s (clone-local payload paths this guard did not write already exist)\n' "$dir" >&2
    exit "$FM_NM_TARGET_EXIT"
  fi
  mkdir -p "$dir" || die "cannot create the hook directory: $dir"
  script="$dir/$FM_NM_TARGET_PAYLOAD_SCRIPT"
  lib="$dir/$FM_NM_TARGET_PAYLOAD_LIB"
  script_tmp=$(mktemp "$dir/.fm-nm-pr-target-script.XXXXXX") \
    || die "cannot write the clone-local guard payload"
  lib_tmp=$(mktemp "$dir/.fm-nm-pr-target-lib.XXXXXX") \
    || { rm -f "$script_tmp"; die "cannot write the clone-local guard library"; }
  if ! cp "$SCRIPT_DIR/fm-nm-pr-target.sh" "$script_tmp" \
     || ! cp "$SCRIPT_DIR/fm-nm-pr-target-lib.sh" "$lib_tmp" \
     || ! chmod 0755 "$script_tmp" \
     || ! chmod 0644 "$lib_tmp"; then
    rm -f "$script_tmp" "$lib_tmp"
    die "cannot prepare the clone-local guard payload"
  fi
  mv -f "$lib_tmp" "$lib" \
    || { rm -f "$script_tmp" "$lib_tmp"; die "cannot install the clone-local guard library"; }
  mv -f "$script_tmp" "$script" \
    || { rm -f "$script_tmp"; die "cannot install the clone-local guard payload"; }
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
    printf '  Inspect it with: %s check %s\n' "$0" "$repo"
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
