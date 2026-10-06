#!/usr/bin/env bash
# Drives the real remote-reply relay (fm-procevent.sh runner, the remote-reply
# adapter, the remote entrypoint, fm-send.sh) against a disposable parent home
# and a disposable remote home. Only ssh is replaced, by a local exec of the
# real remote entrypoint.
#
# Usage: drive-continuity.sh <mode> <root> [<old-root>]
#   issue    the issue 6701 reproduction, then the adversarial legs
#   upgrade  first break under <old-root>, everything after under <root>
set -u
umask 022
MODE=$1
ROOT=$2
OLD_ROOT=${3:-$ROOT}
ACTIVE_ROOT=$ROOT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-6701-drive.XXXXXX")
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
CLAIMS="$TMP_ROOT/claims"
# The parent is a marked lab home, the only home a gate agent may send from.
"$ROOT/bin/fm-lab-home.sh" create "$PARENT" >/dev/null || exit 1
mkdir -p "$REMOTE/state" "$CLAIMS" "$TMP_ROOT/fake"
LOG="$REMOTE/state/parent-replies.status"
STATUS="$PARENT/state/ios.status"
FAILS=0
LAST_HANDLE_RC=
LAST_RESULT=
RESOLVE_RC=

. "$ROOT/bin/fm-remote-job-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"

