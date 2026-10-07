#!/usr/bin/env bash
# Drives the real remote-reply adapter, process-event runner, and remote reader
# of the checkout at <root> against a disposable parent home and remote home.
# Only the SSH transport is replaced: a local stand-in runs the real
# fm-remote-entrypoint.sh in place of a network hop.
#
# Usage: drive-continuity.sh <root>
set -u
# The process-event runner refuses a group-writable state root.
umask 022
ROOT=$(cd "$1" && pwd -P)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-6701-drive.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN="$TMP_ROOT/fakebin"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data" "$CLAIMS" "$FAKEBIN"
# shellcheck disable=SC1091
. "$ROOT/bin/fm-remote-job-lib.sh"
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
: > "$REMOTE/state/parent-replies.status"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
STATUS="$PARENT/state/ios.status"
CURSOR="$PARENT/state/remote-replies/ios.cursor"
COUNT="$PARENT/state/remote-replies/ios.retirements"
SID=$(remote_env "$ADAPTER" source-id ios)
GEN=0
FAILED=0

say() { printf '\n== %s\n' "$*"; }
abort() { printf 'DRIVER ABORT: %s\n' "$*"; sed 's/^/  runner: /' "$TMP_ROOT/runner.log" 2>/dev/null; exit 2; }
blocked_count() { grep -cF 'blocked [key=remote-reply-continuity-ios]' "$STATUS" 2>/dev/null || true; }
open_decisions() { status_open_decisions "$STATUS" | cut -f1 | tr '\n' ' '; }
show() {
  printf 'cursor: %s\n' "$(tr '\n' ' ' < "$CURSOR" 2>/dev/null || echo absent)"
  printf 'retirement count file: %s\n' "$(cat "$COUNT" 2>/dev/null || echo absent)"
  printf 'continuity lines in parent state/ios.status:\n'
  grep -F 'key=remote-reply-continuity-ios' "$STATUS" | sed 's/^/    /'
  printf 'blocked lines: %s   open decisions: [%s]\n' "$(blocked_count)" "$(open_decisions)"
}
expect() { # <description> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf 'PASS: %s (got %s)\n' "$1" "$2"
  else
    printf 'FAIL: %s (expected %s, got %s)\n' "$1" "$3" "$2"
    FAILED=$((FAILED + 1))
  fi
}

