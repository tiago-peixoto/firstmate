#!/usr/bin/env bash
# Behavioral regressions for the one automatic review-and-merge PR monitor.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-activity-watch)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

ack_watcher_cycle() {
  local state=$1 err sequence generation
  err="$state/.test-wake-drain.err"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

make_case() {
  local name=$1 dir fakebin fake_root
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  fake_root="$dir/root"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/wt" "$fakebin" "$fake_root/bin"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:?}"
case " $* " in
  *" headRefOid "*)
    printf '%s\n' 0123456789abcdef0123456789abcdef01234567
    ;;
  *" /repos/o/r/pulls/1/reviews"*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_REVIEW_ID:-10}"
    ;;
  *" /repos/o/r/issues/1/comments"*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_ISSUE_COMMENT_ID:-20}"
    ;;
  *" /repos/o/r/pulls/1/comments"*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    printf '%s\n' "${FM_TEST_REVIEW_COMMENT_ID:-30}"
    ;;
  *" /repos/o/r/pulls/1 "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    case "${FM_TEST_GH_STATE:-open}" in
      MERGED|merged) state=merged ;;
      OPEN|open) state=open ;;
      CLOSED|closed) state=closed ;;
      *) state=${FM_TEST_GH_STATE:-open} ;;
    esac
    printf '%s\t%s\t%s\n' "$state" "${FM_TEST_REQUESTED_COUNT:-1}" \
      "${FM_TEST_UPDATED_AT:-2026-08-30T10:00:00Z}"
    ;;
  *" state "*)
    [ "${FM_TEST_GH_FAIL:-0}" = 0 ] || exit 1
    case "${FM_TEST_GH_STATE:-OPEN}" in
      MERGED|merged) printf '%s\n' MERGED ;;
      OPEN|open) printf '%s\n' OPEN ;;
      CLOSED|closed) printf '%s\n' CLOSED ;;
      *) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
    esac
    ;;
esac
SH
  cat > "$fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TEST_GLAB_LOG:?}"
[ "${FM_TEST_GLAB_FAIL:-0}" = 0 ] || exit 1
printf 'title:\tfixture merge request\nstate:\t%s\nauthor:\tsomeone\n' "${FM_TEST_GLAB_STATE:-opened}"
SH
  chmod 0700 "$fake_root/bin/fm-guard.sh" "$fakebin/gh" "$fakebin/glab"
  : > "$dir/gh.log"
  : > "$dir/glab.log"
  fm_write_meta "$dir/home/state/task-a.meta" \
    'window=firstmate:fm-task-a' \
    'endpoint_task_id=task-a' \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    'kind=ship' \
    'mode=no-mistakes'
  printf '%s\n' "$dir"
}

