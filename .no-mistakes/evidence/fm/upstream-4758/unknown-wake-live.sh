#!/usr/bin/env bash
# Live driver: runs the real away daemon (via bin/fm-afk-start.sh) against a
# private tmux socket with a fake supervisor composer that logs every submitted
# line. Unknown wakes are enqueued exactly as bin/fm-inactive-reconcile.sh does
# (fm_wake_append check <key> <payload>). Nothing touches the live fleet.
set -u
ROOT=${1:?repo root}
EVID=${2:?evidence dir}
REAL_TMUX=$(command -v tmux)
SOCKET="fm-unk-ack-$$"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-unk-ack.XXXXXX")
HOMEDIR="$W/home"; STATE="$HOMEDIR/state"; mkdir -p "$STATE"
LOGF="$W/submitted.log"; : > "$LOGF"
TR="$EVID/unknown-wake-live-transcript.txt"; : > "$TR"
DPID=
say() { printf '%s\n' "$*" | tee -a "$TR"; }
RESULTS=()
check() { if eval "$2"; then say "PASS: $1"; RESULTS+=("PASS $1"); else say "FAIL: $1"; RESULTS+=("FAIL $1"); fi; }
cleanup() {
  [ -n "$DPID" ] && { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; }
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null
  echo "KEPT_WORKDIR=$W"
}
trap cleanup EXIT

"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50
PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')
cat > "$W/loop.sh" <<'LOOP'
#!/usr/bin/env bash
LOG="$1"; stty -echo -icanon min 1 time 0 2>/dev/null
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"; }
submit() { printf '%s\n' "$_buf" >> "$LOG"; _buf=; printf '\r\033[K\n'; redraw; }
redraw
while IFS= read -r -n 1 c; do
  if [ -z "$c" ]; then submit; continue; fi
  case "$c" in $'\r'|$'\n') submit ;; *) _buf="$_buf$c"; redraw ;; esac
done
LOOP
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$W/loop.sh' '$LOGF'" Enter
sleep 1
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-c9 -t supervisor
mkdir -p "$W/shim"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$W/shim/tmux"; chmod +x "$W/shim/tmux"

start_session() {  # fresh away-session entry through the real entry point
  PATH="$W/shim:$PATH" FM_HOME="$HOMEDIR" FM_STATE_OVERRIDE="$STATE" \
  FM_SUPERVISOR_TARGET="$PANE" FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=3 FM_CHECK_INTERVAL=999999 FM_STALE_ESCALATE_SECS=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=5 FM_WEDGE_ALARM_EXEC=discard \
    "$ROOT/bin/fm-afk-start.sh" >"$W/daemon.out" 2>"$W/daemon.err" &
  DPID=$!
  for _ in $(seq 60); do [ -f "$STATE/.supervise-daemon.pid" ] && break; sleep 0.2; done
  [ -f "$STATE/.supervise-daemon.pid" ] || { cat "$W/daemon.err"; say "daemon did not start"; exit 1; }
}
stop_session() { kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null; DPID=; sleep 1; }
enqueue() {  # <key> <payload>  same call bin/fm-inactive-reconcile.sh publish_actionable makes
  ( STATE="$STATE"; FM_HOME="$HOMEDIR"; . "$ROOT/bin/fm-wake-lib.sh"; fm_wake_append check "$1" "$2" )
}
wait_drained() { for _ in $(seq 40); do [ -s "$STATE/.wake-queue" ] || { sleep 3; return 0; }; sleep 0.5; done; return 1; }
digests() { grep -c 'Supervisor escalate' "$LOGF" || true; }
count_in_log() { grep -cF -- "$1" "$LOGF" || true; }
A="inactive terminal outcome awaiting captain presentation: child=c1 state=done pr=https://example.test/pull/1"
B="decision closed already: needs-decision d-42 resolved by captain"

