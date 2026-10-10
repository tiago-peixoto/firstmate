#!/usr/bin/env bash
# A foreign session's real watcher is frozen with SIGSTOP while the idle
# supervisor's arm is attached to it, so its beacon goes stale.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"
T=$(fm_test_tmproot fm-idle-stall)
git clone -q "$ROOT" "$T/project" || exit 2; ROOT="$T/project"; echo "product under test: plain clone at $(git -C "$ROOT" rev-parse --short HEAD), FM_GATE_REFUSE_BYPASS unset, marked lab home"
H="$T/home"; S="$H/state"; L="$S/.codex-idle-continuity.lock"
CONT="$ROOT/bin/fm-codex-idle-continuity.sh"
export FM_PROCEVENT_CLAIM_ROOT="$T/claims"
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=3 FM_GUARD_GRACE=4 FM_WATCHER_STALL_BOUND=8
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || exit 2; mkdir -p "$T/fakebin"; unset FM_GATE_REFUSE_BYPASS
printf '#!/bin/sh\nexec sleep 900\n' > "$T/perpetual.sh"; chmod +x "$T/perpetual.sh"
printf '#!/bin/sh\ncat >> %s\n' "$T/queue" > "$T/queue.sh"; chmod +x "$T/queue.sh"
: > "$T/queue"
ln -s "$(command -v bash)" "$T/fakebin/codex"
fm_test_track_procevent_home "$H" "$FM_PROCEVENT_CLAIM_ROOT"
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish forever -- "$T/perpetual.sh" >/dev/null || exit 2
payload=$(jq -cn '{stop_hook_active:true,session_id:"thread-live"}')
stop_hook() { printf '%s' "$payload" | FM_HOME="$H" FM_CODEX_IDLE_OWNER_PID="$owner" FM_CODEX_IDLE_QUEUE="$T/queue.sh" "$T/fakebin/codex" -c 'printf "%s\n" "$$" > "$1/state/.lock"; shift; "$@"' _ "$H" "$CONT" >/dev/null 2>&1; }
sleep 900 & owner=$!
FM_HOME="$H" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 200 >"$T/fcp.out" 2>&1 & fcp=$!
for _ in $(seq 1 60); do fw=$(cat "$S/.watch.lock/pid" 2>/dev/null); [ -n "$fw" ] && kill -0 "$fw" 2>/dev/null && break; sleep 0.2; done
echo "foreign watcher pid=$fw"
stop_hook
for _ in $(seq 1 60); do grep -q '^watcher: attached' "$L/arm.out" 2>/dev/null && break; sleep 0.2; done
sp=$(cat "$L/pid"); echo "supervisor pid=$sp arm: $(cat "$L/arm.out")"
kill -STOP "$fw"; echo "froze foreign watcher $fw at $(date +%T)"
prev=
for _ in $(seq 1 900); do
  cur=$(cat "$L/arm.out" 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then echo "--- arm.out at $(date +%T)"; printf '%s\n' "$cur" | sed 's/^/    /'; prev=$cur; fi
  kill -0 "$sp" 2>/dev/null || break
  sleep 0.2
done
echo "supervisor alive=$(kill -0 "$sp" 2>/dev/null && echo yes || echo no) at $(date +%T)"
echo "failure notice present=$([ -e "$S/.codex-idle-continuity-failure-notified" ] && echo yes || echo no)"
echo "queued into thread:"; sed 's/^/    /' "$T/queue"
echo "foreign watcher $fw alive=$(kill -0 "$fw" 2>/dev/null && echo yes || echo no)"
stop_hook; sleep 3
echo "next allowing Stop: idle lock present=$([ -d "$L" ] && echo yes || echo no)"
kill -CONT "$fw" 2>/dev/null; kill "$fw" "$fcp" "$owner" 2>/dev/null
FM_HOME="$H" "$CONT" --handover </dev/null >/dev/null 2>&1
FM_HOME="$H" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1
FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1
