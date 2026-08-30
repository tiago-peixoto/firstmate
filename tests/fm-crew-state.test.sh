#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-state.sh - the deterministic crew-current-state
# helper.
#
# The status file (state/<id>.status) is a best-effort append-only EVENT LOG, so
# `tail -1` of it reports the last event, not the current state. fm-crew-state
# reads the AUTHORITATIVE source (a matching no-mistakes run-step, else the
# semantic busy-state contract) and reconciles the possibly-stale log against it. These
# cases pin every branch of that logic, hermetically, over real throwaway git
# repos with a fake `no-mistakes` (run-step source) and a fake `tmux` (pane
# source):
#   (a) active run-step is authoritative                          -> run-step
#   (b) needs-decision/blocked log + resumed run = SUPERSEDED     -> run-step
#   (c) genuine parked run + needs-decision log = NOT superseded  -> run-step
#   (d) terminal run-step (passed/failed) is authoritative        -> run-step
#   (e) cross-branch attribution: this branch's own run found via list lookup
#   (f) no run + semantic busy                                    -> pane
#   (g) no run + semantic idle falls to the status-log verb       -> status-log
#   (h) dead pane: no run -> unknown/none; with a run -> run-step (not the shell)
#   (i) kind=scout skips the run lookup                           -> pane/status-log
#   (j) torn-down worktree / missing meta                         -> unknown/none
#   (k) crew_is_provably_working end-to-end over the REAL helper (not a canned
#       fake fm-crew-state.sh verdict): cross-branch attribution via the runs
#       list -> absorbed; genuinely no run anywhere + idle pane -> surfaced.
#       This is the direct regression pair for the 2026-07-02 herdr incident,
#       proving the watcher's own absorb-only-when-provably-working predicate
#       benefits from the fix in both directions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state)
fm_git_identity fmtest fmtest@example.invalid

# A real git repo checked out on <branch>, so the helper's branch attribution
# (git symbolic-ref) resolves like it would for a live crew worktree.
make_repo_on_branch() {  # <dir> <branch>
  local dir=$1 branch=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" checkout -q -b "$branch"
  # Real worktree HEAD for run head-binding (fixtures read FM_FAKE_RUN_HEAD).
  FM_FAKE_RUN_HEAD=$(git -C "$dir" rev-parse HEAD)
  FM_FAKE_PR_HEAD=$FM_FAKE_RUN_HEAD
  export FM_FAKE_RUN_HEAD FM_FAKE_PR_HEAD
}

# A fakebin with a fake `no-mistakes` (serves the env-driven run output) and a
# fake `tmux` (serves a busy or idle pane). The fake no-mistakes mirrors the real
# command surface the helper uses: `axi status`, `axi status --run <id>` (the
# `axi` surface - no runs-listing subcommand exists under it, verified against
# the real CLI), and the actual top-level run-listing command, `no-mistakes
# runs --limit N`, which is plain text - no run id, no quoting - serving
# FM_FAKE_RUNS_LIST verbatim.
make_fakebin() {  # <dir> -> echoes fakebin path
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      status)
        shift
        if [ "${1:-}" = --run ]; then printf '%s\n' "${FM_FAKE_AXI_STATUS_RUN:-}"
        else printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"; fi ;;
      logs)
        printf '%s\n' "${FM_FAKE_CI_LOGS:-}" ;;
    esac
    ;;
  runs)
    if [ "${FM_FAKE_RUNS_EMPTY:-0}" = 1 ]; then
      :
    elif [ -n "${FM_FAKE_RUNS_LIST:-}" ]; then
      printf '%s\n' "$FM_FAKE_RUNS_LIST"
    else
      branch=$(printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" | sed -n 's/^[[:space:]]*branch:[[:space:]]*//p' | head -1)
      head_sha=$(printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" | sed -n 's/^[[:space:]]*head:[[:space:]]*"\{0,1\}\([^"[:space:]]*\).*/\1/p' | head -1)
      outcome=$(printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" | sed -n 's/^[[:space:]]*outcome:[[:space:]]*//p' | head -1)
      run_status=$(printf '%s\n' "${FM_FAKE_AXI_STATUS:-}" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)
      case "$outcome" in
        passed) run_status=completed ;;
        checks-passed) run_status=running ;;
        failed|cancelled) run_status=$outcome ;;
        *)
          case "$run_status" in ci|fixing) run_status=running ;; esac
          ;;
      esac
      if [ -n "$branch" ] && [ -n "$head_sha" ] && [ -n "$run_status" ]; then
        printf '%-12s %s %s  %s\n' "$run_status" "$branch" "${head_sha:0:8}" "$(date '+%Y-%m-%d %H:%M')"
      fi
    fi ;;
