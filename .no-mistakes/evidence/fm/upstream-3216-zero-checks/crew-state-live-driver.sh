#!/usr/bin/env bash
# Disposable driver: runs the REAL bin/fm-crew-state.sh from the gate worktree
# against a throwaway FM_HOME, with the no-mistakes CLI (axi), tmux and forge
# CLIs replaced by the test suite's fake tools so the ci log text is controlled.
set -u
WT=$1 LAB=$2
ROOT=$WT
. "$WT/tests/lib.sh"
eval "$(awk '/^make_fakebin\(\)/{p=1} p{print} p&&/^}/{exit}' "$WT/tests/fm-crew-state.test.sh")"
eval "$(awk '/^run_ci_monitoring\(\)/{p=1} p{print} p&&/^}/{exit}' "$WT/tests/fm-crew-state.test.sh")"
eval "$(awk '/^make_repo_on_branch\(\)/{p=1} p{print} p&&/^}/{exit}' "$WT/tests/fm-crew-state.test.sh")"
fm_git_identity fmtest fmtest@example.invalid

export NM_HOME="$LAB/nm-unused"
export FM_FAKE_BUSY=0 FM_FAKE_TMUX_MISSING=0 FM_FAKE_TMUX_WINDOW_GONE=0 FM_FAKE_TMUX_UNREADABLE=0
export FM_FAKE_HERDR_BUSY=0 FM_FAKE_HERDR_MISSING=0 FM_FAKE_HERDR_READ_FAIL=0 FM_FAKE_HERDR_HUSK=0
export FM_FAKE_HERDR_AGENT_STATUS="" FM_FAKE_HERDR_PROCESS=agent FM_FAKE_HERDR_SHELL_PID=$$
export FM_FAKE_DAEMON_DOWN=0 FM_FAKE_DAEMON_TIMEOUT=0 FM_FAKE_DAEMON_OUTPUT='  ● daemon running (pid 4242)'
export FM_FAKE_PR_STATE=OPEN FM_FAKE_PR_MERGED=false FM_FAKE_PR_READ_FAIL=0

scenario() {  # <name> <flag:on|off> <status-log-line-or-empty> <ci-log-text>
  local name=$1 flag=$2 statusline=$3 cilog=$4 home id branch out
  home="$LAB/home-$name"; id="task-$name"; branch="fm/$id"
  mkdir -p "$home/state" "$home/config"
  make_repo_on_branch "$home/wt" "$branch"
  make_fakebin "$home" >/dev/null
  fm_write_meta "$home/state/$id.meta" "window=fm:fm-$id" "worktree=$home/wt" "kind=ship"
  [ -z "$statusline" ] || printf '%s\n' "$statusline" > "$home/state/$id.status"
  [ "$flag" = on ] && : > "$home/config/ci-no-checks-not-green"
  [ "$flag" = near-miss ] && : > "$home/config/ci-no-checks-not-green-typo"
  export FM_FAKE_AXI_STATUS; FM_FAKE_AXI_STATUS="$(run_ci_monitoring "$branch")"
  export FM_FAKE_CI_LOGS; FM_FAKE_CI_LOGS="$cilog"
  printf '\n===== scenario: %s =====\n' "$name"
  printf 'home: %s\nflag config/ci-no-checks-not-green: %s\n' "$home" "$([ -e "$home/config/ci-no-checks-not-green" ] && echo present || echo absent)"
  printf 'status log: %s\n' "${statusline:-<none>}"
  printf 'axi status (fake):\n%s\n' "$(printf '%s\n' "$FM_FAKE_AXI_STATUS" | grep -E 'status:|ci,')"
  printf 'axi logs --step ci --full (fake):\n%s\n' "$cilog"
  printf -- '--- $ FM_HOME=%s bin/fm-crew-state.sh %s\n' "$home" "$id"
  out=$(cd "$WT" && env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
        PATH="$home/fakebin:$PATH" FM_HOME="$home" bin/fm-crew-state.sh "$id" 2>&1)
  printf '%s\n' "$out"
  printf -- '--- exit=%s\n' "$?"
}

NOCHECKS='no CI checks reported - still monitoring until merged or closed'
PASSED='all CI checks passed - still monitoring until merged or closed'
NOTYET='no CI checks reported yet, waiting for checks to register...'
scenario flag-on-zero-checks on "" "$NOCHECKS"
scenario flag-on-crew-says-green-zero-checks on 'done: PR https://github.com/o/r/pull/2 checks green' "$NOCHECKS"
scenario flag-off-zero-checks-default off "" "$NOCHECKS"
scenario flag-off-crew-says-green-zero-checks off 'done: PR https://github.com/o/r/pull/2 checks green' "$NOCHECKS"
scenario flag-on-real-green on "" "$PASSED"
scenario flag-on-zero-then-green on "" "$(printf '%s\n%s' "$NOCHECKS" "$PASSED")"
scenario flag-on-green-then-zero on "" "$(printf '%s\n%s' "$PASSED" "$NOCHECKS")"
scenario flag-on-not-yet on "" "$NOTYET"
scenario flag-near-miss-name-zero-checks near-miss "" "$NOCHECKS"
