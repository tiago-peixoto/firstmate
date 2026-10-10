#!/usr/bin/env bash
# Claim one of this machine's shared heavy-run slots, run a heavy command in it,
# and release it.
# Usage: fm-heavy-slot.sh run --task <task-id> --load <max> --slot <path> [--slot <path>...] -- <command> [args...]
#        fm-heavy-slot.sh claim --task <task-id> --load <max> --slot <path> [--slot <path>...]
#        fm-heavy-slot.sh release --task <task-id> --slot <path> [--slot <path>...]
#        fm-heavy-slot.sh status --slot <path> [--slot <path>...]
# A slot is a directory at a full absolute path that every Firstmate home on the
# machine shares. Which paths a home's briefs list, and in what order, is owned
# by bin/fm-brief.sh and docs/configuration.md ("Heavy-run slots"); this script
# takes the paths explicitly and never derives one from a bare suffix.
# A claim is one atomic `mkdir` of the slot path: the mkdir is the check and the
# claim in one step, so two claimers can never both succeed, and a plain file at
# a slot path is never mistaken for a free slot. The claimer then writes
# <slot>/owner as one line, `task=<task-id> pid=<pid>`, by rename so a reader
# never sees a half-written line. The pid is the process running the heavy
# command, or `-` while a claim that spans several commands has none running.
# While the command runs, a heartbeat refreshes the owner file's time every poll
# interval. Its age, not whether some pid exists, is the liveness signal: a
# suite starts short-lived processes one after another, so any one pid can be
# gone while the suite is still working, and only the heartbeat spans the gaps.
# Each slot reads as one of:
#   working           a command is running and its heartbeat is fresh;
#   between commands  claimed with no command running, for at most the idle bound;
#   idle              claimed with no command running for longer than the idle bound;
#   stale             a command was recorded but its heartbeat stopped;
#   free, no owner, unreadable owner, or not a directory.
# Waiters are served in arrival order. A waiter keeps a ticket, refreshed every
# poll, in the queue directory fm-heavy-slot-queue beside the first listed slot,
# and claims a free slot only when no live waiter that arrived earlier may claim
# that slot now. So a slot goes to the longest waiter rather than the fastest
# poller. A ticket not refreshed for the stale bound is ignored, so a waiter
# that died cannot hold up the queue; a working holder is never preempted.
#   run      waits until the 1-minute load is at or below --load and a listed
#            slot can be claimed, trying the slots in the order given, runs the
#            command with that slot held, releases it when the command ends, and
#            exits with the command's status. The owner pid is this wrapper's
#            own. A TERM, INT, or HUP takes effect only once the command has
#            ended, so the slot is never released under a command that is still
#            running. When the task already holds one of the listed slots (from
#            claim), run uses that slot at once, records its own pid there while
#            the command runs, and leaves the slot held, with pid `-`, afterwards.
#   claim    waits the same way and keeps the slot, with pid `-`, after it exits,
#            for heavy work that spans several commands, such as a no-mistakes
#            pipeline whose Test step runs inside the daemon. A task holds at
#            most one slot, so a task already holding a listed slot keeps it.
#   release  removes the task's own slot among those listed. It never removes,
#            moves, or rewrites a slot whose owner names another task, a slot with
#            no readable owner, or a slot path that is not a directory.
#   status   prints each listed slot's reading and the queue, longest waiter
#            first, and changes nothing.
# Exit status: run exits with the command's own status; claim, release, and
# status exit 0 on success; 1 when the 1-minute load cannot be read or the owner
# line or ticket cannot be written; 2 on a usage error.
# FM_HEAVY_SLOT_POLL sets the seconds between admission attempts and heartbeats
# (default 15), FM_HEAVY_SLOT_STALE the whole seconds after which a heartbeat or
# ticket is stale (default 120), and FM_HEAVY_SLOT_IDLE the whole seconds a
# claim may run no command before it reads idle (default 600).
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
  run|claim|release|status) MODE=$1; shift ;;
  *) die_usage "unknown subcommand '$1' (expected run, claim, release, or status)" ;;
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

