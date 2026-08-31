#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/blocked/paused/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|done|blocked|paused|failed|unknown> · source: <run-step|pane|status-log|remote-endpoint|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta. A meta
#      recording remote_host= is a remote secondmate: its worktree and endpoint
#      live on that host, so the local worktree and pane reads are skipped and
#      the remote host is asked for the endpoint's recovery-grade state
#      (fm-on.sh + fm-remote-secondmate-control.sh state). alive falls through
#      to the routed status log; dead/missing report the remote verdict; an
#      unreachable or unreadable remote reports unknown-remote, never a false
#      gone/dead.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. Three limits
#      bound that authority, each of which this reader learned the hard way:
#        - While the active step is ci, `axi status` alone cannot tell "still
#          waiting on checks" from "checks green, waiting on merge", so CI
#          readiness comes from the ci step's log settled against the forge
#          (nm_ci_checks_state). A green reading raises working -> done; a
#          "no checks at all" reading NEVER does, and a PR the forge says has
#          no CI at all is reported as exactly that, never as green.
#        - A terminal verdict must prove it describes the CURRENT incarnation
#          of the task before it may outrank the worker's own live signals
#          (nm_run_is_current_incarnation).
#        - A `done` this reader INFERRED from CI, as opposed to one no-mistakes
#          recorded as the run's outcome, loses to the worker's own declared
#          `paused:` line: the worker saying "I am waiting and not finished"
#          outranks an inference about a surface that has misreported before.
#      What a finished run PUBLISHED is read from its pr step and pr field, not
#      inferred from the outcome (nm_publication_detail): a run whose publishing
#      steps were skipped published nothing, which is a different fact from a
#      pull request that reached a terminal disposition.
#   3. Reconcile the status log: if its last line says needs-decision/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend's pane busy state, then the status log's last line only
#      when its verb maps to a recognized run-state. Decision-only events such as
#      `resolved` never become current state or detail.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead endpoint also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=${FM_CREW_STATE_NM_TIMEOUT:-10}
case "$NM_TIMEOUT" in ''|*[!0-9]*) NM_TIMEOUT=10 ;; esac
# How many of the most recent `no-mistakes runs` rows the cross-branch fallback
# (nm_runs_status_for_branch, below) scans. Generous enough to still find a
# branch's own run on a busy multi-crew fleet without listing the entire
# history every call.
FM_CREW_STATE_RUNS_LIMIT=${FM_CREW_STATE_RUNS_LIMIT:-200}
case "$FM_CREW_STATE_RUNS_LIMIT" in ''|*[!0-9]*) FM_CREW_STATE_RUNS_LIMIT=200 ;; esac
# Hard bound on the one forge call this reader may make (see
# forge_zero_check_verdict). It fires only when the ci log claims a state that
# would end the wait, never on the ordinary still-validating path.
FORGE_TIMEOUT=${FM_CREW_STATE_FORGE_TIMEOUT:-8}
case "$FORGE_TIMEOUT" in ''|*[!0-9]*|0) FORGE_TIMEOUT=8 ;; esac
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
HARNESS=$(meta_value harness)
REMOTE_HOST=$(meta_value remote_host)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read. A
# remote secondmate's recorded worktree is a path on ITS host, so the local
# probe proves nothing for it - the remote arm below reads the true source.
if [ -z "$REMOTE_HOST" ] && { [ -z "$WT" ] || [ ! -d "$WT" ]; }; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
# Map a status-log verb onto a canonical state for the fallback path. `paused` is
# the deliberate-external-wait verb (fm-classify-lib.sh's FM_CLASSIFY_PAUSED_VERB):
# a crew with no active run and an idle pane that declared a known external wait
# reports `paused` distinctly, so a supervisor reading this sees a declared pause
# and its reason rather than a wedge-suspect idle.
map_log_state() {  # <line>
  if status_is_paused "$1"; then
    echo paused
    return
  fi
  case "$(status_line_verb "$1")" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(status_line_verb "$LOG_LINE")

# --- remote secondmate: the true source is the remote endpoint ---------------
# A remote mate's recorded worktree and backend target live on its own host, so
# the local worktree probe above and the local pane reads below would misreport
# a healthy remote mate as gone or dead. Ask the remote host for the endpoint's
# recovery-grade state over the same fm-on.sh transport fm-send uses, then read
# current activity from the routed status log exactly as for a local
# secondmate (an idle endpoint is healthy for a secondmate either way). An
# unreachable host or unreadable endpoint is reported as unknown-remote -
# explicitly NOT proof of death - so a transport blip never reads as a torn
# down or dead mate; only the remote host's own dead/missing verdict may say
# the endpoint is actually gone.
if [ -n "$REMOTE_HOST" ]; then
  if ! REMOTE_STATE=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-on.sh" "$ID" \
    fm-remote-secondmate-control.sh state "$ID" < /dev/null 2>/dev/null); then
    REMOTE_STATE=
  fi
  REMOTE_STATE=$(printf '%s\n' "$REMOTE_STATE" | tail -1)
  case "$REMOTE_STATE" in
    alive)
      if [ -n "$LOG_VERB" ]; then
        LOG_STATE=$(map_log_state "$LOG_LINE")
        if [ "$LOG_STATE" != unknown ]; then
          emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")${SEP}remote endpoint alive on $REMOTE_HOST"
        fi
      fi
      emit unknown remote-endpoint "alive on $REMOTE_HOST (an idle secondmate is healthy)"
      ;;
    dead|missing)
      emit unknown remote-endpoint "remote endpoint $REMOTE_STATE on $REMOTE_HOST"
      ;;
    '')
      emit unknown remote-endpoint "unknown-remote: $REMOTE_HOST unreachable or endpoint unreadable (not proof of death)"
      ;;
    *)
      emit unknown remote-endpoint "unknown-remote: endpoint state '$REMOTE_STATE' on $REMOTE_HOST (not proof of death)"
      ;;
  esac
