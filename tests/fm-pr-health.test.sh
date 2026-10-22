#!/usr/bin/env bash
# PR health monitor behavior through its registered check and the watcher.
#
# Every case drives bin/fm-pr-health.sh through the check shim that arm
# registers, against a fake forge whose REST single-PR read reports a stale
# base commit, as GitHub's does, so only the GraphQL base branch commit can
# move the fingerprint. Ownership comes from real task records, status lines,
# task copies and contribution records in a throwaway home.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-health)
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BASE_1=1111111111111111111111111111111111111111
BASE_2=2222222222222222222222222222222222222222
BASE_3=3333333333333333333333333333333333333333

new_home() { # name -> home with the monitor flag on
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/forge" "$home/root/bin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  : > "$home/config/pr-health-monitor"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  # REST serves the PR state and mergeability, GraphQL the base branch
  # commit, review requests, reviews and the head's check rollup; both render
  # from one model file per PR. Every read is logged.
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FORGE/calls.log"
model() { cat "$FORGE/pr-$1.json"; }
case "$1 $2" in
  'api graphql')
    n=
    for arg in "$@"; do case "$arg" in number=*) n=${arg#number=} ;; esac; done
    model "$n" | jq '{data:{repository:{pullRequest:{
      headRefOid:(.graphql_head // .head),isDraft:.draft,baseRef:{target:{oid:.base}},
      reviewRequests:{nodes:[range(.requests) | {requestedReviewer:{__typename:"User"}}]},
      latestReviews:{nodes:[range(.reviews) | {author:{__typename:"User",login:"reviewer"}}]},
      statusCheckRollup:(if (.checks | length) == 0 then null else {
        contexts:{pageInfo:{hasNextPage:false},nodes:[.checks[] | {__typename:"CheckRun",name,
          status:(if .conclusion == null then "IN_PROGRESS" else "COMPLETED" end),
          conclusion,startedAt:(.at // "2026-10-21T00:00:00Z"),isRequired:.required}]}} end)}}}}' ;;
  'pr view')
    case "$*" in
      *headRefOid,reviewDecision*) model "${3##*/}" | jq '{headRefOid:.head,reviewDecision:""}' ;;
      *) printf 'https://github.com/o/r/pull/%s\n' "$3" ;;
    esac ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  'api repos/o/r/pulls/'*)
    rest=${2#repos/o/r/pulls/}
    case "$rest" in
      *[!0-9]*) printf '[[]]\n' ;;
      *) model "$rest" | jq '{state:(if .state == "open" then "open" else "closed" end),
           merged_at:(if .state == "merged" then "2026-10-21T00:00:00Z" else null end),
           user:{login:"author"},draft,mergeable,head:{sha:.head},
           base:{sha:"0000000000000000000000000000000000000000"},requested_reviewers:[]}' ;;
    esac ;;
  'api repos/o/r/issues/'*) printf '[[]]\n' ;;
  'api repos/o/r/commits/'*)
    case "$2" in *check-runs*) printf '[{"check_runs":[]}]\n' ;; *) printf '[[]]\n' ;; esac ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  # gh-axi resolves the open PR for a branch, as fm-teardown.sh's lookup reads it.
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
branch=
while [ "$#" -gt 0 ]; do [ "$1" = --head ] && branch=$2; shift; done
file="$FORGE/branch-$(printf '%s' "$branch" | tr '/' '_')"
if [ -f "$file" ]; then
  printf '%s\n' 'count: 1' 'pull_requests[1]{number,title,state,author,draft,review}:' "  $(cat "$file"),\"t\",open,author,yes,none"
else
  printf '%s\n' 'count: 0' 'pull_requests: []'
fi
SH
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  : > "$home/forge/calls.log"
  printf '%s\n' "$home"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}

pr() { # home number head base mergeable(true|false|null) draft(true|false)
  jq -n --arg head "$3" --arg base "$4" --argjson mergeable "$5" --argjson draft "$6" \
    '{state:"open",head:$head,base:$base,mergeable:$mergeable,draft:$draft,requests:1,reviews:0,checks:[]}' \
    > "$1/forge/pr-$2.json"
}

set_pr() { # home number jq-update
  jq "$3" "$1/forge/pr-$2.json" > "$1/forge/update.json" || fail 'fixture update failed'
  mv "$1/forge/update.json" "$1/forge/pr-$2.json"
}