cleanup() {
  TMUX_TMPDIR="$PARENT/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ACTIVE_ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$TMP_ROOT/fake/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$TMP_ROOT/fake/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ACTIVE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$TMP_ROOT/fake/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ACTIVE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}
adapter() { remote_env "$ACTIVE_ROOT/bin/fm-procevent-remote-reply.sh" "$@"; }
runner() { remote_env "$ACTIVE_ROOT/bin/fm-procevent.sh" "$@"; }

write_secondmates() {
  cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ACTIVE_ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
}

say() { printf '\n== %s\n' "$*"; }
blocked_count() { grep -cF 'blocked [key=remote-reply-continuity-ios]' "$STATUS" 2>/dev/null || true; }
open_decisions() { status_open_decisions "$STATUS" | cut -f1,2; }
latest_result() {
  ls "$PARENT/state/procevent-inbox/" 2>/dev/null | sed -n "s/^$SID\.\([0-9]*\)\.result\$/\1/p" | sort -n | tail -1
}
show_state() {
  local f
  for f in cursor continuity; do
    if [ -f "$PARENT/state/remote-replies/ios.$f" ]; then
      printf '%s file: %s\n' "$f" "$(tr '\n' ' ' < "$PARENT/state/remote-replies/ios.$f")"
    else
      printf '%s file: <absent>\n' "$f"
    fi
  done
  printf 'blocked continuity lines: %s\n' "$(blocked_count)"
  printf 'open decisions: %s\n' "$(open_decisions | tr '\t\n' '  ')"
}
expect() { # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf 'PASS  %s (%s)\n' "$1" "$2"
  else
    printf 'FAIL  %s: got "%s", expected "%s"\n' "$1" "$2" "$3"
    FAILS=$((FAILS + 1))
  fi
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

# Let the runner read the log until the cursor reaches the log's byte length.
read_to_end() {
  local want gen _
  want=$(wc -c < "$LOG" | tr -d ' ')
  if [ "$(runner list 2>/dev/null | awk -v id="$SID" 'NR > 1 && $1 == id { print $3; exit }')" != live ]; then
    runner start "$SID" >/dev/null 2>&1 &
  fi
  for _ in $(seq 1 800); do
    gen=$(latest_result)
    if grep -qx "offset=$want" "$PARENT/state/remote-replies/ios.cursor" 2>/dev/null \
      && [ -f "$PARENT/state/procevent-inbox/$SID.$gen.handled" ]; then
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# The runner reads the log as it now is, captures the break, and applies it
# through the adapter on its own. Prints the captured result and the state.
read_break() { # <expected-reason-line>
  local before gen result rc
  before=$(latest_result)
  runner start "$SID" > "$TMP_ROOT/start.out" 2>&1
  gen=$(latest_result)
  if [ -z "$gen" ] || [ "$gen" = "$before" ]; then
    printf 'FAIL  the runner captured no new result\n'; cat "$TMP_ROOT/start.out"
    FAILS=$((FAILS + 1)); return 1
  fi
  result="$PARENT/state/procevent-inbox/$SID.$gen.result"
  printf 'captured result %s: %s\n' "$gen" "$(grep -E '^(status|reason|from_offset|to_offset)=' "$result" | tr '\n' ' ')"
  printf 'classify: %s\n' "$(adapter classify "$result")"
  adapter handle ios "$gen" "$result" > "$TMP_ROOT/handle.out" 2>&1
  rc=$?
  printf 'handle exit status: %s (%s)\n' "$rc" "$(tr '\n' ' ' < "$TMP_ROOT/handle.out")"
  LAST_HANDLE_RC=$rc
  LAST_RESULT=$result
}

# The operator command runs inside the lab's private tmux server, where the
# route's steering pane lives, so fm-send.sh delivers the answer and then
# writes the close line itself.
lab_tmux() { TMUX_TMPDIR="$PARENT/tmux" tmux -L fm-lab "$@"; }
resolve_decision() {
  local _
  rm -f "$TMP_ROOT/send.out" "$TMP_ROOT/send.rc"
  lab_tmux send-keys -t lab:op "'$ACTIVE_ROOT/bin/fm-send.sh' ios --resolve-key remote-reply-continuity-ios 'accepted the continuity break' > '$TMP_ROOT/send.out' 2>&1; echo \$? > '$TMP_ROOT/send.rc'" Enter
  for _ in $(seq 1 600); do
    [ -s "$TMP_ROOT/send.rc" ] && break
    sleep 0.1
  done
  RESOLVE_RC=$(cat "$TMP_ROOT/send.rc" 2>/dev/null || echo timeout)
  printf 'fm-send.sh ios --resolve-key remote-reply-continuity-ios exit status: %s\n' "$RESOLVE_RC"
  [ "$RESOLVE_RC" = 0 ] || sed 's/^/  fm-send: /' "$TMP_ROOT/send.out"
  printf 'close line: %s\n' "$(grep -F 'resolved [key=remote-reply-continuity-ios]' "$STATUS" | tail -1)"
}

mkdir -p "$PARENT/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$PARENT/tmux" tmux -L fm-lab new-session -d -s lab -n op -x 200 -y 50 \
  -c "$ROOT" -e FM_HOME="$PARENT" bash --norc || exit 1
lab_tmux new-window -d -t lab -n fm-ios -c "$ROOT" cat
printf 'window=lab:fm-ios\nendpoint_task_id=ios\nworktree=%s\nproject=%s\nharness=echo\nkind=secondmate\nmode=secondmate\nyolo=off\n' \
  "$PARENT" "$PARENT" > "$PARENT/state/ios.meta"

write_secondmates
: > "$LOG"
SID=$(adapter source-id ios)

if [ "$MODE" = upgrade ]; then
  ACTIVE_ROOT=$OLD_ROOT
  write_secondmates
fi

say "1. reader advances over a 77-byte log, then the log is replaced by a 2-byte file"
adapter arm ios
printf 'working: first line of the original remote reply log\nworking: second line...\n' > "$LOG"
expect "original log size" "$(wc -c < "$LOG" | tr -d ' ')" 77
read_to_end || { echo "FAIL  reader never reached offset 77"; FAILS=$((FAILS + 1)); }
cp "$LOG" "$TMP_ROOT/original-log"
stop_listener
printf 'x\n' > "$LOG"
read_break
show_state
expect "first break handle exit status" "$LAST_HANDLE_RC" 3
expect "blocked lines after first break" "$(blocked_count)" 1
expect "open decision after first break" "$(open_decisions)" "$(printf 'remote-reply-continuity-ios\tblocked')"

say "2. operator resolves the continuity decision"
resolve_decision
expect "operator resolve exit status" "$RESOLVE_RC" 0
expect "open decisions after resolve" "$(open_decisions)" ""
expect "blocked lines after resolve" "$(blocked_count)" 1

if [ "$MODE" = upgrade ]; then
  say "UPGRADE: the home now runs the changed scripts; it has the blocked line and no episode file"
  stop_listener
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    fm_remote_job_stop_worker_tree "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" || true
  fi
  ACTIVE_ROOT=$ROOT
  write_secondmates
  show_state
fi

say "3. a later read of that same shortened log (cursor has not moved)"
adapter arm ios
read_break
show_state
expect "repeat break handle exit status" "$LAST_HANDLE_RC" 3
expect "blocked lines after unchanged re-read" "$(blocked_count)" 1
expect "open decisions after unchanged re-read" "$(open_decisions)" ""

if [ "$MODE" = issue ]; then
  say "4. retire the route, restore a 43-byte log, reader advances from the start"
  adapter retire ios
  show_state
  printf 'working: route restored and readable again\n' > "$LOG"
  adapter arm ios
  read_to_end || { echo "FAIL  reader never reached offset 43"; FAILS=$((FAILS + 1)); }
  show_state
  expect "cursor offset after restore" "$(sed -n 's/^offset=//p' "$PARENT/state/remote-replies/ios.cursor")" 43
  expect "blocked lines after restore" "$(blocked_count)" 1
  expect "open decisions after restore" "$(open_decisions)" ""

  say "5. empty the restored log: the second, distinct break"
  stop_listener
  : > "$LOG"
  read_break
  show_state
  expect "second break handle exit status" "$LAST_HANDLE_RC" 3
  expect "blocked lines after second break" "$(blocked_count)" 2
  expect "open decision after second break" "$(open_decisions)" "$(printf 'remote-reply-continuity-ios\tblocked')"

  say "6. adversarial: replay the same captured result, then read the unchanged empty log again"
  adapter ingest ios "$LAST_RESULT" >/dev/null 2>&1
  expect "blocked lines after replayed ingest" "$(blocked_count)" 2
  adapter arm ios
  read_break
  expect "blocked lines after a fresh read of the unchanged break" "$(blocked_count)" 2

  say "7. adversarial: resolve, then read the unchanged break once more (must stay closed)"
  resolve_decision
  adapter arm ios
  read_break
  show_state
  expect "blocked lines after resolve and unchanged re-read" "$(blocked_count)" 2
  expect "open decisions after resolve and unchanged re-read" "$(open_decisions)" ""

  say "8. no retirement: the 43-byte log comes back with one more line, the reader advances, the log is emptied"
  printf 'working: route restored and readable again\nworking: extended without retirement\n' > "$LOG"
else
  say "4. no retirement: the original 77-byte log comes back with one more line, the reader advances, the log is emptied"
  { cat "$TMP_ROOT/original-log"; printf 'working: extended after the upgrade\n'; } > "$LOG"
fi
want=$(wc -c < "$LOG" | tr -d ' ')
adapter arm ios
read_to_end || { echo "FAIL  reader never reached offset $want"; FAILS=$((FAILS + 1)); }
before=$(blocked_count)
show_state
expect "open decisions after the cursor moved" "$(open_decisions)" ""
stop_listener
: > "$LOG"
read_break
show_state
expect "moved-cursor break handle exit status" "$LAST_HANDLE_RC" 3
expect "blocked lines after the moved-cursor break" "$(blocked_count)" "$((before + 1))"
expect "open decision after the moved-cursor break" "$(open_decisions)" "$(printf 'remote-reply-continuity-ios\tblocked')"

say "final parent status log (continuity lines)"
grep -F 'key=remote-reply-continuity-ios' "$STATUS"

printf '\nRESULT: %s failed expectation(s)\n' "$FAILS"
[ "$FAILS" -eq 0 ]