fi

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose endpoint has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown. Backend-aware
# (fm_backend_of_meta defaults absent backend= to tmux, the P1 contract): a
# herdr task is read through fm_backend_capture instead of a bare tmux probe.
TASK_BACKEND=$(fm_backend_of_meta "$META")
BACKEND_TARGET=$(fm_backend_target_of_meta "$META")
EXPECTED_LABEL="fm-$ID"
pane_readable() {  # <target>
  case "$TASK_BACKEND" in
    tmux) tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 ;;
    *) fm_backend_capture "$TASK_BACKEND" "$1" 1 "$EXPECTED_LABEL" >/dev/null 2>&1 ;;
  esac
}
# crew_busy_verdict: the crew's semantic busy state from the one contract
# owner (bin/fm-busy-lib.sh), as "<busy|idle|unknown> <source>". A converted
# adapter answers from its own lifecycle record; Grok answers from its
# isolated rendered-tail fallback; a herdr crew's native `busy` is accepted
# when no record exists, but its native `idle` is NOT, because agent.get
# reports generation state (idle while a crew blocks on its own long-running
# foreground tool call) rather than turn state.
crew_busy_verdict() {  # <target>
  local tail40=''
  case "$HARNESS" in
    grok*) tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 "$EXPECTED_LABEL" 2>/dev/null) || tail40='' ;;
  esac
  fm_busy_classify "$TASK_BACKEND" "$1" "$HARNESS" "$ID" "$STATE" "$tail40"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --
# trim, strip_quotes, the bounded nm_run call, nm_field's TOON parse, and the
# branch+head attribution rule below are thin wrappers over the ONE owner in
# bin/fm-nm-run-lib.sh, shared with fm-teardown.sh's pre-teardown run abort.