task() { # home id [meta lines...]
  local home=$1 id=$2; shift 2
  { printf 'kind=ship\n'; printf '%s\n' "$@"; } > "$home/state/$id.meta"
  chmod 600 "$home/state/$id.meta"
}

arm() {
  with_home "$1" "$ROOT/bin/fm-pr-health.sh" arm >/dev/null || fail 'could not arm the PR health monitor'
}

pass_once() { # home -> the registered check's output
  with_home "$1" bash "$1/state/pr-health.check.sh" || fail 'the PR health check failed'
}

expect_silent() { # home why
  local out
  out=$(pass_once "$1")
  [ -z "$out" ] || fail "$2: $out"
}

expect_one() { # home pattern why
  local out
  out=$(pass_once "$1")
  if [ "$(printf '%s\n' "$out" | grep -c .)" != 1 ] || ! printf '%s\n' "$out" | grep -E "$2" >/dev/null; then
    fail "$3: $out"
  fi
}

test_unknown_then_dirty_wakes_once() {
  local home
  home=$(new_home unknown-dirty)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" null false
  arm "$home"
  expect_silent "$home" 'UNKNOWN mergeability must not read as a conflict'
  set_pr "$home" 8 '.mergeable = false'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/8 conflicts with its base at latest commit aaaaaaa .*ship1' \
    'UNKNOWN then DIRTY must wake once'
  pass 'UNKNOWN then DIRTY wakes once'
}

test_dirty_again_at_same_commits_is_silent() {
  local home
  home=$(new_home dirty-again)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  expect_one "$home" 'conflicts with its base' 'a first DIRTY read must wake'
  expect_silent "$home" 'DIRTY again at the same commits must not wake'
  set_pr "$home" 8 '.mergeable = null'
  expect_silent "$home" 'UNKNOWN after DIRTY must not clear or wake'
  set_pr "$home" 8 '.mergeable = false'
  expect_silent "$home" 'DIRTY after UNKNOWN at the same commits must not wake'
  pass 'DIRTY seen again at the same commits wakes nothing'
}

test_conflict_clears_and_returns_at_new_base() {
  local home
  home=$(new_home conflict-returns)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  expect_one "$home" 'conflicts with its base' 'the first conflict must wake'
  set_pr "$home" 8 ".mergeable = true | .base = \"$BASE_2\""
  expect_silent "$home" 'a cleared conflict must not wake'
  set_pr "$home" 8 ".mergeable = false | .base = \"$BASE_3\""
  expect_one "$home" 'conflicts with its base' 'a conflict that returns at a new base commit must wake again'
  set_pr "$home" 8 ".base = \"$BASE_1\""
  expect_one "$home" 'conflicts with its base' 'a new base commit must start a fresh conflict fingerprint'
  pass 'a conflict that clears and returns at a new base commit wakes again'
}

test_adopted_draft_red_required_check_after_pause_wakes_once() {
  local home wt
  home=$(new_home adopted-draft)
  wt="$home/copy"
  git init -q -b ART-9999-infer-tree-diameter "$wt"
  # The recorded branch does not match the adopted branch the PR uses.
  task "$home" slot9999 "worktree=$wt" branch=fm/artemis-slot-art-9999
  printf '5\n' > "$home/forge/branch-ART-9999-infer-tree-diameter"
  pr "$home" 5 "$HEAD_A" "$BASE_1" true true
  set_pr "$home" 5 '.checks = [{name:"CI Status",conclusion:null,required:true},
    {name:"Backend",conclusion:null,required:true},{name:"E2E Tests (independent)",conclusion:null,required:false}]'
  arm "$home"
  printf 'paused [at=1792500000]: Checks are still running on the draft.\n' > "$home/state/slot9999.status"
  expect_silent "$home" 'running checks on a draft must not wake'
  set_pr "$home" 5 '.checks[2].conclusion = "FAILURE" | .checks[1].conclusion = "FAILURE"'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/5 has failing required checks at latest commit aaaaaaa: Backend .*slot9999' \
    'a failing required check on an adopted draft must wake once'
  set_pr "$home" 5 '.checks[0].conclusion = "FAILURE"'
  expect_silent "$home" 'a second failing required check at the same commits must not wake again'
  pass 'a draft on an adopted branch whose required check fails after its worker pauses wakes once'
}

