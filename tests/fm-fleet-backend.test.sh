#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-backend)
[ -f "$ROOT/bin/fm-fleet-backend-lib.sh" ] || fail 'fleet backend helper is missing'
# shellcheck source=/dev/null
. "$ROOT/bin/fm-fleet-backend-lib.sh"

new_home() {
  STATE_DIR="$TMP_ROOT/$1/state"
  CONFIG_DIR="$TMP_ROOT/$1/config"
  mkdir -p "$STATE_DIR" "$CONFIG_DIR"
}

refuses() {
  local out
  if out=$("$@" 2>&1); then fail "unexpected success: $*"; fi
  assert_contains "$out" 'fleet backend' 'refusal identifies fleet backend'
}

test_read_only() {
  local home="$TMP_ROOT/read-only"
  bash -c 'STATE="$1/state"; FM_STATE_OVERRIDE=$STATE; . "$2"; fm_fleet_backend_read "$STATE"; fm_fleet_backend_validate "$STATE" "$1/config" hc' \
    _ "$home" "$ROOT/bin/fm-fleet-backend-lib.sh" > "$TMP_ROOT/read.out"
  assert_equals hc "$(cat "$TMP_ROOT/read.out")" 'read and validate return only the selection'
  assert_absent "$home" 'sourcing and validating do not create a home'
  new_home resume
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr >/dev/null
  assert_equals herdr "$(FM_BACKEND=hc HERDR_ENV=0 fm_fleet_backend_read "$STATE_DIR")" 'resume reads recorded selection, not environment'
  pass 'read-only interfaces preserve state and expose the recorded resume runtime'
}

test_binding() {
  local backend before
  for backend in herdr hc; do
    new_home "$backend"
    assert_equals "$(fm_fleet_backend_read "$STATE_DIR")" '' 'new fleet is unbound'
    assert_equals "$(fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" "$backend")" "$backend" 'validation accepts runtime'
    assert_absent "$STATE_DIR/fleet-backend" 'validation does not pin'
    assert_equals "$(fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" "$backend")" "$backend" 'binding accepts runtime'
    before=$(ls -i "$STATE_DIR/fleet-backend")
    fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" "$backend" >/dev/null
    assert_equals "$(ls -i "$STATE_DIR/fleet-backend")" "$before" 'idempotence preserves existing file'
    assert_equals "$(fm_fleet_backend_read "$STATE_DIR")" "$backend" 'read returns durable runtime'
    refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" tmux
    assert_equals "$(cat "$STATE_DIR/fleet-backend")" "$backend" 'conflict never overwrites pin'
  done
  pass 'herdr and hc bind independently and idempotently'
}

test_explicit_conflicts() {
  new_home conflicts
  printf 'hc\n' > "$CONFIG_DIR/backend"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr
  assert_absent "$STATE_DIR/fleet-backend" 'child config conflict cannot pin'
  printf 'herdr\n' > "$CONFIG_DIR/backend"
  FM_BACKEND=hc refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr
  (
    FM_BACKEND=hc
    export -n FM_BACKEND
    refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr
  )
  assert_absent "$STATE_DIR/fleet-backend" 'environment conflict cannot pin'
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr >/dev/null
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" hc
  pass 'child config, environment, and explicit runtime conflicts refuse'
}

test_config_compatibility() {
  new_home config-lines
  printf '\n \t\nh c\nh erdr\n' > "$CONFIG_DIR/backend"
  assert_equals hc "$(fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" hc)" 'first nonempty config line selects runtime'
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" herdr
  printf ' \t\n\n' > "$CONFIG_DIR/backend"
  assert_equals hc "$(fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" hc)" 'blank config is unset'
  pass 'configuration retains first nonempty line semantics'
}

test_existing_records() {
  local record
  for record in 'backend=hc' 'window=fm-old' 'backend=rex' 'window=remote:child\nremote_backend=hc'; do
    new_home records
    printf '%b\n' "$record" > "$STATE_DIR/old.meta"
    refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr
    assert_absent "$STATE_DIR/fleet-backend" 'existing fleet is never silently migrated'
  done
  printf 'backend=herdr\n' > "$STATE_DIR/old.meta"
  printf 'window=remote:child\n' > "$STATE_DIR/child.meta"
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr >/dev/null
  printf 'backend=hc\n' > "$STATE_DIR/old.meta"
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" herdr
  pass 'local and remote records constrain both initial and existing bindings'
}

