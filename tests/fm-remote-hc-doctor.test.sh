#!/usr/bin/env bash
# Readiness against a disposable account and protocol fixture, never a real core.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(TMPDIR=/tmp fm_test_tmproot hc-doctor)
HOLDER_PIDS=()
stop_holders() {
  local pid
  for pid in "${HOLDER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap stop_holders EXIT
CASE_N=0
TOOLS="$TMP/tools"
mkdir -p "$TOOLS"
for tool in git jq python3; do ln -s "$(command -v "$tool")" "$TOOLS/$tool"; done
new_case() {
  CASE_N=$((CASE_N + 1))
  CASE_HOME="$TMP/case$CASE_N/home"
  CASE_STATE="$TMP/case$CASE_N/state"
  CASE_BIN="$TMP/case$CASE_N/bin"
  CASE_LAUNCHCTL_LOG="$CASE_STATE/launchctl.log"
  mkdir -p "$CASE_HOME" "$CASE_STATE" "$CASE_BIN"
  : > "$CASE_LAUNCHCTL_LOG"
  printf '#!/bin/sh\nprintf "Linux\\n"\n' > "$CASE_BIN/uname"
  printf '#!/bin/sh\nexit 0\n' > "$CASE_BIN/claude"
  cp "$CASE_BIN/claude" "$CASE_BIN/treehouse"
  [ "${2:-}" != with-herdr ] || cp "$CASE_BIN/claude" "$CASE_BIN/herdr"
  cat > "$CASE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.6\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  chmod +x "$CASE_BIN/"*
}
doctor() {
  DOCTOR_RC=0
  DOCTOR_OUT=$(env -u FM_ROOT_OVERRIDE -u FM_HC_BIN -u XDG_RUNTIME_DIR -u XDG_STATE_HOME \
    HOME="$CASE_HOME" FM_HOME="$CASE_HOME/fm" PATH="$CASE_BIN:$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" \
    FM_REMOTE_JOB_ACTIVE=1 FM_FAKE_STATE="$CASE_STATE" \
    HC_SESSION=foreign HC_SOCKET=/foreign FM_HC_SOCKET=/foreign \
    "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1) || DOCTOR_RC=$?
}

# hc uses its own detached core, never the classic Herdr launch agent.
install_case_hc() {
  cat > "$CASE_BIN/herdr-core" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|%s|%s\n' "${HC_SESSION:-}" "${HC_SOCKET:-}" "$*" >> "$FM_FAKE_STATE/hc.calls"
case "$1" in
  --version) cat "$FM_FAKE_STATE/hc.version" ;;
  connect)
    cat >/dev/null
    printf '{"result":{"generation":%s}}\n' "$(cat "$FM_FAKE_STATE/hc.generation")"
    ;;
  server)
    [ "$2" = status ] || exit 90
    if [ ! -S "$HOME/.local/state/herdr-core/fm-remote/fm-remote.sock" ]; then
      python3 "$FM_FAKE_STATE/hc-listener.py" "$HOME/.local/state/herdr-core/fm-remote/fm-remote.sock" </dev/null >/dev/null 2>&1 &
      echo "$!" > "$FM_FAKE_STATE/hc.pid"
      for ((i=0; i<100; i++)); do
        [ ! -S "$HOME/.local/state/herdr-core/fm-remote/fm-remote.sock" ] || break
        sleep .01
      done
    fi
    echo '{}'
    ;;
  *) exit 91 ;;
esac
SH
  cat > "$CASE_STATE/hc-listener.py" <<'PY'
import os, socket, sys
os.makedirs(os.path.dirname(sys.argv[1]), exist_ok=True)
server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen()
while True:
    connection, _ = server.accept()
    connection.close()
PY
  printf 'hc 0.1.14\n' > "$CASE_STATE/hc.version"
  printf '1\n' > "$CASE_STATE/hc.generation"
  chmod +x "$CASE_BIN/herdr-core"
}

new_case Linux no-herdr
install_case_hc
# Constrain hc to the disposable account regardless of the invoking terminal.
unset FM_HC_BIN FM_HC_SOCKET HC_SOCKET HC_SESSION XDG_RUNTIME_DIR XDG_STATE_HOME
doctor --backend hc
assert_contains "$DOCTOR_OUT" 'required hc=' 'hc must resolve the herdr-core binary'
assert_contains "$DOCTOR_OUT" 'check hc=ok:' 'compatible hc must pass its version gate'
assert_contains "$DOCTOR_OUT" 'check hc-server=fixable:' 'a missing hc core must need repair'
assert_no_grep 'server status' "$CASE_STATE/hc.calls" 'check mode must not autostart hc'
assert_not_contains "$DOCTOR_OUT" 'check herdr-server=' 'hc must not check classic Herdr'
doctor --backend hc --fix
[ ! -f "$CASE_STATE/hc.pid" ] || HOLDER_PIDS+=("$(cat "$CASE_STATE/hc.pid")")
expect_code 0 "$DOCTOR_RC" "hc readiness repair failed: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check hc-server=ok: session fm-remote' 'repair must prove the protocol'
assert_no_grep 'dev.firstmate.herdr' "$CASE_LAUNCHCTL_LOG" 'hc must not install a classic Herdr agent'
assert_grep 'fm-remote||server status' "$CASE_STATE/hc.calls" 'repair must start the dedicated hc session'
assert_no_grep '/foreign' "$CASE_STATE/hc.calls" 'readiness must discard ambient socket overrides'
pass 'hc check is read-only and explicit repair verifies its dedicated core'

printf '2\n' > "$CASE_STATE/hc.generation"
cp "$CASE_STATE/hc.calls" "$CASE_STATE/hc.before"
doctor --backend hc --fix
expect_code 1 "$DOCTOR_RC" 'an incompatible answering hc core must refuse readiness'
assert_contains "$DOCTOR_OUT" 'check hc-server=human:' 'protocol mismatch must require operator action'
[ "$(grep -c 'server status' "$CASE_STATE/hc.calls")" = "$(grep -c 'server status' "$CASE_STATE/hc.before")" ] \
  || fail 'doctor restarted an answering incompatible core'
printf 'hc 0.1.13\n' > "$CASE_STATE/hc.version"
doctor --backend hc
assert_contains "$DOCTOR_OUT" 'check hc=human:' 'old hc must fail version validation'
pass 'hc readiness refuses incompatible protocol and binary without restarting a core'

new_case Linux with-herdr
# An explicitly selected but missing hc must not choose installed classic Herdr.
doctor --backend hc
expect_code 1 "$DOCTOR_RC" 'missing selected hc must refuse readiness'
assert_contains "$DOCTOR_OUT" 'required hc=MISSING' 'selected hc must report the missing binary'
assert_not_contains "$DOCTOR_OUT" 'check herdr-server=' 'selected hc must never fall back to herdr'
pass 'missing selected hc never falls back to classic Herdr'