test_replaced_cancelled_run_is_not_failing() {
  local home
  home=$(new_home rerun)
  task "$home" ship1 pr=https://github.com/o/r/pull/9
  pr "$home" 9 "$HEAD_A" "$BASE_1" true false
  # GitHub keeps the run a base move cancelled beside the rerun that passed.
  set_pr "$home" 9 '.checks = [{name:"CI Status",conclusion:"CANCELLED",required:true,at:"2026-10-21T01:00:00Z"},
    {name:"CI Status",conclusion:"SUCCESS",required:true,at:"2026-10-21T01:05:00Z"}]'
  arm "$home"
  expect_silent "$home" 'a cancelled run that a passing rerun replaced must not read as failing'
  set_pr "$home" 9 '.checks += [{name:"CI Status",conclusion:"FAILURE",required:true,at:"2026-10-21T01:10:00Z"}]'
  expect_one "$home" 'pull/9 has failing required checks at latest commit aaaaaaa: CI Status' \
    'a newer failing run of the same check must wake'
  pass 'each check is judged by its newest run'
}

test_latest_commit_moving_between_reads_waits() {
  local home
  home=$(new_home moving-head)
  task "$home" ship1 pr=https://github.com/o/r/pull/7
  pr "$home" 7 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 7 ".graphql_head = \"$HEAD_B\""
  arm "$home"
  expect_silent "$home" 'reads that disagree on the latest commit must not wake'
  set_pr "$home" 7 'del(.graphql_head)'
  expect_one "$home" 'pull/7 conflicts with its base at latest commit aaaaaaa' 'reads that agree again must wake'
  pass 'a latest commit that moves between the two reads waits for the next pass'
}

test_other_homes_red_check_is_silent() {
  local home other out
  home=$(new_home this-home)
  other=$(new_home other-home)
  task "$other" theirs pr=https://github.com/o/r/pull/20
  pr "$other" 20 "$HEAD_A" "$BASE_1" true false
  set_pr "$other" 20 '.checks = [{name:"CI Status",conclusion:"FAILURE",required:true}]'
  cp "$other/forge/pr-20.json" "$home/forge/pr-20.json"
  task "$home" mine pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" true false
  # A secondmate's status names the PR its own home owns.
  printf 'kind=secondmate\n' > "$home/state/mate.meta"
  printf 'working [at=1792500000]: The child home opened https://github.com/o/r/pull/20 for review.\n' > "$home/state/mate.status"
  arm "$home"
  arm "$other"
  out=$(pass_once "$other")
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/20 has failing required checks' >/dev/null \
    || fail "the owning home must wake for its own red PR: $out"
  expect_silent "$home" "another home's red PR must wake nothing in this home"
  if grep -E 'pulls/20$|number=20( |$)' "$home/forge/calls.log" >/dev/null; then
    fail "this home read another home's PR: $(cat "$home/forge/calls.log")"
  fi
  pass "a red check on another home's PR wakes nothing in this home"
}

test_enrolled_before_ready_and_after_cleanup_still_wake() {
  local home out cmd
  home=$(new_home enrolled-early)
  task "$home" early
  pr "$home" 12 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 12 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  printf 'working [at=1792500000]: The draft is open at https://github.com/o/r/pull/12 and its checks are running.\n' \
    > "$home/state/early.status"
  arm "$home"
  # Run the ownership check exactly as the worker's brief spells it.
  : > "$home/config/wait-no-turns"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" early sample --mode direct-PR >/dev/null 2>&1 || fail 'could not write a brief'
  # shellcheck disable=SC2016  # The pattern matches literal backticks.
  cmd=$(grep -o '`FM_HOME=[^`]*owned <pr-url>`' "$home/data/early/brief.md" | tr -d '`') \
    || fail 'the brief names no ownership check'
  out=$(PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_ROOT_OVERRIDE="$home/root" \
    bash -c "${cmd%<pr-url>}https://github.com/o/r/pull/12") \
    || fail "a PR named in a live task's status line must be owned before any ready report: $out"
  [ "$out" = 'owned: https://github.com/o/r/pull/12' ] || fail "the ownership check printed: $out"
  out=$(PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_ROOT_OVERRIDE="$home/root" \
    bash -c "${cmd%<pr-url>}https://github.com/o/r/pull/13") && fail "an unnamed PR read as owned: $out"
  expect_silent "$home" 'running checks must not wake'
  set_pr "$home" 12 '.checks[0].conclusion = "FAILURE"'
  expect_one "$home" 'pull/12 has failing required checks' 'a PR enrolled before its ready report must wake'
  # Worker cleanup removes the task record and its status lines.
  rm -f "$home/state/early.meta" "$home/state/early.status"
  set_pr "$home" 12 ".head = \"$HEAD_B\" | .mergeable = false | .checks[0].conclusion = null"
  expect_one "$home" 'pull/12 conflicts with its base at latest commit bbbbbbb' 'a PR kept after cleanup must wake'
  pass 'a PR enrolled before any ready report, and one kept after cleanup, both still wake'
}

