#!/usr/bin/env bash
# Drives bin/fm-codex-idle-continuity.sh, with no gate bypass, in a marked lab home against
# fm-watch.sh and fm-watch-checkpoint.sh in a disposable FM_HOME.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
T=$(fm_test_tmproot fm-idle-live)
git clone -q "$ROOT" "$T/project" || exit 2; ROOT="$T/project"; echo "product under test: plain clone at $(git -C "$ROOT" rev-parse --short HEAD), FM_GATE_REFUSE_BYPASS unset, marked lab home"
H="$T/home"; S="$H/state"; L="$S/.codex-idle-continuity.lock"
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"
export FM_PROCEVENT_CLAIM_ROOT="$T/claims"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 2; mkdir -p "$T/fakebin"; unset FM_GATE_REFUSE_BYPASS
printf '#!/bin/sh\nexec sleep 900\n' > "$T/perpetual.sh"; chmod +x "$T/perpetual.sh"
printf '#!/bin/sh\ncat >> %s\n' "$T/queue" > "$T/queue.sh"; chmod +x "$T/queue.sh"
ln -s "$(command -v bash)" "$T/fakebin/codex"
FAKE="$T/fakebin/codex"
fm_test_track_procevent_home "$H" "$FM_PROCEVENT_CLAIM_ROOT"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish forever -- "$T/perpetual.sh" >/dev/null || { echo "SETUP FAIL register"; exit 2; }
payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-live"}')
RES=0
say() { printf '%s\n' "$*"; }
verdict() { if [ "$2" = 0 ]; then say "PASS - $1"; else say "FAIL - $1"; RES=1; fi; }
wait_until() { local n=$1 i=0; shift; while [ "$i" -lt "$n" ]; do "$@" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
live() { local p; p=$(cat "$1" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
sup_up() { live "$L/pid"; }
watch_up() { live "$S/.watch.lock/pid"; }
wpid() { cat "$S/.watch.lock/pid" 2>/dev/null; }
armline() { grep -E '^watcher: (started|attached) ' "$L/arm.out" 2>/dev/null | tail -1; }
arm_says() { armline | grep -q "^watcher: $1 "; }
as_owner() { "$FAKE" -c 'printf "%s\n" "$$" > "$1/state/.lock"; shift; "$@"; rc=$?; exit "$rc"' _ "$H" "$@"; }
stop_hook() { printf '%s' "$payload" | FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$T/queue.sh" as_owner "$CONT" >/dev/null 2>&1; }
owner_cp() { as_owner env FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$1"; }
foreign_cp() { FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$1"; }
new_owner() { sleep 900 & owner=$!; }
reset() { FM_HOME="$H" "$CONT" --handover </dev/null >/dev/null 2>&1; FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1; wait_until 40 bash -c "! [ -d '$L' ]"; }

say "== S1: a second session's checkpoint leaves the owner's idle supervisor running"
new_owner; stop_hook
wait_until 60 bash -c "[ -s '$L/pid' ]" ; wait_until 60 arm_says started
sp=$(cat "$L/pid"); w=$(wpid)
say "supervisor pid=$sp owner=$(cat "$L/owner") arm: $(armline) watcher=$w"
out=$(foreign_cp 2 2>&1); rc=$?
say "foreign checkpoint rc=$rc: $out"
say "after: supervisor pid=$(cat "$L/pid" 2>/dev/null) alive=$(sup_up && echo yes || echo no) watcher=$(wpid) alive=$(watch_up && echo yes || echo no)"
[ "$rc" = 124 ] && sup_up && [ "$(cat "$L/pid")" = "$sp" ] && [ "$(wpid)" = "$w" ] && watch_up; verdict S1 $?

say "== S6: TERM (owner checkpoint handover) stops a watcher the supervisor started itself"
out=$(owner_cp 2 2>&1); rc=$?
say "owner checkpoint rc=$rc: $out"
say "old watcher $w alive=$(kill -0 "$w" 2>/dev/null && echo yes || echo no); idle lock present=$([ -d "$L" ] && echo yes || echo no)"
{ [ "$rc" = 0 ] || [ "$rc" = 124 ]; } && ! kill -0 "$w" 2>/dev/null && ! kill -0 "$sp" 2>/dev/null && [ ! -d "$L" ]; verdict S6 $?
reset

say "== S2a: 8 overlapping allowing Stops start exactly one supervisor"
for i in 1 2 3 4 5 6 7 8; do stop_hook & hp[$i]=$!; done
for i in 1 2 3 4 5 6 7 8; do wait "${hp[$i]}"; done
sleep 2
n=$(pgrep -f "fm-codex-idle-continuity.sh --supervise" | while read -r p; do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "FM_HOME=$H" && echo "$p"; done | wc -l)
say "supervisors running for this home: $n (recorded pid=$(cat "$L/pid" 2>/dev/null))"
[ "$n" = 1 ] && sup_up; verdict S2a $?
reset

say "== S2b: a lock whose startup hook is alive and has no pid yet is not reclaimed by a later Stop"
sleep 60 & starter=$!
mkdir "$L"; printf '%s\n' "$starter" > "$L/starting"; printf '%s\n' "$owner" > "$L/owner"
stop_hook
say "after second Stop: starting=$(cat "$L/starting" 2>/dev/null) pid-file=$([ -s "$L/pid" ] && cat "$L/pid" || echo empty)"
n=$(pgrep -f "fm-codex-idle-continuity.sh --supervise" | while read -r p; do tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -qx "FM_HOME=$H" && echo "$p"; done | wc -l)
say "supervisors running for this home: $n"
FM_HOME="$H" "$CONT" --handover </dev/null; hrc=$?
say "handover while startup holds the lock rc=$hrc, lock present=$([ -d "$L" ] && echo yes || echo no)"
[ "$(cat "$L/starting" 2>/dev/null)" = "$starter" ] && [ ! -s "$L/pid" ] && [ "$n" = 0 ] && [ "$hrc" != 0 ] && [ -d "$L" ]; a=$?
kill "$starter"; wait "$starter" 2>/dev/null
stop_hook; wait_until 60 sup_up; b=$?
say "after the startup hook died, next Stop: supervisor alive=$(sup_up && echo yes || echo no)"
[ "$a" = 0 ] && [ "$b" = 0 ]; verdict S2b $?
reset

say "== S3: owner exits while the arm only attached to another session's watcher"
foreign_cp 25 >"$T/fcp.out" 2>&1 & fcp=$!
wait_until 60 watch_up; fw=$(wpid)
say "foreign checkpoint watcher pid=$fw"
stop_hook; wait_until 60 arm_says attached
say "supervisor pid=$(cat "$L/pid" 2>/dev/null) arm: $(armline)"
sp=$(cat "$L/pid"); arm_says attached; pre=$?
kill "$owner"; wait "$owner" 2>/dev/null
wait_until 60 bash -c "! [ -d '$L' ]"
sleep 2
say "owner gone: supervisor alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no) lock present=$([ -d "$L" ] && echo yes || echo no) foreign watcher $fw alive=$(kill -0 "$fw" 2>/dev/null && echo yes || echo no) lock pid=$(wpid)"
[ "$pre" = 0 ] && ! kill -0 "$sp" 2>/dev/null && [ ! -d "$L" ] && kill -0 "$fw" 2>/dev/null && [ "$(wpid)" = "$fw" ]; verdict S3 $?

say "== S4: owner checkpoint hands over a supervisor that only attached to the foreign watcher"
new_owner; stop_hook; wait_until 60 arm_says attached
sp=$(cat "$L/pid" 2>/dev/null); say "supervisor pid=$sp arm: $(armline) foreign watcher=$(wpid)"
arm_says attached && [ "$(wpid)" = "$fw" ]; pre=$?
t0=$(date +%s); out=$(owner_cp 2 2>&1); rc=$?; t1=$(date +%s)
say "owner checkpoint rc=$rc after $((t1-t0))s: $out"
say "supervisor alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no) foreign watcher $fw alive=$(kill -0 "$fw" 2>/dev/null && echo yes || echo no)"
[ "$pre" = 0 ] && ! kill -0 "$sp" 2>/dev/null && kill -0 "$fw" 2>/dev/null && printf '%s' "$out" | grep -q 'already running' && ! printf '%s' "$out" | grep -q 'did not finish handing over'; verdict S4 $?
wait "$fcp" 2>/dev/null; say "foreign checkpoint finished: $(cat "$T/fcp.out")"
reset

say "== S5: started then attached - the supervisor's watcher yields the lock, then TERM"
stop_hook; wait_until 60 arm_says started
a=$(wpid); sp=$(cat "$L/pid"); say "supervisor pid=$sp started watcher A=$a"
rm -rf "$S/.watch.lock"
FM_HOME="$H" "$ROOT/bin/fm-watch.sh" >"$T/b.out" 2>&1 & bjob=$!
wait_until 100 arm_says attached; pre=$?
b=$(wpid)
say "arm.out now:"; sed 's/^/    /' "$L/arm.out" 2>/dev/null
say "watcher A=$a alive=$(kill -0 "$a" 2>/dev/null && echo yes || echo no); lock holder B=$b"
FM_HOME="$H" "$CONT" --handover </dev/null; hrc=$?
sleep 1
say "handover rc=$hrc supervisor alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no) watcher B=$b alive=$(kill -0 "$b" 2>/dev/null && echo yes || echo no)"
[ "$pre" = 0 ] && [ "$b" != "$a" ] && [ "$hrc" = 0 ] && ! kill -0 "$sp" 2>/dev/null && kill -0 "$b" 2>/dev/null; verdict S5 $?
kill "$bjob" 2>/dev/null; wait "$bjob" 2>/dev/null
reset

say "== S7: host-opted home starts no idle supervisor"
: > "$H/config/supervision-host"
stop_hook; sleep 3
say "config/supervision-host present: lock present=$([ -d "$L" ] && echo yes || echo no) watcher alive=$(watch_up && echo yes || echo no)"
[ ! -d "$L" ] && ! watch_up; verdict S7 $?
rm -f "$H/config/supervision-host"

reset
kill "$owner" 2>/dev/null
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
say "RESULT=$RES"
exit $RES
