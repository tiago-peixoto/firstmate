#!/usr/bin/env bash
# Live driver: runs the real bin/fm-teardown.sh, bin/fm-pr-merge.sh and
# bin/fm-capacity.sh from the run worktree against disposable fixture homes.
# The forge is a local emulator (stub gh/glab on PATH) except in the scenarios
# marked REAL, which use the machine's gh login for read-only PR views.
# Usage: drive.sh <worktree-root> [scenario...]
set -u
WT_ROOT=$1; shift
T=$WT_ROOT/tests/fm-teardown.test.sh
M=$WT_ROOT/tests/fm-pr-merge.test.sh
# Fixture builders come from the repository's own test files (helpers only, no tests).
HELPERS=$(mktemp)
{
  awk '/^test_local_only_fork_remote_allows\(\) \{$/{exit} /^set -u$/{on=1} on' "$T" \
    | sed "s|\\. \"\\\$(dirname \"\\\${BASH_SOURCE\\[0\\]}\")/lib.sh\"|. \"$WT_ROOT/tests/lib.sh\"|"
  sed -n '/^add_glab_mr_for_head() {$/,/^}$/p' "$T"
  for fn in write_github_required write_github_live_json add_gh_mocks run_pr_merge; do
    sed -n "/^$fn() {\$/,/^}\$/p" "$M"
  done
} > "$HELPERS"
# shellcheck disable=SC1090
. "$HELPERS"
FNS=$(mktemp); { declare -f run_pr_merge; declare -p ROOT; } > "$FNS"
rm -f "$HELPERS"
export PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
export REAL_MV=$(command -v mv)
set +e

say() { printf '\n%s\n' "$*"; }
run() {  # label, then command; prints output and exit code
  local label=$1 out rc; shift
  out=$("$@" 2>&1); rc=$?
  printf '$ %s\n%s\n[exit %s]\n' "$label" "$out" "$rc"
  return "$rc"
}
state_of() {
  local c=$1
  printf 'task record: %s | isolated copy: %s | backlog row: %s\n' \
    "$([ -f "$c/state/task-x1.meta" ] && echo PRESENT || echo deleted)" \
    "$([ -d "$c/wt" ] && echo PRESENT || echo deleted)" \
    "$(backlog_row_state "$c")"
}
ready_ship() {  # case_dir url -> a published ship task with a recorded pr=
  local c=$1 url=$2
  write_meta "$c" no-mistakes ship
  wt_commit_file "$c" feature.txt hello "ready PR"
  add_fork_with_pushed_branch "$c"
  printf 'pr=%s\n' "$url" >> "$c/state/task-x1.meta"
  seed_backlog_in_flight "$c"
}
GH_URL=https://github.com/example/repo/pull/7

s_open_then_merged() {
  say "=== S1: open GitHub PR (emulated forge) - cleanup refused, then allowed after merge ==="
  local c head; c=$(make_case s1); ready_ship "$c" "$GH_URL"
  head=$(git -C "$c/wt" rev-parse HEAD)
  add_gh_pr_open_for_head "$c" "$head"
  run "fm-teardown.sh task-x1   # forge says OPEN" run_teardown "$c"; state_of "$c"
  add_gh_pr_merged_for_head "$c" "$head"
  run "fm-teardown.sh task-x1   # forge says MERGED" run_teardown "$c"; state_of "$c"
}

s_baseline() {
  say "=== S1-baseline: same open PR on base commit a9ae3c0c - the record is deleted (the bug) ==="
  local c head base; c=$(make_case s1base); ready_ship "$c" "$GH_URL"
  head=$(git -C "$c/wt" rev-parse HEAD)
  add_gh_pr_open_for_head "$c" "$head"
  base="$TMP_ROOT/base-tree"; mkdir -p "$base"
  git -C "$WT_ROOT" archive a9ae3c0c673bd98ecafdab52fc130a13621fb7af | tar -x -C "$base"
  run "BASE fm-teardown.sh task-x1   # forge says OPEN" env \
    FM_ROOT_OVERRIDE="$base" FM_STATE_OVERRIDE="$c/state" FM_DATA_OVERRIDE="$c/data" \
    FM_CONFIG_OVERRIDE="$c/config" PATH="$c/fakebin:$PATH" "$base/bin/fm-teardown.sh" task-x1
  state_of "$c"
}

