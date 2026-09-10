#!/usr/bin/env bash
# Opt-in native lifecycle guard; only an isolated named Herdr lab is touched.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shared gate is the live-harness family's one on/off contract: it is what
# lets FM_LIVE=0 turn every live guard off together, and tests/fm-live-gate.test.sh
# sweeps the whole family for it. lib.sh exports ROOT, so this drops the local
# recomputation, and the trailing tool list replaces the hand-rolled codex check.
fm_live_gate opt-in FM_CODEX_NATIVE_LIVE codex

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-busy-verdict-unmeasured-at-installed-version)
FM_CODEX_NATIVE_LAB=$(mktemp -d /tmp/fm-native-live-XXXXXXXX)
export HERDR_LAB_HELPER HERDR_LAB_SESSION FM_CODEX_NATIVE_LAB
cleanup() {
  local status=$?
  if "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then
    # Removing the scratch directory is not the teardown result. Report it and
    # carry on, so a failed rm never turns a passing run red nor reads as a
    # failed lab teardown.
    rm -rf "$FM_CODEX_NATIVE_LAB" || echo 'warn: disposable lab directory not removed' >&2
  else
    # A failed teardown is a real failed acceptance; keep the lab for evidence.
    [ "$status" -ne 0 ] || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
python3 "$ROOT/tests/fm-codex-appserver-live.py" "$ROOT"
