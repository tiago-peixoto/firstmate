#!/usr/bin/env bash
# Drives bin/fm-teardown.sh in disposable homes with stub forge CLIs.
# usage: drive.sh <worktree> <impl-root> <mode> [tests...]
WT=$1 IMPL=$2 MODE=$3; shift 3
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-retain-drive.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
# Function definitions of the changed test file, with the bare invocation lines removed.
awk '!/^test_[a-z_0-9]+$/' "$WT/tests/fm-teardown.test.sh" \
  | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$WT/tests/lib.sh\"#" > "$SCRATCH/defs.sh"
. "$SCRATCH/defs.sh"
ROOT=$IMPL
TEARDOWN=$ROOT/bin/fm-teardown.sh
echo "# teardown under test: $TEARDOWN ($(git -C "$WT" rev-parse --short HEAD) worktree; impl=$(basename "$IMPL"))"
case "$MODE" in
  tests) for t in "$@"; do "$t"; done ;;
  matrix)
    # $1 = label used only in case names; output is normalized so base and head diff cleanly.
    for retain in no yes; do for forge in github forgejo gitlab; do for flag in none park-on-review auto-land; do
      [ "$retain" = no ] || [ "$1" = head ] || continue
      case_dir=$(make_case "m-$forge-$flag-$retain")
      case "$forge" in
        github) url=https://github.com/example/repo/pull/7; log=gh ;;
        forgejo) url=https://git.example.org/team/repo/pulls/7; log=tea ;;
        gitlab) url=https://gitlab.example.com/team/sub/repo/-/merge_requests/7; log=glab ;;
      esac
      write_meta "$case_dir" no-mistakes ship
      wt_commit "$case_dir" "ready MR"
      add_fork_with_pushed_branch "$case_dir"
      printf 'pr=%s\n' "$url" >> "$case_dir/state/task-x1.meta"
      seed_backlog_in_flight "$case_dir"
      head=$(git -C "$case_dir/wt" rev-parse HEAD)
      case "$forge" in
        github) add_gh_pr_open_for_head "$case_dir" "$head" ;;
        forgejo) add_tea_pull_for_head "$case_dir" false "$head" git.example.org open ;;
        gitlab) add_glab_mr_for_head "$case_dir" opened "$head" ;;
      esac
      [ "$flag" = none ] || : > "$case_dir/config/$flag"
      [ "$retain" = no ] || : > "$case_dir/config/retain-open-pr"
      rc=0; out=$(run_teardown "$case_dir" 2>&1) || rc=$?
      printf '== forge=%s legacy-flag=%s retain-open-pr=%s\n' "$forge" "$flag" "$retain"
      printf 'exit=%s forge-read=%s task-record=%s worktree=%s backlog=%s\n' "$rc" \
        "$([ -e "$case_dir/$log.log" ] && echo yes || echo no)" \
        "$([ -e "$case_dir/state/task-x1.meta" ] && echo kept || echo removed)" \
        "$([ -d "$case_dir/wt" ] && echo kept || echo removed)" "$(backlog_row_state "$case_dir")"
      printf '%s\n' "$out" | sed "s#$TMP_ROOT#<TMP>#g; s#$IMPL#<ROOT>#g; s#$head#<HEAD>#g" | sed 's/^/  | /'
    done; done; done ;;
  unreadable)
    case_dir=$(make_case unreadable-pr)
    : > "$case_dir/config/retain-open-pr"
    write_meta "$case_dir" no-mistakes ship
    wt_commit "$case_dir" "ready PR"
    add_fork_with_pushed_branch "$case_dir"
    printf 'pr=https://github.com/example/repo/pull/7\n' >> "$case_dir/state/task-x1.meta"
    seed_backlog_in_flight "$case_dir"
    # make_case's default gh stubs fail "pr view": the record is unreadable.
    rc=0; out=$(run_teardown "$case_dir" 2>&1) || rc=$?
    printf 'exit=%s task-record=%s worktree=%s backlog=%s\n' "$rc" \
      "$([ -e "$case_dir/state/task-x1.meta" ] && echo kept || echo removed)" \
      "$([ -d "$case_dir/wt" ] && echo kept || echo removed)" "$(backlog_row_state "$case_dir")"
    printf '%s\n' "$out" | sed "s#$TMP_ROOT#<TMP>#g" | sed 's/^/  | /' ;;
esac
