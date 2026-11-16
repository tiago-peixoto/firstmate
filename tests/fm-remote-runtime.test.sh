#!/usr/bin/env bash
# Exercise both clean remote environments without starting hc or a service.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(TMPDIR=/tmp fm_test_tmproot remote-runtime)
mkdir -p "$TMP"
TMP=$(cd "$TMP" && pwd -P)
LISTENER_PID=
cleanup() {
  if [ -n "$LISTENER_PID" ]; then kill "$LISTENER_PID"; wait "$LISTENER_PID" 2>/dev/null || true; fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT
REMOTE_ROOT="$TMP/code"
ACCOUNT="$TMP/account"
INSTANCE="$TMP/instance"
RUNTIME="$TMP/runtime"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT" "$INSTANCE" "$RUNTIME"
chmod 700 "$RUNTIME"
RUNTIME_ENV=("XDG_RUNTIME_DIR=$RUNTIME")
if [ "${1:-}" = --account-runtime-lab ]; then
  [ -f /.dockerenv ] && [ "$(id -u)" = 0 ] || fail 'account fixture requires a disposable root container'
  ACCOUNT=$(unset HOME; cd ~ && pwd -P)
  RUNTIME=/run/user/0
  [ ! -e "$RUNTIME" ] || fail 'account fixture refuses an existing runtime directory'
  mkdir -p "$RUNTIME"
  chmod 700 "$RUNTIME"
  RUNTIME_ENV=(-u XDG_RUNTIME_DIR)
fi
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" \
  "$ROOT/bin/fm-remote-job-worker.sh" "$REMOTE_ROOT/bin/"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-remote-doctor.sh" <<'PROBE'
#!/usr/bin/env bash
printf 'runtime=%s\nsocket=%s\n' "${XDG_RUNTIME_DIR:-absent}" "${HC_SOCKET:-absent}"
PROBE
cp "$REMOTE_ROOT/bin/fm-remote-doctor.sh" "$REMOTE_ROOT/bin/fm-probe.sh"
chmod +x "$REMOTE_ROOT/bin/"*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add .
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
out=$(env "${RUNTIME_ENV[@]}" HC_SOCKET=/foreign \
  bash "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" 1 "$(b64 "$REMOTE_ROOT")" \
  "$(b64 "$INSTANCE")" "$(printf 'fm-remote-doctor.sh\0' | base64 | tr -d '\n')")
assert_contains "$out" "runtime=$RUNTIME" 'bootstrap discarded the private runtime directory'
assert_contains "$out" 'socket=absent' 'bootstrap forwarded an ambient hc socket'
pass 'doctor bootstrap retains the validated runtime directory only'

# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
export FM_REMOTE_JOB_STATE_ROOT="$TMP/jobs" FM_ROOT_OVERRIDE="$REMOTE_ROOT"
fm_remote_job_stage "$ACCOUNT" "$REMOTE_ROOT" "$INSTANCE" fm-probe.sh </dev/null >/dev/null
env "${RUNTIME_ENV[@]}" HOME="$ACCOUNT" HC_SOCKET=/foreign \
  bash "$REMOTE_ROOT/bin/fm-remote-job-worker.sh" --lane "$FM_REMOTE_JOB_ID"
out=$(cat "$FM_REMOTE_JOB_JOBS/$FM_REMOTE_JOB_ID/stdout")
assert_contains "$out" "runtime=$RUNTIME" 'job worker discarded the private runtime directory'
assert_contains "$out" 'socket=absent' 'job worker forwarded an ambient hc socket'
pass 'queued commands share the bootstrap runtime directory'

# Invalid explicit directories must not silently select another account socket.
chmod 755 "$RUNTIME"
if XDG_RUNTIME_DIR="$RUNTIME" fm_remote_job_runtime_dir "$ACCOUNT" >/dev/null 2>&1; then
  fail 'world-accessible runtime directory was accepted'
fi
chmod 700 "$RUNTIME"
ln -s "$RUNTIME" "$TMP/runtime-link"
if XDG_RUNTIME_DIR="$TMP/runtime-link" fm_remote_job_runtime_dir "$ACCOUNT" >/dev/null 2>&1; then
  fail 'symlink runtime directory was accepted'
fi
if XDG_RUNTIME_DIR=relative fm_remote_job_runtime_dir "$ACCOUNT" >/dev/null 2>&1; then
  fail 'relative runtime directory was accepted'
fi
if XDG_RUNTIME_DIR="$TMP/missing" fm_remote_job_runtime_dir "$ACCOUNT" >/dev/null 2>&1; then
  fail 'missing explicit runtime silently fell back'
fi
out=$(XDG_RUNTIME_DIR='' fm_remote_job_runtime_dir "$TMP/account")
[ -z "$out" ] || fail 'scratch HOME discovered the account runtime directory'
pass 'unsafe runtime directories refuse and scratch HOME stays isolated'

if [ "${1:-}" != --account-runtime-lab ]; then
  printf 'note: run --account-runtime-lab in a disposable Linux container for absent-variable account discovery and ownership checks\n'
  exit 0
fi
chown 65534 "$RUNTIME"
if XDG_RUNTIME_DIR='' fm_remote_job_runtime_dir "$ACCOUNT" >/dev/null 2>&1; then
  fail 'another account runtime directory was accepted'
fi
chown 0 "$RUNTIME"
pass 'discovered runtime directory must belong to the executing account'

cp "$ROOT/bin/fm-remote-doctor.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
  "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$ROOT/bin/fm-backend.sh" \
  "$ROOT/bin/fm-fleet-backend-lib.sh" "$REMOTE_ROOT/bin/"
for library in fm-backend-hometag-lib fm-composer-lib fm-agent-process-lib fm-session-lock-lib fm-gemini-lib fm-hermes-process-lib fm-cursor-lib; do
  cp "$ROOT/bin/$library.sh" "$REMOTE_ROOT/bin/"
done
mkdir -p "$REMOTE_ROOT/bin/backends"
cp "$ROOT/bin/backends/hc.sh" "$REMOTE_ROOT/bin/backends/"
cat > "$REMOTE_ROOT/bin/herdr-core" <<'HC'
#!/usr/bin/env bash
set -eu
fixture=$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd -P)
printf '%s\n' "$*" >> "$fixture/hc.calls"
case "$1" in
  --version) echo 'hc 0.1.20' ;;
  connect)
    cat >/dev/null
    python3 - <<'PYTHON'
