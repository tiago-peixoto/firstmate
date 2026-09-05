#!/usr/bin/env bash
# Native Codex reads must preserve failures and reject unavailable observation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-native)
python3 "$ROOT/tests/fm-codex-appserver-fixture.py" "$ROOT" "$TMP_ROOT"

EXIT_ROOT=$(fm_test_tmproot fm-codex-live-exit)
FAKEBIN=$(fm_fakebin "$EXIT_ROOT")
fm_fake_exit0 "$FAKEBIN" codex
cat > "$FAKEBIN/lab-helper" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  name) printf '%s\n' fm-lab-native-exit-fixture ;;
  provision)
    [ "$2" = fm-lab-native-exit-fixture ]
    printf '%s\n' "$FM_CODEX_NATIVE_LAB" >> "$FM_TEST_CLEANUP_REGISTRY"
    printf '%s\n' "$FM_CODEX_NATIVE_LAB" > "$FM_FAKE_LIVE_LAB_PATH"
    printf 'provision %s\n' "$2"
    ;;
  teardown)
    [ "$2" = fm-lab-native-exit-fixture ]
    printf 'teardown %s\n' "$2"
    exit "$FM_FAKE_LIVE_TEARDOWN_STATUS"
    ;;
  *) exit 97 ;;
esac
SH
cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'guard %s\n' "$*"
exit "$FM_FAKE_LIVE_GUARD_STATUS"
SH
chmod +x "$FAKEBIN/lab-helper" "$FAKEBIN/python3"

for guard_status in 0 23; do
  for teardown_status in 0 29; do
    status=0
    output=$(PATH="$FAKEBIN:$PATH" FM_CODEX_NATIVE_LIVE=1 \
      HERDR_LAB_HELPER="$FAKEBIN/lab-helper" \
      FM_TEST_CLEANUP_REGISTRY="$FM_TEST_CLEANUP_REGISTRY" \
      FM_FAKE_LIVE_LAB_PATH="$EXIT_ROOT/lab-path" \
      FM_FAKE_LIVE_GUARD_STATUS="$guard_status" \
      FM_FAKE_LIVE_TEARDOWN_STATUS="$teardown_status" \
      bash "$ROOT/tests/fm-codex-appserver-live-e2e.test.sh" 2>&1) || status=$?
    expected=$guard_status
    if [ "$guard_status" -eq 0 ] && [ "$teardown_status" -ne 0 ]; then expected=1; fi
    [ "$status" -eq "$expected" ] || fail "guard=$guard_status teardown=$teardown_status returned $status, expected $expected: $output"
    expected_output="provision fm-lab-native-exit-fixture
guard $ROOT/tests/fm-codex-appserver-live.py $ROOT
teardown fm-lab-native-exit-fixture"
    [ "$output" = "$expected_output" ] || fail "live guard did not execute provision, guard and teardown in order: $output"
    lab_path=$(cat "$EXIT_ROOT/lab-path")
    if [ "$teardown_status" -eq 0 ]; then
      assert_absent "$lab_path" "successful teardown left the disposable lab directory"
    else
      assert_present "$lab_path" "failed teardown discarded the disposable lab directory"
    fi
    pass "live guard exit: guard=$guard_status teardown=$teardown_status result=$status"
  done
done