s_acceptance() {
  say "=== S2: stopped ready worker -> refused cleanup -> merge approval -> guarded merge -> final cleanup ==="
  local c head before; c=$(make_case s2); ready_ship "$c" "$GH_URL"
  head=$(git -C "$c/wt" rev-parse HEAD)
  add_gh_pr_open_for_head "$c" "$head"
  before=$(cat "$c/state/task-x1.meta")
  printf 'task record before:\n%s\n' "$before" | sed "s|$c|<home>|g"
  run "fm-teardown.sh task-x1   # PR open, worker already stopped" run_teardown "$c"; state_of "$c"
  say "-- capacity while the record is retained --"
  run "fm-capacity.sh" env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$c" FM_STATE_OVERRIDE="$c/state" \
    FM_DATA_OVERRIDE="$c/data" FM_CONFIG_OVERRIDE="$c/config" "$ROOT/bin/fm-capacity.sh"
  (
    . "$ROOT/bin/fm-backend.sh" 2>/dev/null; . "$ROOT/bin/fm-wake-lib.sh" 2>/dev/null; . "$ROOT/bin/fm-project-capacity-lib.sh" 2>/dev/null
    lock=$(fm_treehouse_project_lock_path "$c/project" 2>/dev/null)
    fm_project_capacity_occupants "$lock" "$c/project" "$c/state" new-task
    printf '$ fm_project_capacity_occupants <project> (real lib)\noccupants=%s ids=[%s] error=[%s]\n' \
      "$FM_PROJECT_CAPACITY_OCCUPANTS" "$FM_PROJECT_CAPACITY_OCCUPANT_IDS" "$FM_PROJECT_CAPACITY_ERROR"
  )
  say "-- later merge approval: guarded merge using the retained record --"
  mkdir -p "$c/home/data" "$c/home/config" "$c/user-home"
  fm_test_tasks_toml "$c/home/.tasks.toml"
  cp "$c/data/backlog.md" "$c/home/data/backlog.md"
  printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$c/github-outcome"
  : > "$c/github-rules"; : > "$c/gh.log"; : > "$c/gh-axi.log"
  write_github_required "$c"
  add_gh_mocks "$c" "$head"
  run "fm-pr-merge.sh task-x1 $GH_URL" env PATH="$(dirname "$(mise which node)"):$PATH" bash -c '. "$0"; run_pr_merge "$@"' "$FNS" "$c" task-x1 "$GH_URL"
  printf 'forge merge call received: %s\n' "$(grep '^pr merge ' "$c/gh.log")"
  printf 'task record after merge (diff against before; original lines untouched):\n'
  diff <(printf '%s\n' "$before") "$c/state/task-x1.meta" | sed "s|$c|<home>|g"
  say "-- final cleanup, forge now reports MERGED --"
  add_gh_pr_merged_for_head "$c" "$head"
  run "fm-teardown.sh task-x1" run_teardown "$c"; state_of "$c"
}

s_unreadable() {
  say "=== S3: forge read fails (unreadable PR record) - cleanup refused ==="
  local c; c=$(make_case s3); ready_ship "$c" "$GH_URL"
  run "fm-teardown.sh task-x1   # gh pr view exits 1" run_teardown "$c"; state_of "$c"
}

s_force() {
  say "=== S4: open PR with explicit discard (--force) - cleanup proceeds ==="
  local c; c=$(make_case s4); ready_ship "$c" "$GH_URL"
  add_gh_pr_open_for_head "$c" "$(git -C "$c/wt" rev-parse HEAD)"
  run "fm-teardown.sh task-x1 --force" run_teardown "$c" --force; state_of "$c"
}

s_closed() {
  say "=== S5: CLOSED PR - unlanded and uncommitted work stay protected, landed work cleans up ==="
  local c; c=$(make_case s5)
  write_meta "$c" no-mistakes ship
  wt_commit_file "$c" feature.txt hello "add feature"
  printf 'pr=%s\n' "$GH_URL" >> "$c/state/task-x1.meta"
  seed_backlog_in_flight "$c"
  add_gh_pr_open_for_head "$c" "$(git -C "$c/wt" rev-parse HEAD)" CLOSED
  run "fm-teardown.sh task-x1   # closed, change on no remote" run_teardown "$c"; state_of "$c"
  land_on_origin_main "$c" feature.txt hello
  printf '%s\n' draft > "$c/wt/notes.txt"
  run "fm-teardown.sh task-x1   # closed, change landed, uncommitted file" run_teardown "$c"; state_of "$c"
  rm "$c/wt/notes.txt"
  run "fm-teardown.sh task-x1   # closed, change landed, clean" run_teardown "$c"; state_of "$c"
}

s_open_dirty() {
  say "=== S5b: MERGED PR but uncommitted changes in the copy - still refused ==="
  local c head; c=$(make_case s5b); ready_ship "$c" "$GH_URL"
  head=$(git -C "$c/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$c" "$head"
  printf '%s\n' draft > "$c/wt/notes.txt"
  run "fm-teardown.sh task-x1   # merged, uncommitted file" run_teardown "$c"; state_of "$c"
}

s_gitlab() {
  say "=== S6: open GitLab merge request - gate follows the opt-in flags ==="
  local c flag url=https://gitlab.example.com/team/sub/repo/-/merge_requests/7
  for flag in park-on-review auto-land none; do
    c=$(make_case "s6-$flag"); ready_ship "$c" "$url"
    add_glab_mr_for_head "$c" opened "$(git -C "$c/wt" rev-parse HEAD)"
    [ "$flag" = none ] || : > "$c/config/$flag"
    run "fm-teardown.sh task-x1   # config flag: $flag" run_teardown "$c"; state_of "$c"
    printf 'glab calls: %s\n' "$(cat "$c/glab.log" 2>/dev/null | tr '\n' ';' || true)"
  done
}

s_real() {
  say "=== S7 REAL: real gh login, read-only views of real upstream PRs ==="
  local c n
  for n in "$@"; do
    c=$(make_case "s7-$n"); ready_ship "$c" "https://github.com/kunchenguid/firstmate/pull/$n"
    rm -f "$c/fakebin/gh" "$c/fakebin/gh-axi"
    printf 'forge truth: gh pr view %s -> %s\n' "$n" \
      "$(gh pr view "$n" --repo kunchenguid/firstmate --json state,mergedAt -q '.state + " mergedAt=" + (.mergedAt // "null")' 2>&1)"
    run "fm-teardown.sh task-x1   # pr=.../pull/$n" run_teardown "$c"; state_of "$c"
  done
}

[ "$#" -gt 0 ] || set -- open baseline acceptance unreadable force closed dirty gitlab
for s in "$@"; do
  case "$s" in
    open) s_open_then_merged ;;
    baseline) s_baseline ;;
    acceptance) s_acceptance ;;
    unreadable) s_unreadable ;;
    force) s_force ;;
    closed) s_closed ;;
    dirty) s_open_dirty ;;
    gitlab) s_gitlab ;;
    real:*) IFS=, read -r -a nums <<< "${s#real:}"; s_real "${nums[@]}" ;;
  esac
done
