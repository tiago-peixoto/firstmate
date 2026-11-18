#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-home-seed-backend)
mkdir -p "$TMP_ROOT/code" "$TMP_ROOT/home/config" "$TMP_ROOT/tools"
cp -R "$ROOT/bin" "$TMP_ROOT/code/bin"
# Inject a resolver failure at its public boundary while executing the real seed command.
cat > "$TMP_ROOT/code/bin/fm-backend.sh" <<'STUB'
fm_backend_name() { echo 'error: injected runtime resolution failure' >&2; return 1; }
STUB
cat > "$TMP_ROOT/tools/ssh" <<'STUB'
#!/usr/bin/env bash
: > "$FM_TEST_SSH_CALLED"
exit 99
STUB
chmod +x "$TMP_ROOT/tools/ssh"
if PATH="$TMP_ROOT/tools:$PATH" FM_HOME="$TMP_ROOT/home" FM_ROOT_OVERRIDE="$TMP_ROOT/home" \
  FM_STATE_OVERRIDE="$TMP_ROOT/home/state" FM_DATA_OVERRIDE="$TMP_ROOT/home/data" \
  FM_TEST_SSH_CALLED="$TMP_ROOT/ssh-called" \
  bash "$TMP_ROOT/code/bin/fm-remote-home-seed.sh" child remote-host /remote/code /remote/child --no-projects \
  > "$TMP_ROOT/out" 2> "$TMP_ROOT/err"; then
  fail 'remote seed accepted failed runtime resolution'
fi
assert_contains "$(cat "$TMP_ROOT/err")" 'fleet runtime selection failed' 'remote seed preserves runtime resolution failure'
assert_absent "$TMP_ROOT/ssh-called" 'runtime failure must not reach SSH'
assert_absent "$TMP_ROOT/home/state/.secondmate-registry.lock" 'runtime failure must not lock the registry'
assert_absent "$TMP_ROOT/home/data" 'runtime failure must not publish a route'
pass 'remote seeding refuses resolver failures before route publication or SSH'