import os, socket
runtime = os.environ.get('XDG_RUNTIME_DIR')
path = runtime + '/herdr-core/fm-remote.sock' if runtime else os.environ['HOME'] + '/.local/state/herdr-core/fm-remote/fm-remote.sock'
with socket.socket(socket.AF_UNIX) as connection:
    connection.connect(path)
print('{"result":{"generation":1}}')
PYTHON
    ;;
  *) exit 91 ;;
esac
HC
chmod +x "$REMOTE_ROOT/bin/herdr-core"
cat > "$TMP/listen.py" <<'PYTHON'
import os, socket, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
with socket.socket(socket.AF_UNIX) as server:
    server.bind(sys.argv[1])
    server.listen()
    while True:
        connection, _ = server.accept()
        connection.close()
PYTHON
check_listening_socket() {
  local path=$1 out rc=0
  python3 "$TMP/listen.py" "$path" &
  LISTENER_PID=$!
  for ((i=0; i<100; i++)); do
    [ ! -S "$path" ] || break
    sleep .01
  done
  [ -S "$path" ] || fail 'fixture listener did not bind'
  out=$(env -u XDG_RUNTIME_DIR bash "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
    1 "$(b64 "$REMOTE_ROOT")" "$(b64 "$INSTANCE")" \
    "$(printf 'fm-remote-doctor.sh\0--backend\0hc\0' | base64 | tr -d '\n')" 2>&1) || rc=$?
  [ "$rc" -le 1 ] || fail "doctor could not run: $out"
  assert_contains "$out" 'check hc-server=ok: session fm-remote' "doctor missed listener at $path"
  assert_no_grep '^serve' "$TMP/hc.calls" 'check mode started hc'
  kill "$LISTENER_PID"
  wait "$LISTENER_PID" 2>/dev/null || true
  LISTENER_PID=
  rm "$path"
}
check_listening_socket "$RUNTIME/herdr-core/fm-remote.sock"
pass 'absent XDG_RUNTIME_DIR: real doctor finds account listener without starting hc'
rmdir "$RUNTIME/herdr-core" "$RUNTIME"
out=$(XDG_RUNTIME_DIR='' fm_remote_job_runtime_dir "$ACCOUNT")
[ -z "$out" ] || fail 'absent account runtime directory did not select state fallback'
check_listening_socket "$ACCOUNT/.local/state/herdr-core/fm-remote/fm-remote.sock"
pass 'absent account runtime directory: real doctor finds state listener without starting hc'
