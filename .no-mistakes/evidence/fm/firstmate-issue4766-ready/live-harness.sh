#!/usr/bin/env bash
# Live harness for firstmate issue 4766 (captain hold/release reaching the
# worker status log). Stands up an isolated firstmate home against a REAL tmux
# server on a private socket, the real tasks-axi backlog, the real
# bin/fm-captain-hold.sh, and the real watcher launched through
# bin/fm-watch-arm.sh, then drains and acknowledges each wake the way the
# firstmate session does (bin/fm-wake-drain.sh). Only forge/pipeline CLIs
# (gh, gh-axi, no-mistakes, treehouse) are stubbed, so crew state never
# reaches a network. A "live" worker is a pane whose foreground process is
# named after the harness (/bin/sleep exec'd under that argv0); a "stopped"
# worker is a bare shell.
#
# Usage: live-harness.sh <code-root> <scenario> [label]
set -u

CODE=$1
SCENARIO=$2
LABEL=${3:-$(basename "$CODE")}
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm4766-live.XXXXXX")
SCR=$(cd -P "$SCR" && pwd -P)
HOME_DIR="$SCR/home"
FAKEBIN="$SCR/fakebin"
SOCK="fm4766-$$"
REAL_TMUX=$(command -v tmux)
T0=$(date +%s)

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  [ -n "${ARM_PID:-}" ] && kill "$ARM_PID" 2>/dev/null
  pkill -f "$SCR/" 2>/dev/null || true
  if [ -n "${KEEP:-}" ]; then echo "kept $SCR"; else rm -rf "$SCR"; fi
}
trap cleanup EXIT

say() { printf '[%s t=%02ds] %s\n' "$LABEL" "$(( $(date +%s) - T0 ))" "$*"; }

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/sample" "$FAKEBIN"
cp "$CODE/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
for tool in gh gh-axi no-mistakes treehouse; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$tool"; done
chmod +x "$FAKEBIN"/*
for agent in codex grok; do
  printf '#!/bin/bash\nexec -a %s /bin/sleep "$@"\n' "$agent" > "$FAKEBIN/$agent"; chmod +x "$FAKEBIN/$agent"
done
export PATH="$FAKEBIN:$PATH"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
STATE="$HOME_DIR/state"
tmux new-session -d -s firstmate -n supervisor -x 200 -y 50 'bash --noprofile --norc' || { echo "tmux failed"; exit 1; }

# <id> <kind> <dead|live> [status lines...]; LANE_AGE=<secs> back-dates the log
add_lane() {
  local id=$1 kind=$2 life=$3 cmd
  shift 3
  (cd "$HOME_DIR" && tasks-axi add "$id" "Sample $id" --kind "$kind" --repo sample >/dev/null)
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$HOME_DIR/projects/sample" \
    "project=$HOME_DIR/projects/sample" "harness=${LANE_HARNESS:-codex}" "kind=$kind" "mode=$kind" backend=tmux \
    "spawn_gen=live-$id" > "$STATE/$id.meta"
  case "$life" in
    dead) cmd="env PS1='$ ' bash --noprofile --norc" ;;
    live) cmd="$FAKEBIN/${LANE_HARNESS:-codex} 100000" ;;
  esac
  tmux new-window -d -t firstmate -n "fm-$id" "$cmd"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$STATE/$id.status"
    [ -z "${LANE_AGE:-}" ] || backdate "$STATE/$id.status" "$LANE_AGE"
    mark_seen "$id"
  fi
}

# The worker's own lines were already surfaced and handled by firstmate.
mark_seen() {
  bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ \
    "$CODE/bin/fm-wake-lib.sh" "$STATE" "$STATE/$1.status"
}

backdate() {  # <file> <seconds>
  local back=$(( $(date +%s) - $2 ))
  touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$1"
}

captain() {
  say "\$ fm-captain-hold.sh $*"
  "$CODE/bin/fm-captain-hold.sh" "$@" 2>&1 | sed 's/^/    /'
  return "${PIPESTATUS[0]}"
}

show_status() {
  say "state/$1.status now reads:"
  sed 's/^/    | /' "$STATE/$1.status" 2>/dev/null || echo "    (no status log)"
  say "last_status_line -> $(bash -c '. "$1"; last_status_line "$2"' _ "$CODE/bin/fm-classify-lib.sh" "$STATE/$1.status")"
}

away_on() {
  "$CODE/bin/fm-afk-contract.sh" propose >/dev/null 2>&1 && "$CODE/bin/fm-afk-contract.sh" confirm >/dev/null 2>&1
  say "away-posture record written (state/.afk-contract present; watcher-owned away posture)"
}

ack_all() {
  local err="$SCR/drain.err" seq gen
  "$CODE/bin/fm-wake-drain.sh" > "$SCR/drain.out" 2> "$err" || return 0
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && "$CODE/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}

# Supervise for <seconds>: arm the watcher, record every wake it surfaces,
# drain+ack it, and re-arm - what the firstmate session does on each wake.
WAKES="$SCR/wakes.log"
: > "$WAKES"
supervise() {  # <seconds>
  local until=$(( $(date +%s) + $1 )) out="$SCR/arm.out" line
  while [ "$(date +%s)" -lt "$until" ]; do
    : > "$out"
    "$CODE/bin/fm-watch-arm.sh" > "$out" 2>&1 &
    ARM_PID=$!
    while kill -0 "$ARM_PID" 2>/dev/null && [ "$(date +%s)" -lt "$until" ]; do sleep 0.3; done
    if kill -0 "$ARM_PID" 2>/dev/null; then
      kill "$ARM_PID" 2>/dev/null; wait "$ARM_PID" 2>/dev/null
      break
    fi
    wait "$ARM_PID" 2>/dev/null
    while IFS= read -r line; do
      case "$line" in watcher:*started*|watcher:*attached*|'') continue ;; esac
      say "WAKE: $line" | tee -a "$WAKES"
    done < "$out"
    ack_all
  done
  ARM_PID=
  # stop any watcher still holding this home's lock
  local wpid
  wpid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
  [ -n "$wpid" ] && kill "$wpid" 2>/dev/null
  sleep 1.5
}

wake_count() {  # <pattern>
  grep -cF -- "$1" "$WAKES" 2>/dev/null || true
}

triage_tail() {  # <pattern>
  grep -F -- "$1" "$STATE/.watch-triage.log" 2>/dev/null | tail -n "${2:-3}" | sed 's/^/    triage: /'
}

. "$(dirname "$0")/live-scenarios.sh"
"scenario_$SCENARIO"
