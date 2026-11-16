#!/usr/bin/env bash
# Real terminal behavior behind fake SSH, without a model or user app.
# Excludes SSH authentication/login, remote-entrypoint, job-worker, and model recovery.
# Logical fm-remote is translated to an owned fm-hclab session, not a user's core.
# Steering asserts durable delivery only; a shell cannot consume a model doorbell.
set -eu
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

HC_BIN=${FM_HC_BIN:-$(command -v herdr-core || command -v hc || true)}
[ -x "$HC_BIN" ] || { echo 'skip: hc not found'; exit 0; }
for tool in jq python3 treehouse; do
  command -v "$tool" >/dev/null || { echo "skip: $tool not found"; exit 0; }
done
export FM_HC_BIN=$HC_BIN
printf 'CLI: %s (%s)\n' "$("$HC_BIN" --version)" "$HC_BIN"
TMP_ROOT=$(fm_test_tmproot fm-remote-hc-smoke)
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name remote)
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
WT=
cleanup_lab() {
  local rc=$?
  trap - EXIT
  export FM_HC_BIN=$HC_BIN
  if ! hc_test_safe_teardown "$ROOT" "$HC_TEST_SES"; then
    echo "not ok - lab cleanup failed; preserved $HC_LAB_DIR" >&2
    exit 1
  fi
  if [ -z "$WT" ] && [ -f "${CHILD:-}/state/shell-worker.meta" ]; then
    WT=$(sed -n 's/^worktree=//p' "$CHILD/state/shell-worker.meta")
  fi
  if [ -n "$WT" ]; then
    treehouse return --force "$WT" >/dev/null 2>&1 || rc=1
  fi
  [ "$rc" -ne 0 ] || pass 'lab teardown: core stopped, processes removed, real fleet tripwire unchanged'
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT
# Keep the tripwire pointed at real state while preventing login-shell dotfiles.
export XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
export HOME="$TMP_ROOT/user" SHELL=/bin/bash FM_HC_SOCKET=$HC_TEST_SOCK
mkdir -p "$HOME"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET HERDR_APP_HOME FM_BACKEND
# Embed the pins before core startup so terminal children inherit this wrapper.
mkdir -p "$TMP_ROOT/guard-bin"
{
  printf '#!/bin/bash\nset -eu\n'
  printf 'source %q\n' "$ROOT/tests/hc-test-safety.sh"
  printf 'lab=%q\nsocket=%q\ndir=%q\nbinary=%q\naccount=%q\nlog=%q\n' \
    "$HC_TEST_SES" "$HC_TEST_SOCK" "$HC_LAB_DIR" "$HC_BIN" "$HOME" "$TMP_ROOT/hc.calls"
  printf 'export FM_HC_LAB_DIR=%q\n' "$(hc_test_lab_dir)"
  cat <<'GUARD'
hc_test_refuse_if_unsafe "$lab" || exit 90
[ -S "$socket" ] || exit 91
# Only the adapter's negotiation may carry a logical session argument.
if [ "${1:-}" = connect ]; then
  [ "$#" = 3 ] && [ "$2" = --session ] && [ "$3" = fm-remote ] || exit 92
  set -- connect
fi
for arg in "$@"; do
  case "$arg" in --session|--session=*|--socket|--socket=*|--on|--on=*) exit 93 ;; esac
done
case "${1:-}" in
  --version|run|ls) ;;
  server) [ "$#" = 3 ] && [ "$2" = status ] && [ "$3" = --json ] || exit 94 ;;
  connect) ;;
  read)
    [ "$#" = 4 ] && [ "$2" = --lines ] && [[ "$4" =~ ^t[0-9]+$ ]] || exit 95 ;;
  get|send|keys)
    target=${2:-}
    [ "$target" != --json ] || target=${3:-}
    [[ "$target" =~ ^t[0-9]+$ ]] || exit 95 ;;
  *) exit 96 ;;
esac
printf '%s|%s|%s\n' "$lab" "$socket" "$*" >> "$log"
exec env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE \
  HOME="$account" HC_SESSION="$lab" HC_SOCKET="$socket" \
  XDG_STATE_HOME="$dir/env/xdg-state" XDG_CONFIG_HOME="$dir/env/xdg-config" \
  XDG_DATA_HOME="$dir/env/xdg-data" XDG_RUNTIME_DIR="$dir/env/xdg-runtime" "$binary" "$@"
