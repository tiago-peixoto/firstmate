#!/usr/bin/env bash
# Shared setup for the live drivers: an isolated firstmate home, a private tmux
# server (TMUX_TMPDIR), and a no-op `no-mistakes` so no real pipeline state is read.
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/5dfc3e2f8f7a/01M26GG2J3W9EF8H268QPXN3HF
EV=/Users/tiago/.no-mistakes/evidence/01M26GG2J3W9EF8H268QPXN3HF
WORK=${WORK:-$(mktemp -d /tmp/fm-live.XXXXXX)}
WORK=$(cd -P "$WORK" && pwd -P)
unset TMUX TMUX_PANE FM_CAPTAIN_RE
export TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$TMUX_TMPDIR" "$WORK/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/fakebin/no-mistakes"
chmod +x "$WORK/fakebin/no-mistakes"
export PATH="$WORK/fakebin:$PATH"

say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }
check() {  # <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null; then printf 'PASS: %s\n' "$d"; else printf 'FAIL: %s\n' "$d"; FAILS=$((FAILS + 1)); fi
}
FAILS=0
between() { [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

make_home() {  # <name>
  local h="$WORK/$1"
  mkdir -p "$h/state" "$h/data" "$h/projects" "$h/config"
  printf '%s\n' "$h"
}

write_meta() {  # <file> <kv...>
  local f=$1; shift
  : > "$f"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}

snapshot_event() {  # <home> <id>
  FM_HOME="$1" "$ROOT/bin/fm-fleet-snapshot.sh" --json \
    | jq -c --arg id "$2" '.tasks[] | select(.id == $id) | .paths.status_log.last_event'
}

cleanup_tmux() { tmux kill-server 2>/dev/null || true; }
