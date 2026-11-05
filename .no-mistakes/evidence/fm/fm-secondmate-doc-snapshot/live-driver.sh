#!/usr/bin/env bash
# Live lab driver for the fm-secondmate-report.sh --doc snapshot handoff.
# Drives the real scripts in disposable homes under one mktemp lab:
#   parent      - a marked lab home (bin/fm-lab-home.sh create), the routing parent
#   local-mate  - a route=local secondmate of that parent
#   remote-mate - a route=remote secondmate ("ios") reached through bin/fm-on.sh
#   mac-home    - a second remote home ("mac") that receives an onward copy
# The only stand-in is the network hop: FM_SSH_BIN points at a shim that execs
# the real bin/fm-remote-entrypoint.sh locally with a lab-private job-worker
# state root, so the real worker, fm-remote-file.sh, fm-document-snapshot.sh,
# adapter, and process-event runner all run. Real ssh to this Mac would use the
# operator's shared ~/.firstmate/remote-job worker, so it is not used.
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/bbb16e1f0808/01M6P07XYATPPRN04RMXHF48Z7
EV=/Users/tiago/.no-mistakes/evidence/01M6P07XYATPPRN04RMXHF48Z7
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
PARENT="$LAB/parent"
LOCALMATE="$LAB/local-mate"
REMOTE="$LAB/remote-mate"
MACHOME="$LAB/mac-home"
ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
FAILS=0
RUNNER_PID=

