#!/usr/bin/env bash
# Native Codex reads must preserve failures and reject unavailable observation.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-codex-native)
python3 "$ROOT/tests/fm-codex-appserver-fixture.py" "$ROOT" "$TMP_ROOT"