trim() { fm_nm_trim "$@"; }
strip_quotes() { fm_nm_strip_quotes "$@"; }
nm_run() {  # <args...>
  fm_nm_run "$WT" "$NM_TIMEOUT" "$@"
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  fm_nm_field "$RUN_OUT" "$1"
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(status_line_note "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

# Status word of one row in the run's steps[] table, e.g. "completed",
# "skipped", "running". Empty when the run object carries no such row.
nm_step_status() {  # <step-name>
  local row rest
  row=$(printf '%s\n' "$RUN_OUT" | grep -E "^[[:space:]]*$1,[[:space:]]*\"?[a-z_]+\"?[[:space:]]*," | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  rest=${row#*,}
  strip_quotes "$(trim "${rest%%,*}")"
}

nm_ci_step_status() {
  local step_status
  step_status=$(nm_step_status ci)
  case "$step_status" in running|fixing) printf '%s' "$step_status" ;; esac
}

# What a finished run actually PUBLISHED, as the tail of "run passed: ...".
#
# A run can finish with its publishing steps deliberately skipped - the
# supported --skip flags, or a contribution model that forbids opening the pull
# request yet - and `outcome: passed` says nothing about which. Inferring
# publication from the outcome once produced "run passed: PR merged/closed" for
# a run whose push, pr and ci steps had all been SKIPPED and for which no pull
# request existed anywhere: a positive claim about an artifact that was never
# created. Skipped, succeeded, merged and closed-unmerged are four different
# facts, so this reads the pr step and the run's own pr field instead.
#
# Merged vs closed-unmerged comes from the ci log (nm_ci_pr_disposition), not
# from the outcome, and when the log cannot say the wording stays honestly
# ambiguous rather than claiming a merge that may not have happened.
nm_publication_detail() {
  local pr_step pr_url disposition
  pr_step=$(nm_step_status pr)
  pr_url=$(strip_quotes "$(nm_field pr)")
  if [ "$pr_step" = skipped ] || { [ -z "$pr_step" ] && [ -z "$pr_url" ]; }; then
    printf 'nothing published (publishing steps skipped)'
    return
  fi
  disposition=$(nm_ci_pr_disposition)
  [ -n "$disposition" ] || disposition='merged or closed unmerged'
  if [ -n "$pr_url" ]; then
    printf 'PR %s - %s' "$disposition" "$pr_url"
  else
    printf 'PR %s' "$disposition"
  fi
}

# Detail for a PR that no CI will ever verify. Deliberately shares no wording
# with the green case: this is the sentence a supervisor reads before deciding
# whether to merge something nothing has checked.
nm_no_ci_detail() {
  local pr_url
  pr_url=$(strip_quotes "$(nm_field pr)")
  if [ -n "$pr_url" ]; then
    printf 'no CI configured for this PR: nothing verified this change - %s' "$pr_url"
  else
    printf 'no CI configured for this PR: nothing verified this change'
  fi
}

nm_effective_ci_step_status() {
  local step_status
  if [ "${RUN_STATUS:-}" = fixing ]; then
    printf 'fixing'
    return 0
  fi
  step_status=$(nm_ci_step_status)
  if [ -n "$step_status" ]; then
    printf '%s' "$step_status"
    return 0
  fi
  if [ "${RUN_STATUS:-}" = ci ]; then
    printf 'running'
  fi
}

# --- CI readiness: what the ci step's log actually says ---------------------
#
# Root cause of the PR #252 incident (2026-07): for a repo where merge is left
# to the captain, no-mistakes' ci step (and therefore top-level status/outcome)
# stays "running" for the ENTIRE CI-monitor phase, including long after GitHub
# reports every check green - it only reaches outcome=passed once the PR is
# actually merged (or closed). `axi status`'s steps[] table never distinguishes
# "still waiting on checks" from "checks green, waiting on merge": both read as
# plain `ci,running,...`. The only place that transition is recorded is the ci
# step's own log text, read here through `axi logs --step ci`.
#
# Root cause of the 2026-08 false-green incidents (PRs 1716, 1944, 2674): the
# marker "no CI checks reported - still monitoring until merged or closed" was
# mapped to green alongside the genuine "all CI checks passed", while the
# near-identical "no CI checks reported yet" was mapped to not-ready. Reading
# real ci logs shows the two no-checks spellings are NOT a "pending vs settled"
# pair: they interleave within one run (the "yet" form during the initial
# registration window, the other on every later poll that still sees nothing),
# and both are routinely followed by "CI checks running" once checks finally
# register. Both state the SAME fact - this poll saw zero checks - and neither
# is a pass. Mapping either to green was worst exactly where it was most
# dangerous: a head whose workflows await maintainer approval has had the LEAST
# verification of any state, and that is the normal state of a fork PR.
#
# So a marker is classified into the FACT it states, never straight into a
# verdict, and a zero-checks fact is then settled at the forge rather than
# guessed:
#   passed      - "all CI checks passed": every registered check succeeded.
#   zero-checks - either "no CI checks reported" spelling: nothing has run.
#   pending     - checks running, failing, being auto-fixed, or re-armed.
#   unknown     - no recognized marker in the log tail.
# Markers are matched whole-line (allowing TOON's optional leading quote) so a
# fix agent's own prose in the same log - it writes its verification notes
# there - cannot be mistaken for a pipeline marker.
nm_ci_marker_class() {  # <marker-line>
  case "$1" in
    *"all CI checks passed"*)  printf 'passed' ;;
    *"no CI checks reported"*) printf 'zero-checks' ;;
    *"skipping CI"*)           printf 'zero-checks' ;;
    *) printf 'pending' ;;
  esac
}

