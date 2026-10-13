#!/usr/bin/env bash
# Claim one of this machine's shared heavy-run slots, run a heavy command in it,
# and release it.
# Usage: fm-heavy-slot.sh run --task <task-id> --load <max> --slot <path> [--slot <path>...] -- <command> [args...]
#        fm-heavy-slot.sh claim --task <task-id> --load <max> --slot <path> [--slot <path>...]
#        fm-heavy-slot.sh release --task <task-id> --slot <path> [--slot <path>...]
# A slot is a directory at a full absolute path that every Firstmate home on the
# machine shares. Which paths a home's briefs list, and in what order, is owned
# by bin/fm-brief.sh and docs/configuration.md ("Heavy-run slots"); this script
# takes the paths explicitly and never derives one from a bare suffix.
# A claim is one atomic `mkdir` of the slot path: the mkdir is the check and the
# claim in one step, so two claimers can never both succeed, and a plain file at
# a slot path is never mistaken for a free slot. The claimer then writes
# <slot>/owner as one line, `task=<task-id> pid=<pid>`, by rename so a reader
# never sees a half-written line. The pid is the process running the heavy
# command, alive for as long as that command runs, or `-` while a claim that
# spans several commands has none running.
#   run      waits until the 1-minute load is at or below --load and a listed
#            slot can be claimed, trying the slots in the order given, runs the
#            command with that slot held, releases it when the command ends, and
#            exits with the command's status. The owner pid is this wrapper's
#            own, so it stays alive for the whole command, including the gaps
#            between the short-lived processes a suite starts one after another.
#            A TERM, INT, or HUP takes effect only once the command has ended, so
#            the slot is never released under a command that is still running.
#            When the task already holds one of the listed slots (from claim),
#            run uses that slot at once, records its own pid there while the
#            command runs, and leaves the slot held, with pid `-`, afterwards.
#   claim    waits the same way and keeps the slot, with pid `-`, after it exits,
#            for heavy work that spans several commands, such as a no-mistakes
#            pipeline whose Test step runs inside the daemon. A task holds at
#            most one slot, so a task already holding a listed slot keeps it.
#   release  removes the task's own slot among those listed. It never removes,
#            moves, or rewrites a slot whose owner names another task, a slot with
#            no readable owner, or a slot path that is not a directory.
# Exit status: run exits with the command's own status; claim and release exit 0
# on success; 1 when the 1-minute load cannot be read or the owner line cannot
# be written; 2 on a usage error.
# FM_HEAVY_SLOT_POLL sets the seconds between admission attempts (default 15).
# With FM_TEST_SEAM=1, FM_HEAVY_SLOT_LOADAVG_OVERRIDE names a file read in place
# of /proc/loadavg.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die_usage() {
  echo "fm-heavy-slot: $*" >&2
  exit 2
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
case "$1" in
  -h|--help) usage; exit 0 ;;
  run|claim|release) MODE=$1; shift ;;
  *) die_usage "unknown subcommand '$1' (expected run, claim, or release)" ;;
esac

TASK=
LOAD_MAX=
SLOTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task) [ "$#" -ge 2 ] || die_usage "--task requires a value"; TASK=$2; shift 2 ;;
    --load) [ "$#" -ge 2 ] || die_usage "--load requires a value"; LOAD_MAX=$2; shift 2 ;;
    --slot) [ "$#" -ge 2 ] || die_usage "--slot requires a value"; SLOTS+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) die_usage "unknown argument '$1'" ;;
  esac
done