GUARD
} > "$TMP_ROOT/guard-bin/hc"
chmod +x "$TMP_ROOT/guard-bin/hc"
ln -s hc "$TMP_ROOT/guard-bin/herdr-core"
export PATH="$TMP_ROOT/guard-bin:$PATH"
"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES"
hc_test_refuse_if_unsafe "$HC_TEST_SES" || fail 'unsafe lab session'
mkdir -m 700 "$HC_LAB_DIR/env/xdg-runtime"
export FM_HC_BIN="$TMP_ROOT/guard-bin/hc"
export HC_SESSION=fm-remote XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state"
export XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
export FM_SKIP_SECONDMATE_SYNC=1 FM_SPAWN_NO_GUARD=1
PRIMARY="$TMP_ROOT/parent"
CHILD="$TMP_ROOT/child"
PROJ="$TMP_ROOT/project"
fm_test_spawn_home "$PRIMARY"
cp -R "$ROOT/bin/." "$PRIMARY/bin/"
fm_test_spawn_home "$CHILD"
seed_secondmate_home_marker "$CHILD" captain
cp -R "$ROOT/bin/." "$CHILD/bin/"
fm_git_init_commit "$CHILD"
fm_git_init_commit "$PROJ"
git clone -q --bare "$PROJ" "$TMP_ROOT/origin.git"
git -C "$PROJ" remote add origin "$TMP_ROOT/origin.git"
scaffold_secondmate_charter "$PRIMARY" captain 'Supervise the shell worker' --no-projects
printf 'Supervise the shell worker\n' > "$CHILD/data/charter.md"
printf -- '- captain - shell fleet (host: fixture-host; root: %s; home: %s; scope: smoke; projects: ; added 2026-11-15)\n' "$PRIMARY" "$CHILD" > "$PRIMARY/data/secondmates.md"
fm_test_spawn_brief "$CHILD" shell-worker 'Run the isolated shell workload'

cat > "$TMP_ROOT/captain.sh" <<'INNER'
#!/bin/bash
set -eu
export FM_HC_BIN="$(dirname "$0")/guard-bin/hc"
receipt=$1
printf '%s\n' "home=$FM_HOME" "backend=$FM_BACKEND" "session=$HC_SESSION" "terminal=$HC_TERMINAL_ID" "shell_pid=$$" > "$receipt"
printf 'READY_FOR_ENTER\n'
IFS= read -r _
/bin/bash "$2" "$3" "$4" "$5" "$6"
export PS1='❯ '
exec /bin/bash --noprofile --norc -i
INNER
cat > "$TMP_ROOT/worker.sh" <<'INNER'
#!/bin/bash
set -eu
export FM_HC_BIN="$(dirname "$0")/guard-bin/hc"
printf 'WORKER_%s\n' EXECUTED
printf '%s\n' "session=$HC_SESSION" "terminal=$HC_TERMINAL_ID" "shell_pid=$$" > "$1"
export PS1='❯ '
exec /bin/bash --noprofile --norc -i
INNER
cat > "$TMP_ROOT/dispatch.sh" <<'INNER'
#!/bin/bash
set -eu
project=$1
workload=$2
receipt=$3
# No runtime or session override: this process inherits the secondmate's launch.
"$FM_HOME/bin/fm-spawn.sh" shell-worker "$project" "/bin/bash '$workload' '$receipt'" --mode no-mistakes --yolo off
printf 'CAPTAIN_%s\n' DISPATCHED
printf 'done\n' > "$4"
INNER

wait_file() {
  local file=$1 attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [ -s "$file" ] && return 0
    sleep 0.2
  done
  if [ -n "${CAPTAIN_TERM:-}" ]; then
    FM_HC_BIN="$HC_BIN" "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read --lines 100 "$CAPTAIN_TERM" >&2 || true
  fi
  fail "timed out waiting for $file"
}
# The fake transport validates the complete envelope and never executes entrypoint.
export REMOTE_SMOKE_ROOT="$PRIMARY" REMOTE_SMOKE_HOME="$CHILD" REMOTE_SMOKE_TMP="$TMP_ROOT"
cat > "$TMP_ROOT/ssh" <<'SSH'
#!/usr/bin/env python3
import base64, os, sys
args = sys.argv[1:]
while args and args[0] == '-o':
    args = args[2:]