test_green_ready_with_no_reviewer_wakes_once_per_latest_commit() {
  local home
  home=$(new_home no-reviewer)
  task "$home" hotfix pr=https://github.com/o/r/pull/40
  pr "$home" 40 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 40 '.requests = 0 | .checks = [{name:"CI Status",conclusion:null,required:true}]'
  arm "$home"
  expect_silent "$home" 'a PR whose required check is still running is not green yet'
  set_pr "$home" 40 '.checks[0].conclusion = "SUCCESS"'
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/40 is green and out of draft with no reviewer requested at latest commit aaaaaaa' \
    'a green ready PR with no reviewer requested must wake'
  expect_silent "$home" 'the same green PR must not wake twice at one latest commit'
  set_pr "$home" 40 ".base = \"$BASE_2\""
  expect_silent "$home" 'a base move alone must not repeat the missing-reviewer wake'
  set_pr "$home" 40 ".head = \"$HEAD_B\""
  expect_one "$home" 'is green and out of draft with no reviewer requested at latest commit bbbbbbb' \
    'a new latest commit that is still unreviewed must wake again'
  set_pr "$home" 40 ".head = \"$HEAD_A\" | .base = \"$BASE_3\" | .requests = 1"
  expect_silent "$home" 'a PR with a requested reviewer must not wake'
  set_pr "$home" 40 '.requests = 0 | .reviews = 1'
  expect_silent "$home" 'a PR a reviewer already reviewed must not wake'
  set_pr "$home" 40 '.reviews = 0 | .draft = true'
  expect_silent "$home" 'a green draft must not ask for a reviewer'
  pass 'green, out of draft, no reviewer requested wakes once per latest commit'
}

test_base_without_required_checks_counts_any_failing_check() {
  local home
  home=$(new_home no-required)
  task "$home" a pr=https://github.com/o/r/pull/30
  task "$home" b pr=https://github.com/o/r/pull/31
  pr "$home" 30 "$HEAD_A" "$BASE_1" true false
  pr "$home" 31 "$HEAD_A" "$BASE_1" true false
  set_pr "$home" 30 '.checks = [{name:"lint",conclusion:"SUCCESS",required:false},{name:"test",conclusion:"FAILURE",required:false}]'
  set_pr "$home" 31 '.checks = [{name:"CI Status",conclusion:"SUCCESS",required:true},{name:"test",conclusion:"FAILURE",required:false}]'
  arm "$home"
  expect_one "$home" '^pr-health: https://github.com/o/r/pull/30 has failing checks at latest commit aaaaaaa: test' \
    'a failing check must count when the base requires none, and an optional one must not when it does'
  pass 'a base with no required checks counts a failing reported check'
}

test_nothing_prints_while_nothing_changed() {
  local home n
  home=$(new_home quiet)
  task "$home" a pr=https://github.com/o/r/pull/50
  task "$home" b pr=https://github.com/o/r/pull/51
  pr "$home" 50 "$HEAD_A" "$BASE_1" null false
  pr "$home" 51 "$HEAD_A" "$BASE_1" true true
  set_pr "$home" 50 '.checks = [{name:"CI Status",conclusion:null,required:true}]'
  set_pr "$home" 51 '.checks = [{name:"CI Status",conclusion:"SUCCESS",required:true}]'
  arm "$home"
  for n in 1 2 3; do
    expect_silent "$home" "pass $n printed with nothing actionable"
  done
  [ -s "$home/forge/calls.log" ] || fail 'the quiet passes never read the forge'
  pass 'nothing prints while nothing changed'
}

