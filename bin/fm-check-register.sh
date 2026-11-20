#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id> [--run-once]
# --run-once then runs the bound bytes once, the way the watcher would (same
# snapshot, bash, FM_CHECK_TIMEOUT bound), prints the check's output and
# `exit: <code>`, and exits with that code, so a broken check shows up now.
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

RUN_ONCE=0
[ "$#" -ne 2 ] || [ "$2" != --run-once ] || RUN_ONCE=1
if [ "$#" -ne $((1 + RUN_ONCE)) ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
[ "$RUN_ONCE" -eq 1 ] || exit 0

trap 'fm_custom_check_snapshot_cleanup' EXIT HUP INT TERM
fm_custom_check_snapshot_prepare "$STATE" "$ID" || { echo "error: custom check snapshot is unavailable" >&2; exit 1; }
LIMIT=${FM_CHECK_TIMEOUT:-30}
RC=0
if command -v timeout >/dev/null 2>&1; then
  timeout "$LIMIT" bash "$FM_CUSTOM_CHECK_SNAPSHOT" || RC=$?
elif command -v gtimeout >/dev/null 2>&1; then
  gtimeout "$LIMIT" bash "$FM_CUSTOM_CHECK_SNAPSHOT" || RC=$?
else
  # The alarm survives exec, so it bounds the check itself.
  perl -e 'alarm shift; exec @ARGV' "$LIMIT" bash "$FM_CUSTOM_CHECK_SNAPSHOT" || RC=$?
fi
printf 'exit: %s\n' "$RC"
exit "$RC"