esac
exit 0
SH
  # Fake `gh`, serving only the two read-only calls fm-crew-state may make when
  # a ci-step marker claims a state that would end the wait: the PR's head sha,
  # and that head's check suites. FM_FAKE_CHECK_SUITES is the --jq projection
  # the helper asks for - total_count on the first line, then one
  # "status|conclusion|latest_check_runs_count" row per suite - so a case can
  # reproduce a real forge answer verbatim. FM_FAKE_GH_MISSING=1 removes gh
  # FM_FAKE_GH_FAILS=1 keeps gh present but failing; run_crew_state_without_gh
  # covers the other half, a host with no gh installed at all.
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_FAKE_GH_FAILS:-0}" = 1 ] && exit 1
[ "${1:-}" = api ] || exit 1
case "$2" in
  */check-suites*)
    suites=${FM_FAKE_CHECK_SUITES:-}
    case " $* " in
      *" --paginate "*)
        [ -z "${FM_FAKE_CHECK_SUITES_ALL:-}" ] || suites=$FM_FAKE_CHECK_SUITES_ALL
        printf '%s\n' "$suites" | awk 'NR == 1 { print "total|" $0; next } { print "suite|" $0 }'
        ;;
      *)
        [ -z "${FM_FAKE_CHECK_SUITES_PAGE_1:-}" ] || suites=$FM_FAKE_CHECK_SUITES_PAGE_1
        printf '%s\n' "$suites"
        ;;
    esac ;;
  */pulls/*)      printf '%s\n' "${FM_FAKE_PR_HEAD:-deadbee0deadbee0deadbee0deadbee0deadbee0}" ;;
  *)              exit 1 ;;
esac
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    printf '%%1\n' ;;
  capture-pane)
    [ "${FM_FAKE_TMUX_MISSING:-0}" = 1 ] && exit 1
    if [ "${FM_FAKE_BUSY:-0}" = 1 ]; then printf 'work in progress\n%s\n' "${FM_FAKE_BUSY_TEXT:-esc to interrupt}"
    else printf 'all quiet\n> \n'; fi ;;
esac
exit 0
SH
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    [ "${2:-}" = --json ] && {
      printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
      exit 0
    } ;;
  server)
    exit 0 ;;
  pane)
    case "${2:-}" in
      read)
        [ "${FM_FAKE_HERDR_MISSING:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_HERDR_BUSY:-0}" = 1 ]; then printf 'work in progress\nesc to interrupt\n'
        else printf 'all quiet\n> \n'; fi
        exit 0 ;;
    esac ;;
  agent)
    case "${2:-}" in
      get)
        [ -n "${FM_FAKE_HERDR_AGENT_STATUS:-}" ] || exit 1
        printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$FM_FAKE_HERDR_AGENT_STATUS"
        exit 0 ;;
    esac ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/herdr" "$fb/gh"
  printf '%s\n' "$fb"
}

make_no_timeout_toolbin() {  # <dir> -> echoes toolbin path
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash git grep sed head cut tail dirname perl date; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

# Run the helper for one case dir. FM_FAKE_* env (run output, busy flag) are read
# from the caller's environment by the fakes above.
run_crew_state() {  # <case-dir> <id>
  if [ -f "$1/state/$2.meta" ] \
    && [ "${FM_FAKE_DISABLE_AUTO_INCAR:-0}" != 1 ] \
    && ! grep -q '^spawn_gen=' "$1/state/$2.meta"; then
    printf 'spawn_gen=s1.1.1\n' >> "$1/state/$2.meta"
  fi
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

# Same, on a host with no gh at all. The PATH is the fakebin plus a minimal
# toolbin, so `command -v gh` genuinely fails instead of falling through to a
# real gh - which would make the case both non-hermetic and a live network call.
run_crew_state_without_gh() {  # <case-dir> <id>
  local toolbin
  toolbin=$(make_no_timeout_toolbin "$1")
  rm -f "$1/fakebin/gh"
  if [ -f "$1/state/$2.meta" ] \
    && [ "${FM_FAKE_DISABLE_AUTO_INCAR:-0}" != 1 ] \
    && ! grep -q '^spawn_gen=' "$1/state/$2.meta"; then
    printf 'spawn_gen=s1.1.1\n' >> "$1/state/$2.meta"
  fi
  PATH="$1/fakebin:$toolbin" FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

new_case() {  # <name> -> echoes case dir with an empty state/
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s\n' "$d"
}

arm_idle_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}

arm_busy_record() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
}

# Clear the fake-driver vars and (re-)mark them exported, so the per-test plain
# assignments below stay exported into the fakes without an `export VAR=$(...)`
# command-substitution assignment (SC2155).
reset_fakes() {
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_AXI_STATUS_RUN=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_RUNS_EMPTY=0
  FM_FAKE_DISABLE_AUTO_INCAR=0
  FM_FAKE_BUSY=0
  FM_FAKE_BUSY_TEXT=
  FM_FAKE_TMUX_MISSING=0
  FM_FAKE_HERDR_BUSY=0
  FM_FAKE_HERDR_MISSING=0
  FM_FAKE_HERDR_AGENT_STATUS=""
  FM_FAKE_CI_LOGS=""
  FM_FAKE_CHECK_SUITES=""
  FM_FAKE_CHECK_SUITES_PAGE_1=""
  FM_FAKE_CHECK_SUITES_ALL=""
  FM_FAKE_PR_HEAD=""
  FM_FAKE_GH_FAILS=0
  export FM_FAKE_AXI_STATUS FM_FAKE_AXI_STATUS_RUN FM_FAKE_RUNS_LIST FM_FAKE_RUNS_EMPTY FM_FAKE_DISABLE_AUTO_INCAR
  export FM_FAKE_BUSY FM_FAKE_BUSY_TEXT FM_FAKE_TMUX_MISSING
  export FM_FAKE_HERDR_BUSY FM_FAKE_HERDR_MISSING FM_FAKE_HERDR_AGENT_STATUS FM_FAKE_CI_LOGS
  export FM_FAKE_CHECK_SUITES FM_FAKE_CHECK_SUITES_PAGE_1 FM_FAKE_CHECK_SUITES_ALL
  export FM_FAKE_PR_HEAD FM_FAKE_GH_FAILS
}

# The three forge answers this reader has to tell apart, each recorded from a
# real head (see the check-suite comments in bin/fm-crew-state.sh).
suites_none()  { printf '0\n'; }
suites_gated() { printf '2\ncompleted|action_required|0\ncompleted|action_required|0\n'; }
suites_green() { printf '2\ncompleted|success|12\ncompleted|success|1\n'; }

# --- run-object fixtures (TOON, as `no-mistakes axi status` emits) -----------

run_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
  steps[2]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,running,0,0
EOF
}

run_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
EOF
}

run_top_level_ci() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: ci
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
EOF
}

run_parked() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[2]{id,severity,file,line,action,description}:
    r1,warning,a.go,,auto-fix,ignored error
    r2,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_scalar_gate_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate: review
EOF
}

run_parked_in_gate_block() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings[1]{id,severity,file,line,action,description}:
    r1,error,b.go,,ask-user,changes product behavior
gate:
  step: review
  status: fix_review
steps[3]{step,status,findings,duration_ms}:
  intent,completed,0,0
  review,fix_review,1,0
  test,pending,0,0
EOF
}

run_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
outcome: passed
EOF
}

run_checks_passed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    pr,completed,0,0
    ci,running,0,0
outcome: checks-passed
EOF
}

run_passed_pr_published_ci_skipped() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/1"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    push,completed,0,0
    pr,completed,0,0
    ci,skipped,0,0
outcome: passed
EOF
}

# A run that finished with its publishing steps deliberately skipped: no push,
# no pr, no ci, and no pr field at all. Real shape, from run
# 01M0G0G71F75XY782REH7Y3KRZ, which the reader once described as "PR
# merged/closed" though no pull request had ever been opened for that branch.
run_passed_publish_skipped() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  findings: none
  steps[9]{step,status,findings,duration_ms}:
    intent,completed,0,0
    rebase,completed,0,4133
    review,completed,0,692929
    test,completed,0,784322
    document,completed,0,250475
    lint,completed,0,11440
    push,skipped,0,0
    pr,skipped,0,0
    ci,skipped,0,0
outcome: passed
EOF
}

run_failed() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: completed
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: ""
  findings: none
outcome: failed
EOF
}

run_ci_monitoring() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: running
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_fixing_ci_running() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}

run_ci_fixing() {  # <branch>
  cat <<EOF
run:
  id: "01RUN"
  branch: $1
  status: fixing
  head: "${FM_FAKE_RUN_HEAD:-abc1234}"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,fixing,0,0
EOF
}

# ---------------------------------------------------------------------------
# (a) active run-step is authoritative
test_active_run_is_authoritative() {
  reset_fakes
  local d; d=$(new_case active)
  make_repo_on_branch "$d/wt" fm/feat-a
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-a.meta" "window=fm:fm-feat-a" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-a)"
  local out; out=$(run_crew_state "$d" feat-a)
  assert_contains "$out" "state: working" "active run -> working"
  assert_contains "$out" "source: run-step" "active run -> run-step source"
  assert_contains "$out" "validating (running)" "active run reports the step"
  pass "active run-step is authoritative"
}

# (b) needs-decision log + a resumed (running/fixing) run = SUPERSEDED
test_stale_needs_decision_superseded() {
  reset_fakes
  local d; d=$(new_case superseded)
  make_repo_on_branch "$d/wt" fm/feat-b
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-b.meta" "window=fm:fm-feat-b" "worktree=$d/wt" "kind=ship"
  printf 'working: started\nneeds-decision: pick A or B\n' > "$d/state/feat-b.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-b)"
  local out; out=$(run_crew_state "$d" feat-b)
  assert_contains "$out" "state: working" "resumed run -> working despite needs-decision log"
  assert_contains "$out" "source: run-step" "resumed run -> run-step source"
  assert_contains "$out" "superseded" "stale needs-decision log flagged superseded"
  pass "stale needs-decision over active run is superseded"
}

# blocked log + a resumed run is also superseded
test_stale_blocked_superseded() {
  reset_fakes
  local d; d=$(new_case superseded-blocked)
  make_repo_on_branch "$d/wt" fm/feat-bb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-bb.meta" "window=fm:fm-feat-bb" "worktree=$d/wt" "kind=ship"
  printf 'blocked: waiting on review answer\n' > "$d/state/feat-bb.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-bb)"
  local out; out=$(run_crew_state "$d" feat-bb)
  assert_contains "$out" "state: working" "resumed run -> working despite blocked log"
  assert_contains "$out" "superseded" "stale blocked log flagged superseded"
  pass "stale blocked over active run is superseded"
}

# (c) genuine parked run + needs-decision log AGREE -> parked, NOT superseded
test_genuine_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked)
  make_repo_on_branch "$d/wt" fm/feat-c
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-c.meta" "window=fm:fm-feat-c" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-c.status"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-c)"
  local out; out=$(run_crew_state "$d" feat-c)
  assert_contains "$out" "state: parked" "genuine parked run -> parked"
  assert_contains "$out" "source: run-step" "parked -> run-step source"
  assert_contains "$out" "2 finding(s)" "parked includes gate finding count"
  assert_contains "$out" "ask-user" "parked surfaces ask-user finding"
  assert_not_contains "$out" "superseded" "agreeing parked+needs-decision not flagged stale"
  pass "genuine parked run is not flagged superseded"
}

test_scalar_gate_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-scalar-gate)
  make_repo_on_branch "$d/wt" fm/feat-cs
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cs.meta" "window=fm:fm-feat-cs" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cs.status"
  FM_FAKE_AXI_STATUS="$(run_parked_scalar_gate_running fm/feat-cs)"
  local out; out=$(run_crew_state "$d" feat-cs)
  assert_contains "$out" "state: parked" "scalar gate wait -> parked"
  assert_contains "$out" "source: run-step" "scalar gate wait -> run-step source"
  assert_contains "$out" "parked at review" "scalar gate wait names the gate"
  assert_contains "$out" "1 finding(s)" "scalar gate wait includes finding count"
  assert_not_contains "$out" "superseded" "scalar gate wait not flagged stale"
  pass "scalar gate parked run is not flagged superseded"
}

test_gate_block_parked_not_superseded() {
  reset_fakes
  local d; d=$(new_case parked-gate-block)
  make_repo_on_branch "$d/wt" fm/feat-cb
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cb.meta" "window=fm:fm-feat-cb" "worktree=$d/wt" "kind=ship"
  printf 'needs-decision: review gate\n' > "$d/state/feat-cb.status"
  FM_FAKE_AXI_STATUS="$(run_parked_in_gate_block fm/feat-cb)"
  local out; out=$(run_crew_state "$d" feat-cb)
  assert_contains "$out" "state: parked" "gate block wait -> parked"
  assert_contains "$out" "source: run-step" "gate block wait -> run-step source"
  assert_contains "$out" "parked at review" "gate block wait names the gate"
  assert_contains "$out" "1 finding(s)" "gate block wait includes finding count"
  assert_not_contains "$out" "superseded" "gate block wait not flagged stale"
  pass "gate block parked run is not flagged superseded"
}

test_ci_ready_done_log_beats_monitoring_run() {
  reset_fakes
  local d; d=$(new_case ci-ready)
  make_repo_on_branch "$d/wt" fm/feat-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ci.meta" "window=fm:fm-feat-ci" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-ci.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ci)"
  FM_FAKE_CHECK_SUITES=$(suites_green)
  local out; out=$(run_crew_state "$d" feat-ci)
  assert_contains "$out" "state: done" "ci-ready status log -> done"
  assert_contains "$out" "source: status-log" "ci-ready state comes from the status log"
  assert_contains "$out" "checks green" "ci-ready detail preserves the report"
  assert_not_contains "$out" "state: working" "ci-ready is not hidden by monitoring run"
  pass "ci-ready status log beats monitoring run"
}

# Regression for the PR #252 incident: the crew's own status log never got a
# "done: ... checks green" line (log_reports_ci_ready above does not apply),
# but the ci step's log tail shows CI is actually green and only waiting on
# merge/close. fm-crew-state must surface this as done, not "validating
# (running)", so a green PR is never silently absorbed as still-in-progress.
test_ci_monitoring_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case ci-green)
  make_repo_on_branch "$d/wt" fm/feat-cigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigreen.meta" "window=fm:fm-feat-cigreen" "worktree=$d/wt" "kind=ship"
  # No status-log line at all: the crew never reported its own checks-green line.
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigreen)"
  FM_FAKE_CHECK_SUITES=$(suites_green)
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
CI checks running, waiting for results...
all CI checks passed - still monitoring until merged or closed
EOF
)
  local out; out=$(run_crew_state "$d" feat-cigreen)
  assert_contains "$out" "state: done" "green ci-monitor run -> done"
  assert_contains "$out" "source: run-step" "green ci-monitor -> run-step source"
  assert_contains "$out" "checks green" "green ci-monitor detail mentions checks green"
  assert_not_contains "$out" "state: working" "green ci-monitor must not read as still validating"
  pass "ci-monitoring run with checks already green surfaces done"
}

test_top_level_ci_checks_green_surfaces_done() {
  reset_fakes
  local d; d=$(new_case top-level-ci-green)
  make_repo_on_branch "$d/wt" fm/feat-topcigreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topcigreen.meta" "window=fm:fm-feat-topcigreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_top_level_ci fm/feat-topcigreen)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  FM_FAKE_CHECK_SUITES=$(suites_green)
  local out; out=$(run_crew_state "$d" feat-topcigreen)
  assert_contains "$out" "state: done" "top-level ci with green log -> done"
  assert_contains "$out" "source: run-step" "top-level ci green -> run-step source"
  assert_contains "$out" "checks green" "top-level ci green detail mentions checks green"
  assert_not_contains "$out" "state: working" "top-level ci green must not stay working"
  pass "top-level ci status uses ci log green marker"
}

# The 2026-08 false-green regression. "no CI checks reported - still monitoring
# until merged or closed" used to map to green alongside the genuine "all CI
# checks passed", while the near-identical "...reported yet" mapped to
# not-ready. Real ci logs show the two spellings interleave inside one run and
# state the same fact - this poll saw zero checks - so they must never give
# opposite verdicts again. Each case below drives the SAME marker and varies
# only what the forge says about the head, which is where the answer lives.
#
# Reproduced live on 2026-08-30 against kunchenguid/firstmate PR 3244 (head
# 4812b9b0: 0 check runs, two suites at action_required): before the fix the
# reader said "done - checks green: PR ready for review".
test_no_checks_marker_awaiting_approval_is_not_green() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-gated)
  make_repo_on_branch "$d/wt" fm/feat-cigated
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cigated.meta" "window=fm:fm-feat-cigated" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cigated)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_CHECK_SUITES=$(suites_gated)
  local out; out=$(run_crew_state "$d" feat-cigated)
  assert_contains "$out" "state: working" "approval-gated head -> still working"
  assert_not_contains "$out" "state: done" "approval-gated head must never read done"
  assert_not_contains "$out" "checks green" "approval-gated head must never read checks green"
  assert_contains "$out" "awaiting maintainer approval" "detail names why nothing has run"
  pass "no-checks marker with approval-gated workflows is not green"
}

# The heart of the defect: the two near-identical spellings gave OPPOSITE
# verdicts. This drives both through the same forge state and asserts they
# agree, so a future edit cannot split them again. It is deliberately an
# equality assertion rather than two separate expectations - the old mapping
# satisfied "the yet spelling is not green" perfectly well while still
# contradicting its twin.
test_both_no_checks_spellings_agree() {
  reset_fakes
  local d spelling out first="" suites
  suites=$(suites_gated)
  local i=0
  for spelling in \
    "no CI checks reported - still monitoring until merged or closed" \
    "no CI checks reported yet, waiting for checks to register..."; do
    i=$((i + 1))
    reset_fakes
    d=$(new_case "ci-nochecks-agree-$i")
    make_repo_on_branch "$d/wt" "fm/feat-agree$i"
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/feat-agree$i.meta" "window=fm:fm-feat-agree$i" "worktree=$d/wt" "kind=ship"
    FM_FAKE_AXI_STATUS="$(run_ci_monitoring "fm/feat-agree$i")"
    FM_FAKE_CI_LOGS="$spelling"
    FM_FAKE_CHECK_SUITES="$suites"
    out=$(run_crew_state "$d" "feat-agree$i")
    out=${out%% · source*}
    if [ -z "$first" ]; then
      first=$out
    elif [ "$out" != "$first" ]; then
      fail "the two no-checks spellings disagree: '$first' vs '$out'"
    fi
    assert_not_contains "$out" "done" "a zero-checks reading is never done here"
  done
  assert_contains "$first" "state: working" "and the verdict they agree on is not-ready"
  pass "both no-checks spellings give the same verdict"
}

# A PR with no CI at all is a different fact from one whose CI is not permitted
# to start: nothing can ever arrive, so the wait is over - but the change is
# still unverified, and the detail has to say so instead of claiming green.
# Recorded from PR 2674 head 3d398129, the head of the 2026-08-20 false-green.
test_no_checks_marker_no_ci_configured_reports_unverified() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-noci)
  make_repo_on_branch "$d/wt" fm/feat-cinoci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinoci.meta" "window=fm:fm-feat-cinoci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinoci)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_CHECK_SUITES=$(suites_none)
  local out; out=$(run_crew_state "$d" feat-cinoci)
  assert_contains "$out" "state: done" "a PR nothing will ever check is not still validating"
  assert_contains "$out" "nothing verified this change" "detail states the change is unverified"
  assert_not_contains "$out" "checks green" "no CI configured must never read as checks green"
  pass "no-checks marker with no CI configured reports the change unverified"
}

# The forge outranks the log marker in the other direction too: checks that
# registered after the marker was written make this green.
test_no_checks_marker_with_passing_checks_is_green() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-passed)
  make_repo_on_branch "$d/wt" fm/feat-cinowgreen
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinowgreen.meta" "window=fm:fm-feat-cinowgreen" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinowgreen)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_CHECK_SUITES=$(suites_green)
  local out; out=$(run_crew_state "$d" feat-cinowgreen)
  assert_contains "$out" "state: done" "checks that arrived after the marker -> done"
  assert_contains "$out" "checks green" "and they are reported as green"
  pass "no-checks marker is overruled by checks the forge reports as passed"
}

# The ambiguous middle: the marker says nothing ran and the forge cannot be
# asked. "We saw nothing" is not evidence of a pass, so this stays not-ready.
test_no_checks_marker_unreadable_forge_is_not_green() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-noforge)
  make_repo_on_branch "$d/wt" fm/feat-cinoforge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinoforge.meta" "window=fm:fm-feat-cinoforge" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinoforge)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  local out; out=$(run_crew_state_without_gh "$d" feat-cinoforge)
  assert_contains "$out" "state: working" "unreachable forge keeps a no-checks reading not-ready"
  assert_not_contains "$out" "checks green" "unreachable forge never invents a green"
  assert_contains "$out" "forge could not be reached" "detail says the forge could not be asked"
  pass "no-checks marker with an unreadable forge is never green"
}

# A gh that exists but fails is the same ambiguity, reached a different way.
test_no_checks_marker_failing_forge_call_is_not_green() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-ghfail)
  make_repo_on_branch "$d/wt" fm/feat-cighfail
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cighfail.meta" "window=fm:fm-feat-cighfail" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cighfail)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_GH_FAILS=1
  local out; out=$(run_crew_state "$d" feat-cighfail)
  assert_contains "$out" "state: working" "a failing forge call keeps the reading not-ready"
  assert_not_contains "$out" "checks green" "a failing forge call never invents a green"
  pass "no-checks marker with a failing forge call is never green"
}

test_passed_marker_without_forge_is_not_terminal() {
  reset_fakes
  local d; d=$(new_case ci-passed-noforge)
  make_repo_on_branch "$d/wt" fm/feat-cipassnoforge
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cipassnoforge.meta" "window=fm:fm-feat-cipassnoforge" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cipassnoforge)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state_without_gh "$d" feat-cipassnoforge)
  assert_contains "$out" "state: working" "passed marker without forge evidence is not terminal"
  assert_not_contains "$out" "checks green" "stale log text alone is not a green verdict"
  pass "passed marker without forge evidence stays working"
}

# A fix agent writes its own verification prose into the same ci log. Only
# whole-line pipeline markers may be read as pipeline state.
test_agent_prose_is_not_read_as_a_marker() {
  reset_fakes
  local d; d=$(new_case ci-prose)
  make_repo_on_branch "$d/wt" fm/feat-ciprose
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciprose.meta" "window=fm:fm-feat-ciprose" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciprose)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
  "CI checks running, waiting for results..."
  "Verified locally: all CI checks passed after the rebase, so the remaining failure is unrelated."
EOF
)
  local out; out=$(run_crew_state "$d" feat-ciprose)
  assert_contains "$out" "state: working" "agent prose does not end the wait"
  assert_not_contains "$out" "checks green" "agent prose is not a pipeline marker"
  pass "agent prose in the ci log is not read as a pipeline marker"
}

test_ci_monitoring_green_then_rearm_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-rearm)
  make_repo_on_branch "$d/wt" fm/feat-cirearm
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirearm.meta" "window=fm:fm-feat-cirearm" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirearm)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirearm)
  assert_contains "$out" "state: working" "base-advance rearm marker -> working"
  assert_not_contains "$out" "state: done" "base-advance rearm marker must not read as done"
  assert_not_contains "$out" "checks green" "base-advance rearm marker must not read as checks green"
  pass "base-advance rearm after green stays working"
}

test_ci_monitoring_no_checks_yet_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-nochecks-yet)
  make_repo_on_branch "$d/wt" fm/feat-cinochecksyet
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cinochecksyet.meta" "window=fm:fm-feat-cinochecksyet" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cinochecksyet)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
no CI checks reported - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
no CI checks reported yet, waiting for checks to register...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cinochecksyet)
  assert_contains "$out" "state: working" "pending no-checks marker -> working"
  assert_not_contains "$out" "state: done" "pending no-checks marker must not read as done"
  assert_not_contains "$out" "checks green" "pending no-checks marker must not read as checks green"
  pass "pending no-checks ci-monitor marker stays working"
}

test_ci_monitoring_still_waiting_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-waiting)
  make_repo_on_branch "$d/wt" fm/feat-ciwait
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciwait.meta" "window=fm:fm-feat-ciwait" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciwait)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-ciwait)
  assert_contains "$out" "state: working" "ci step still red -> working"
  assert_not_contains "$out" "checks green" "no green marker present -> no checks-green detail"
  pass "ci-monitoring run with checks not yet green stays working"
}

# A later merge-conflict auto-fix round after an earlier green reading must
# not be masked: the MOST RECENT marker in the log tail wins.
test_ci_monitoring_green_then_new_issue_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-green-then-issue)
  make_repo_on_branch "$d/wt" fm/feat-cirelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cirelapse.meta" "window=fm:fm-feat-cirelapse" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cirelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
issues detected: merge conflict - auto-fixing (attempt 2/10)...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cirelapse)
  assert_contains "$out" "state: working" "a later relapse marker must win over an earlier green one"
  assert_not_contains "$out" "state: done" "relapsed ci run must not read as done"
  pass "a fresh issue after an earlier green reading is not masked"
}

test_ci_ready_done_log_relapse_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-ready-then-relapse)
  make_repo_on_branch "$d/wt" fm/feat-cireadyrelapse
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cireadyrelapse.meta" "window=fm:fm-feat-cireadyrelapse" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cireadyrelapse.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-cireadyrelapse)"
  FM_FAKE_CI_LOGS=$(cat <<'EOF'
all CI checks passed - still monitoring until merged or closed
base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout
CI checks running, waiting for results...
EOF
)
  local out; out=$(run_crew_state "$d" feat-cireadyrelapse)
  assert_contains "$out" "state: working" "a stale ready status must not mask a later CI relapse"
  assert_contains "$out" "source: run-step" "relapsed ci run remains run-step sourced"
  assert_not_contains "$out" "state: done" "relapsed ci run with stale done log must not read as done"
  pass "stale checks-green status log does not mask CI relapse"
}

test_ci_fixing_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case ci-fixing-after-green)
  make_repo_on_branch "$d/wt" fm/feat-cifixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-cifixing.meta" "window=fm:fm-feat-cifixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-cifixing.status"
  FM_FAKE_AXI_STATUS="$(run_ci_fixing fm/feat-cifixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-cifixing)
  assert_contains "$out" "state: working" "ci fixing step must stay working"
  assert_contains "$out" "source: run-step" "ci fixing remains run-step sourced"
  assert_not_contains "$out" "state: done" "ci fixing must not read as checks-green done"
  pass "ci fixing is not overridden by an earlier green marker"
}

test_top_level_fixing_ci_running_after_green_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-ci-running)
  make_repo_on_branch "$d/wt" fm/feat-topfixingci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixingci.meta" "window=fm:fm-feat-topfixingci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_fixing_ci_running fm/feat-topfixingci)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixingci)
  assert_contains "$out" "state: working" "top-level fixing with ci running must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing with ci running remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not use stale green marker"
  pass "top-level fixing is not overridden by a stale ci running row"
}

test_top_level_fixing_done_log_stays_working() {
  reset_fakes
  local d; d=$(new_case top-level-fixing-done-log)
  make_repo_on_branch "$d/wt" fm/feat-topfixing
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-topfixing.meta" "window=fm:fm-feat-topfixing" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/2 checks green\n' > "$d/state/feat-topfixing.status"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-topfixing)"
  FM_FAKE_CI_LOGS="all CI checks passed - still monitoring until merged or closed"
  local out; out=$(run_crew_state "$d" feat-topfixing)
  assert_contains "$out" "state: working" "top-level fixing must stay working"
  assert_contains "$out" "source: run-step" "top-level fixing remains run-step sourced"
  assert_contains "$out" "validating (fixing)" "top-level fixing keeps fixing detail"
  assert_not_contains "$out" "state: done" "top-level fixing must not read as stale checks-green done"
  pass "top-level fixing is not overridden by a stale done log"
}

# (d) terminal run-step is authoritative
test_terminal_passed() {
  reset_fakes
  local d; d=$(new_case passed)
  make_repo_on_branch "$d/wt" fm/feat-d
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-d.meta" "window=fm:fm-feat-d" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-d)"
  local out; out=$(run_crew_state "$d" feat-d)
  assert_contains "$out" "state: done" "passed run -> done"
  assert_contains "$out" "source: run-step" "passed -> run-step source"
  pass "terminal passed run is authoritative"
}

test_terminal_failed() {
  reset_fakes
  local d; d=$(new_case failed)
  make_repo_on_branch "$d/wt" fm/feat-e
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-e.meta" "window=fm:fm-feat-e" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-e)"
  local out; out=$(run_crew_state "$d" feat-e)
  assert_contains "$out" "state: failed" "failed run -> failed"
  assert_contains "$out" "source: run-step" "failed -> run-step source"
  pass "terminal failed run is authoritative"
}

# (e) cross-branch attribution: `axi status` returns ANOTHER branch's run (the
# routine case once more than one crew validates the same underlying repo
# concurrently - they share ONE no-mistakes repo registration), so the helper
# falls back to the real top-level `no-mistakes runs` listing to learn whether
# THIS branch has an active run of its own. Regression coverage for the
# 2026-07-02 herdr incident: the old fallback shelled out to `no-mistakes axi`
# (bare) expecting a `runs[N]{...}:` TOON table that the real CLI never emits
# (verified against the installed v1.32.2 - the `axi` surface has no
# runs-listing subcommand at all), so attribution silently failed every time
# the repo-wide answer was not this crew's own branch.
test_cross_branch_attribution_via_runs_list() {
  reset_fakes
  local d short; d=$(new_case crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-f
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-f.meta" "window=fm:fm-feat-f" "worktree=$d/wt" "kind=ship"
  # The repo-wide active/most-recent run belongs to a different crew's branch.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  # Real `no-mistakes runs` shape: plain text, newest-first, no run id, no
  # quoting - "<status> <branch> <short-sha> <date> [<pr-url>]".
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-f ${short}  2026-07-02 22:05
EOF
)"
  local out; out=$(run_crew_state "$d" feat-f)
  assert_contains "$out" "state: working" "this branch's own run attributed via the runs list"
  assert_contains "$out" "source: run-step" "runs-list-resolved run -> run-step source"
  pass "cross-branch run is attributed via the real runs list"
}

# The runs list is newest-first; a branch with an OLDER completed run must not
# shadow its own newer active one - the first (topmost) matching row wins.
test_cross_branch_attribution_picks_most_recent_row() {
  reset_fakes
  local d short; d=$(new_case crossbranch-mostrecent)
  make_repo_on_branch "$d/wt" fm/feat-fq
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-fq.meta" "window=fm:fm-feat-fq" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-fq ${short}  2026-07-02 21:50
  completed  fm/feat-fq bbbbbbb  2026-07-02 20:00  https://github.com/o/r/pull/1
EOF
)"
  local out; out=$(run_crew_state "$d" feat-fq)
  assert_contains "$out" "state: working" "most recent (running) row wins over an older completed row"
  assert_contains "$out" "source: run-step" "most-recent-row resolution -> run-step source"
  pass "cross-branch attribution picks the branch's most recent row"
}

test_coarse_run_does_not_promote_ready_status_without_forge() {
  reset_fakes
  local d short; d=$(new_case coarse-ready-other-log)
  make_repo_on_branch "$d/wt" fm/feat-coarseready
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-coarseready.meta" "window=fm:fm-feat-coarseready" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/4 checks green\n' > "$d/state/feat-coarseready.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-coarseready ${short}  2026-07-02 22:05
EOF
)"
  FM_FAKE_CI_LOGS="CI checks running, waiting for results..."
  local out; out=$(run_crew_state "$d" feat-coarseready)
  assert_contains "$out" "state: working" "coarse run stays working without current forge evidence"
  assert_contains "$out" "source: run-step" "coarse run remains run-step sourced"
  assert_not_contains "$out" "state: done" "coarse status text alone is not terminal"
  pass "coarse run does not promote status text without forge evidence"
}

# A different-branch run with NO matching runs-list row must NOT be
# misattributed, and must not be treated as a false "working" verdict either.
test_other_branch_run_ignored() {
  reset_fakes
  local d; d=$(new_case otherbranch)
  make_repo_on_branch "$d/wt" fm/feat-g
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-g.meta" "window=fm:fm-feat-g" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'done: implemented, ready to validate\n' > "$d/state/feat-g.status"
  FM_FAKE_AXI_STATUS="$(run_running fm/some-other)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/some-other aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-g
  local out; out=$(run_crew_state "$d" feat-g)
  assert_not_contains "$out" "source: run-step" "another branch's run not misattributed"
  assert_contains "$out" "source: status-log" "no own run -> falls back to status-log"
  assert_contains "$out" "state: done" "falls back to the log verb"
  pass "another branch's run is ignored, falls back"
}

# (f) no run for this crew + a busy pane -> working via pane
test_no_run_busy_pane() {
  reset_fakes
  local d; d=$(new_case busy)
  make_repo_on_branch "$d/wt" fm/feat-h
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h.meta" "window=fm:fm-feat-h" "worktree=$d/wt" "kind=ship" "harness=claude"
  # No matching run anywhere. The busy verdict comes from the crew's own
  # semantic lifecycle record (bin/fm-busy-lib.sh), not from rendered text.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-h)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-h busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-h)
  assert_contains "$out" "state: working" "busy record -> working"
  assert_contains "$out" "source: pane" "busy record -> pane source"
  assert_contains "$out" "claude-hook" "the working verdict names its semantic source"
  pass "no run + a busy semantic record reads working, attributed to its source"
}

# A converted adapter must NOT read working from rendered footer text: the
# redesign removed that dependency, so a pane painting "esc to interrupt" with
# no semantic record is unknown, never working and never silently idle.
test_no_run_footer_text_alone_is_not_working() {
  reset_fakes
  local d; d=$(new_case busy-footer-only)
  make_repo_on_branch "$d/wt" fm/feat-h2
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h2.meta" "window=fm:fm-feat-h2" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  printf 'done: stale completion event\n' > "$d/state/feat-h2.status"
  local out; out=$(run_crew_state "$d" feat-h2)
  assert_not_contains "$out" "state: working" "a footer alone must not read working for a converted adapter"
  assert_contains "$out" "state: unknown" "no semantic record -> unknown"
  assert_not_contains "$out" "source: status-log" "unknown semantic state must not fall through to a stale log"
  pass "a converted adapter never reads working from rendered footer text"
}

# Grok keeps its isolated temporary rendered-tail fallback until its structured
# lifecycle is live-verified, so a grok crew still reads working from its own
# verified signature.
test_no_run_grok_uses_isolated_fallback() {
  reset_fakes
  local d; d=$(new_case busy-grok)
  make_repo_on_branch "$d/wt" fm/feat-h3
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-h3.meta" "window=fm:fm-feat-h3" "worktree=$d/wt" "kind=ship" "harness=grok"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=1
  FM_FAKE_BUSY_TEXT='Ctrl+c:cancel'
  export FM_FAKE_BUSY_TEXT
  local out; out=$(run_crew_state "$d" feat-h3)
  assert_contains "$out" "state: working" "grok busy tail -> working"
  assert_contains "$out" "grok-regex" "the grok verdict names its isolated fallback source"
  pass "grok still reads working through its isolated rendered-tail fallback"
}

test_no_run_herdr_unknown_uses_backend_capture() {
  command -v jq >/dev/null 2>&1 || { pass "herdr pane fallback skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-busy)
  make_repo_on_branch "$d/wt" fm/feat-herdr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr.meta" "window=default:w1:p2" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_BUSY=1
  FM_FAKE_HERDR_AGENT_STATUS=working
  local out; out=$(run_crew_state "$d" feat-herdr)
  assert_contains "$out" "state: working" "herdr native busy -> working"
  assert_contains "$out" "source: pane" "herdr native busy -> pane source"
  assert_contains "$out" "herdr-native" "the herdr verdict names its native source"
  pass "herdr's native busy verdict reads working with no record present"
}

# Regression (2026-07 herdr false-surface incident, now solved semantically):
# herdr's agent.get reports generation state ("working" only while the model is
# actively streaming - docs/herdr-backend.md "Busy state"), not "this crew's
# turn is still in progress". A crew blocked on its own long-running foreground
# `no-mistakes axi run` (no --yes; blocks until a gate or outcome) is not
# generating for that whole span, so agent.get reads idle. The crew's own
# semantic lifecycle record still says busy for the whole turn, and it outranks
# the narrower native verdict - so the crew is no longer misread as not-working.
test_no_run_herdr_idle_agent_status_outranked_by_record() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle corroboration skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-busy-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-idle
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-idle.meta" "window=default:w1:p3" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  # No run attributable (mirrors a no-mistakes run-step lookup that found no
  # matching row within the configured runs-list window): the crew's semantic
  # busy state is the only remaining signal.
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-idle)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-idle busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" feat-herdr-idle)
  assert_contains "$out" "state: working" "a busy record with herdr idle agent_status -> working"
  assert_contains "$out" "claude-hook" "the record's source outranks herdr's narrower native verdict"
  pass "a mid-tool-call crew stays working because its record outranks herdr's generation state"
}

# The record must not mask a genuinely idle or human-blocked agent: an idle
# record with idle agent_status still reads not-busy.
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle() {
  command -v jq >/dev/null 2>&1 || { pass "herdr idle+idle-record skipped without jq"; return; }
  reset_fakes
  local d; d=$(new_case herdr-idle-idle-record)
  make_repo_on_branch "$d/wt" fm/feat-herdr-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-herdr-stopped.meta" "window=default:w1:p4" "worktree=$d/wt" "kind=ship" \
    "backend=herdr" "harness=claude"
  printf 'working: implementing\n' > "$d/state/feat-herdr-stopped.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  FM_FAKE_HERDR_AGENT_STATUS=idle
  FM_FAKE_HERDR_BUSY=0
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-herdr-stopped)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-herdr-stopped idle --gen "$gen" \
    --source claude-hook --event stop
  local out; out=$(run_crew_state "$d" feat-herdr-stopped)
  assert_not_contains "$out" "source: pane" "an idle record must not read as busy"
  assert_contains "$out" "source: status-log" "an idle record falls to the status log"
  pass "an idle record with idle agent_status stays not-busy (no regression for a human-blocked agent)"
}

# (g) no run + idle pane -> the status-log verb, as-is
test_no_run_idle_pane_uses_log() {
  reset_fakes
  local d; d=$(new_case idle)
  make_repo_on_branch "$d/wt" fm/feat-i
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-i.meta" "window=fm:fm-feat-i" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision: which database?\n' > "$d/state/feat-i.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-i
  local out; out=$(run_crew_state "$d" feat-i)
  assert_contains "$out" "state: parked" "needs-decision log -> parked"
  assert_contains "$out" "source: status-log" "idle pane -> status-log source"
  pass "no run + idle pane uses the status-log verb"
}

test_no_run_idle_pane_uses_keyed_log() {
  reset_fakes
  local d; d=$(new_case keyed-idle)
  make_repo_on_branch "$d/wt" fm/feat-keyed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-keyed.meta" "window=fm:fm-feat-keyed" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'needs-decision [key=q1]: which database?\n' > "$d/state/feat-keyed.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-keyed
  local out; out=$(run_crew_state "$d" feat-keyed)
  assert_contains "$out" "state: parked" "keyed needs-decision log -> parked"
  assert_contains "$out" "which database?" "key token is excluded from status detail"
  pass "no run + idle pane parses keyed status syntax"
}

# (g') no run + idle pane on a DECLARED external-wait pause -> state: paused, so a
# supervisor reading the crew sees a distinct pause (and its reason) rather than a
# wedge-suspect idle. This is the reader half the watcher/daemon build on.
test_no_run_idle_pane_paused() {
  reset_fakes
  local d; d=$(new_case paused)
  make_repo_on_branch "$d/wt" fm/feat-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pause.meta" "window=fm:fm-feat-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'paused: holding for the upstream tool release\n' > "$d/state/feat-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-pause
  local out; out=$(run_crew_state "$d" feat-pause)
  assert_contains "$out" "state: paused" "paused log -> paused"
  assert_contains "$out" "source: status-log" "idle pause -> status-log source"
  assert_contains "$out" "holding for the upstream tool release" "the pause reason is carried in the detail"
  pass "no run + idle pane on a paused: status reports state: paused with its reason"
}

test_no_run_idle_pane_custom_paused_verb() {
  reset_fakes
  local d; d=$(new_case custom-paused)
  make_repo_on_branch "$d/wt" fm/feat-custom-pause
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-custom-pause.meta" "window=fm:fm-feat-custom-pause" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'awaiting: vendor maintenance window\n' > "$d/state/feat-custom-pause.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" feat-custom-pause
  local out; out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: paused" "custom paused verb -> paused"
  assert_contains "$out" "source: status-log" "custom paused verb -> status-log source"
  assert_contains "$out" "vendor maintenance window" "custom pause preserves its reason"
  printf 'paused: default verb no longer selected\n' > "$d/state/feat-custom-pause.status"
  out=$(FM_CLASSIFY_PAUSED_VERB=awaiting run_crew_state "$d" feat-custom-pause)
  assert_contains "$out" "state: unknown" "custom paused verb replaces the default"
  pass "no run + idle pane honors the configured paused verb"
}

# A trailing keyed resolved: event is a decision-CLOSING event, not a run-state
# verb. It must never become the current state or leak its resolution prose as the
# detail: a healthy idle secondmate that just closed a keyed decision falls through
# to the idle default (unknown/none), not `unknown` with the resolution note as its
# `doing`. Regression for the bearings render bug where such a secondmate showed
# state=unknown with resolution prose. The one-owner keyed fold in fm-classify-lib.sh
# is untouched; this only stops the deriver from reading a non-state event as state.
test_no_run_idle_secondmate_resolved_event_not_state() {
  reset_fakes
  local d; d=$(new_case resolved-idle)
  mkdir -p "$d/wt"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/mate.meta" "window=fm:fm-mate" "worktree=$d/wt" "kind=secondmate" "home=$d/wt"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$d/state/mate.status"
  printf 'resolved [key=race]: went with subscribe-before-write\n' >> "$d/state/mate.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_BUSY=0
  local out; out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: unknown" "resolved-then-idle secondmate is not a spurious run-state"
  assert_contains "$out" "source: none" "a resolved event is not treated as a status-log state source"
  assert_not_contains "$out" "subscribe-before-write" "resolution prose must not leak into the detail"
  # A bare (non-keyed) resolved: closes the default key and behaves the same.
  printf 'blocked: waiting on infra\nresolved: infra access granted\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "source: none" "a bare resolved: is not a state source either"
  assert_not_contains "$out" "infra access granted" "bare resolution prose must not leak into the detail"
  # Control: a genuine trailing state verb still renders from the log.
  printf 'working: reconciling routed items\n' > "$d/state/mate.status"
  out=$(run_crew_state "$d" mate)
  assert_contains "$out" "state: working" "a real trailing state verb still renders"
  assert_contains "$out" "reconciling routed items" "a real state line still carries its detail"
  pass "a trailing resolved: event does not corrupt state render (idle stays idle)"
}

test_dead_window_ignores_stale_status_log() {
  reset_fakes
  local d; d=$(new_case dead-window)
  make_repo_on_branch "$d/wt" fm/feat-dead
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead.meta" "window=fm:fm-feat-dead" "worktree=$d/wt" "kind=ship"
  printf 'done: old completion event\n' > "$d/state/feat-dead.status"
  FM_FAKE_AXI_STATUS=""
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead)
  assert_contains "$out" "state: unknown" "dead window -> unknown"
  assert_contains "$out" "source: none" "dead window -> none source"
  assert_not_contains "$out" "source: status-log" "dead window does not reuse stale log"
  pass "dead window ignores stale status log"
}

# A closed/unreadable pane must NOT mask an authoritative run-step: judge by the
# run-step, not the shell. The common case is a finished crew whose agent has
# exited and closed its window (the normal gap between completion and teardown) -
# it must still report its terminal run-step state (e.g. done), never unknown.
test_dead_window_still_reports_terminal_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-done)
  make_repo_on_branch "$d/wt" fm/feat-dead-done
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-done.meta" "window=fm:fm-feat-dead-done" "worktree=$d/wt" "kind=ship"
  printf 'done: PR https://github.com/o/r/pull/3 checks green\n' > "$d/state/feat-dead-done.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-dead-done)"
  FM_FAKE_TMUX_MISSING=1   # the crew's window has closed
  local out; out=$(run_crew_state "$d" feat-dead-done)
  assert_contains "$out" "state: done" "closed pane still reports terminal run-step done"
  assert_contains "$out" "source: run-step" "closed pane does not mask the run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with a run must never be unknown"
  pass "closed pane still reports a terminal run-step"
}

# The same for an active run: an agent pane that crashed mid-validation while the
# daemon-backed run continues must report the live run-step, not unknown.
test_dead_window_still_reports_active_run_step() {
  reset_fakes
  local d; d=$(new_case dead-window-active)
  make_repo_on_branch "$d/wt" fm/feat-dead-act
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-dead-act.meta" "window=fm:fm-feat-dead-act" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/feat-dead-act)"
  FM_FAKE_TMUX_MISSING=1
  local out; out=$(run_crew_state "$d" feat-dead-act)
  assert_contains "$out" "state: working" "closed pane still reports active run-step"
  assert_contains "$out" "source: run-step" "closed pane does not mask the active run-step"
  assert_not_contains "$out" "state: unknown" "closed pane with an active run must never be unknown"
  pass "closed pane still reports an active run-step"
}

test_no_timeout_uses_perl_bound() {
  reset_fakes
  local d toolbin out start elapsed calls_file calls
  d=$(new_case no-timeout)
  make_repo_on_branch "$d/wt" fm/feat-timeout
  make_fakebin "$d" >/dev/null
  calls_file="$d/no-mistakes.calls"
  : > "$calls_file"
  cat > "$d/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_NM_CALLS:-/dev/null}"
while :; do :; done
SH
  chmod +x "$d/fakebin/no-mistakes"
  toolbin=$(make_no_timeout_toolbin "$d")
  fm_write_meta "$d/state/feat-timeout.meta" "window=fm:fm-feat-timeout" "worktree=$d/wt" "kind=ship" \
    "harness=claude"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat-timeout)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat-timeout busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  start=$SECONDS
  out=$(FM_FAKE_NM_CALLS="$calls_file" PATH="$d/fakebin:$toolbin" FM_STATE_OVERRIDE="$d/state" FM_CREW_STATE_NM_TIMEOUT=1 "$CREW_STATE" feat-timeout)
  elapsed=$((SECONDS - start))
  assert_contains "$out" "state: working" "timed-out no-mistakes falls back to pane"
  assert_contains "$out" "source: pane" "timed-out no-mistakes -> pane source"
  [ "$elapsed" -lt 5 ] || fail "perl timeout did not bound no-mistakes calls (elapsed ${elapsed}s)"
  calls=$(awk 'END { print NR + 0 }' "$calls_file" 2>/dev/null || echo 0)
  [ "$calls" -eq 1 ] || fail "empty no-mistakes status triggered extra lookups ($calls calls)"
  pass "no timeout command uses perl bound"
}

# (i) kind=scout skips the run lookup entirely (its deliverable is a report).
test_scout_skips_run_lookup() {
  reset_fakes
  local d; d=$(new_case scout)
  make_repo_on_branch "$d/wt" fm/scout-j
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/scout-j.meta" "window=fm:fm-scout-j" "worktree=$d/wt" "kind=scout" \
    "harness=claude"
  # Even if a run existed on this branch, a scout must not read it.
  FM_FAKE_AXI_STATUS="$(run_running fm/scout-j)"
  FM_FAKE_BUSY=1
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" scout-j)
  "$ROOT/bin/fm-busy-event.sh" apply "$d/state" scout-j busy --gen "$gen" \
    --source claude-hook --event user-prompt-submit
  local out; out=$(run_crew_state "$d" scout-j)
  assert_not_contains "$out" "source: run-step" "scout ignores no-mistakes run-step"
  assert_contains "$out" "source: pane" "scout reads its semantic busy state"
  pass "scout skips the run lookup"
}

# (j) torn-down worktree and missing meta are graceful (unknown/none, exit 0)
test_torn_down_worktree() {
  reset_fakes
  local d; d=$(new_case torndown)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/gone-k.meta" "window=fm:fm-gone-k" "worktree=$d/no-such-worktree" "kind=ship"
  local out rc
  out=$(run_crew_state "$d" gone-k); rc=$?
  expect_code 0 "$rc" "torn-down worktree exits 0"
  assert_contains "$out" "state: unknown" "torn-down -> unknown"
  assert_contains "$out" "source: none" "torn-down -> none source"
  pass "torn-down worktree is handled gracefully"
}

# --- remote secondmate arm ---------------------------------------------------
# A meta recording remote_host= must never be read through the local worktree
# probe or a local backend adapter: the recorded worktree and pane live on the
# remote host, and the old local reads misreported a healthy remote mate as
# "worktree gone". These cases drive the real helper over the real fm-on.sh
# route with a stubbed ssh transport (FM_SSH_BIN seam): the stub prints
# FM_FAKE_REMOTE_STATE_OUT as the remote endpoint's recovery-grade state and
# exits FM_FAKE_SSH_RC.

setup_remote_case() {  # <name> -> echoes case dir with remote meta + registry
  local d
  d=$(new_case "$1")
  mkdir -p "$d/data" "$d/fakebin"
  fm_write_meta "$d/state/rsm.meta" \
    "window=remote:rsm" \
    "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" \
    "kind=secondmate" \
    "mode=secondmate" \
    "remote_host=remote-mac" \
    "remote_root=/remote/root" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$d/data/secondmates.md" <<EOF
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
EOF
  cat > "$d/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
[ -z "${FM_FAKE_REMOTE_STATE_OUT:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_STATE_OUT"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$d/fakebin/fake-ssh"
  printf '%s\n' "$d"
}

run_remote_crew_state() {  # <case-dir> <id>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" \
    FM_SSH_BIN="$1/fakebin/fake-ssh" "$CREW_STATE" "$2"
}

test_remote_alive_with_log_uses_status_log() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-log)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive exits 0"
  assert_contains "$out" "state: working" "alive remote mate with a working log reads working"
  assert_contains "$out" "source: status-log" "alive remote mate reads current activity from the routed log"
  assert_contains "$out" "remote endpoint alive on remote-mac" "the remote liveness read should be visible"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  pass "fm-crew-state remote: alive endpoint falls through to the routed status log"
}

test_remote_alive_idle_is_healthy_not_gone() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-alive-idle)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=alive FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote alive-idle exits 0"
  assert_contains "$out" "source: remote-endpoint" "the remote endpoint is the reported source"
  assert_contains "$out" "alive on remote-mac" "an idle remote mate reads alive"
  assert_not_contains "$out" "worktree gone" "a healthy remote mate must never read as torn down"
  assert_not_contains "$out" "backend target gone" "a healthy remote mate must never read as a dead target"
  pass "fm-crew-state remote: an idle alive endpoint reads alive, never gone or dead"
}

test_remote_unreachable_is_unknown_remote_not_dead() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-unreachable)
  make_fakebin "$d" >/dev/null
  printf 'working: refactoring the quota adapter\n' > "$d/state/rsm.status"
  out=$(FM_FAKE_SSH_RC=255 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "unreachable remote exits 0"
  assert_contains "$out" "unknown-remote" "an unreachable remote must be labeled unknown-remote"
  assert_contains "$out" "not proof of death" "an unreachable remote must not read as dead"
  assert_not_contains "$out" "worktree gone" "an unreachable remote must never read as torn down"
  assert_not_contains "$out" "backend target gone" "an unreachable remote must never read as a dead target"
  pass "fm-crew-state remote: an unreachable host reads unknown-remote, never gone or dead"
}

test_remote_dead_reports_remote_verdict() {
  reset_fakes
  local d out rc
  d=$(setup_remote_case remote-dead)
  make_fakebin "$d" >/dev/null
  out=$(FM_FAKE_REMOTE_STATE_OUT=dead FM_FAKE_SSH_RC=0 run_remote_crew_state "$d" rsm); rc=$?
  expect_code 0 "$rc" "remote dead exits 0"
  assert_contains "$out" "remote endpoint dead on remote-mac" \
    "a genuinely dead remote endpoint reports the remote host's own verdict"
  pass "fm-crew-state remote: the remote host's own dead verdict is reported truthfully"
}

test_missing_meta() {
  reset_fakes
  local d; d=$(new_case nometa)
  make_fakebin "$d" >/dev/null
  local out rc
  out=$(run_crew_state "$d" ghost-z); rc=$?
  expect_code 0 "$rc" "missing meta exits 0"
  assert_contains "$out" "state: unknown" "missing meta -> unknown"
  assert_contains "$out" "source: none" "missing meta -> none source"
  pass "missing meta is handled gracefully"
}

# (k) crew_is_provably_working end-to-end over the REAL fm-crew-state.sh (not a
# canned fake verdict, unlike tests/fm-watch-triage.test.sh's classifier
# coverage). This is the direct regression pair for the 2026-07-02 herdr
# incident: a validating crew whose bare `axi status` answer belongs to
# another branch must still be absorbed by the watcher via the runs-list
# fallback (working), while a crew with genuinely no run anywhere and an idle
# pane must still surface (the safety property the fix must never widen away).
test_provably_working_via_runs_list_fallback() {
  reset_fakes
  local d short; d=$(new_case provably-working-crossbranch)
  make_repo_on_branch "$d/wt" fm/feat-provable
  short=$(git -C "$d/wt" rev-parse --short=7 HEAD)
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-provable.meta" "window=fm:fm-feat-provable" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<EOF
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
  running    fm/feat-provable ${short}  2026-07-02 22:05
EOF
)"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-provable \
    || fail "cross-branch attribution via the runs list was not treated as provably working"
  pass "crew_is_provably_working absorbs a validating crew found only via the runs-list fallback"
}

test_not_provably_working_when_stopped() {
  reset_fakes
  local d; d=$(new_case provably-working-stopped)
  make_repo_on_branch "$d/wt" fm/feat-stopped
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-stopped.meta" "window=fm:fm-feat-stopped" "worktree=$d/wt" "kind=ship"
  # Repo-wide run belongs to someone else, and this branch has no row in the
  # runs list either (it never validated, or genuinely finished/stopped) - the
  # only remaining signal is the pane, which is idle.
  FM_FAKE_AXI_STATUS="$(run_running fm/other-crew)"
  FM_FAKE_RUNS_LIST="$(cat <<'EOF'
  running    fm/other-crew aaaaaaa  2026-07-02 22:10
EOF
)"
  FM_FAKE_BUSY=0
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" crew_is_provably_working feat-stopped \
    && fail "a stopped crew with no run anywhere and an idle pane was treated as provably working"
  pass "crew_is_provably_working still surfaces a genuinely stopped crew (safety property preserved)"
}

# Usage error (no id) is the one non-zero exit.
test_usage_error() {
  reset_fakes
  local rc
  "$CREW_STATE" >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "no-arg usage error exits 2"
  pass "usage error exits 2"
}

# Head-binding: same branch name with a rewritten/diverged worktree tip must not
# attribute a historical no-mistakes run (multi-stage branch reuse incident).
test_historical_same_branch_rewritten_head_not_current() {
  reset_fakes
  local d old_head new_head out
  d=$(new_case rewritten-head)
  make_repo_on_branch "$d/wt" fm/todo-flag
  old_head=$(git -C "$d/wt" rev-parse HEAD)
  # Simulate a rebase rewrite: orphan new history on the same branch name.
  git -C "$d/wt" checkout -q --orphan tmp-rewrite
  git -C "$d/wt" commit -q --allow-empty -m 'rewritten tip'
  git -C "$d/wt" branch -q -M fm/todo-flag
  new_head=$(git -C "$d/wt" rev-parse HEAD)
  [ "$old_head" != "$new_head" ] || fail "rewrite did not produce a new head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/wishlist.meta" "window=fm:fm-wishlist" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 setup complete rebased onto merged #76\n' > "$d/state/wishlist.status"
  # Historical run still reports the pre-rewrite head on the reused branch.
  FM_FAKE_RUN_HEAD="$old_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/todo-flag)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" wishlist
  out=$(run_crew_state "$d" wishlist)
  assert_not_contains "$out" "source: run-step" "historical rewritten head must not use run-step"
  assert_not_contains "$out" "parked at" "historical parked run must not mask current state"
  assert_contains "$out" "source: status-log" "falls back to status-log after head mismatch"
  assert_contains "$out" "state: working" "status-log working: remains current"
  pass "historical same-branch rewritten head is not attributed as current"
}

# Head-binding: an active pipeline whose run head is a descendant of the local
# tip (fix commits on the same history) remains current.
test_active_run_descendant_fix_head_remains_current() {
  reset_fakes
  local d base_head fix_head out
  d=$(new_case pipeline-descendant)
  make_repo_on_branch "$d/wt" fm/feat-pipeline
  base_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'pipeline fix commit'
  fix_head=$(git -C "$d/wt" rev-parse HEAD)
  # Worktree still at the pre-fix tip; run reports the pipeline fix head.
  git -C "$d/wt" reset -q --hard "$base_head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/pipe.meta" "window=fm:fm-pipe" "worktree=$d/wt" "kind=ship"
  FM_FAKE_RUN_HEAD="$fix_head"
  FM_FAKE_AXI_STATUS="$(run_fixing fm/feat-pipeline)"
  out=$(run_crew_state "$d" pipe)
  assert_contains "$out" "source: run-step" "descendant pipeline fix head remains run-step"
  assert_contains "$out" "state: working" "active fixing run remains working"
  pass "active run with valid descendant fix head remains current"
}

# Head-binding: local work that advanced past the run head invalidates the run.
test_local_advanced_past_run_head_invalidates() {
  reset_fakes
  local d run_head out
  d=$(new_case local-advanced)
  make_repo_on_branch "$d/wt" fm/feat-adv
  run_head=$(git -C "$d/wt" rev-parse HEAD)
  git -C "$d/wt" commit -q --allow-empty -m 'local stage-2 work after prior run'
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/adv.meta" "window=fm:fm-adv" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: stage 2 implementation in progress\n' > "$d/state/adv.status"
  FM_FAKE_RUN_HEAD="$run_head"
  FM_FAKE_AXI_STATUS="$(run_parked fm/feat-adv)"
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" adv
  out=$(run_crew_state "$d" adv)
  assert_not_contains "$out" "source: run-step" "local-advanced tip must not use historical run"
  assert_contains "$out" "source: status-log" "falls back after local advanced past run"
  assert_contains "$out" "state: working" "status-log working: is current"
  pass "local work advanced past run head invalidates attribution"
}

test_missing_run_head_falls_back_to_current_state() {
  reset_fakes
  local d out
  d=$(new_case missing-run-head)
  make_repo_on_branch "$d/wt" fm/feat-no-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/no-head.meta" "window=fm:fm-no-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  printf 'working: current stage still in progress\n' > "$d/state/no-head.status"
  FM_FAKE_AXI_STATUS=$(run_parked fm/feat-no-head | grep -v '^  head:')
  FM_FAKE_RUNS_LIST=""
  FM_FAKE_BUSY=0
  arm_idle_record "$d/state" no-head
  out=$(run_crew_state "$d" no-head)
  assert_not_contains "$out" "source: run-step" "missing run head must not permit branch-only attribution"
  assert_contains "$out" "source: status-log" "missing run head falls back to current state sources"
  assert_contains "$out" "state: working" "status-log remains current after missing run head"
  pass "missing run head falls back instead of matching by branch"
}

# Skipped, succeeded, merged and closed-unmerged are four different facts.
# `outcome: passed` alone tells them apart for none of them, so publication is
# read from the pr step and the run's pr field.
test_passed_run_with_skipped_publish_claims_no_pr() {
  reset_fakes
  local d; d=$(new_case passed-skipped-publish)
  make_repo_on_branch "$d/wt" fm/feat-skippub
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-skippub.meta" "window=fm:fm-feat-skippub" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_publish_skipped fm/feat-skippub)"
  local out; out=$(run_crew_state "$d" feat-skippub)
  assert_contains "$out" "state: done" "a passed run is still done"
  assert_contains "$out" "nothing published" "a skipped pr step published nothing"
  assert_not_contains "$out" "merged" "no pull request exists, so none can have merged"
  pass "passed run with skipped publishing steps does not claim a PR"
}

test_passed_run_names_a_merge_when_the_log_records_one() {
  reset_fakes
  local d; d=$(new_case passed-merged)
  make_repo_on_branch "$d/wt" fm/feat-merged
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-merged.meta" "window=fm:fm-feat-merged" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-merged)"
  FM_FAKE_CI_LOGS="  \"PR has been merged!\""
  FM_FAKE_RUNS_LIST="  completed    fm/feat-merged ${FM_FAKE_RUN_HEAD:0:8}  2026-08-20 13:36"
  local out; out=$(run_crew_state "$d" feat-merged)
  assert_contains "$out" "PR merged" "a recorded merge is reported as a merge"
  assert_not_contains "$out" "closed unmerged" "a merge is not hedged as maybe-closed"

  # The discriminating half: the same run whose log records a CLOSE must not
  # produce the same sentence. Two outcomes that read alike are the defect.
  reset_fakes
  local e; e=$(new_case passed-merged-vs-closed)
  make_repo_on_branch "$e/wt" fm/feat-merged
  make_fakebin "$e" >/dev/null
  fm_write_meta "$e/state/feat-merged.meta" "window=fm:fm-feat-merged" "worktree=$e/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-merged)"
  FM_FAKE_CI_LOGS="  \"PR has been closed\""
  local other; other=$(run_crew_state "$e" feat-merged)
  [ "$other" != "$out" ] || fail "a merged PR and a closed one produced the same line: $out"
  pass "passed run reports a merge the ci log actually recorded"
}

test_passed_run_names_a_close_when_the_log_records_one() {
  reset_fakes
  local d; d=$(new_case passed-closed)
  make_repo_on_branch "$d/wt" fm/feat-closed
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-closed.meta" "window=fm:fm-feat-closed" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-closed)"
  FM_FAKE_CI_LOGS="  \"PR has been closed\""
  FM_FAKE_RUNS_LIST="  completed    fm/feat-closed ${FM_FAKE_RUN_HEAD:0:8}  2026-08-20 13:36"
  local out; out=$(run_crew_state "$d" feat-closed)
  assert_contains "$out" "closed unmerged" "a PR closed unmerged is not called a merge"
  pass "passed run reports a close the ci log actually recorded"
}

# The ci step can skip CI entirely, e.g. when gh is not authenticated. That
# leaves the change unchecked by the pipeline, so it is settled at the forge
# exactly like any other zero-checks reading rather than left to a stale marker.
test_skipping_ci_marker_is_settled_at_the_forge() {
  reset_fakes
  local d; d=$(new_case ci-skipped)
  make_repo_on_branch "$d/wt" fm/feat-ciskip
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-ciskip.meta" "window=fm:fm-feat-ciskip" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-ciskip)"
  FM_FAKE_CI_LOGS="skipping CI: gh CLI is not authenticated"
  FM_FAKE_CHECK_SUITES=$(suites_gated)
  local out; out=$(run_crew_state "$d" feat-ciskip)
  assert_contains "$out" "state: working" "a skipped CI step has verified nothing"
  assert_not_contains "$out" "checks green" "a skipped CI step is never checks green"

  # Same marker, different forge answer, different verdict - which is the point:
  # the marker states a fact about the pipeline, the forge decides what it means.
  FM_FAKE_CHECK_SUITES=$(suites_none)
  local out2; out2=$(run_crew_state "$d" feat-ciskip)
  assert_contains "$out2" "nothing verified this change" "no CI at all is named as unverified"
  [ "$out2" != "$out" ] || fail "the forge answer made no difference to a skipped-CI reading"
  pass "skipping-CI marker is settled at the forge, not assumed green"
}

test_passed_run_with_published_pr_names_it() {
  reset_fakes
  local d; d=$(new_case passed-published)
  make_repo_on_branch "$d/wt" fm/feat-pubpr
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pubpr.meta" "window=fm:fm-feat-pubpr" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-pubpr)"
  local out; out=$(run_crew_state "$d" feat-pubpr)
  assert_contains "$out" "state: done" "a published passed run is done"
  assert_contains "$out" "https://github.com/o/r/pull/1" "the PR it published is named"
  pass "passed run with a published PR names the PR"
}

# The 2026-08-20 captain-presentation incident: the worker had declared a pause
# saying it was NOT done, and the reader's own CI inference overruled it.
test_declared_pause_beats_inferred_done() {
  reset_fakes
  local d; d=$(new_case pause-vs-inferred-done)
  make_repo_on_branch "$d/wt" fm/feat-pausedone
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pausedone.meta" "window=fm:fm-feat-pausedone" "worktree=$d/wt" "kind=ship"
  printf 'paused [key=pr-awaiting-ci]: waiting on CI at head abc1234; NOT done\n' \
    > "$d/state/feat-pausedone.status"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-pausedone)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_CHECK_SUITES=$(suites_none)
  local out; out=$(run_crew_state "$d" feat-pausedone)
  assert_contains "$out" "state: paused" "the worker's declared pause wins"
  assert_not_contains "$out" "state: done" "an inferred done must not overrule a declared pause"
  assert_contains "$out" "worker declares it is not done" "the contradiction is stated"
  pass "declared pause beats a done this reader only inferred"
}

# But a terminal outcome recorded by no-mistakes itself is not an inference, so
# a stale pause does not suppress it.
test_declared_pause_does_not_beat_recorded_outcome() {
  reset_fakes
  local d; d=$(new_case pause-vs-outcome)
  make_repo_on_branch "$d/wt" fm/feat-pauseoutcome
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-pauseoutcome.meta" "window=fm:fm-feat-pauseoutcome" "worktree=$d/wt" "kind=ship"
  printf 'paused: waiting on CI\n' > "$d/state/feat-pauseoutcome.status"
  FM_FAKE_AXI_STATUS="$(run_passed fm/feat-pauseoutcome)"
  FM_FAKE_RUNS_LIST="  completed    fm/feat-pauseoutcome ${FM_FAKE_RUN_HEAD:0:8}  2026-08-20 13:36"
  local out; out=$(run_crew_state "$d" feat-pauseoutcome)
  assert_contains "$out" "state: done" "a recorded outcome still wins over a stale pause"
  pass "declared pause does not suppress a recorded terminal outcome"
}

# Currency, direction one: `axi status` handed back a run that a newer run for
# the same branch has already superseded, and the superseded one had failed.
# Reporting that failure upward is the 2026-08-20 false-red.
test_superseded_failed_run_does_not_report_failure() {
  reset_fakes
  local d; d=$(new_case superseded-failed)
  make_repo_on_branch "$d/wt" fm/feat-superseded
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/feat-superseded.meta" "window=fm:fm-feat-superseded" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-superseded)"
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" feat-superseded
  # Newest row for this branch is a DIFFERENT, running run.
  FM_FAKE_RUNS_LIST=$(cat <<EOF
  running      fm/feat-superseded 9f9f9f9f  2026-08-20 13:36
  failed       fm/feat-superseded ${FM_FAKE_RUN_HEAD:0:8}  2026-08-20 12:53
EOF
)
  local out; out=$(run_crew_state "$d" feat-superseded)
  assert_contains "$out" "state: working" "a live newer run answers instead"
  assert_not_contains "$out" "state: failed" "a superseded run must not report a failure"
  pass "a failed run superseded by a newer run does not report failure"
}

# Currency, direction two: the attributed run is the newest for this branch but
# started before this worker was spawned, so it describes an earlier
# incarnation of the same task id. The worker's own signals answer instead.
test_run_predating_this_incarnation_is_not_terminal_authority() {
  reset_fakes
  local d; d=$(new_case earlier-incarnation)
  make_repo_on_branch "$d/wt" fm/feat-earlier
  make_fakebin "$d" >/dev/null
  local spawn_epoch stamp
  spawn_epoch=$(awk 'BEGIN { print 1787000000 }')
  fm_write_meta "$d/state/feat-earlier.meta" "window=fm:fm-feat-earlier" "worktree=$d/wt" "kind=ship" \
    "spawn_gen=s$spawn_epoch.123.456"
  printf 'working: rebuilding from a clean base\n' > "$d/state/feat-earlier.status"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-earlier)"
  # The run is the newest for the branch, but it started a day before the spawn.
  stamp=$(date -r $((spawn_epoch - 86400)) '+%Y-%m-%d %H:%M' 2>/dev/null \
    || date -d "@$((spawn_epoch - 86400))" '+%Y-%m-%d %H:%M')
  FM_FAKE_RUNS_LIST="  failed       fm/feat-earlier ${FM_FAKE_RUN_HEAD:0:8}  $stamp"
  local out; out=$(run_crew_state "$d" feat-earlier)
  assert_not_contains "$out" "state: failed" "a run from an earlier incarnation is not this task's failure"
  assert_contains "$out" "source: pane" "the worker's own signals answer instead"
  pass "a run predating this incarnation cannot report a terminal verdict"
}

# The same run, started after the spawn, keeps its authority - the guard must
# discriminate rather than blanket-suppressing terminal verdicts.
test_run_within_this_incarnation_keeps_terminal_authority() {
  reset_fakes
  local d; d=$(new_case current-incarnation)
  make_repo_on_branch "$d/wt" fm/feat-current
  make_fakebin "$d" >/dev/null
  local spawn_epoch stamp
  spawn_epoch=$(awk 'BEGIN { print 1787000000 }')
  fm_write_meta "$d/state/feat-current.meta" "window=fm:fm-feat-current" "worktree=$d/wt" "kind=ship" \
    "spawn_gen=s$spawn_epoch.123.456"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-current)"
  stamp=$(date -r $((spawn_epoch + 600)) '+%Y-%m-%d %H:%M' 2>/dev/null \
    || date -d "@$((spawn_epoch + 600))" '+%Y-%m-%d %H:%M')
  FM_FAKE_RUNS_LIST="  failed       fm/feat-current ${FM_FAKE_RUN_HEAD:0:8}  $stamp"
  local out; out=$(run_crew_state "$d" feat-current)
  assert_contains "$out" "state: failed" "a run from this incarnation still reports its failure"
  assert_contains "$out" "source: run-step" "and it stays the run-step verdict"
  pass "a run started within this incarnation keeps terminal authority"
}

test_terminal_run_without_runs_row_falls_back_to_worker() {
  reset_fakes
  local d; d=$(new_case terminal-no-row)
  make_repo_on_branch "$d/wt" fm/feat-terminal-no-row
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/terminal-no-row.meta" "window=fm:fm-terminal-no-row" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-terminal-no-row)"
  FM_FAKE_RUNS_EMPTY=1
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" terminal-no-row
  local out; out=$(run_crew_state "$d" terminal-no-row)
  assert_contains "$out" "state: working" "a terminal run without a current runs row falls back"
  assert_not_contains "$out" "state: failed" "an unattributed terminal row cannot report failure"
  pass "terminal run without a runs row falls back to worker state"
}

test_terminal_run_without_spawn_generation_falls_back() {
  reset_fakes
  local d; d=$(new_case terminal-no-spawn)
  make_repo_on_branch "$d/wt" fm/feat-terminal-no-spawn
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/terminal-no-spawn.meta" "window=fm:fm-terminal-no-spawn" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-terminal-no-spawn)"
  FM_FAKE_DISABLE_AUTO_INCAR=1
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" terminal-no-spawn
  local out; out=$(run_crew_state "$d" terminal-no-spawn)
  assert_contains "$out" "state: working" "a terminal run without spawn proof falls back"
  assert_not_contains "$out" "state: failed" "missing spawn proof cannot report failure"
  pass "terminal run without spawn proof falls back to worker state"
}

test_coarse_terminal_without_incarnation_proof_falls_back() {
  reset_fakes
  local d; d=$(new_case coarse-terminal-no-spawn)
  make_repo_on_branch "$d/wt" fm/feat-coarse-terminal
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/coarse-terminal.meta" "window=fm:fm-coarse-terminal" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_running fm/other-branch)"
  FM_FAKE_RUNS_LIST="  completed    fm/feat-coarse-terminal ${FM_FAKE_RUN_HEAD:0:8}  $(date '+%Y-%m-%d %H:%M')"
  FM_FAKE_DISABLE_AUTO_INCAR=1
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" coarse-terminal
  local out; out=$(run_crew_state "$d" coarse-terminal)
  assert_contains "$out" "state: working" "a coarse terminal result without spawn proof falls back"
  assert_not_contains "$out" "state: done" "coarse terminal state needs incarnation proof"
  pass "coarse terminal result also requires incarnation proof"
}

test_newer_same_head_run_supersedes_old_failure() {
  reset_fakes
  local d stamp; d=$(new_case newer-same-head)
  make_repo_on_branch "$d/wt" fm/feat-newer-same-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/newer-same-head.meta" "window=fm:fm-newer-same-head" "worktree=$d/wt" "kind=ship" "harness=claude"
  FM_FAKE_AXI_STATUS="$(run_failed fm/feat-newer-same-head)"
  stamp=$(date '+%Y-%m-%d %H:%M')
  FM_FAKE_RUNS_LIST=$(printf '  running      fm/feat-newer-same-head %s  %s\n  failed       fm/feat-newer-same-head %s  %s\n' \
    "${FM_FAKE_RUN_HEAD:0:8}" "$stamp" "${FM_FAKE_RUN_HEAD:0:8}" "$stamp")
  FM_FAKE_BUSY=1
  arm_busy_record "$d/state" newer-same-head
  local out; out=$(run_crew_state "$d" newer-same-head)
  assert_contains "$out" "state: working" "the newer healthy run and worker win"
  assert_not_contains "$out" "state: failed" "an older same-head failure cannot win"
  pass "newer same-head run supersedes an older failure"
}

test_marker_prefix_collision_is_not_pipeline_output() {
  reset_fakes
  local d; d=$(new_case ci-prefix-collision)
  make_repo_on_branch "$d/wt" fm/feat-prefix-collision
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/prefix-collision.meta" "window=fm:fm-prefix-collision" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-prefix-collision)"
  FM_FAKE_CI_LOGS=$(printf '%s\n%s\n' \
    'CI checks running, waiting for results...' \
    '"all CI checks passed" is the marker being audited, not the result')
  local out; out=$(run_crew_state "$d" prefix-collision)
  assert_contains "$out" "state: working" "a marker prefix inside prose is not pipeline output"
  assert_not_contains "$out" "checks green" "a prefix collision cannot claim checks green"
  pass "marker prefix collision is not treated as pipeline output"
}

test_ci_marker_mapping_by_input() {
  local name marker suites_kind want d out
  while IFS='|' read -r name marker suites_kind want; do
    reset_fakes
    d=$(new_case "ci-marker-$name")
    make_repo_on_branch "$d/wt" "fm/feat-marker-$name"
    make_fakebin "$d" >/dev/null
    fm_write_meta "$d/state/marker-$name.meta" "window=fm:fm-marker-$name" "worktree=$d/wt" "kind=ship"
    FM_FAKE_AXI_STATUS="$(run_ci_monitoring "fm/feat-marker-$name")"
    FM_FAKE_CI_LOGS=$marker
    case "$suites_kind" in
      green) FM_FAKE_CHECK_SUITES=$(suites_green) ;;
      gated) FM_FAKE_CHECK_SUITES=$(suites_gated) ;;
    esac
    out=$(run_crew_state "$d" "marker-$name")
    assert_contains "$out" "state: $want" "$name marker maps to $want"
  done <<'EOF'
passed|all CI checks passed - still monitoring until merged or closed|green|done
running|CI checks running, waiting for results...|green|working
failed|checks failed|green|working
issues-detected|issues detected: merge conflict - auto-fixing (attempt 2/10)...|green|working
re-armed|base branch advanced (aaaaaaa..bbbbbbb), re-arming CI monitor timeout|green|working
skipped-ci|skipping CI: gh CLI is not authenticated|gated|working
EOF
  pass "every supported CI marker maps by its complete input"
}

test_forge_head_must_match_attributed_run() {
  reset_fakes
  local d; d=$(new_case forge-head-mismatch)
  make_repo_on_branch "$d/wt" fm/feat-forge-head
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/forge-head.meta" "window=fm:fm-forge-head" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-forge-head)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  FM_FAKE_PR_HEAD=ffffffffffffffffffffffffffffffffffffffff
  FM_FAKE_CHECK_SUITES=$(suites_green)
  local out; out=$(run_crew_state "$d" forge-head)
  assert_contains "$out" "state: working" "checks from a different PR head are ignored"
  assert_not_contains "$out" "checks green" "another head cannot make this run green"
  pass "forge verdict is bound to the attributed run head"
}

test_checks_passed_without_ci_reports_unverified() {
  reset_fakes
  local d; d=$(new_case checks-passed-no-ci)
  make_repo_on_branch "$d/wt" fm/feat-checks-passed-no-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/checks-passed-no-ci.meta" "window=fm:fm-checks-passed-no-ci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-checks-passed-no-ci)"
  FM_FAKE_CHECK_SUITES=$(suites_none)
  local out; out=$(run_crew_state "$d" checks-passed-no-ci)
  assert_contains "$out" "state: done" "trusted no-CI completion does not wait forever"
  assert_contains "$out" "nothing verified this change" "trusted no-CI completion is unverified"
  assert_not_contains "$out" "checks green" "zero checks are not green"
  pass "checks-passed with no CI reports unverified completion"
}

test_checks_passed_with_real_checks_is_green() {
  reset_fakes
  local d; d=$(new_case checks-passed-green)
  make_repo_on_branch "$d/wt" fm/feat-checks-passed-green
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/checks-passed-green.meta" "window=fm:fm-checks-passed-green" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_checks_passed fm/feat-checks-passed-green)"
  FM_FAKE_CHECK_SUITES=$(suites_green)
  local out; out=$(run_crew_state "$d" checks-passed-green)
  assert_contains "$out" "state: done" "checks-passed with real checks is done"
  assert_contains "$out" "checks green" "real passing checks keep the green path"
  pass "checks-passed with real checks stays green"
}

test_published_pr_with_skipped_ci_is_not_terminal_disposition() {
  reset_fakes
  local d; d=$(new_case published-pr-skipped-ci)
  make_repo_on_branch "$d/wt" fm/feat-published-skipped-ci
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/published-skipped-ci.meta" "window=fm:fm-published-skipped-ci" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_passed_pr_published_ci_skipped fm/feat-published-skipped-ci)"
  local out; out=$(run_crew_state "$d" published-skipped-ci)
  assert_contains "$out" "PR published" "the completed PR step proves publication"
  assert_not_contains "$out" "merged" "skipped CI does not prove a merge"
  assert_not_contains "$out" "closed unmerged" "skipped CI does not prove closure"
  pass "published PR with skipped CI has no invented disposition"
}

test_paginated_check_suites_include_later_failure() {
  reset_fakes
  local d i page_one all_pages
  d=$(new_case paginated-check-suites)
  make_repo_on_branch "$d/wt" fm/feat-paginated-suites
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/paginated-suites.meta" "window=fm:fm-paginated-suites" "worktree=$d/wt" "kind=ship"
  FM_FAKE_AXI_STATUS="$(run_ci_monitoring fm/feat-paginated-suites)"
  FM_FAKE_CI_LOGS="no CI checks reported - still monitoring until merged or closed"
  page_one=31
  i=0
  while [ "$i" -lt 30 ]; do
    page_one="$page_one
completed|success|1"
    i=$((i + 1))
  done
  all_pages="$page_one
completed|action_required|0"
  FM_FAKE_CHECK_SUITES_PAGE_1=$page_one
  FM_FAKE_CHECK_SUITES_ALL=$all_pages
  local out; out=$(run_crew_state "$d" paginated-suites)
  assert_contains "$out" "state: working" "a later non-passing suite keeps CI pending"
  assert_not_contains "$out" "checks green" "page one alone cannot establish green"
  pass "all check-suite pages contribute to the verdict"
}

test_active_run_is_authoritative
test_stale_needs_decision_superseded
test_stale_blocked_superseded
test_genuine_parked_not_superseded
test_scalar_gate_parked_not_superseded
test_gate_block_parked_not_superseded
test_ci_ready_done_log_beats_monitoring_run
test_ci_monitoring_checks_green_surfaces_done
test_top_level_ci_checks_green_surfaces_done
test_no_checks_marker_awaiting_approval_is_not_green
test_both_no_checks_spellings_agree
test_no_checks_marker_no_ci_configured_reports_unverified
test_no_checks_marker_with_passing_checks_is_green
test_no_checks_marker_unreadable_forge_is_not_green
test_no_checks_marker_failing_forge_call_is_not_green
test_passed_marker_without_forge_is_not_terminal
test_agent_prose_is_not_read_as_a_marker
test_ci_monitoring_green_then_rearm_stays_working
test_ci_monitoring_no_checks_yet_stays_working
test_ci_monitoring_still_waiting_stays_working
test_ci_monitoring_green_then_new_issue_stays_working
test_ci_ready_done_log_relapse_stays_working
test_ci_fixing_after_green_stays_working
test_top_level_fixing_ci_running_after_green_stays_working
test_top_level_fixing_done_log_stays_working
test_terminal_passed
test_terminal_failed
test_cross_branch_attribution_via_runs_list
test_cross_branch_attribution_picks_most_recent_row
test_coarse_run_does_not_promote_ready_status_without_forge
test_other_branch_run_ignored
test_no_run_busy_pane
test_no_run_footer_text_alone_is_not_working
test_no_run_grok_uses_isolated_fallback
test_no_run_herdr_unknown_uses_backend_capture
test_no_run_herdr_idle_agent_status_outranked_by_record
test_no_run_herdr_idle_agent_status_and_idle_record_stays_idle
test_no_run_idle_pane_uses_log
test_no_run_idle_pane_uses_keyed_log
test_no_run_idle_pane_paused
test_no_run_idle_pane_custom_paused_verb
test_no_run_idle_secondmate_resolved_event_not_state
test_dead_window_ignores_stale_status_log
test_dead_window_still_reports_terminal_run_step
test_dead_window_still_reports_active_run_step
test_no_timeout_uses_perl_bound
test_scout_skips_run_lookup
test_torn_down_worktree
test_remote_alive_with_log_uses_status_log
test_remote_alive_idle_is_healthy_not_gone
test_remote_unreachable_is_unknown_remote_not_dead
test_remote_dead_reports_remote_verdict
test_missing_meta
test_provably_working_via_runs_list_fallback
test_not_provably_working_when_stopped
test_usage_error
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_missing_run_head_falls_back_to_current_state
test_passed_run_with_skipped_publish_claims_no_pr
test_passed_run_with_published_pr_names_it
test_passed_run_names_a_merge_when_the_log_records_one
test_passed_run_names_a_close_when_the_log_records_one
test_skipping_ci_marker_is_settled_at_the_forge
test_declared_pause_beats_inferred_done
test_declared_pause_does_not_beat_recorded_outcome
test_superseded_failed_run_does_not_report_failure
test_run_predating_this_incarnation_is_not_terminal_authority
test_run_within_this_incarnation_keeps_terminal_authority
test_terminal_run_without_runs_row_falls_back_to_worker
test_terminal_run_without_spawn_generation_falls_back
test_coarse_terminal_without_incarnation_proof_falls_back
test_newer_same_head_run_supersedes_old_failure
test_marker_prefix_collision_is_not_pipeline_output
test_ci_marker_mapping_by_input
test_forge_head_must_match_attributed_run
test_checks_passed_without_ci_reports_unverified
test_checks_passed_with_real_checks_is_green
test_published_pr_with_skipped_ci_is_not_terminal_disposition
test_paginated_check_suites_include_later_failure

echo "all fm-crew-state tests passed"