if [ "$MODE" != status ]; then
  fm_task_id_path_safe "$TASK" || die_usage "--task must be a valid task id (got '$TASK')"
fi
[ "${#SLOTS[@]}" -ge 1 ] || die_usage "at least one --slot is required"
for slot in "${SLOTS[@]}"; do
  case "$slot" in
    /*/) die_usage "--slot must not end with '/' (got '$slot')" ;;
    /?*) ;;
    *) die_usage "--slot must be a full absolute path, never a bare suffix (got '$slot')" ;;
  esac
  [ -d "${slot%/*}/" ] || die_usage "the directory holding --slot $slot does not exist"
done
case "$MODE" in
  run|claim)
    printf '%s\n' "$LOAD_MAX" | grep -Eq '^[0-9]+([.][0-9]+)?$' \
      || die_usage "--load must be a non-negative number (got '$LOAD_MAX')" ;;
esac
if [ "$MODE" = run ]; then
  [ "$#" -ge 1 ] || die_usage "run needs a command after --"
elif [ "$#" -gt 0 ]; then
  die_usage "$MODE takes no command"
fi

POLL=${FM_HEAVY_SLOT_POLL:-15}
STALE=${FM_HEAVY_SLOT_STALE:-120}
IDLE=${FM_HEAVY_SLOT_IDLE:-600}
printf '%s\n' "$POLL" | grep -Eq '^[0-9]+([.][0-9]+)?$' || die_usage "FM_HEAVY_SLOT_POLL must be a number of seconds (got '$POLL')"
case "$STALE$IDLE" in *[!0-9]*|'') die_usage "FM_HEAVY_SLOT_STALE and FM_HEAVY_SLOT_IDLE must be whole seconds" ;; esac
QUEUE="${SLOTS[0]%/*}/fm-heavy-slot-queue"
SLOT=
CREATED=0
TICKET=
BEATER=
MY_SINCE=

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

# Whole seconds since the file last changed; fails when it is gone.
file_age() {
  local mtime
  mtime=$(fm_pr_file_mtime "$1") || return 1
  [ -n "$mtime" ] || return 1
  printf '%s\n' "$(( $(date +%s) - mtime ))"
}

# Sets O_TASK and O_PID from a slot's owner line; fails when it is not one.
read_owner() {
  local line='' word
  local -a words
  O_TASK=
  O_PID=
  [ -d "$1" ] && [ ! -L "$1" ] && [ -f "$1/owner" ] || return 1
  IFS= read -r line < "$1/owner" || [ -n "$line" ] || return 1
  read -r -a words <<< "$line"
  for word in "${words[@]}"; do
    case "$word" in
      task=*) O_TASK=${word#task=} ;;
      pid=*) O_PID=${word#pid=} ;;
    esac
  done
  [ -n "$O_TASK" ] && [ -n "$O_PID" ]
}

owner_task() {
  read_owner "$1" || return 1
  printf '%s\n' "$O_TASK"
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

# Sets V_LABEL, V_TASK, and V_AGE for one slot path.
slot_verdict() {
  V_TASK=
  V_AGE=
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then V_LABEL=free; return 0; fi
  if [ ! -d "$1" ] || [ -L "$1" ]; then V_LABEL="not a directory"; return 0; fi
  if [ ! -e "$1/owner" ]; then V_LABEL="no owner"; return 0; fi
  if ! read_owner "$1" || ! V_AGE=$(file_age "$1/owner"); then V_LABEL="unreadable owner"; return 0; fi
  V_TASK=$O_TASK
  if [ "$O_PID" = - ]; then
    if [ "$V_AGE" -le "$IDLE" ]; then V_LABEL="between commands"; else V_LABEL=idle; fi
  elif [ "$V_AGE" -le "$STALE" ]; then
    V_LABEL=working
  else
    V_LABEL=stale
  fi
}

now_stamp() {
  local stamp=${EPOCHREALTIME:-}
  stamp=${stamp/,/.}
  [ -n "$stamp" ] || stamp=$(date +%s)
  printf '%s\n' "$stamp"
}

# Sets T_TASK, T_SINCE, T_LOAD, and T_SLOTS (newline-framed) from a ticket.
read_ticket() {
  local line
  T_TASK=
  T_SINCE=
  T_LOAD=
  T_SLOTS=$'\n'
  while IFS= read -r line; do
    case "$line" in
      task=*) T_TASK=${line#task=} ;;
      since=*) T_SINCE=${line#since=} ;;
      load=*) T_LOAD=${line#load=} ;;
      slot=*) T_SLOTS="$T_SLOTS${line#slot=}"$'\n' ;;
    esac
  done < "$1"
  [ -n "$T_TASK" ] && [ -n "$T_SINCE" ] && [ -n "$T_LOAD" ]
}

write_ticket() {
  local tmp="$QUEUE/.${TICKET##*/}.tmp" slot
  {
    printf 'task=%s\nsince=%s\npid=%s\nload=%s\n' "$TASK" "$MY_SINCE" "$$" "$LOAD_MAX"
    for slot in "${SLOTS[@]}"; do printf 'slot=%s\n' "$slot"; done
  } > "$tmp" && mv -f "$tmp" "$TICKET"
}

