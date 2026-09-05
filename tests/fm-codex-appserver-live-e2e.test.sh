#!/usr/bin/env bash
# Opt-in native lifecycle guard; only an isolated named Herdr lab is touched.
set -eu
if [ "${FM_CODEX_NATIVE_LIVE:-0}" != 1 ]; then
  echo 'skip: set FM_CODEX_NATIVE_LIVE=1 for the credentialed Codex native lifecycle guard'
  exit 0
fi
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v codex >/dev/null || { echo 'not ok - Codex is not installed' >&2; exit 1; }
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-"$ROOT/bin/fm-herdr-lab.sh"}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-busy-verdict-unmeasured-at-installed-version)
FM_CODEX_NATIVE_LAB=$(mktemp -d /tmp/fm-native-live-XXXXXXXX)
export HERDR_LAB_HELPER HERDR_LAB_SESSION FM_CODEX_NATIVE_LAB
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" && rm -rf "$FM_CODEX_NATIVE_LAB"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
python3 "$ROOT/tests/fm-codex-appserver-live.py" "$ROOT"
