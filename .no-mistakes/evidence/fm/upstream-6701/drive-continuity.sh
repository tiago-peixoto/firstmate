#!/usr/bin/env bash
# Drives the real remote-reply adapter and process-event runner from a checkout
# against a disposable parent home and remote home. Follows the issue 6701
# operator sequence and prints the parent status log after each step.
# Usage: drive-continuity.sh <checkout-root>
# The only stand-in is the ssh transport: it execs the checkout's real
# bin/fm-remote-entrypoint.sh on this machine instead of on another host.
set -u
# Firstmate requires a state root that the group cannot write.
umask 022
ROOT=$(cd "$1" && pwd -P)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-6701-drive.XXXXXX")
PARENT="$T/parent"; REMOTE="$T/remote"; CLAIMS="$T/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$CLAIMS" "$T/bin"
. "$ROOT/bin/fm-remote-job-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"
ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
STATUS="$PARENT/state/ios.status"
LOG="$REMOTE/state/parent-replies.status"
CURSOR="$PARENT/state/remote-replies/ios.cursor"

cleanup() {
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  [ ! -f "$T/remote-jobs/worker.pid" ] || fm_remote_job_stop_worker_tree "$(cat "$T/remote-jobs/worker.pid")" || true
  rm -rf -- "$T"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
: > "$LOG"
cat > "$T/bin/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$T/bin/fake-ssh"

renv() {
  FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$ROOT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$T/bin/fake-ssh" FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 "$@"
}
SID=$(renv "$ADAPTER" source-id ios)

stop_listener() {
  local pid _
  pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.05; done
}
show() { # <step title>
  printf '\n=== %s ===\n' "$1"
  printf 'cursor: %s  retirements file: %s\n' \
    "$(tr '\n' ' ' < "$CURSOR" 2>/dev/null || echo absent)" \
    "$(cat "$PARENT/state/remote-replies/ios.retirements" 2>/dev/null || echo absent)"
  printf 'blocked continuity lines on parent status log: %s\n' \
    "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$STATUS" 2>/dev/null || true)"
  grep -F 'key=remote-reply-continuity-ios' "$STATUS" 2>/dev/null | sed 's/^/  | /'
  printf 'open decisions: [%s]\n' "$(status_open_decisions "$STATUS" | cut -f1 | tr '\n' ' ')"
}
all_handled() {
  local r
  for r in "$PARENT/state/procevent-inbox/$SID".*.result; do
    [ -e "$r" ] || continue
    [ -f "${r%.result}.handled" ] || return 1
  done
}
# Arm the route at the committed cursor and let the listener read to <bytes>.
read_to() {
  local want _
  want=$(wc -c < "$LOG" | tr -d ' ')
  renv "$ADAPTER" arm ios >/dev/null
  renv "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 &
  for _ in $(seq 1 600); do
    # Stop only after the listener acknowledged its capture, so the stop does
    # not interrupt the handler between the cursor write and the acknowledgement.
    if grep -qx "offset=$want" "$CURSOR" 2>/dev/null && all_handled; then stop_listener; return 0; fi
    sleep 0.05
  done
  echo "DRIVER ERROR: reader never reached offset $want"; exit 2
}
# Arm at the committed cursor and run one listener pass over the current log.
# A continuity break ends the listener, so this waits for it to exit.
read_break() {
  local result gen
  stop_listener
  renv "$ADAPTER" arm ios >/dev/null 2>&1 || true
  renv "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1
  result=$(ls -t "$PARENT/state/procevent-inbox/$SID".*.result | head -1)
  printf 'listener captured %s classified as: %s\n' "${result##*/}" "$(renv "$ADAPTER" classify "$result")"
  # The handler the check wake calls. It acknowledges the captured result.
  gen=${result%.result}; gen=${gen##*.}
  renv "$ADAPTER" handle ios "$gen" "$result" >/dev/null 2>&1
  printf 'handle ios %s exit status: %s\n' "$gen" "$?"
}
resolve() {
  printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' >> "$STATUS"
}

A=$'working: first reply\nworking: second reply\n'
B=$A$'working: third reply after repair\n'

printf '%s' "$A" > "$LOG"; read_to
show "1. route healthy, reader caught up"

printf 'failed: log replaced\n' > "$LOG"; read_break
show "2. first break: remote log replaced under the cursor"

resolve
show "3. operator resolves the decision"

read_break
show "4. same unchanged break read again (cursor not moved): expect no new line, decision closed"

printf '%s' "$B" > "$LOG"; read_to
show "5. log repaired and extended, reader advances, no retirement"

: > "$LOG"; read_break
show "6. LATER DISTINCT BREAK at the new cursor: expect a second blocked line, decision open"

read_break
show "7. that later break read again: expect still two lines"

resolve
renv "$ADAPTER" retire ios || { echo "DRIVER ERROR: retire failed"; exit 2; }
printf '%s' "$B" > "$LOG"; read_to
show "8. operator resolves, retires the route, restores identical bytes; reader back at the same offset"

: > "$LOG"; read_break
show "9. break after retirement with identical bytes: expect a third blocked line, decision open"

read_break
show "10. that break read again: expect still three lines"