# Succeeds, setting OLDER_TASK, when a live waiter that arrived before this one
# lists the slot and the current load admits it too.
older_waiter_for() {
  local ticket age
  for ticket in "$QUEUE"/*; do
    [ -f "$ticket" ] && [ "$ticket" != "$TICKET" ] || continue
    age=$(file_age "$ticket") && [ "$age" -le "$STALE" ] || continue
    read_ticket "$ticket" 2>/dev/null || continue
    case "$T_SLOTS" in *$'\n'"$1"$'\n'*) ;; *) continue ;; esac
    awk -v now="$LAST_LOAD" -v max="$T_LOAD" 'BEGIN { exit !(now + 0 <= max + 0) }' || continue
    awk -v a="$T_SINCE" -v b="$MY_SINCE" -v an="${ticket##*/}" -v bn="${TICKET##*/}" \
      'BEGIN { exit !(a + 0 < b + 0 || (a + 0 == b + 0 && an < bn)) }' || continue
    OLDER_TASK=$T_TASK
    return 0
  done
  return 1
}

# Waits in this shell, not a subshell, so an interrupted wait can never leave a
# claim behind that no process remembers.
acquire() {
  local slot state reported=
  mkdir -p "$QUEUE" 2>/dev/null
  MY_SINCE=$(now_stamp)
  TICKET="$QUEUE/$TASK.$$"
  write_ticket 2>/dev/null || { echo "fm-heavy-slot: could not write a queue ticket in $QUEUE" >&2; exit 1; }
  while :; do
    if [ -f "$TICKET" ]; then
      touch -c "$TICKET" 2>/dev/null
    else
      write_ticket 2>/dev/null || { echo "fm-heavy-slot: could not write a queue ticket in $QUEUE" >&2; exit 1; }
    fi
    if load_admits; then
      state=
      for slot in "${SLOTS[@]}"; do
        if [ -e "$slot" ] || [ -L "$slot" ]; then
          slot_verdict "$slot"
          state="$state; $slot held${V_TASK:+ by $V_TASK} ($V_LABEL)"
        elif older_waiter_for "$slot"; then
          state="$state; $slot free, kept for longer waiter $OLDER_TASK"
        elif mkdir "$slot" 2>/dev/null; then
          SLOT=$slot
          CREATED=1
          rm -f -- "$TICKET"
          TICKET=
          return 0
        else
          state="$state; $slot just taken"
        fi
      done
      state="waiting for a slot: ${state#; }"
    else
      state="waiting for the 1-minute load ($LAST_LOAD) to fall to $LOAD_MAX or below"
    fi
    case "$state" in "$reported") ;; *) echo "fm-heavy-slot: $state" >&2; reported=$state ;; esac
    sleep "$POLL"
  done
}

