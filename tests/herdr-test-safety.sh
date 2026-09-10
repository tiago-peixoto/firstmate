#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

# herdr_forget_inherited_pane: drop the Herdr PANE identity this test process
# inherited from whatever terminal it was started in.
#
# Herdr injects HERDR_ENV, HERDR_PANE_ID, HERDR_TAB_ID, HERDR_WORKSPACE_ID,
# HERDR_SOCKET_PATH, and HERDR_SESSION into every process it manages a pane for
# (verified 0.7.5 - docs/verification/runtime-backends.md), and a test run from
# inside a Herdr pane inherits all of them. Spawn now treats that pane as the
# authoritative parent to place workers next to, so a leaked identity from the
# developer's own session would follow the test into its isolated lab session
# and be refused there as a cross-session parent - a result that depends on
# where the suite was launched from, not on what it asserts.
#
# Call this before exporting the lab HERDR_SESSION in any suite whose subject is
# the per-home container path. A suite that means to exercise a launcher-bound
# spawn sets HERDR_PANE_ID itself, to a pane it created in its own lab session.
herdr_forget_inherited_pane() {
  unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
}

# herdr_hold_live_foreground: run a long-lived payload in <pane> of <session>
# and wait until pane process-info shows a foreground process group that is
# not the shell. Registration via pane report-agent is not live on its own.
herdr_hold_live_foreground() { # <session> <pane>
  local session=$1 pane=$2 i info shell_pid pgid
  herdr pane run "$pane" "sleep 3600" --session "$session" >/dev/null 2>&1 || return 1
  for i in $(seq 1 50); do
    info=$(herdr pane process-info --pane "$pane" --session "$session" 2>/dev/null || true)
    shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true)
    pgid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null || true)
    if [ -n "$shell_pid" ] && [ -n "$pgid" ] && [ "$shell_pid" != "$pgid" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
