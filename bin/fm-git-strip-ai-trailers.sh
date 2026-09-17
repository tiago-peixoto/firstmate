#!/usr/bin/env bash
# Strip AI co-author and generated-with trailers from a commit message, and
# install that strip as a per-task git commit-msg hook for a fleet launch.
#
# Usage:
#   fm-git-strip-ai-trailers.sh <msgfile>
#       Commit-msg hook mode. Git passes the proposed message file as $1.
#       Rewrites that file in place, then exits 0 so the commit proceeds.
#   fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree>
#       Recreate <hooks-dir> as a core.hooksPath for this launch: a commit-msg
#       hook that runs this strip, then every other executable hook from the
#       worktree's previous hooksPath (or $GIT_DIR/hooks) so husky and friends
#       still run. Does not touch the project's git config; the caller exports
#       GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0 for the pane.
#
# WHY THIS EXISTS. Claude launches already carry attribution-off in their
# per-launch --settings JSON. Cursor and other non-Claude runtimes inject a
# Co-Authored-By (or "Made with Cursor") trailer at the tooling layer AFTER the
# worker types a clean message, so the typed message is not the commit object.
# A prior per-machine ~/.cursor/cli-config.json attribution-off is not durable:
# it does not travel with Firstmate, and Cursor's CLI has ignored that setting
# on some paths. The spawn-owned commit-msg hook is the layer that sees the
# assembled message, including --trailer, before the commit object is written.
# Human Co-Authored-By trailers are left untouched. Author identity is not
# rewritten. git commit --no-verify still skips hooks; that is git's own
# escape hatch, not a Firstmate setting.
set -u
unset CDPATH

SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

usage() {
  cat >&2 <<'EOF'
usage:
  fm-git-strip-ai-trailers.sh <msgfile>
  fm-git-strip-ai-trailers.sh install <hooks-dir> <worktree>
EOF
  exit 2
}

trim_space() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# True when this line is AI attribution that must not reach a commit object.
# Matches known product names and vendor emails only; a human co-author whose
# name or address merely contains a substring such as "ai" is kept.
fm_is_ai_attribution_line() {
  local raw=$1 lowered rest name email
  raw=${raw%$'\r'}
  raw=$(trim_space "$raw")
  [ -n "$raw" ] || return 1
  lowered=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
  'made with cursor' | 'made with cursor.' | 'made-with: cursor' | 'made-with:cursor')
    return 0
    ;;
  esac
  case "$lowered" in
  *'generated with'*claude* | *'generated-by:'*claude* | *'generated-by:'*cursor*)
    return 0
    ;;
  esac
  case "$lowered" in
  co-authored-by:*) ;;
  *) return 1 ;;
  esac
  rest=$(trim_space "${raw#*:}")
  name=$rest
  email=
  case "$rest" in
  *'<'*'>'*)
    email=$(printf '%s' "$rest" | tr '[:upper:]' '[:lower:]')
    email=${email#*'<'}
    email=${email%%'>'*}
    name=$(trim_space "${rest%%'<'*}")
    ;;
  esac
  name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  case "$email" in
  *@cursor.com | *@anysphere.com | *@anthropic.com | copilot@github.com | cursoragent@* | noreply@openai.com)
    return 0
    ;;
  esac
  case "$name" in
  cursor | 'cursor agent' | claude | 'claude code' | 'github copilot' | copilot | codex | chatgpt | gemini | 'google gemini' | grok | openai)
    return 0
    ;;
  esac
  return 1
}

strip_msgfile() {
  local src=$1 tmp
  [ -f "$src" ] || {
    echo "error: commit message file not found: $src" >&2
    return 1
  }
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-git-strip-ai-trailers.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if fm_is_ai_attribution_line "$line"; then
      continue
    fi
    printf '%s\n' "$line"
  done <"$src" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$src"
}

quote_for_hook() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

resolve_orig_hooks() {
  local wt=$1 orig
  orig=$(git -C "$wt" config --path --get core.hooksPath 2>/dev/null || true)
  if [ -n "$orig" ]; then
    printf '%s\n' "$orig"
    return 0
  fi
  orig=$(git -C "$wt" rev-parse --git-path hooks) || return 1
  case "$orig" in
  /*) printf '%s\n' "$orig" ;;
  *) printf '%s\n' "$wt/$orig" ;;
  esac
}

write_executable() {
  local dest=$1
  cat >"$dest" || return 1
  chmod 700 "$dest"
}

install_hooks() {
  local hooks_dir=$1 wt=$2 orig base hook
  [ -n "$hooks_dir" ] && [ -n "$wt" ] || usage
  [ -d "$wt" ] || {
    echo "error: worktree is not a directory: $wt" >&2
    return 1
  }
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null || {
    echo "error: not a git worktree: $wt" >&2
    return 1
  }
  orig=$(resolve_orig_hooks "$wt") || {
    echo "error: cannot resolve git hooks path for $wt" >&2
    return 1
  }
  rm -rf "$hooks_dir"
  mkdir -p "$hooks_dir" || return 1
  chmod 700 "$hooks_dir" 2>/dev/null || true

  write_executable "$hooks_dir/commit-msg" <<EOF
#!/usr/bin/env bash
set -u
$(quote_for_hook "$SELF") "\$1" || exit \$?
orig=$(quote_for_hook "$orig/commit-msg")
if [ -x "\$orig" ]; then
  unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
  exec "\$orig" "\$@"
fi
EOF

  if [ -d "$orig" ]; then
    for hook in "$orig"/*; do
      [ -f "$hook" ] && [ -x "$hook" ] || continue
      base=$(basename -- "$hook")
      case "$base" in
      *.sample | commit-msg) continue ;;
      esac
      write_executable "$hooks_dir/$base" <<EOF
#!/usr/bin/env bash
set -u
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
exec $(quote_for_hook "$hook") "\$@"
EOF
    done
  fi
}

CMD=${1:-}
case "$CMD" in
install)
  [ "$#" -eq 3 ] || usage
  install_hooks "$2" "$3"
  ;;
-h | --help)
  usage
  ;;
'')
  usage
  ;;
*)
  if [ "$CMD" = "${CMD#-}" ] && [ "$#" -ge 1 ]; then
    strip_msgfile "$1"
  else
    usage
  fi
  ;;
esac