fm_task_id_path_safe "$TASK" || die_usage "--task must be a valid task id (got '$TASK')"
[ "${#SLOTS[@]}" -ge 1 ] || die_usage "at least one --slot is required"
for slot in "${SLOTS[@]}"; do
  case "$slot" in
    /*/) die_usage "--slot must not end with '/' (got '$slot')" ;;
    /?*) ;;
    *) die_usage "--slot must be a full absolute path, never a bare suffix (got '$slot')" ;;
  esac
  [ -d "${slot%/*}/" ] || die_usage "the directory holding --slot $slot does not exist"
done
if [ "$MODE" != release ]; then
  printf '%s\n' "$LOAD_MAX" | grep -Eq '^[0-9]+([.][0-9]+)?$' \
    || die_usage "--load must be a non-negative number (got '$LOAD_MAX')"
fi
if [ "$MODE" = run ]; then
  [ "$#" -ge 1 ] || die_usage "run needs a command after --"
elif [ "$#" -gt 0 ]; then
  die_usage "$MODE takes no command"
fi

POLL=${FM_HEAVY_SLOT_POLL:-15}
SLOT=
CREATED=0

load1() {
  local source=/proc/loadavg
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_HEAVY_SLOT_LOADAVG_OVERRIDE:-}" ]; then
    source=$FM_HEAVY_SLOT_LOADAVG_OVERRIDE
  fi
  if [ -r "$source" ]; then
    cut -d' ' -f1 < "$source"
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{ print $2 }'
  fi
}

# Sets LAST_LOAD; exits 1 when the load cannot be read rather than admitting blind.
load_admits() {
  LAST_LOAD=$(load1)
  printf '%s\n' "$LAST_LOAD" | grep -Eq '^[0-9]+([.][0-9]+)?$' || {
    echo "fm-heavy-slot: cannot read the 1-minute load (got '$LAST_LOAD')" >&2
    exit 1
  }
  awk -v now="$LAST_LOAD" -v max="$LOAD_MAX" 'BEGIN { exit !(now + 0 <= max + 0) }'
}

owner_task() {
  local line='' word
  local -a words
  [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/owner" ] || return 1
  IFS= read -r line < "$1/owner" || [ -n "$line" ] || return 1
  read -r -a words <<< "$line"
  for word in "${words[@]}"; do
    case "$word" in task=*) printf '%s\n' "${word#task=}"; return 0 ;; esac
  done
  return 1
}

own_slot() {
  local slot
  for slot in "${SLOTS[@]}"; do
    [ "$(owner_task "$slot" 2>/dev/null)" = "$TASK" ] && { printf '%s\n' "$slot"; return 0; }
  done
  return 1
}

write_owner() {
  printf 'task=%s pid=%s\n' "$TASK" "$2" > "$1/owner.$$" && mv -f "$1/owner.$$" "$1/owner"
}

# Waits in this shell, not a subshell, so an interrupted wait can never leave a
# claim behind that no process remembers.
acquire() {
  local slot reported=
  while :; do
    if load_admits; then
      for slot in "${SLOTS[@]}"; do
        if mkdir "$slot" 2>/dev/null; then
          SLOT=$slot
          CREATED=1
          return 0
        fi
      done
      [ "$reported" = slots ] || echo "fm-heavy-slot: waiting for a free slot among: ${SLOTS[*]}" >&2
      reported=slots
    else
      [ "$reported" = load ] || echo "fm-heavy-slot: waiting for the 1-minute load ($LAST_LOAD) to fall to $LOAD_MAX or below" >&2
      reported=load
    fi
    sleep "$POLL"
  done
}

release_slot() {
  [ "$(owner_task "$1" 2>/dev/null)" = "$TASK" ] || return 0
  rm -rf -- "$1"
}

case "$MODE" in
  release)
    if slot=$(own_slot); then
      release_slot "$slot"
      echo "fm-heavy-slot: released $slot"
    else
      echo "fm-heavy-slot: task $TASK holds none of: ${SLOTS[*]}"
    fi
    exit 0
    ;;
  claim)
    if slot=$(own_slot); then
      echo "fm-heavy-slot: task $TASK already holds $slot"
      exit 0
    fi
    trap '[ "$CREATED" = 1 ] && rm -rf -- "$SLOT"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    acquire
    write_owner "$SLOT" - || { echo "fm-heavy-slot: could not write $SLOT/owner" >&2; exit 1; }
    CREATED=0
    echo "fm-heavy-slot: claimed $SLOT"
    exit 0
    ;;
esac

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  if [ "$CREATED" = 1 ]; then
    rm -rf -- "$SLOT"
  elif [ -n "$SLOT" ] && [ "$(owner_task "$SLOT" 2>/dev/null)" = "$TASK" ]; then
    write_owner "$SLOT" -
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if held=$(own_slot); then
  SLOT=$held
else
  acquire
fi
write_owner "$SLOT" "$$" || { echo "fm-heavy-slot: could not write $SLOT/owner" >&2; exit 1; }
"$@"
rc=$?
exit "$rc"