test_merged_pr_is_not_read_again() {
  local home before
  home=$(new_home merged)
  task "$home" done1 pr=https://github.com/o/r/pull/60
  pr "$home" 60 "$HEAD_A" "$BASE_1" false false
  set_pr "$home" 60 '.state = "merged"'
  arm "$home"
  expect_silent "$home" 'a merged PR must not wake'
  before=$(grep -c 'pulls/60$' "$home/forge/calls.log")
  expect_silent "$home" 'a merged PR must stay silent'
  [ "$(grep -c 'pulls/60$' "$home/forge/calls.log")" = "$before" ] || fail 'a merged PR was read again'
  pass 'a merged PR leaves the monitor'
}

test_absent_flag_changes_nothing() {
  local home out before
  home=$(new_home flag-off)
  rm -f "$home/config/pr-health-monitor"
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  printf 'working [at=1792500000]: Opened https://github.com/o/r/pull/9 for review.\n' > "$home/state/ship1.status"
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  before=$(ls -A "$home/state" "$home/data")
  out=$(with_home "$home" "$ROOT/bin/fm-pr-health.sh" poll 2>&1) || fail "poll failed with the flag absent: $out"
  [ -z "$out" ] || fail "poll printed with the flag absent: $out"
  if with_home "$home" "$ROOT/bin/fm-pr-health.sh" arm >/dev/null 2>&1; then
    fail 'arm succeeded with the flag absent'
  fi
  if with_home "$home" "$ROOT/bin/fm-pr-health.sh" owned https://github.com/o/r/pull/9 >/dev/null 2>&1; then
    fail 'owned claimed a PR with the flag absent'
  fi
  [ "$(ls -A "$home/state" "$home/data")" = "$before" ] \
    || fail "the flag-off monitor wrote records: $(ls -A "$home/state" "$home/data")"
  [ ! -s "$home/forge/calls.log" ] || fail "the flag-off monitor read the forge: $(cat "$home/forge/calls.log")"
  pass 'an absent flag leaves the home untouched'
}

test_watcher_surfaces_one_wake() {
  local home rc rows
  home=$(new_home watcher)
  task "$home" ship1 pr=https://github.com/o/r/pull/8
  pr "$home" 8 "$HEAD_A" "$BASE_1" false false
  arm "$home"
  [ -f "$home/state/contributions.check.sh" ] || fail 'arm did not arm the contribution observer for enrolled PRs'
  rc=0
  with_home "$home" env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 15 > "$home/watcher.out" 2> "$home/watcher.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher did not surface the conflict: $(cat "$home/watcher.err")"
  rows=$(awk -F '\t' -v key="$home/state/pr-health.check.sh" '$3 == "check" && $4 == key && $5 ~ /pull\/8 conflicts with its base/ { n++ } END { print n + 0 }' \
    "$home/state/.wake-queue")
  [ "$rows" = 1 ] || fail "one conflict queued $rows wakes: $(cat "$home/state/.wake-queue")"
  rc=0
  with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$home/watcher-repeat.out" 2> "$home/watcher-repeat.err" || rc=$?
  [ "$rc" -eq 124 ] || fail "an unchanged conflict woke the watcher again: $(cat "$home/watcher-repeat.out")"
  pass 'the watcher turns one conflict into one durable wake'
}

failures=0
for test_name in test_unknown_then_dirty_wakes_once test_dirty_again_at_same_commits_is_silent \
  test_conflict_clears_and_returns_at_new_base test_adopted_draft_red_required_check_after_pause_wakes_once \
  test_replaced_cancelled_run_is_not_failing test_latest_commit_moving_between_reads_waits \
  test_other_homes_red_check_is_silent test_enrolled_before_ready_and_after_cleanup_still_wake \
  test_green_ready_with_no_reviewer_wakes_once_per_latest_commit test_base_without_required_checks_counts_any_failing_check \
  test_nothing_prints_while_nothing_changed test_merged_pr_is_not_read_again test_absent_flag_changes_nothing \
  test_watcher_surfaces_one_wake; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures PR health regressions"
