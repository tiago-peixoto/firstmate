#!/usr/bin/env bash
# Provision an isolated Herdr lab, run the demo, always tear the lab down.
set -eu
ROOT=${1:?repo root}
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name codex-native-demo)
FM_CODEX_NATIVE_LAB=$(mktemp -d /tmp/fm-native-demo-XXXXXXXX)
export HERDR_LAB_HELPER HERDR_LAB_SESSION FM_CODEX_NATIVE_LAB
cleanup() {
  status=$?
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || echo 'warn: lab teardown failed' >&2
  rm -rf "$FM_CODEX_NATIVE_LAB" || echo 'warn: scratch not removed' >&2
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
python3 "$(dirname "$0")/demo.py" "$ROOT"