# The last disposition the ci monitor recorded for the PR it was watching, as
# "merged", "closed", or empty. no-mistakes records outcome=passed for BOTH a
# merged PR and one closed unmerged (verified 2026-08-21 against runs
# 01KZ73S79TQDSZZ219P9QFGW4H and 01M08SMZF23P3X6C81Z8445G5M, whose PRs were
# closed unmerged and whose runs still finished passed), so the outcome cannot
# tell them apart and only the ci log can.
nm_ci_pr_disposition() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || return 0
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || return 0
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E '^[[:space:]]*"?PR has been (merged|closed)' | tail -1)
  case "$marker" in
    *"has been merged"*) printf 'merged' ;;
    *"has been closed"*) printf 'closed unmerged' ;;
  esac
}

# Owner/repo/number of a GitHub pull request URL, as "<owner>/<repo> <number>".
# Empty for anything that is not a github.com PR URL, so a GitLab or other
# forge URL degrades to "cannot tell" rather than being probed wrongly.
forge_pr_coordinates() {  # <pr-url>
  local url=$1 rest owner repo number
  case "$url" in
    https://github.com/*/*/pull/*) rest=${url#https://github.com/} ;;
    *) return 0 ;;
  esac
  owner=${rest%%/*}; rest=${rest#*/}
  repo=${rest%%/*};  rest=${rest#*/}
  case "$rest" in pull/*) number=${rest#pull/} ;; *) return 0 ;; esac
  number=${number%%/*}
  case "$owner$repo$number" in ''|*' '*) return 0 ;; esac
  case "$number" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s/%s %s' "$owner" "$repo" "$number"
}

# Settle a zero-checks reading against the forge itself, echoing one of:
#   no-ci-configured - the head has NO check suites: nothing can ever arrive.
#   ci-pending       - check suites exist but have produced no passing result,
#                      including the approval-gated case that started this bug.
#   green            - every suite completed successfully with runs behind it.
#   unknown          - gh missing, not a GitHub PR, or the call failed.
# One bounded call to `commits/<sha>/check-suites` answers all of it: the
# documented response carries total_count plus each suite's status, conclusion,
# and latest_check_runs_count (GitHub REST "List check suites for a Git
# reference", API version 2022-11-28). The docs do not say what a repo with no
# CI returns; verified empirically 2026-08-21 that it is total_count 0
# (kunchenguid/firstmate PR 2674 head 3d398129, the head of the 2026-08-20
# false-green), while an approval-gated head returns suites at
# conclusion=action_required with latest_check_runs_count 0 (PR 2747 head
# 681a637c). The verdict deliberately turns on the STRUCTURE - are there
# suites, did they finish, did they produce runs - so it does not depend on
# GitHub's conclusion vocabulary staying fixed; the conclusion is read only to
# say WHY in the detail line.
forge_zero_check_verdict() {  # <pr-url> -> verdict[ <detail>]
  local url=$1 coords repo number sha suites total unfinished=0 runs=0 gated=0
  command -v gh >/dev/null 2>&1 || { printf 'unknown'; return; }
  coords=$(forge_pr_coordinates "$url")
  [ -n "$coords" ] || { printf 'unknown'; return; }
  repo=${coords%% *}
  number=${coords##* }
  sha=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/pulls/$number" --jq .head.sha) || sha=
  sha=$(trim "$sha")
  [ -n "$sha" ] || { printf 'unknown'; return; }
  suites=$(fm_run_timed "$FORGE_TIMEOUT" gh api "repos/$repo/commits/$sha/check-suites" \
    --jq '.total_count, (.check_suites[] | "\(.status)|\(.conclusion)|\(.latest_check_runs_count)")') || suites=
  total=$(printf '%s\n' "$suites" | head -1)
  case "$total" in ''|*[!0-9]*) printf 'unknown'; return ;; esac
  [ "$total" = 0 ] && { printf 'no-ci-configured'; return; }
  local status conclusion count
  while IFS='|' read -r status conclusion count; do
    [ -n "$status" ] || continue
    case "$status" in completed) ;; *) unfinished=1 ;; esac
    case "$conclusion" in success|skipped|neutral) ;; *) unfinished=1 ;; esac
    case "$conclusion" in action_required) gated=1 ;; esac
    case "$count" in ''|*[!0-9]*) ;; *) runs=$((runs + count)) ;; esac
  done <<EOF
$(printf '%s\n' "$suites" | tail -n +2)
EOF
  if [ "$unfinished" = 0 ] && [ "$runs" -gt 0 ]; then
    printf 'green'
    return
  fi
  if [ "$gated" = 1 ]; then
    printf 'ci-pending awaiting maintainer approval, no checks have run'
    return
  fi
  printf 'ci-pending no checks have reported yet'
}

# Current CI readiness for the monitoring ci step, as "<state>[ <detail>]":
#   green            - checks ran and passed; only merge/close is outstanding.
#   no-ci-configured - the PR has no CI at all, so nothing will ever verify it.
#   not-ready        - checks can still arrive, or we could not prove otherwise.
#   unknown          - the ci log told us nothing either way.
# The log is append-only and chronological, so the LAST recognized marker is
# the current one. A marker that would end the wait (passed or zero-checks) is
# confirmed at the forge before it is believed, because both of this reader's
# reported incidents came from believing such a marker. When the forge cannot
# answer, a "passed" marker keeps its own verdict - it is itself derived from
# the forge and has never been implicated - while a zero-checks marker never
# becomes green, because "we saw nothing" is not evidence of a pass.
nm_ci_checks_state() {
  local run_id log_tail marker class pr verdict
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" \
    | grep -E '^[[:space:]]*"?(all CI checks passed|no CI checks reported|skipping CI|CI checks running|checks failed|issues detected|base branch advanced.*re-arming CI monitor timeout)' \
    | tail -1)
  [ -n "$marker" ] || { printf 'unknown'; return; }
  class=$(nm_ci_marker_class "$marker")
  case "$class" in
    pending) printf 'not-ready'; return ;;
  esac
  pr=$(strip_quotes "$(nm_field pr)")
  verdict=$(forge_zero_check_verdict "$pr")
  case "${verdict%% *}" in
    green)            printf 'green' ;;
    no-ci-configured) printf 'no-ci-configured' ;;
    ci-pending)       printf 'not-ready %s' "${verdict#ci-pending }" ;;
    *)
      # Forge unreadable. Trust a passed marker, never a zero-checks one.
      if [ "$class" = passed ]; then printf 'green'
      else printf 'not-ready no checks reported and the forge could not be reached'
      fi
      ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <start-date> <start-time> [<pr-url>]"
# separated by runs of spaces (verified: no quoting, so splitting on successive
# whitespace runs is exact). The date column is the run's START, not its end:
# verified 2026-08-21 that run 01KZ4W4CKN3XT9F7ST0G7R92K2 lists as
# "2026-08-03 19:32" while its first step log was written at 19:33 and its last
# at 2026-08-04 15:40.
#
# One parser, two consumers: the coarse attribution fallback below, and the
# currency proof a terminal verdict must pass (nm_run_is_current_incarnation).
# Echoes this crew's branch rows, newest first, as
# "<status> <short-sha> <YYYY-MM-DD> <HH:MM>".
nm_branch_run_rows() {
  local out row st rest br sha day clock
  [ -n "$CREW_BRANCH" ] || return 0
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=$(trim "${row#* }")
    br=${rest%% *}
    rest=$(trim "${rest#* }")
    sha=${rest%% *}
    rest=$(trim "${rest#* }")
    day=${rest%% *}
    rest=$(trim "${rest#* }")
    clock=${rest%% *}
    [ "$br" = "$CREW_BRANCH" ] || continue
    printf '%s %s %s %s\n' "$st" "$sha" "$day" "$clock"
  done <<< "$out"
  return 0
}

# Coarse status word (running/completed/cancelled/failed) of the most recent
# run for this crew's branch whose head still binds to the worktree, or empty
# when the branch has no such run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {
  local st sha
  while read -r st sha _; do
    # Same code-identity rule as axi status: skip a same-branch row whose
    # short-sha does not match this worktree (rewritten or advanced tip).
    nm_coarse_head_matches_worktree "$sha" || continue
    printf '%s' "$st"
    return 0
  done <<< "$(nm_branch_run_rows)"
  return 0
}

# 0 when two abbreviated shas name the same commit prefix. Under seven shared
# characters is not an identity claim and is rejected.
short_sha_eq() {  # <a> <b>
  local a=$1 b=$2 n
  [ -n "$a" ] && [ -n "$b" ] || return 1
  n=${#a}
  [ "${#b}" -lt "$n" ] && n=${#b}
  [ "$n" -ge 7 ] || return 1
  [ "${a:0:$n}" = "${b:0:$n}" ]
}

# This worker incarnation's spawn time, formatted exactly as `no-mistakes runs`
# prints a run's start ("YYYY-MM-DD HH:MM", local). Empty when the meta predates
# spawn_gen= or the host's date cannot format an epoch, which simply means the
# incarnation test below cannot run. BSD date takes -r <epoch>; GNU date reads
# -r as a reference FILE and fails, so it is served by the -d @<epoch> form.
spawn_generation_stamp() {
  local gen epoch
  gen=$(meta_value spawn_gen)
  epoch=${gen#s}
  epoch=${epoch%%.*}
  case "$epoch" in ''|*[!0-9]*) return 0 ;; esac
  date -r "$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null && return 0
  date -d "@$epoch" '+%Y-%m-%d %H:%M' 2>/dev/null || true
}

# Does the attributed run describe the CURRENT incarnation of this task?
#   0 - yes, or there is not enough evidence to say otherwise
#   1 - superseded: a newer run exists for this branch (NEWER_RUN_STATUS is set)
#   2 - it started before this worker was spawned, so it belongs to an earlier
#       incarnation of the same task id
#
# `axi status` answers with the active-or-most-recent run it can find for the
# branch, and it has twice handed back a run that did not describe the work in
# front of it: on 2026-08-14 a run released days earlier, for a worker spawned
# two minutes before, and on 2026-08-20 a run a newer run for the same branch
# had already superseded. Both were reported upward as a failure that had not
# happened. A run-step verdict therefore has to prove currency before it may
# outrank the worker's own live signals - but only when the verdict is
# terminal, so the ordinary still-validating read pays nothing for this.
NEWER_RUN_STATUS=""
nm_run_is_current_incarnation() {  # <run-head>
  local head=$1 newest st sha day clock stamp
  NEWER_RUN_STATUS=""
  newest=$(nm_branch_run_rows | head -1)
  [ -n "$newest" ] || return 0
  st=${newest%% *};    newest=${newest#* }
  sha=${newest%% *};   newest=${newest#* }
  day=${newest%% *};   newest=${newest#* }
  clock=${newest%% *}
  if ! short_sha_eq "$head" "$sha"; then
    NEWER_RUN_STATUS=$st
    return 1
  fi
  stamp=$(spawn_generation_stamp)
  [ -n "$stamp" ] && [ -n "$day" ] && [ -n "$clock" ] || return 0
  # "YYYY-MM-DD HH:MM" compares lexicographically exactly as it does
  # chronologically, so no epoch arithmetic and no timezone handling is needed.
  [[ "$day $clock" < "$stamp" ]] && return 2
  return 0
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rule owned by
# fm_nm_head_matches_worktree in bin/fm-nm-run-lib.sh.
nm_run_head_matches_worktree() {
  local run_head
  run_head=$(strip_quotes "$(nm_field head)")
  fm_nm_head_matches_worktree "$WT" "$run_head"
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  fm_nm_head_matches_worktree "$WT" "$1"
}

HAVE_RUN=0
# RUN_SOURCE distinguishes the two ways HAVE_RUN=1 can happen: "full" means
# $RUN_OUT is real `axi status` TOON with step/gate detail; "coarse" means only
# a bare status word came back from the runs-list fallback above, so the
# run-step block below skips the TOON field parsing entirely for this crew.
RUN_SOURCE=full
COARSE_STATUS=""
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      COARSE_STATUS=$(nm_runs_status_for_branch)
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  RUN_STATE=working
  RUN_DETAIL=""
  CI_STEP_STATUS=""
  CI_LOG_STATE=""
  RUN_STATUS=""
  # 1 only when `done` was INFERRED from the CI surface rather than recorded by
  # no-mistakes itself as the run's own outcome. The distinction decides
  # whether a worker's declared pause may overrule it below.
  RUN_DONE_INFERRED=0
  if [ "$RUN_SOURCE" = coarse ]; then
    # No step/gate detail is available from the plain runs list - only ever
    # true/working, done, or failed. A crew genuinely parked at a gate still
    # gets full detail once `axi status` reports its own branch again (e.g.
    # once its own step is the most-recently-touched one), and its own
    # needs-decision/blocked status-log append (a captain-relevant VERB) is
    # surfaced through signal_reason_is_actionable regardless of this
    # coarse-vs-full distinction, so a real gate is never silently missed.
    case "$COARSE_STATUS" in
      running)   RUN_STATE=working; RUN_DETAIL="validating (background run)" ;;
      completed) RUN_STATE="done";  RUN_DETAIL="run completed" ;;
      failed)    RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled) RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      *)         RUN_STATE=unknown; RUN_DETAIL="runs list status: $COARSE_STATUS" ;;
    esac
  else
    status=$(strip_quotes "$(nm_field status)")
    RUN_STATUS=$status
    outcome=$(strip_quotes "$(nm_field outcome)")
    awaiting=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*awaiting_agent:' | head -1 || true)
    gate_status=$(nm_gate_status)
    has_gate=0
    nm_has_gate && has_gate=1

    if [ -n "$outcome" ]; then
      case "$outcome" in
        passed)        RUN_STATE="done"; RUN_DETAIL="run passed: $(nm_publication_detail)" ;;
        checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
        failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
        cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
        *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
      esac
    elif [ -n "$awaiting" ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
      if [ "$has_gate" = 1 ]; then
        gate=$(nm_gate_line_name)
      else
        gate=$(nm_gate_name)
      fi
      [ -n "$gate" ] || gate=$status
      [ -n "$gate" ] || gate=gate
      RUN_STATE=parked
      RUN_DETAIL="parked at $gate"
      fcount=$(nm_gate_findings_count)
      [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
      if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
        RUN_DETAIL="$RUN_DETAIL (ask-user: authority decision)"
      fi
    else
      case "$status" in
        ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
        running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
        completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
        failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
        cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
        "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
        *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
      esac
      if [ "$RUN_STATE" = working ]; then
        CI_STEP_STATUS=$(nm_effective_ci_step_status)
        case "$CI_STEP_STATUS" in
          running)
            CI_LOG_STATE=$(nm_ci_checks_state)
            case "${CI_LOG_STATE%% *}" in
              green)
                RUN_STATE="done"
                RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
                RUN_DONE_INFERRED=1
                ;;
              no-ci-configured)
                RUN_STATE="done"
                RUN_DETAIL="$(nm_no_ci_detail)"
                RUN_DONE_INFERRED=1
                ;;
              not-ready)
                [ "$CI_LOG_STATE" = not-ready ] \
                  || RUN_DETAIL="$RUN_DETAIL${SEP}${CI_LOG_STATE#not-ready }"
                ;;
            esac
            ;;
          fixing)
            CI_LOG_STATE=not-ready
            ;;
        esac
      fi
    fi
  fi

  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    if [ "$RUN_SOURCE" = coarse ]; then
      emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
    fi
    [ -n "$CI_STEP_STATUS" ] || CI_STEP_STATUS=$(nm_effective_ci_step_status)
    if [ "$RUN_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    elif [ "$CI_STEP_STATUS" = running ] && [ -z "$CI_LOG_STATE" ]; then
      CI_LOG_STATE=$(nm_ci_checks_state)
    elif [ "$CI_STEP_STATUS" = fixing ]; then
      CI_LOG_STATE=not-ready
    fi
    case "${CI_LOG_STATE%% *}" in
      not-ready)
        # The worker reported checks green, and the ci step's own reading says
        # they are not. Never relay a claim the pipeline contradicts.
        ;;
      no-ci-configured)
        # The worker's wording ("checks green") is wrong here and must not be
        # passed on to a supervisor; state what is actually true instead.
        emit "done" run-step "$(nm_no_ci_detail)"
        ;;
      *)
        emit "done" status-log "$(status_line_note "$LOG_LINE")${SEP}run still monitoring PR"
        ;;
    esac
  fi

  # A terminal verdict must prove it describes the CURRENT incarnation before
  # it is reported as this task's state (see nm_run_is_current_incarnation).
  # A superseded reading is replaced by the newer run's own coarse status; a
  # reading from an earlier incarnation is dropped entirely, leaving the worker's
  # own live signals below to answer, which is what firstmate had to do by hand
  # both times this misfired.
  if [ "$RUN_SOURCE" = full ] && { [ "$RUN_STATE" = failed ] || [ "$RUN_STATE" = "done" ]; }; then
    CURRENCY_RC=0
    nm_run_is_current_incarnation "$(strip_quotes "$(nm_field head)")" || CURRENCY_RC=$?
    SUPERSEDED_DETAIL="$RUN_STATE - $RUN_DETAIL"
    case "$CURRENCY_RC" in
      1)
        case "$NEWER_RUN_STATUS" in
          running)          RUN_STATE=working; RUN_DETAIL="validating (newer run for this branch)" ;;
          completed)        RUN_STATE="done";  RUN_DETAIL="newer run for this branch completed" ;;
          failed|cancelled) RUN_STATE=failed;  RUN_DETAIL="newer run for this branch $NEWER_RUN_STATUS" ;;
          *)                HAVE_RUN=0 ;;
        esac
        [ "$HAVE_RUN" = 1 ] && RUN_DETAIL="$RUN_DETAIL${SEP}superseded reading: $SUPERSEDED_DETAIL"
        ;;
      2) HAVE_RUN=0 ;;
    esac
  fi
fi

if [ "$HAVE_RUN" = 1 ]; then
  # A declared pause outranks an INFERRED done. `done` reached through the CI
  # surface is this reader's own inference about a surface that has been wrong
  # in both directions; `paused:` is the worker's explicit statement that it is
  # waiting and NOT finished. On 2026-08-20 exactly such an inference overruled
  # a worker's "paused ... NOT done" line and queued the task for the captain as
  # a finished outcome on a pull request nothing had verified. A terminal
  # outcome recorded by no-mistakes itself is not an inference and still wins.
  if [ "$RUN_STATE" = "done" ] && [ "$RUN_DONE_INFERRED" = 1 ] && status_is_paused "$LOG_LINE"; then
    emit paused status-log \
      "$(status_line_note "$LOG_LINE")${SEP}worker declares it is not done; CI reading says $RUN_DETAIL"
  fi

  # Reconcile the status log. A needs-decision/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run) is deterministically
  # stale: the gate resolved and the run resumed or finished.
  case "$LOG_VERB" in
    needs-decision|blocked)
      if [ "$RUN_STATE" != parked ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable target means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$BACKEND_TARGET" ] || emit unknown none "no backend target recorded"
pane_readable "$BACKEND_TARGET" || emit unknown none "backend target gone: $BACKEND_TARGET"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# state is not meaningful for them; read their state from the status log only.
# Only an exact busy verdict reports working here, and only an exact idle
# verdict permits the status-log fallback below. Missing, malformed, stale, or
# unverified semantic state remains unknown.
if [ "$KIND" != secondmate ]; then
  BUSY_VERDICT=$(crew_busy_verdict "$BACKEND_TARGET")
  case "${BUSY_VERDICT%% *}" in
    busy) emit working pane "harness busy (${BUSY_VERDICT#* })" ;;
    idle) ;;
    *) emit unknown pane "harness state unavailable ($BUSY_VERDICT)" ;;
  esac
fi

# Fall back to the status log's last line, but ONLY when its verb maps to a real
# run-state. A decision-closing event - resolved: (fm-classify-lib.sh's
# FM_CLASSIFY_RESOLVE_VERB), and any future decision-only sibling - is NOT a state:
# it exists solely to CLOSE a keyed decision in the durable fold, so a trailing
# resolved: must never become the current state or leak its resolution prose as the
# detail. Skipping it lets a just-resolved idle crew (typically a secondmate, which
# has no busy check above) fall through to the idle default instead of rendering
# `unknown` with the resolution note as `doing`. map_log_state is the single owner of
# the verb->state mapping (including the configurable paused verb), so reusing its
# `unknown` verdict as the "not a state" test needs no second verb list here.
if [ -n "$LOG_VERB" ]; then
  LOG_STATE=$(map_log_state "$LOG_LINE")
  if [ "$LOG_STATE" != unknown ]; then
    emit "$LOG_STATE" status-log "$(status_line_note "$LOG_LINE")"
  fi
fi

emit unknown none "no current-state source available"