reply_owner() {
  remote_env "$ROOT/bin/fm-procevent.sh" list 2>/dev/null \
    | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }'
}
stop_listener() {
  local pid _
  pid=$(sed -n '2p' "$CLAIMS/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}
# Put <content> in the remote log, arm, and let the runner read it.
read_route() { # <content>
  local result _
  printf '%s' "$1" > "$REMOTE/state/parent-replies.status"
  remote_env "$ADAPTER" arm ios
  GEN=$((GEN + 1))
  result="$PARENT/state/procevent-inbox/$SID.$GEN.result"
  if [ "$(reply_owner)" != live ]; then
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >> "$TMP_ROOT/runner.log" 2>&1 &
  fi
  for _ in $(seq 1 800); do
    [ -s "$result" ] && [ -f "${result%.result}.handled" ] && return 0
    sleep 0.05
  done
  abort "generation $GEN was not read"
}
# Empty the remote log under the committed cursor, let the runner capture the
# break, and run the adapter's handle on it. Sets RESULT_BREAK.
break_route() {
  local rc
  stop_listener || abort "listener did not stop"
  : > "$REMOTE/state/parent-replies.status"
  GEN=$((GEN + 1))
  remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1
  RESULT_BREAK=$(find "$PARENT/state/procevent-inbox" -name "$SID.$GEN.result" -print -quit)
  [ -n "$RESULT_BREAK" ] || abort "break produced no result for generation $GEN"
  printf 'adapter classify: %s\n' "$(remote_env "$ADAPTER" classify "$RESULT_BREAK")"
  remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_BREAK"
  rc=$?
  printf 'adapter handle exit status: %s\n' "$rc"
}
resolve() {
  printf '%s\n' 'resolved [key=remote-reply-continuity-ios]: operator accepted the break' >> "$STATUS"
  printf 'operator appended: resolved [key=remote-reply-continuity-ios]\n'
}

printf 'checkout under test: %s (%s)\n' "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo exported)"

LOG_A=$'working: first line from the remote mate\n'
LOG_B=$LOG_A$'working: second line after the repair\n'

say "1. Read the route, then break it (first break)"
read_route "$LOG_A"
break_route
RESULT_FIRST=$RESULT_BREAK
show
expect "first break appends one blocked line" "$(blocked_count)" 1
expect "first break opens the decision" "$(open_decisions)" "remote-reply-continuity-ios "

say "2. Operator resolves; the same unchanged break is read again"
resolve
rm -f "$PARENT/state/procevent-inbox/$SID.$GEN.handled"
remote_env "$ADAPTER" handle ios "$GEN" "$RESULT_FIRST"
printf 'adapter handle exit status: %s\n' "$?"
remote_env "$ADAPTER" ingest ios "$RESULT_FIRST" >/dev/null 2>&1
show
expect "unchanged repeat appends nothing" "$(blocked_count)" 1
expect "unchanged repeat leaves the decision closed" "$(open_decisions)" ""

say "3. Issue 6701: repair the log, reader advances, later distinct break (no retirement)"
read_route "$LOG_B"
expect "repair alone appends no blocked line" "$(blocked_count)" 1
break_route
RESULT_SECOND=$RESULT_BREAK
show
expect "later distinct break appends a new blocked line" "$(blocked_count)" 2
expect "later distinct break opens the decision again" "$(open_decisions)" "remote-reply-continuity-ios "

say "4. The later break is read again before any resolve"
remote_env "$ADAPTER" ingest ios "$RESULT_SECOND" >/dev/null 2>&1
show
expect "repeat of the later break appends nothing" "$(blocked_count)" 2

say "5. Resolve, retire the route, restore identical bytes, break at the same position"
resolve
remote_env "$ADAPTER" retire ios
printf 'adapter retire exit status: %s\n' "$?"
before=$(blocked_count)
read_route "$LOG_B"
expect "identical restore alone appends no blocked line" "$(blocked_count)" "$before"
expect "identical restore leaves the decision closed" "$(open_decisions)" ""
break_route
RESULT_THIRD=$RESULT_BREAK
show
expect "break after retirement and identical restore appends a new blocked line" "$(blocked_count)" $((before + 1))
expect "break after retirement opens the decision again" "$(open_decisions)" "remote-reply-continuity-ios "
remote_env "$ADAPTER" ingest ios "$RESULT_THIRD" >/dev/null 2>&1
expect "repeat of that break appends nothing" "$(blocked_count)" $((before + 1))

say "6. Adversarial: retirement cannot remove the cursor (cursor path is a directory)"
resolve
count_before=$(cat "$COUNT" 2>/dev/null || echo absent)
cp "$CURSOR" "$TMP_ROOT/cursor.saved"
rm -f "$CURSOR"; mkdir "$CURSOR"
remote_env "$ADAPTER" retire ios
rc=$?
printf 'adapter retire exit status: %s\n' "$rc"
expect "retirement reports failure" "$([ "$rc" -ne 0 ] && echo failed || echo succeeded)" failed
expect "failed retirement leaves the count unchanged" "$(cat "$COUNT" 2>/dev/null || echo absent)" "$count_before"
rmdir "$CURSOR"; cp "$TMP_ROOT/cursor.saved" "$CURSOR"
before=$(blocked_count)
remote_env "$ADAPTER" ingest ios "$RESULT_THIRD" >/dev/null 2>&1
show
expect "after the failed retirement the resolved break still appends nothing" "$(blocked_count)" "$before"
expect "after the failed retirement the decision stays closed" "$(open_decisions)" ""

say "RESULT: $FAILED expectation(s) failed"
[ "$FAILED" -eq 0 ]
