#!/usr/bin/env bash
# The supervisor's own watcher A loses state/.watch.lock to watcher B, the same
# arm then follows B, and the supervisor is handed over (TERM).
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
T=$(fm_test_tmproot fm-idle-yield)
git clone -q "$ROOT" "$T/project" || exit 2; ROOT="$T/project"
echo "product under test: plain clone at $(git -C "$ROOT" rev-parse --short HEAD), FM_GATE_REFUSE_BYPASS unset, marked lab home"
H="$T/home"; S="$H/state"; L="$S/.codex-idle-continuity.lock"; CONT="$ROOT/bin/fm-codex-idle-continuity.sh"
export FM_PROCEVENT_CLAIM_ROOT="$T/claims"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 2; mkdir -p "$T/fakebin"; unset FM_GATE_REFUSE_BYPASS
printf '#!/bin/sh\nexec sleep 900\n' > "$T/perpetual.sh"; chmod +x "$T/perpetual.sh"
ln -s "$(command -v bash)" "$T/fakebin/codex"
fm_test_track_procevent_home "$H" "$FM_PROCEVENT_CLAIM_ROOT"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish forever -- "$T/perpetual.sh" >/dev/null || exit 2
payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-live"}')
wpid() { cat "$S/.watch.lock/pid" 2>/dev/null; }
last() { grep -E '^watcher: (started|attached) ' "$L/arm.out" 2>/dev/null | tail -1; }
sleep 900 & owner=$!
rc=1
for try in 1 2 3 4 5 6; do
  printf '%s' "$payload" | FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE=/bin/true "$T/fakebin/codex" -c 'printf "%s\n" "$$" > "$1/state/.lock"; shift; "$@"' _ "$H" "$CONT" >/dev/null 2>&1
  for _ in $(seq 1 60); do last | grep -q started && break; sleep 0.2; done
  a=$(wpid); sp=$(cat "$L/pid")
  rm -rf "$S/.watch.lock" "$S"/.watch.lock.owner.*
  FM_HOME="$H" "$ROOT/bin/fm-watch.sh" >"$T/b.out" 2>&1 & bjob=$!
  both=0
  for _ in $(seq 1 60); do
    if grep -q '^watcher: started ' "$L/arm.out" 2>/dev/null && last | grep -q attached; then both=1; break; fi
    sleep 0.2
  done
  if [ "$both" = 1 ]; then
    b=$(wpid)
    echo "try $try: supervisor pid=$sp; arm.out of the one arm:"; sed 's/^/    /' "$L/arm.out"
    echo "watcher A=$a alive=$(kill -0 "$a" 2>/dev/null && echo yes || echo no); lock holder B=$b"
    FM_HOME="$H" "$CONT" --handover </dev/null; hrc=$?
    sleep 1
    echo "handover rc=$hrc supervisor alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no) watcher B=$b alive=$(kill -0 "$b" 2>/dev/null && echo yes || echo no) lock pid=$(wpid)"
    [ "$hrc" = 0 ] && ! kill -0 "$sp" 2>/dev/null && kill -0 "$b" 2>/dev/null && [ "$b" != "$a" ] && rc=0
    [ "$rc" = 0 ] && echo "PASS - S5" || echo "FAIL - S5"
    kill "$bjob" 2>/dev/null; break
  fi
  echo "try $try: the arm did not print started then attached in one cycle; retrying"
  FM_HOME="$H" "$CONT" --handover </dev/null >/dev/null 2>&1
  kill "$bjob" 2>/dev/null; wait "$bjob" 2>/dev/null
  FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1; sleep 1
done
kill "$owner" 2>/dev/null
FM_HOME="$H" "$CONT" --handover </dev/null >/dev/null 2>&1
FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
exit $rc