assert len(args) == 7 and args[:4] == ['--', 'fixture-host', 'fm-remote-entrypoint.sh', '1']
root, home = (base64.b64decode(v).decode() for v in args[4:6])
assert root == os.environ['REMOTE_SMOKE_ROOT'] and home == os.environ['REMOTE_SMOKE_HOME']
argv = base64.b64decode(args[6]).decode().split('\0')
assert argv.pop() == '' and argv[0] == 'fm-remote-secondmate-control.sh'
assert argv[1] in ('route', 'capture', 'key', 'send', 'state', 'validate-backend')
if os.path.exists(os.environ['REMOTE_SMOKE_TMP'] + '/offline'):
    sys.exit(255)
env = dict(os.environ, FM_HOME=home, FM_ROOT_OVERRIDE=root, HC_SESSION='fm-remote')
for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
    env.pop(key, None)
os.execve(root + '/bin/' + argv[0], argv, env)
SSH
chmod +x "$TMP_ROOT/ssh"
export FM_SSH_BIN="$TMP_ROOT/ssh"
remote() { FM_HOME="$PRIMARY" "$ROOT/bin/fm-on.sh" captain fm-remote-secondmate-control.sh "$@"; }
remote validate-backend captain hc
mkdir -p "$CHILD/state/parent-route" "$CHILD/data/.parent-route"
FM_HOME="$PRIMARY" FM_ROOT_OVERRIDE="$PRIMARY" FM_BACKEND=hc FM_HC_SPACE=parent-custom \
  FM_STATE_OVERRIDE="$CHILD/state/parent-route" FM_DATA_OVERRIDE="$CHILD/data/.parent-route" \
  "$PRIMARY/bin/fm-spawn.sh" captain "$CHILD" \
  "/bin/bash '$TMP_ROOT/captain.sh' '$TMP_ROOT/captain.env' '$TMP_ROOT/dispatch.sh' '$PROJ' '$TMP_ROOT/worker.sh' '$TMP_ROOT/worker.env' '$TMP_ROOT/dispatch.done'" --secondmate
wait_file "$TMP_ROOT/captain.env"
grep -Fx "home=$CHILD" "$TMP_ROOT/captain.env" || fail 'secondmate home differs'
grep -Fx 'session=fm-remote' "$TMP_ROOT/captain.env" || fail 'logical session differs'
CAPTAIN_TERM=$(sed -n 's/^hc_terminal=//p' "$CHILD/state/parent-route/captain.meta")
for ((attempt=0; attempt<100; attempt++)); do
  screen=$(remote capture captain 100)
  case "$screen" in *READY_FOR_ENTER*) break ;; esac
  sleep 0.2
done
[ "$attempt" -lt 100 ] || fail 'shell did not reach its read'
remote key captain Enter
wait_file "$TMP_ROOT/dispatch.done"
wait_file "$TMP_ROOT/worker.env"
META="$CHILD/state/shell-worker.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
WORKER_TERM=$(sed -n 's/^hc_terminal=//p' "$META")
grep -Fx 'backend=hc' "$META" || fail 'worker runtime differs'
grep -Fx "hc_session=fm-remote" "$META" || fail 'worker session differs'
grep -Fx "session=$HC_TEST_SES" "$TMP_ROOT/worker.env" || fail 'worker command ran in another session'
grep -Fx "terminal=$WORKER_TERM" "$TMP_ROOT/worker.env" || fail 'worker command ran in another terminal'
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"
PARENT_TAG=$(FM_HOME="$PRIMARY" FM_ROOT="$PRIMARY" fm_backend_hometag)
CHILD_TAG=$(FM_HOME="$CHILD" FM_ROOT="$CHILD" fm_backend_hometag)
for terminal in "$CAPTAIN_TERM" "$WORKER_TERM"; do
  receipt="$TMP_ROOT/worker.env"
  [ "$terminal" != "$CAPTAIN_TERM" ] || receipt="$TMP_ROOT/captain.env"
  shell_pid=$(sed -n 's/^shell_pid=//p' "$receipt")
  for ((attempt=0; attempt<100; attempt++)); do
    FM_HC_BIN="$HC_BIN" "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$terminal" --json > "$TMP_ROOT/$terminal.json"
    jq -e --argjson pid "$shell_pid" '.foreground.pid == $pid and .foreground.argv == ["/bin/bash", "--noprofile", "--norc", "-i"]' \
      "$TMP_ROOT/$terminal.json" >/dev/null && break
    sleep 0.2
  done
  [ "$attempt" -lt 100 ] || fail 'native foreground never reached the recorded shell'
