#!/usr/bin/env bash
# Drives bin/fm-teardown.sh against disposable fixture homes (fixture builders from tests/fm-teardown.test.sh).
# Forge CLIs (gh, gh-axi, glab) are external-boundary fakes; teardown, git, and tasks-axi are real.
. "$1"
step() { printf '\n=== %s ===\n' "$*"; }
run() { set +e; out=$(run_teardown "$@" 2>&1); rc=$?; set -e; printf 'exit=%s\n%s\n' "$rc" "$out" | grep -v '^$' | tail -6; }
url=https://github.com/example/repo/pull/7

step "A. unreadable record: gh and gh-axi both fail, work landed on origin branch"
c=$(make_case adv-unreadable); write_meta "$c" no-mistakes ship; wt_commit "$c" ready
add_fork_with_pushed_branch "$c"; printf 'pr=%s\n' "$url" >> "$c/state/task-x1.meta"; seed_backlog_in_flight "$c"
printf '#!/usr/bin/env bash\nexit 1\n' > "$c/fakebin/gh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$c/fakebin/gh-axi"
run "$c"; [ "$rc" = 1 ] && [ -f "$c/state/task-x1.meta" ] && [ -d "$c/wt" ] && [ "$(backlog_row_state "$c")" = in_flight ] && echo "RESULT A: PASS (refused, meta+copy+backlog kept)" || echo "RESULT A: FAIL"

step "B. lowercase gitlab-style open state from GitLab MR"
c=$(make_case adv-gitlab-open); write_meta "$c" no-mistakes ship; wt_commit "$c" ready
add_fork_with_pushed_branch "$c"; printf 'pr=%s\n' "https://gitlab.com/example/repo/-/merge_requests/7" >> "$c/state/task-x1.meta"; seed_backlog_in_flight "$c"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"state\\":\\"opened\\"}"\n' > "$c/fakebin/glab"; chmod +x "$c/fakebin/glab"
run "$c"; [ "$rc" = 1 ] && [[ "$out" == *"open or unreadable PR"* ]] && [ -f "$c/state/task-x1.meta" ] && echo "RESULT B: PASS (refused open MR)" || echo "RESULT B: FAIL"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "{\\"state\\":\\"merged\\"}"\n' > "$c/fakebin/glab"
run "$c"; [ "$rc" = 0 ] && [ ! -f "$c/state/task-x1.meta" ] && echo "RESULT B2: PASS (merged MR torn down)" || echo "RESULT B2: FAIL"

step "C. CLOSED PR, landed work on remote, but an unpushed extra commit on top"
c=$(make_case adv-closed-unpushed); write_meta "$c" no-mistakes ship; wt_commit "$c" ready
add_fork_with_pushed_branch "$c"; wt_commit_file "$c" extra.txt more "unpushed extra"
printf 'pr=%s\n' "$url" >> "$c/state/task-x1.meta"; seed_backlog_in_flight "$c"
add_gh_pr_open_for_head "$c" "$(git -C "$c/wt" rev-parse HEAD)" CLOSED
run "$c"; [ "$rc" = 1 ] && [[ "$out" != *"open or unreadable PR"* ]] && [ -f "$c/state/task-x1.meta" ] && echo "RESULT C: PASS (existing unpushed refusal, not the PR gate)" || echo "RESULT C: FAIL"

step "D. CLOSED PR, work pushed to fork remote, clean tree -> existing path allows without --force"
c=$(make_case adv-closed-pushed); write_meta "$c" no-mistakes ship; wt_commit "$c" ready
add_fork_with_pushed_branch "$c"; printf 'pr=%s\n' "$url" >> "$c/state/task-x1.meta"; seed_backlog_in_flight "$c"
add_gh_pr_open_for_head "$c" "$(git -C "$c/wt" rev-parse HEAD)" CLOSED
run "$c"; [ "$rc" = 0 ] && [ ! -f "$c/state/task-x1.meta" ] && echo "RESULT D: PASS" || echo "RESULT D: FAIL"

step "E. --force with OPEN PR but uncommitted changes -> force path discards"
c=$(make_case adv-open-force-dirty); write_meta "$c" no-mistakes ship; wt_commit "$c" ready
printf 'pr=%s\n' "$url" >> "$c/state/task-x1.meta"; seed_backlog_in_flight "$c"
add_gh_pr_open_for_head "$c" "$(git -C "$c/wt" rev-parse HEAD)"; echo wip > "$c/wt/wip.txt"
run "$c"; [ "$rc" = 1 ] && [[ "$out" == *"open or unreadable PR"* ]] && echo "RESULT E1: PASS (refused unforced)" || echo "RESULT E1: FAIL"
run "$c" --force; [ "$rc" = 0 ] && [ ! -f "$c/state/task-x1.meta" ] && echo "RESULT E2: PASS (forced cleanup)" || echo "RESULT E2: FAIL"
