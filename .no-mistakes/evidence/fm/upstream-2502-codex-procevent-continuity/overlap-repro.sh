#!/usr/bin/env bash
# Repeats the overlapping-Stop case: the lock-owning session fires six allowing
# Stops at once; each round counts the --supervise processes left for the home.
set -u
ROOT=$1; ROUNDS=${2:-12}
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-idle-overlap)
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3
mkdir -p "$TMP_ROOT/fakebin"; FAKE_CODEX="$TMP_ROOT/fakebin/codex"; ln -s "$(command -v bash)" "$FAKE_CODEX"
printf '#!/bin/sh\ncat >> %s\n' "$TMP_ROOT/queue" > "$TMP_ROOT/queue.sh"; chmod +x "$TMP_ROOT/queue.sh"
jq -cn '{stop_hook_active:true,session_id:"thread-overlap"}' | tr -d '\n' > "$TMP_ROOT/payload"
supervisors() { local p; for p in $(pgrep -f 'fm-codex-idle-continuity.sh --supervise' || true); do tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "FM_HOME=$1" && printf '%s\n' "$p"; done; }
doubles=0
for r in $(seq 1 "$ROUNDS"); do
  H="$TMP_ROOT/home$r"; mkdir -p "$H/bin" "$H/state"; git init -q "$H"; : > "$H/AGENTS.md"; : > "$H/state/demo.meta"
  sleep 600 & owner=$!
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$TMP_ROOT/queue.sh" \
    "$FAKE_CODEX" -c 'printf "%s\n" "$$" > "$1/state/.lock"; for i in 1 2 3 4 5 6; do "$2" < "$3" >/dev/null & done; wait; :' _ "$H" "$CONT" "$TMP_ROOT/payload"
  sleep 2
  n=$(supervisors "$H" | wc -l | tr -d ' ')
  printf 'round %s: supervisors=%s pids=[%s] lock pid=%s\n' "$r" "$n" "$(supervisors "$H" | tr '\n' ' ')" "$(cat "$H/state/.codex-idle-continuity.lock/pid" 2>/dev/null)"
  [ "$n" -gt 1 ] && doubles=$((doubles + 1))
  kill "$owner"; wait "$owner" 2>/dev/null
  for i in $(seq 1 50); do [ -z "$(supervisors "$H")" ] && break; sleep 0.2; done
  FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
done
printf 'rounds with more than one supervisor: %s of %s\n' "$doubles" "$ROUNDS"

# The window itself, held open: the lock directory exists but `starting` is not
# written yet. One allowing Stop arrives in that state.
H="$TMP_ROOT/window"; mkdir -p "$H/bin" "$H/state"; git init -q "$H"; : > "$H/AGENTS.md"; : > "$H/state/demo.meta"
L="$H/state/.codex-idle-continuity.lock"; mkdir "$L"
sleep 600 & owner=$!
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$TMP_ROOT/queue.sh" \
  "$FAKE_CODEX" -c 'printf "%s\n" "$$" > "$1/state/.lock"; "$2" < "$3" >/dev/null; :' _ "$H" "$CONT" "$TMP_ROOT/payload"
sleep 1
printf 'lock dir created but `starting` not yet written, then one Stop: supervisors started=%s (lock pid=%s)\n' "$(supervisors "$H" | wc -l | tr -d ' ')" "$(cat "$L/pid" 2>/dev/null)"
kill "$owner"; wait "$owner" 2>/dev/null
for i in $(seq 1 50); do [ -z "$(supervisors "$H")" ] && break; sleep 0.2; done
FM_ROOT_OVERRIDE="$H" FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