test_remote_legacy() {
  new_home remote-legacy
  printf 'window=remote:child\nremote_host=host\n' > "$STATE_DIR/child.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  assert_absent "$STATE_DIR/fleet-backend" 'legacy remote herdr cannot migrate to hc'
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr >/dev/null
  printf 'remote_backend=\n' >> "$STATE_DIR/child.meta"
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" herdr
  new_home remote-hc
  printf 'window=remote:child\nremote_host=host\nremote_backend=hc\n' > "$STATE_DIR/child.meta"
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc >/dev/null
  pass 'legacy remote records mean herdr, explicit hc records support hc'
}

test_legacy() {
  new_home legacy
  printf 'backend=rex\n' > "$STATE_DIR/old.meta"
  printf 'tmux\n' > "$CONFIG_DIR/backend"
  assert_equals "$(fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" rex)" rex 'unrelated selection remains unchanged'
  assert_absent "$STATE_DIR/fleet-backend" 'unrelated runtime creates no binding'
  printf '\n hc\nrex\n' > "$CONFIG_DIR/backend"
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" rex
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" rex
  printf 'herdr\n' > "$CONFIG_DIR/backend"
  refuses fm_fleet_backend_validate "$STATE_DIR" "$CONFIG_DIR" tmux
  assert_absent "$STATE_DIR/fleet-backend" 'conflicting legacy selection never pins'
  pass 'unbound unrelated backends retain legacy semantics without overriding managed child config'
}

test_invalid_records() {
  new_home invalid
  printf 'hc\nherdr\n' > "$STATE_DIR/fleet-backend"
  refuses fm_fleet_backend_read "$STATE_DIR"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rm "$STATE_DIR/fleet-backend"
  mkdir "$STATE_DIR/broken.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rmdir "$STATE_DIR/broken.meta"
  ln -s "$TMP_ROOT/missing" "$STATE_DIR/broken.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rm "$STATE_DIR/broken.meta"
  printf 'backend=\n' > "$STATE_DIR/broken.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  printf 'remote_host=host\nbackend=hc\n' > "$STATE_DIR/broken.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  printf '\377\n' > "$STATE_DIR/broken.meta"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rm "$STATE_DIR/broken.meta"
  mkdir "$CONFIG_DIR/backend"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rmdir "$CONFIG_DIR/backend"
  printf 'hc herdr\n' > "$CONFIG_DIR/backend"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rm "$CONFIG_DIR/backend"
  ln -s "$TMP_ROOT/missing" "$STATE_DIR/fleet-backend"
  refuses fm_fleet_backend_read "$STATE_DIR"
  refuses fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc
  rm "$STATE_DIR/fleet-backend"
  assert_absent "$STATE_DIR/fleet-backend" 'record failures cannot default to hc'
  pass 'malformed and unreadable records refuse without a fallback'
}

test_concurrent_bind() {
  local a b ra=0 rb=0 winner
  new_home concurrent
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" herdr > "$TMP_ROOT/a.out" 2> "$TMP_ROOT/a.err" & a=$!
  fm_fleet_backend_bind "$STATE_DIR" "$CONFIG_DIR" hc > "$TMP_ROOT/b.out" 2> "$TMP_ROOT/b.err" & b=$!
  wait "$a" || ra=$?
  wait "$b" || rb=$?
  [ "$((ra + rb))" -gt 0 ] || fail 'conflicting binds both succeeded'
  [ "$ra" -eq 0 ] || [ "$rb" -eq 0 ] || fail 'neither bind succeeded'
  winner=$(cat "$STATE_DIR/fleet-backend")
  assert_equals "$(cat "$TMP_ROOT/a.out" "$TMP_ROOT/b.out")" "$winner" 'only committed selection succeeds'
  pass 'concurrent conflicting binds publish exactly one runtime'
}

test_config_compatibility
test_read_only
test_binding
test_explicit_conflicts
test_existing_records
test_remote_legacy
test_legacy
test_invalid_records
test_concurrent_bind
