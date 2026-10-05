#!/usr/bin/env bash
# Manual drive of the Codex idle supervisor against the real bin/fm-watch-arm.sh
# watcher in a throwaway home. A bash binary named `codex` stands in for the
# Codex process; every firstmate script is the real one from the worktree.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-idle-manual)
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3
H="$TMP_ROOT/home"; S="$H/state"; L="$S/.codex-idle-continuity.lock"
QUEUE_BIN="$TMP_ROOT/queue.sh"
mkdir -p "$H/bin" "$S" "$TMP_ROOT/fakebin"
git init -q "$H"; : > "$H/AGENTS.md"
printf '#!/bin/sh\ncat >> %s\n' "$TMP_ROOT/queue" > "$QUEUE_BIN"; chmod +x "$QUEUE_BIN"
printf '#!/bin/sh\nexec sleep 600\n' > "$TMP_ROOT/perpetual.sh"; chmod +x "$TMP_ROOT/perpetual.sh"
FAKE_CODEX="$TMP_ROOT/fakebin/codex"; ln -s "$(command -v bash)" "$FAKE_CODEX"
fm_test_track_procevent_home "$H" "$FM_PROCEVENT_CLAIM_ROOT"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish forever -- "$TMP_ROOT/perpetual.sh" >/dev/null || { echo "SETUP FAIL register"; exit 2; }
payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-manual"}')
rc=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL - $*"; rc=1; }
wait_until() { local t=$1 i=0; shift; while [ "$i" -lt "$t" ]; do "$@" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
live() { local p; p=$(cat "$1" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
sup_up() { live "$L/pid"; }
watch_up() { live "$S/.watch.lock/pid"; }
home_supervisors() {  # pids of --supervise processes whose FM_HOME is this home
  local p
  for p in $(pgrep -f 'fm-codex-idle-continuity.sh --supervise' || true); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "FM_HOME=$H" && printf '%s\n' "$p"
  done
}
as_owner() { "$FAKE_CODEX" -c 'printf "%s\n" "$$" > "$1/state/.lock"; shift; "$@"; rc=$?; exit "$rc"' _ "$H" "$@"; }
stop_as_owner() { printf '%s' "$payload" | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" as_owner "$CONT" >/dev/null; }

say "== A. six allowing Stops fired at once by the lock-owning session start exactly one supervisor (finding 2)"
sleep 600 & owner=$!
printf '%s' "$payload" > "$TMP_ROOT/payload"
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" \
  "$FAKE_CODEX" -c 'printf "%s\n" "$$" > "$1/state/.lock"; for i in 1 2 3 4 5 6; do "$2" < "$3" >/dev/null & done; wait; :' _ "$H" "$CONT" "$TMP_ROOT/payload"
wait_until 50 sup_up || bad "no supervisor after concurrent stops"
sleep 3
n=$(home_supervisors | wc -l | tr -d ' ')
say "supervisor processes for this home: $n (pids: $(home_supervisors | tr '\n' ' ')); lock pid: $(cat "$L/pid" 2>/dev/null); starting file present: $([ -e "$L/starting" ] && echo yes || echo no)"
[ "$n" -eq 1 ] && [ "$(home_supervisors)" = "$(cat "$L/pid")" ] && say "PASS A" || bad "expected exactly one supervisor matching the lock pid"
wait_until 50 watch_up || bad "supervisor started no watcher"
say "arm.out: $(cat "$L/arm.out" 2>/dev/null | head -2 | tr '\n' '|')"

say "== B. a second session that does not own state/.lock runs a checkpoint and an allowing Stop (finding 1)"
sup_before=$(cat "$L/pid"); watch_before=$(cat "$S/.watch.lock/pid")
"$FAKE_CODEX" -c 'sleep 600; :' & real_owner=$!
printf '%s\n' "$real_owner" > "$S/.lock"
frc=0
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$FAKE_CODEX" -c '"$@"; rc=$?; exit "$rc"' _ "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$TMP_ROOT/fcp.out" 2>&1 || frc=$?
say "non-owner checkpoint rc=$frc output: $(cat "$TMP_ROOT/fcp.out")"
printf '%s' "$payload" | FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$QUEUE_BIN" \
  "$FAKE_CODEX" -c '"$1"; rc=$?; exit "$rc"' _ "$CONT" >/dev/null
sleep 1
say "supervisor pid before=$sup_before after=$(cat "$L/pid" 2>/dev/null); watcher pid before=$watch_before after=$(cat "$S/.watch.lock/pid" 2>/dev/null); supervisors for home: $(home_supervisors | wc -l | tr -d ' '); session lock still $real_owner: $([ "$(cat "$S/.lock")" = "$real_owner" ] && echo yes || echo no)"
if [ "$frc" -eq 124 ] && sup_up && [ "$(cat "$L/pid")" = "$sup_before" ] && [ "$(cat "$S/.watch.lock/pid" 2>/dev/null)" = "$watch_before" ] && [ "$(home_supervisors | wc -l | tr -d ' ')" -eq 1 ]; then say "PASS B"; else bad "non-owner session disturbed the owner's supervisor"; fi
kill "$real_owner" 2>/dev/null; wait "$real_owner" 2>/dev/null

say "== C. owner's checkpoint takes over, supervisor attaches to that watcher, then the Codex owner exits (finding 3)"
# Settle first: the handover leaves watcher downtime that the next watcher
# resurfaces as an actionable wake. Drain it so the long checkpoint stays quiet.
for i in 1 2 3 4; do
  prc=0
  as_owner env FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$TMP_ROOT/pre.out" 2>&1 || prc=$?
  say "settling checkpoint $i rc=$prc: $(tr '\n' '|' < "$TMP_ROOT/pre.out")"
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  [ "$prc" -eq 124 ] && break
done
( as_owner env FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 20 > "$TMP_ROOT/cp.out" 2>&1; echo "$?" > "$TMP_ROOT/cp.rc" ) &
cp_job=$!
wait_until 100 test ! -d "$L" || bad "owner checkpoint did not hand the supervisor over"
wait_until 100 watch_up || bad "checkpoint watcher never took the lock"
cp_watch=$(cat "$S/.watch.lock/pid" 2>/dev/null)
say "owner checkpoint stopped supervisor $sup_before (alive now: $(kill -0 "$sup_before" 2>/dev/null && echo yes || echo no)); checkpoint watcher pid=$cp_watch"
stop_as_owner
wait_until 50 grep -q '^watcher: attached ' "$L/arm.out" || bad "supervisor did not attach: $(cat "$L/arm.out" 2>/dev/null)"
say "supervisor $(cat "$L/pid" 2>/dev/null) arm.out: $(cat "$L/arm.out" 2>/dev/null | tr '\n' '|')"
say "just before owner exit: checkpoint watcher $cp_watch alive: $(kill -0 "$cp_watch" 2>/dev/null && echo yes || echo no); checkpoint still running: $([ -e "$TMP_ROOT/cp.rc" ] && echo no || echo yes)"
kill "$owner"; wait "$owner" 2>/dev/null
wait_until 50 test ! -d "$L" || bad "supervisor survived its Codex owner"
sleep 1
say "after owner exit: checkpoint still running: $([ -e "$TMP_ROOT/cp.rc" ] && echo no || echo yes); supervisor lock present: $([ -d "$L" ] && echo yes || echo no); checkpoint watcher $cp_watch alive: $(kill -0 "$cp_watch" 2>/dev/null && echo yes || echo no); watch lock pid: $(cat "$S/.watch.lock/pid" 2>/dev/null)"
if [ ! -d "$L" ] && kill -0 "$cp_watch" 2>/dev/null && [ "$(cat "$S/.watch.lock/pid" 2>/dev/null)" = "$cp_watch" ]; then say "PASS C"; else bad "owner exit took down a watcher the supervisor only attached to"; fi
wait "$cp_job" 2>/dev/null
say "checkpoint finished rc=$(cat "$TMP_ROOT/cp.rc" 2>/dev/null): $(cat "$TMP_ROOT/cp.out")"

say "== D. host-opted home (config/supervision-host) starts no idle supervisor (scope)"
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
sleep 600 & owner=$!
mkdir -p "$H/config"; : > "$H/config/supervision-host"
stop_as_owner; sleep 3
say "with config/supervision-host: lock present: $([ -d "$L" ] && echo yes || echo no); supervisors: $(home_supervisors | wc -l | tr -d ' ')"
hosted_ok=0; [ ! -d "$L" ] && [ "$(home_supervisors | wc -l | tr -d ' ')" -eq 0 ] && hosted_ok=1
rm -f "$H/config/supervision-host"
stop_as_owner
wait_until 50 sup_up && plain_ok=1 || plain_ok=0
say "after removing config/supervision-host: supervisor up: $(sup_up && echo yes || echo no)"
[ "$hosted_ok" = 1 ] && [ "$plain_ok" = 1 ] && say "PASS D" || bad "host scoping wrong"
kill "$owner"; wait "$owner" 2>/dev/null
wait_until 50 test ! -d "$L" || bad "final supervisor survived owner"
say "leftover supervisors for home: $(home_supervisors | wc -l | tr -d ' ')"
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
exit $rc