arm_watch() {
  local dir=$1 url=${2:-https://github.com/o/r/pull/1}
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GLAB_LOG="$dir/glab.log" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" task-a "$url" >/dev/null || return 1
  bash -c '. "$1"; fm_pr_poll_artifacts_valid "$2" task-a "$3"' _ \
    "$ROOT/bin/fm-pr-lib.sh" "$dir/home/state" "$ROOT/bin/fm-pr-poll.sh"
}

run_watcher_for() {
  local dir=$1 seconds=${2:-2}
  shift 2
  FM_TEST_LIMIT="$seconds" perl -MTime::HiRes=time,sleep -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $end=time()+$ENV{FM_TEST_LIMIT}; while (time() < $end) { my $done=waitpid($pid, 1); exit($? >> 8) if $done == $pid; sleep 0.02 } kill "TERM", $pid; for (1..25) { my $done=waitpid($pid, 1); exit 124 if $done == $pid; sleep 0.02 } kill "KILL", $pid; waitpid $pid, 0; exit 124' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_TEST_GLAB_LOG="$dir/glab.log" \
      FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=1 FM_POLL=0.02 FM_HEARTBEAT=999999 \
      FM_SIGNAL_GRACE=0 PATH="$dir/fakebin:$BASE_PATH" "$WATCH" "$@"
}

assert_review_watch_armed() {
  local state=$1
  [ -f "$state/task-a.pr-poll-seen" ] || fail "reporting a PR did not arm review observation state"
  grep -q '^fm-pr-poll-seen-v1' "$state/task-a.pr-poll-seen" \
    || fail "reporting a PR armed something other than the review-bearing monitor"
}

test_report_arms_review_and_merge_together() {
  local dir state
  dir=$(make_case automatic-arm)
  state="$dir/home/state"
  arm_watch "$dir" || fail "reporting a PR failed"
  assert_review_watch_armed "$state"
  [ -f "$state/task-a.pr-poll" ] || fail "the unified monitor lost merge identity"
  cmp -s "$ROOT/bin/fm-pr-poll.sh" "$state/task-a.check.sh" \
    || fail "reporting a PR did not arm the canonical unified monitor"
}

test_review_wakes_on_fast_cycle_and_flags_nobody_requested() {
  local dir state rc
  dir=$(make_case review-fast-cycle)
  state="$dir/home/state"
  arm_watch "$dir" || fail "could not arm review fixture"
  touch "$state/.last-check"
  set +e
  FM_TEST_UPDATED_AT=2026-08-30T10:01:00Z FM_TEST_REVIEW_ID=11 FM_TEST_REQUESTED_COUNT=0 \
    run_watcher_for "$dir" 8 >"$dir/watch.out" 2>"$dir/watch.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "review did not wake before the slow-check interval (rc=$rc): $(cat "$dir/watch.err")"
  grep -q 'review activity' "$dir/watch.out" || fail "new review did not produce a review wake"
  grep -q 'NOBODY requested' "$dir/watch.out" || fail "new review with no requested reviewer hid the dangerous state"
}

test_comments_wake_and_unchanged_state_stays_silent() {
  local dir rc
  dir=$(make_case comment-and-quiet)
  arm_watch "$dir" || fail "could not arm comment fixture"
  set +e
  FM_TEST_UPDATED_AT=2026-08-30T10:01:00Z FM_TEST_ISSUE_COMMENT_ID=21 FM_TEST_REVIEW_COMMENT_ID=31 \
    run_watcher_for "$dir" 8 >"$dir/comment.out" 2>"$dir/comment.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "new comments did not wake: $(cat "$dir/comment.err")"
  grep -q 'comment activity' "$dir/comment.out" || fail "new comments did not identify their wake"
  ack_watcher_cycle "$dir/home/state" || fail "comment wake acknowledgement failed"

  : > "$dir/gh.log"
  set +e
  FM_TEST_UPDATED_AT=2026-08-30T10:01:00Z FM_TEST_ISSUE_COMMENT_ID=21 FM_TEST_REVIEW_COMMENT_ID=31 \
    run_watcher_for "$dir" 3 >"$dir/quiet.out" 2>"$dir/quiet.err"
  rc=$?
  set -e
  [ "$rc" -eq 124 ] || fail "unchanged review state produced a wake"
  [ ! -s "$dir/quiet.out" ] || fail "unchanged review state was not silent"
  grep -q '/repos/o/r/pulls/1 ' "$dir/gh.log" || fail "quiet monitoring skipped its health observation"
  ! grep -Eq '/reviews\?|/issues/.*/comments\?|/pulls/.*/comments\?' "$dir/gh.log" \
    || fail "quiet monitoring spent detail requests without a changed PR"
}

test_lookup_failure_is_visibly_different_from_quiet() {
  local dir state rc
  dir=$(make_case lookup-health)
  state="$dir/home/state"
  arm_watch "$dir" || fail "could not arm health fixture"
  set +e
  FM_TEST_GH_FAIL=1 run_watcher_for "$dir" 8 >"$dir/failure.out" 2>"$dir/failure.err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "an unreadable GitHub watch stayed silent: $(cat "$dir/failure.err")"
  grep -q 'PR monitor unavailable' "$dir/failure.out" || fail "lookup failure looked like a quiet queue"
  grep -q ' health=error ' "$state/task-a.pr-poll-seen" || fail "lookup failure did not leave visible unhealthy state"
  grep -q ' health=ok ' "$state/task-a.pr-poll-seen" && fail "lookup failure still claimed a healthy observation"
  return 0
}

test_every_old_forge_merge_path_wakes_and_retires_the_unified_monitor() {
  local provider dir state rc suffix url
  for provider in github gitlab; do
    dir=$(make_case "unified-merge-$provider")
    state="$dir/home/state"
    url=https://github.com/o/r/pull/1
    [ "$provider" = github ] \
      || url=https://gitlab.example/group/project/-/merge_requests/2
    arm_watch "$dir" "$url" || fail "could not arm $provider merge fixture"
    set +e
    if [ "$provider" = github ]; then
      FM_TEST_GH_STATE=merged run_watcher_for "$dir" 8 >"$dir/merge.out" 2>"$dir/merge.err"
    else
      FM_TEST_GLAB_STATE=merged run_watcher_for "$dir" 8 >"$dir/merge.out" 2>"$dir/merge.err"
    fi
    rc=$?
    set -e
    [ "$rc" -eq 0 ] \
      || fail "$provider merge did not wake through the unified monitor: $(cat "$dir/merge.err")"
    grep -q ': merged$' "$dir/merge.out" \
      || fail "$provider merge notification changed or disappeared"
    for suffix in check.sh pr-poll pr-poll-registration pr-poll-seen pr-poll-retirement; do
      [ ! -e "$state/task-a.$suffix" ] \
        || fail "$provider merged unified monitor left task-a.$suffix"
    done
  done
}

run_one() {
  local name=$1
  if ("$name"); then
    pass "$name"
    return 0
  fi
  return 1
}

failures=0
for test_name in \
  test_report_arms_review_and_merge_together \
  test_review_wakes_on_fast_cycle_and_flags_nobody_requested \
  test_comments_wake_and_unchanged_state_stays_silent \
  test_lookup_failure_is_visibly_different_from_quiet \
  test_every_old_forge_merge_path_wakes_and_retires_the_unified_monitor; do
  if [ "$#" -eq 0 ] || [ "$1" = "$test_name" ]; then
    run_one "$test_name" || failures=$((failures + 1))
  fi
done

[ "$failures" -eq 0 ] || exit 1