say "=== Session 1: fresh away session via bin/fm-afk-start.sh"
start_session
enqueue "presentation:fp1" "$A"; wait_drained
say "submitted lines after first unknown wake:"; sed 's/^/  | /' "$LOGF" | tee -a "$TR" >/dev/null; cat "$LOGF" | sed 's/^/  | /'
check "S1 first unknown wake escalates once to supervisor pane" '[ "$(count_in_log "unknown wake: $A")" = 1 ]'
check "S1 delivered unknown wake is recorded in state/.subsuper-unknown-acked" 'grep -Fxq "unknown wake: $A" "$STATE/.subsuper-unknown-acked"'
say "ack file:"; sed 's/^/  > /' "$STATE/.subsuper-unknown-acked" | tee -a "$TR"

enqueue "presentation:fp1-again" "$A"; wait_drained
check "S2 same unknown-wake identity re-presented is NOT escalated again" '[ "$(count_in_log "unknown wake: $A")" = 1 ] && [ "$(digests)" = 1 ]'
check "S2 re-presented wake row was drained/acked (not stuck in queue)" '[ ! -s "$STATE/.wake-queue" ]'

enqueue "decision:d-42" "$B"; wait_drained
check "S3 genuinely new unknown wake still escalates" '[ "$(count_in_log "unknown wake: $B")" = 1 ] && [ "$(digests)" = 2 ]'

printf 'done: PR https://example.test/pull/77\n' > "$STATE/c9.status"; sleep 6
printf 'done: PR https://example.test/pull/77\n' >> "$STATE/c9.status"; sleep 6
check "S4 ordinary (non-unknown) escalation still delivered and never written to ack file" '[ "$(count_in_log "pull/77")" -ge 1 ] && ! grep -q "pull/77" "$STATE/.subsuper-unknown-acked"'
say "submitted lines at end of session 1:"; sed 's/^/  | /' "$LOGF" | tee -a "$TR" >/dev/null
stop_session

say "=== Session 2: new away session via bin/fm-afk-start.sh (fresh entry clears acknowledgements)"
rm -f "$STATE/c9.status"
before=$(digests)
start_session
check "S5 fresh away-session entry cleared the acknowledgement file" '[ ! -e "$STATE/.subsuper-unknown-acked" ] || ! grep -Fq "unknown wake: $A" "$STATE/.subsuper-unknown-acked" || [ "$(count_in_log "unknown wake: $A")" = 2 ]'
enqueue "presentation:fp1-session2" "$A"; wait_drained
check "S5 same identity handled in a PRIOR session fires again in the new session" '[ "$(count_in_log "unknown wake: $A")" = 2 ]'
stop_session

say "=== Session 3: acknowledgement write fails after delivery"
start_session
rm -f "$STATE/.subsuper-unknown-acked"; mkdir "$STATE/.subsuper-unknown-acked"
C="unrecognized widget event: w-9"
enqueue "widget:w9" "$C"; wait_drained; sleep 4
check "S6 digest delivered exactly once despite ack-write failure (no re-injection)" '[ "$(count_in_log "unknown wake: $C")" = 1 ]'
check "S6 escalation buffer cleared after delivery" '[ ! -s "$STATE/.subsuper-escalations" ]'
check "S6 daemon logged the acknowledgement-write failure" 'grep -rqs "unknown-wake acknowledgement write failed" "$STATE"/*.log "$STATE"/.*log* 2>/dev/null'
stop_session

say "=== Final supervisor-pane submissions (verbatim)"; sed 's/^/  | /' "$LOGF" | tee -a "$TR" >/dev/null
say "=== Daemon log excerpt"; ls -a "$STATE" | grep -i log | tee -a "$TR" >/dev/null
for f in "$STATE"/*daemon*log* "$STATE"/.*daemon*log*; do [ -f "$f" ] && grep -E "escalate: |acknowledgement|daemon starting|shutting" "$f" | sed 's/^/  L /' | tee -a "$TR" >/dev/null; done
say "=== RESULTS"; printf '%s\n' "${RESULTS[@]}" | tee -a "$TR"
