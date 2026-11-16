#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-bootstrap-fleet-backend)
fakebin=$(fm_fakebin "$TMP_ROOT/tools")
fm_fake_exit0 "$fakebin" node gh gh-axi chrome-devtools-axi tasks-axi quota-axi lavish-axi
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_DEPENDENCY_PROBED"
printf '1.46.0\n'
SH
chmod +x "$fakebin/no-mistakes"

for scenario in config environment malformed; do
  home_dir="$TMP_ROOT/$scenario"
  mkdir -p "$home_dir/config" "$home_dir/state" "$home_dir/data" "$home_dir/projects"
  printf 'manual\n' > "$home_dir/config/backlog-backend"
  printf 'hc\n' > "$home_dir/state/fleet-backend"
  requested=''
  case "$scenario" in
    config) printf 'herdr\n' > "$home_dir/config/backend" ;;
    environment) requested=herdr ;;
    malformed) printf 'hc herdr\n' > "$home_dir/state/fleet-backend" ;;
  esac
  if PATH="$fakebin:$PATH" FM_HOME="$home_dir" FM_ROOT_OVERRIDE="$home_dir" \
    FM_BACKEND="$requested" FM_BOOTSTRAP_NETWORK=skip \
    FM_TEST_DEPENDENCY_PROBED="$home_dir/probed" \
    bash "$ROOT/bin/fm-bootstrap.sh" > "$home_dir/out" 2> "$home_dir/err"; then
    fail "bootstrap accepted fleet runtime $scenario failure"
  fi
  assert_contains "$(cat "$home_dir/err")" 'fleet backend' 'bootstrap explains the runtime failure'
  assert_absent "$home_dir/probed" 'bootstrap stops before dependency checks'
  assert_absent "$home_dir/config/startup-memory-budget" 'bootstrap stops before setup mutation'
  pass "bootstrap refuses $scenario runtime errors before dependency checks or setup"
done