# Refreshes the owner file's time for as long as the wrapper lives and the slot
# is still this task's, so the heartbeat stops when either is gone.
beat() {
  while kill -0 "$1" 2>/dev/null; do
    [ "$(owner_task "$SLOT" 2>/dev/null)" = "$TASK" ] || return 0
    touch -c "$SLOT/owner" 2>/dev/null || return 0
    sleep "$POLL"
  done
}

release_slot() {
  [ "$(owner_task "$1" 2>/dev/null)" = "$TASK" ] || return 0
  rm -rf -- "$1"
}

print_status() {
  local slot ticket age when
  for slot in "${SLOTS[@]}"; do
    slot_verdict "$slot"
    case "$V_LABEL" in
      free) echo "$slot: free" ;;
      working|stale|idle|"between commands")
        echo "$slot: held by $V_TASK, $V_LABEL (owner file changed ${V_AGE}s ago)" ;;
      *) echo "$slot: $V_LABEL" ;;
    esac
  done
  echo "queue (longest waiter first):"
  for ticket in "$QUEUE"/*; do
    [ -f "$ticket" ] || continue
    read_ticket "$ticket" 2>/dev/null || continue
    age=$(file_age "$ticket") || continue
    when=$(awk -v s="$T_SINCE" -v now="$(date +%s)" 'BEGIN { printf "%d", now - s }')
    if [ "$age" -le "$STALE" ]; then
      printf '%s\t  %s waiting %ss for%s\n' "$T_SINCE" "$T_TASK" "$when" "$(printf '%s' "$T_SLOTS" | tr '\n' ' ' | sed 's/ $//')"
    else
      printf '%s\t  %s stale ticket, not refreshed for %ss (ignored)\n' "$T_SINCE" "$T_TASK" "$age"
    fi
  done | LC_ALL=C sort -t "$(printf '\t')" -k1,1g | cut -f2-
}

# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  if [ -n "$BEATER" ]; then
    kill "$BEATER" 2>/dev/null
    wait "$BEATER" 2>/dev/null
  fi
  [ -z "$TICKET" ] || rm -f -- "$TICKET"
  if [ "$CREATED" = 1 ]; then
    rm -rf -- "$SLOT"
  elif [ "$MODE" = run ] && [ -n "$SLOT" ] && [ "$(owner_task "$SLOT" 2>/dev/null)" = "$TASK" ]; then
    write_owner "$SLOT" -
  fi
}

case "$MODE" in
  status)
    print_status
    exit 0
    ;;
  release)
    if slot=$(own_slot); then
      release_slot "$slot"
      echo "fm-heavy-slot: released $slot"
    else
      echo "fm-heavy-slot: task $TASK holds none of: ${SLOTS[*]}"
    fi
    exit 0
    ;;
esac

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$MODE" = claim ]; then
  if slot=$(own_slot); then
    echo "fm-heavy-slot: task $TASK already holds $slot"
    exit 0
  fi
  acquire
  write_owner "$SLOT" - || { echo "fm-heavy-slot: could not write $SLOT/owner" >&2; exit 1; }
  CREATED=0
  echo "fm-heavy-slot: claimed $SLOT"
  exit 0
fi

if held=$(own_slot); then
  SLOT=$held
else
  acquire
fi
write_owner "$SLOT" "$$" || { echo "fm-heavy-slot: could not write $SLOT/owner" >&2; exit 1; }
beat "$$" </dev/null >/dev/null 2>&1 &
BEATER=$!
"$@"
rc=$?
exit "$rc"