done
jq -e --arg owner "$PARENT_TAG" --arg space "fm-$CHILD_TAG" '.labels["firstmate.home"] == $owner and .labels["firstmate.task"] == "fm-captain" and .labels["herdr.space"] == $space' "$TMP_ROOT/$CAPTAIN_TERM.json" >/dev/null || fail 'secondmate labels differ'
jq -e --arg owner "$CHILD_TAG" --arg space "fm-$CHILD_TAG" '.labels["firstmate.home"] == $owner and .labels["firstmate.task"] == "fm-shell-worker" and .labels["herdr.space"] == $space' "$TMP_ROOT/$WORKER_TERM.json" >/dev/null || fail 'worker labels differ'
remote capture captain 100 > "$TMP_ROOT/captain.peek"
FM_HOME="$CHILD" "$CHILD/bin/fm-peek.sh" shell-worker 100 > "$TMP_ROOT/worker.peek"
assert_grep CAPTAIN_DISPATCHED "$TMP_ROOT/captain.peek" 'parent peek missed executed dispatch'
assert_grep WORKER_EXECUTED "$TMP_ROOT/worker.peek" 'child peek missed executed workload'
remote send captain 'remote-smoke durable payload' fire-and-forget
find "$CHILD/state/parent-route/captain.inbox" -name '*.msg' -exec cat {} \; > "$TMP_ROOT/inbox"
assert_grep 'remote-smoke durable payload' "$TMP_ROOT/inbox" 'remote steer was not persisted'
remote route captain > "$TMP_ROOT/route.before"
touch "$TMP_ROOT/offline"
rc=0
remote capture captain 100 > "$TMP_ROOT/offline.out" 2>&1 || rc=$?
[ "$rc" = 255 ] || fail 'transport failure did not propagate'
rm "$TMP_ROOT/offline"
remote route captain > "$TMP_ROOT/route.after"
cmp "$TMP_ROOT/route.before" "$TMP_ROOT/route.after" || fail 'route changed across disconnect'
remote capture captain 100 > "$TMP_ROOT/reconnected"
assert_grep CAPTAIN_DISPATCHED "$TMP_ROOT/reconnected" 'capture failed after reconnect'
for terminal in "$CAPTAIN_TERM" "$WORKER_TERM"; do
  FM_HC_BIN="$HC_BIN" "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$terminal" --json > "$TMP_ROOT/$terminal.after.json"
  jq -s -e '.[0].created_ms != null and .[0].foreground.pid != null and .[0].created_ms == .[1].created_ms and .[0].foreground.pid == .[1].foreground.pid and .[1].state == "live"' \
    "$TMP_ROOT/$terminal.json" "$TMP_ROOT/$terminal.after.json" >/dev/null || {
      cat "$TMP_ROOT/$terminal.json" "$TMP_ROOT/$terminal.after.json" >&2
      fail 'terminal changed across transport interruption'
    }
done
calls_before=$(wc -l < "$TMP_ROOT/hc.calls")
for args in '--session default ls' 'get other/t1' 'server stop'; do
  # shellcheck disable=SC2086 # Deliberately exercise rejected CLI argument vectors.
  if "$FM_HC_BIN" $args >/dev/null 2>&1; then fail "wrapper accepted $args"; fi
done
[ "$(wc -l < "$TMP_ROOT/hc.calls")" = "$calls_before" ] || fail 'rejected calls reached real hc'
printf 'lab=%s secondmate=%s worker=%s space=fm-%s\n' "$HC_TEST_SES" "$CAPTAIN_TERM" "$WORKER_TERM" "$CHILD_TAG"
pass 'fake transport with real hc: routed Enter/capture, child shell execution, labels, durable steer and reconnect'
echo 'Excluded: real SSH/login, remote-entrypoint/job-worker, physical fm-remote session selection, model doorbell/relaunch.'
echo FM_TEST_COMPLETE