ok() { printf 'PASS [%s] %s\n' "$1" "$2"; }
bad() { printf 'FAIL [%s] %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
check() { local s=$1 d=$2; shift 2; if "$@"; then ok "$s" "$d"; else bad "$s" "$d"; fi; }
has() { grep -Fq -- "$2" <<<"$1"; }
lacks() { ! grep -Fq -- "$2" <<<"$1"; }
section() { printf '\n==================== %s ====================\n' "$*"; }
# Print a command as the user would type it (lab paths shortened), run it, print its exit.
show() {
  local rc=0
  printf '\n$ %s\n' "$(printf '%q ' "$@" | sed "s#$LAB#\$LAB#g; s#$ROOT#\$ROOT#g")"
  "$@" || rc=$?
  printf '[exit %s]\n' "$rc"
  return "$rc"
}
penv() {
  env FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" FM_SSH_BIN="$LAB/bin/ssh" \
    FM_LAB_ROOT="$ROOT" FM_REMOTE_JOB_STATE_ROOT="$LAB/remote-jobs" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_REPLY_WAIT_SECONDS=5 LAB_SSH_LOG="$LAB/ssh.log" LAB_SSH_DOWN="$LAB/ssh-down" "$@"
}
plib() { ( . "$ROOT/bin/fm-pending-reply-lib.sh"; "$@" ); }
clib() { ( . "$ROOT/bin/fm-classify-lib.sh"; "$@" ); }
wait_until() { # <seconds> <command...>
  local limit=$1 i=0; shift
  while [ "$i" -lt $((limit * 10)) ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}
stop_runner() {
  local pid
  pid=$(sed -n '2p' "$LAB/claims/$SID.claim" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) pid=$RUNNER_PID ;; esac
  [ -n "$pid" ] || return 0
  kill -TERM -- -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  wait_until 10 bash -c '! kill -0 "$1" 2>/dev/null' _ "$pid" || true
  RUNNER_PID=
}
start_runner() {
  penv "$ROOT/bin/fm-procevent.sh" start "$SID" >> "$LAB/runner.log" 2>&1 &
  RUNNER_PID=$!
  wait_until 20 test -e "$LAB/claims/$SID.claim" || bad setup "runner never claimed $SID"
}
wait_cursor_current() {
  local offset
  offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
  wait_until 30 grep -qs "offset=$offset" "$PARENT/state/remote-replies/ios.cursor"
}
cleanup() {
  stop_runner 2>/dev/null
  penv "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$LAB/remote-jobs/worker.pid" ]; then
    ( . "$ROOT/bin/fm-remote-job-lib.sh"; fm_remote_job_stop_worker_tree "$(cat "$LAB/remote-jobs/worker.pid")" ) || true
  fi
  [ -f "$LAB/runner.log" ] && cp "$LAB/runner.log" "$EV/live-runner.log"
  [ -f "$LAB/ssh.log" ] && cp "$LAB/ssh.log" "$EV/live-transport.log"
  rm -rf -- "$LAB"
  printf '\nlab removed: %s\n' "$([ -e "$LAB" ] && echo no || echo yes)"
}
trap cleanup EXIT

section "Setup: disposable homes"
"$ROOT/bin/fm-lab-home.sh" create "$PARENT" >/dev/null || { echo "cannot create lab parent"; exit 1; }
mkdir -p "$LAB/claims" "$LAB/bin" "$LOCALMATE/state" "$LOCALMATE/data/plans" \
  "$REMOTE/state" "$REMOTE/data/plans" "$MACHOME/state" "$MACHOME/data"
printf 'mate\n' > "$LOCALMATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$LOCALMATE/.fm-secondmate-parent"
printf 'ios\n' > "$REMOTE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent\n' > "$REMOTE/.fm-secondmate-parent"
: > "$REMOTE/state/parent-replies.status"
printf 'mac\n' > "$MACHOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=parent\n' > "$MACHOME/.fm-secondmate-parent"
cat > "$PARENT/data/secondmates.md" <<EOF
- ios - server documents (host: lab-remote; root: $ROOT; home: $REMOTE; scope: documents; projects: alpha; added 2026-11-05)
- mac - mac checks (host: lab-remote; root: $ROOT; home: $MACHOME; scope: checks; projects: alpha; added 2026-11-05)
EOF
cat > "$LAB/bin/ssh" <<'SH'
#!/usr/bin/env bash
# ssh stand-in: no network hop, runs the real remote entrypoint on this machine.
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1 entry=$2
shift 2
[ "$host" = lab-remote ] && [ "$entry" = fm-remote-entrypoint.sh ] || exit 91
argv=$(printf '%s' "$4" | base64 -D | tr '\0' ' ')
if [ -e "$LAB_SSH_DOWN" ] && [ "${argv%% *}" = fm-remote-file.sh ]; then
  printf 'exit=255 (lab transport down) %s\n' "$argv" >> "$LAB_SSH_LOG"
  exit 255
fi
printf 'run %s\n' "$argv" >> "$LAB_SSH_LOG"
exec "$FM_LAB_ROOT/bin/fm-remote-entrypoint.sh" "$@"
SH
chmod +x "$LAB/bin/ssh"
echo "lab=\$LAB parent=\$LAB/parent local-mate=\$LAB/local-mate remote-mate(ios)=\$LAB/remote-mate mac=\$LAB/mac-home"

section "S1 local route: --doc delivers a verified, immutable snapshot with provenance"
cat > "$LOCALMATE/data/plans/routetest-plan.md" <<'EOF'
# Biome check plan for PR 7150

1. Check out the target commit named in the request.
2. Run `bunx biome check` on the changed packages.
3. Report every finding with file and line.
EOF
cp "$LOCALMATE/data/plans/routetest-plan.md" "$LAB/expected-local.md"
CORR_L=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" mate "run the Biome check; the plan is in your home")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_L"
show env FM_HOME="$LOCALMATE" "$REPORT" --doc done "$CORR_L" data/plans/routetest-plan.md "Plan attached for the Biome check." \
  || bad S1 "local --doc report failed"
LINE_L=$(tail -1 "$PARENT/state/mate.status")
printf '\nparent state/mate.status last line:\n%s\n' "$(sed "s#$LAB#\$LAB#g" <<<"$LINE_L")"
SNAP_L=$(grep -oE 'report=data/report-snapshots/[a-f0-9]{64}\.md' <<<"$LINE_L" | cut -d= -f2-)
check S1 "the answer names a data/report-snapshots/<sha256>.md snapshot" test -n "$SNAP_L"
check S1 "the parent home holds a byte-identical copy before the answer line" cmp -s "$LAB/expected-local.md" "$PARENT/$SNAP_L"
check S1 "snapshot name is the sha256 of the bytes" test "$(shasum -a 256 "$PARENT/$SNAP_L" | awk '{print $1}').md" = "${SNAP_L##*/}"
check S1 "line keeps source-host" has "$LINE_L" "source-host=$(hostname)"
check S1 "line keeps source-home" has "$LINE_L" "source-home=$LOCALMATE"
check S1 "line keeps source-document" has "$LINE_L" "source-document=data/plans/routetest-plan.md"
plib fm_pending_reply_try_resolve "$PARENT/state" "$CORR_L" >/dev/null 2>&1
RES_L=$(plib fm_pending_reply_result "$PARENT/state" "$CORR_L")
printf 'pending reply %s: %s\n' "$CORR_L" "$RES_L"
check S1 "the parent's pending request reads answered" has "$RES_L" "request: answered"
printf 'Edited after the report: run eslint instead.\n' > "$LOCALMATE/data/plans/routetest-plan.md"
check S1 "editing the source after reporting leaves the parent copy unchanged" cmp -s "$LAB/expected-local.md" "$PARENT/$SNAP_L"

section "S2 local route boundary: exactly 1048576 bytes is accepted"
head -c 1048576 /dev/zero | tr '\0' y > "$LOCALMATE/data/plans/max.md"
CORR_M=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" mate "send the max-size plan")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_M"
show env FM_HOME="$LOCALMATE" "$REPORT" --doc done "$CORR_M" data/plans/max.md >/dev/null || bad S2 "1 MiB document refused"
SNAP_M=$(tail -1 "$PARENT/state/mate.status" | grep -oE 'report=data/report-snapshots/[a-f0-9]{64}\.md' | cut -d= -f2-)
check S2 "a 1048576-byte document arrives byte-identical" cmp -s "$LOCALMATE/data/plans/max.md" "$PARENT/$SNAP_M"

section "S3 local route guards: unsafe or secret documents never acknowledge the request"
printf 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' > "$LOCALMATE/data/plans/aws.md"
printf 'DATABASE_URL=postgres://app:Zx8Qw2Lp9Vt4@db.internal:5432/app\n' > "$LOCALMATE/data/plans/dburl.md"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n' > "$LOCALMATE/data/plans/key-in-text.md"
printf 'token ghp_%s\n' "$(head -c 36 /dev/zero | tr '\0' A)" > "$LOCALMATE/data/plans/gh.md"
ln -s routetest-plan.md "$LOCALMATE/data/plans/symlink.md"
ln "$LOCALMATE/data/plans/routetest-plan.md" "$LOCALMATE/data/plans/hardlink.md"
printf 'plain prose\n' > "$LOCALMATE/data/plans/id_rsa.txt"
head -c 1048577 /dev/zero | tr '\0' x > "$LOCALMATE/data/plans/oversized.md"
printf 'not under data\n' > "$LOCALMATE/state/outside.md"
printf '\xff\xfe binary\n' > "$LOCALMATE/data/plans/binary.md"
printf 'json\n' > "$LOCALMATE/data/plans/plan.json"
CORR_G=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" mate "guard probe")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_G"
for doc in data/plans/aws.md data/plans/dburl.md data/plans/key-in-text.md data/plans/gh.md \
  data/plans/symlink.md data/plans/hardlink.md data/plans/id_rsa.txt data/plans/oversized.md \
  state/outside.md data/plans/binary.md data/plans/plan.json data/plans/missing.md /etc/hosts; do
  before_lines=$(wc -l < "$PARENT/state/mate.status")
  before_snaps=$(find "$PARENT/data/report-snapshots" -type f | wc -l)
  rc=0
  show env FM_HOME="$LOCALMATE" "$REPORT" --doc done "$CORR_G" "$doc" "guard probe" || rc=$?
  [ "$rc" -ne 0 ] && [ "$(wc -l < "$PARENT/state/mate.status")" = "$before_lines" ] \
    && [ "$(find "$PARENT/data/report-snapshots" -type f | wc -l)" = "$before_snaps" ] \
    && ok S3 "$doc refused: nonzero exit, no answer line, no parent snapshot" \
    || bad S3 "$doc was not refused cleanly"
done
plib fm_pending_reply_try_resolve "$PARENT/state" "$CORR_G" >/dev/null 2>&1
check S3 "the guard probe request is still unanswered" bash -c '! ( . "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_result "$2" "$3" ) >/dev/null' _ "$ROOT" "$PARENT/state" "$CORR_G"

section "S4 local route: an unverifiable parent copy blocks the answer"
printf '# a different plan\n' > "$LOCALMATE/data/plans/blocked.md"
mv "$PARENT/data/report-snapshots" "$PARENT/data/saved-snapshots"
ln -s saved-snapshots "$PARENT/data/report-snapshots"
before_lines=$(wc -l < "$PARENT/state/mate.status")
rc=0
show env FM_HOME="$LOCALMATE" "$REPORT" --doc done "$CORR_G" data/plans/blocked.md "blocked probe" || rc=$?
check S4 "the helper fails when the parent's snapshot directory is a symlink" test "$rc" -ne 0
check S4 "no answer line was appended" test "$(wc -l < "$PARENT/state/mate.status")" = "$before_lines"
rm "$PARENT/data/report-snapshots"
mv "$PARENT/data/saved-snapshots" "$PARENT/data/report-snapshots"

section "S5 remote route through the real runner: a 300000-byte plan arrives verified"
SID=$(penv "$ADAPTER" source-id ios)
show penv "$ADAPTER" arm ios | sed "s#$LAB#\$LAB#g"
start_runner
python3 - "$REMOTE/data/plans/routetest-plan.md" <<'PY'
import sys
lines = ['# Routetest plan for the Biome check\n']
i = 0
while sum(len(l) for l in lines) < 300000:
    i += 1
    lines.append(f'{i:05d}. Run the documented check on package {i % 37} and report file and line.\n')
data = ''.join(lines).encode()[:300000]
open(sys.argv[1], 'wb').write(data)
PY
cp "$REMOTE/data/plans/routetest-plan.md" "$LAB/expected-remote.md"
CORR_R=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" ios "send the routetest plan for the Biome check")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_R"
show env FM_HOME="$REMOTE" "$REPORT" --doc done "$CORR_R" data/plans/routetest-plan.md "The reviewed plan is attached." \
  || bad S5 "remote --doc report failed"
printf 'Changed on the server after reporting.\n' > "$REMOTE/data/plans/routetest-plan.md"
printf 'working [key=after-plan]: starting the Biome check\n' >> "$REMOTE/state/parent-replies.status"
printf '\nremote state/parent-replies.status:\n'; sed "s#$LAB#\$LAB#g" "$REMOTE/state/parent-replies.status"
SNAP_R=$(grep -oE 'report=data/report-snapshots/[a-f0-9]{64}\.md' "$REMOTE/state/parent-replies.status" | tail -1 | cut -d= -f2-)
wait_until 60 grep -Fq 'starting the Biome check' "$PARENT/state/ios.status" || bad S5 "the runner never mirrored the delta"
wait_cursor_current || bad S5 "ingest never committed the cursor"
printf '\nparent state/ios.status:\n'; sed "s#$LAB#\$LAB#g" "$PARENT/state/ios.status"
LOCAL_R="data/remote-secondmates/ios/$SNAP_R"
check S5 "the parent received the originally reviewed 300000 bytes" cmp -s "$LAB/expected-remote.md" "$PARENT/$LOCAL_R"
check S5 "the document is above the ordinary 262144-byte report limit" test "$(wc -c < "$PARENT/$LOCAL_R" | tr -d ' ')" -gt 262144
check S5 "the mirrored answer points at the parent's local copy" grep -Fq "report=$LOCAL_R" "$PARENT/state/ios.status"
check S5 "the mirrored answer keeps source-home" grep -Fq "source-home=$REMOTE" "$PARENT/state/ios.status"
check S5 "the mirrored answer keeps source-document" grep -Fq "source-document=data/plans/routetest-plan.md" "$PARENT/state/ios.status"
RES_R=$(plib fm_pending_reply_result "$PARENT/state" "$CORR_R")
printf 'pending reply %s: %s\n' "$CORR_R" "$RES_R"
check S5 "the parent's pending request reads answered" has "$RES_R" "request: answered"
check S5 "no snapshot escalation was raised" bash -c '! grep -q remote-reply-snapshot- "$1"' _ "$PARENT/state/ios.status"
check S5 "every capture was autohandled (no check wake queued)" bash -c '! grep -qs "procevent remote-reply" "$1"' _ "$PARENT/state/.wake-queue"

section "S6 remote route: transport down (ssh 255) during the snapshot fetch holds the answer, then handle delivers it"
touch "$LAB/ssh-down"
printf '# Second plan\n\nRun the follow-up lint pass.\n' > "$REMOTE/data/plans/second.md"
cp "$REMOTE/data/plans/second.md" "$LAB/expected-second.md"
CORR_T=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" ios "send the second plan")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_T"
show env FM_HOME="$REMOTE" "$REPORT" --doc done "$CORR_T" data/plans/second.md "The second plan is attached." \
  || bad S6 "second remote --doc report failed"
SNAP_T=$(grep -oE 'report=data/report-snapshots/[a-f0-9]{64}\.md' "$REMOTE/state/parent-replies.status" | tail -1 | cut -d= -f2-)
wait_until 60 bash -c 'grep -qs "procevent remote-reply" "$1"' _ "$PARENT/state/.wake-queue" \
  || bad S6 "the failed capture never produced a check wake"
RESULT_T=$(grep -l "corr=$CORR_T" "$PARENT/state/procevent-inbox/$SID".*.result 2>/dev/null | head -1)
SEQ_T=${RESULT_T%.result}; SEQ_T=${SEQ_T##*.}
printf '\ncaptured result: %s (generation %s)\n' "${RESULT_T#$LAB/}" "$SEQ_T"
printf 'wake queue:\n'; sed "s#$LAB#\$LAB#g" "$PARENT/state/.wake-queue"
printf 'transport log (last 3):\n'; tail -3 "$LAB/ssh.log" | cut -c1-160
printf 'runner log (last 3):\n'; tail -3 "$LAB/runner.log" | sed "s#$LAB#\$LAB#g"
check S6 "the delta was captured" test -n "$RESULT_T"
check S6 "the capture is left unacknowledged for the handler" test ! -e "${RESULT_T%.result}.handled"
check S6 "the answer was not mirrored" bash -c '! grep -Fq "corr=$1" "$2"' _ "$CORR_T" "$PARENT/state/ios.status"
check S6 "no escalation or note was raised for a transient failure" bash -c '! grep -Fq "$1" "$2"' _ "$SNAP_T" "$PARENT/state/ios.status"
check S6 "no partial local copy exists" test ! -e "$PARENT/data/remote-secondmates/ios/$SNAP_T"
check S6 "the request is still unanswered" bash -c '! ( . "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_result "$2" "$3" ) >/dev/null' _ "$ROOT" "$PARENT/state" "$CORR_T"
check S6 "the snapshot fetch really saw ssh exit 255" grep -q "exit=255 (lab transport down) fm-remote-file.sh get $SNAP_T" "$LAB/ssh.log"
rm "$LAB/ssh-down"
show penv "$ADAPTER" handle ios "$SEQ_T" "$RESULT_T" | sed "s#$LAB#\$LAB#g"
check S6 "after transport recovers, handle delivers the exact bytes" cmp -s "$LAB/expected-second.md" "$PARENT/data/remote-secondmates/ios/$SNAP_T"
check S6 "the capture is now acknowledged" test -e "${RESULT_T%.result}.handled"
RES_T=$(plib fm_pending_reply_result "$PARENT/state" "$CORR_T")
printf 'pending reply %s: %s\n' "$CORR_T" "$RES_T"
check S6 "the request now reads answered" has "$RES_T" "request: answered"

section "S7 remote route: a missing, malformed, or corrupt snapshot passes through with one keyed escalation"
stop_runner
CORR_X=$(plib fm_pending_reply_create "$PARENT" "$PARENT/state" ios "send the third plan")
plib fm_pending_reply_mark_delivered "$PARENT/state" "$CORR_X"
printf '# Third plan\n' > "$REMOTE/data/plans/third.md"
show env FM_HOME="$REMOTE" "$REPORT" --doc done "$CORR_X" data/plans/third.md "The third plan is attached." \
  || bad S7 "third remote --doc report failed"
SNAP_X=$(grep -oE 'report=data/report-snapshots/[a-f0-9]{64}\.md' "$REMOTE/state/parent-replies.status" | tail -1 | cut -d= -f2-)
show rm "$REMOTE/$SNAP_X"
CORRUPT="data/report-snapshots/$(printf '%064d' 1).md"
printf 'bytes that do not match their digest\n' > "$REMOTE/$CORRUPT"
printf 'done [corr=6666666666666666]: hand-written malformed report=data/report-snapshots/not-a-digest.md\n' >> "$REMOTE/state/parent-replies.status"
printf 'done [corr=7777777777777777]: corrupt report=%s\n' "$CORRUPT" >> "$REMOTE/state/parent-replies.status"
printf 'working [key=after-bad-snapshots]: the line after three unverified snapshots\n' >> "$REMOTE/state/parent-replies.status"
: > "$LAB/ssh.log"
start_runner
wait_until 60 grep -Fq 'the line after three unverified snapshots' "$PARENT/state/ios.status" \
  || bad S7 "the runner never mirrored the line after the bad snapshots"
wait_cursor_current || bad S7 "ingest never committed the cursor"
printf '\nparent state/ios.status (new lines):\n'; tail -7 "$PARENT/state/ios.status" | sed "s#$LAB#\$LAB#g"
check S7 "the missing snapshot's answer is mirrored with its original pointer" grep -Fq "report=$SNAP_X" "$PARENT/state/ios.status"
check S7 "the missing snapshot raised its keyed escalation with the reader's reason" \
  grep -Eq "^blocked \[key=remote-reply-snapshot-ios-[0-9]+\]( \[at=[0-9]+\])?: required document snapshot did not transfer for ios: $SNAP_X - file is not a non-symlink regular file" "$PARENT/state/ios.status"
check S7 "the malformed pointer raised its keyed escalation" \
  grep -Eq '^blocked \[key=remote-reply-snapshot-ios-[0-9]+\]( \[at=[0-9]+\])?: required document snapshot did not transfer for ios: data/report-snapshots/not-a-digest.md - invalid required snapshot digest' "$PARENT/state/ios.status"
check S7 "the corrupt snapshot raised its keyed escalation" \
  grep -Fq "required document snapshot did not transfer for ios: $CORRUPT - cannot deliver document snapshot: snapshot bytes do not match their commitment" "$PARENT/state/ios.status"
check S7 "the corrupt bytes were not stored locally" test ! -e "$PARENT/data/remote-secondmates/ios/$CORRUPT"
check S7 "the missing snapshot was fetched exactly once (a refusal is not retried)" \
  test "$(grep -c "fm-remote-file.sh get $SNAP_X" "$LAB/ssh.log")" = 1
check S7 "the malformed pointer was never fetched" bash -c '! grep -q not-a-digest "$1"' _ "$LAB/ssh.log"
check S7 "the line after the bad snapshots kept flowing" grep -Fq 'the line after three unverified snapshots' "$PARENT/state/ios.status"
RES_X=$(plib fm_pending_reply_result "$PARENT/state" "$CORR_X")
printf 'pending reply %s: %s\n' "$CORR_X" "$RES_X"
check S7 "the answer without its snapshot still settles the request" has "$RES_X" "request: answered"
OPEN=$(clib status_open_decisions "$PARENT/state/ios.status" | grep -c '^remote-reply-snapshot-ios-')
OWN=$(clib status_own_open_decisions "$PARENT/state/ios.status" | grep -c '^remote-reply-snapshot-' || true)
printf 'open snapshot escalations=%s, counted as the mate'"'"'s own decisions=%s\n' "$OPEN" "$OWN"
check S7 "exactly three keyed escalations are open" test "$OPEN" = 3
check S7 "they are the parent's blockers, not the mate's own decisions" test "$OWN" = 0
OFFSET=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
wait_until 10 grep -q "offset=$OFFSET" "$PARENT/state/remote-replies/ios.cursor"
printf 'remote log bytes=%s, parent cursor: %s\n' "$OFFSET" "$(tr '\n' ' ' < "$PARENT/state/remote-replies/ios.cursor")"
check S7 "the cursor advanced to the end of the remote log" grep -q "offset=$OFFSET" "$PARENT/state/remote-replies/ios.cursor"
printf 'working [key=next-generation]: the next generation still mirrors\n' >> "$REMOTE/state/parent-replies.status"
wait_until 60 grep -Fq 'the next generation still mirrors' "$PARENT/state/ios.status"
check S7 "a later generation still mirrors (the channel is not wedged)" grep -Fq 'the next generation still mirrors' "$PARENT/state/ios.status"
check S7 "the later generation did not repeat an escalation" \
  test "$(clib status_open_decisions "$PARENT/state/ios.status" | grep -c '^remote-reply-snapshot-ios-')" = 3
clib status_open_decisions "$PARENT/state/ios.status" | awk -F '\t' '/^remote-reply-snapshot-ios-/ { print $1 }' \
  | while IFS= read -r key; do printf 'resolved [key=%s]: operator supplied the document\n' "$key" >> "$PARENT/state/ios.status"; done
check S7 "an operator closes the escalations with resolved lines" \
  test "$(clib status_open_decisions "$PARENT/state/ios.status" | grep -c '^remote-reply-snapshot-' || true)" = 0
stop_runner

section "S8 onward route: copy the received snapshot into another remote home with fm-on.sh --stdin"
DIGEST=${SNAP_R##*/}; DIGEST=${DIGEST%.md}
SIZE=$(wc -c < "$PARENT/$LOCAL_R" | tr -d ' ')
RECEIPT=$(show penv "$ROOT/bin/fm-on.sh" --stdin mac fm-document-snapshot.sh receive "$DIGEST" "$SIZE" < "$PARENT/$LOCAL_R")
printf '%s\n' "$RECEIPT"
check S8 "the receiving home printed its verified path" has "$RECEIPT" "$SNAP_R"
check S8 "the mac home holds the exact reviewed bytes" cmp -s "$LAB/expected-remote.md" "$MACHOME/$SNAP_R"
printf 'tampered in transit\n' > "$LAB/tampered.md"
rc=0
show penv "$ROOT/bin/fm-on.sh" --stdin mac fm-document-snapshot.sh receive "$(printf '%064d' 2)" "$(wc -c < "$LAB/tampered.md" | tr -d ' ')" < "$LAB/tampered.md" || rc=$?
check S8 "bytes that do not match the digest are refused with exit 1" test "$rc" = 1
check S8 "no file was published for the refused digest" test ! -e "$MACHOME/data/report-snapshots/$(printf '%064d' 2).md"

section "Summary"
printf 'failures=%s\n' "$FAILS"
[ "$FAILS" -eq 0 ]
