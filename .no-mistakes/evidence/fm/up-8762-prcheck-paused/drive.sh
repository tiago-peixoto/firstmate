#!/usr/bin/env bash
# Drives the real bin/fm-pr-check.sh scan (and the real bin/fm-watch.sh sweep)
# against disposable FM homes, with the test suite's local gh emulator on PATH.
# Usage: drive.sh <worktree> [<bin-dir-of-another-revision>]
set -u
WT=$1
ALT_BIN=${2:-}
# Load the suite's fixture builders (make_case, write_task_meta, run_check_entry,
# run_watcher_bounded) without running the suite's own test list.
first=$(grep -n '^test_[a-z_0-9]*$' "$WT/tests/fm-pr-check-security.test.sh" | head -1 | cut -d: -f1)
# shellcheck disable=SC1090
source <(head -n "$((first - 1))" "$WT/tests/fm-pr-check-security.test.sh" \
  | sed "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. \"$WT/tests/lib.sh\"|")
[ -z "$ALT_BIN" ] || PR_CHECK="$ALT_BIN/fm-pr-check.sh"
RC=0

show() {  # <dir> <task>
  local state="$1/home/state" id=$2 pr poll=no
  pr=$(grep '^pr=' "$state/$id.meta" || true)
  ! fm_pr_poll_artifacts_valid "$state" "$id" "$POLL" || poll="valid, watching $FM_PR_DATA_URL"
  printf '    %s: meta %s | merge poll: %s\n' "$id" "${pr:-has no pr= line}" "$poll"
}

scenario() {  # <name> <expected: a PR number or none> <extra env or -> <status lines...>
  local name=$1 want=$2 envs=$3 dir state out got
  shift 3
  dir=$(make_case "s$RANDOM")
  state="$dir/home/state"
  write_task_meta "$dir" task-a
  printf '%s\n' "$@" > "$state/task-a.status"
  printf '\n### %s\n  state/task-a.status:\n' "$name"
  sed 's/^/    /' "$state/task-a.status"
  if [ "$envs" = - ]; then
    out=$(run_check_entry "$dir" scan 2>&1); printf '  $ fm-pr-check.sh scan -> exit %s\n' "$?"
  else
    out=$(env "$envs" bash -c "$(declare -f run_check_entry); PR_CHECK='$PR_CHECK' BASE_PATH='$BASE_PATH' REAL_JQ='$REAL_JQ' run_check_entry '$dir' scan" 2>&1)
    printf '  $ %s fm-pr-check.sh scan -> exit %s\n' "$envs" "$?"
  fi
  [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    stdout: /'
  show "$dir" task-a
  got=$(sed -n 's|^pr=.*/pull/||p' "$state/task-a.meta")
  [ -e "$state/task-a.check.sh" ] || got="${got:+$got-without-poll}"
  got=${got:-none}
  if [ "$got" = "$want" ]; then printf '  RESULT: as expected (%s)\n' "$want"
  else printf '  RESULT: UNEXPECTED - wanted %s, got %s\n' "$want" "$got"; RC=1; fi
  LAST_DIR=$dir
}

P=https://github.com/o/r/pull
printf 'fm-pr-check.sh under test: %s\n' "$PR_CHECK"

scenario 'S1 done then paused on the same PR' 7 - \
  "done [at=2]: PR $P/7 checks green" \
  "paused [at=3]: waiting for review on PR $P/7 until 2026-12-01T00:00Z"
if [ -n "$ALT_BIN" ]; then
  printf '\n(base revision only runs S1, the reported failure)\n'
  exit "$RC"
fi

scenario 'S1b done then two paused lines on the same PR' 7 - \
  "done [at=2]: PR $P/7 checks green" \
  "paused [at=3]: waiting for review on PR $P/7 until 2026-12-01T00:00Z" \
  "paused [at=93]: still waiting on $P/7 until 2026-12-02T00:00Z"
scenario 'S2 done then paused on another PR' none - \
  "done [at=2]: PR $P/8 checks green" \
  "paused [at=3]: waiting for review on $P/9 until 2026-12-01T00:00Z"
scenario 'S2b paused line names the same PR and another PR' none - \
  "done [at=2]: PR $P/10 checks green" \
  "paused [at=3]: $P/10 waits on $P/11 until 2026-12-01T00:00Z"
scenario 'S3 done then working' none - \
  "done [at=2]: PR $P/12 checks green" \
  "working [at=3]: fixing review notes on $P/12"
scenario 'S3b done, paused on the same PR, then working' none - \
  "done [at=2]: PR $P/12 checks green" \
  "paused [at=3]: waiting for review on $P/12 until 2026-12-01T00:00Z" \
  "working [at=4]: fixing review notes on $P/12"
scenario 'S4 paused line with no PR' none - \
  "done [at=2]: PR $P/7 checks green" \
  "paused [at=3]: waiting for the captain until 2026-12-01T00:00Z"
scenario 'S4b done then blocked' none - \
  "done [at=2]: PR $P/7 checks green" \
  "blocked [at=3]: review on $P/7 needs a decision"
scenario 'S4c done then failed' none - \
  "done [at=2]: PR $P/7 checks green" \
  "failed [at=3]: checks on $P/7 went red"
scenario 'S4d done, paused on the same PR, then blocked' none - \
  "done [at=2]: PR $P/7 checks green" \
  "paused [at=3]: waiting for review on $P/7" \
  "blocked [at=4]: $P/7 needs a decision"
scenario 'S4e paused on the same PR with no ready done line before it' none - \
  "working [at=2]: opened $P/7" \
  "paused [at=3]: waiting for review on $P/7"
scenario 'S4f the done line before the wait says the PR is not ready' none - \
  "done [at=2]: PR $P/7 is not ready yet" \
  "paused [at=3]: waiting for review on $P/7"
scenario 'S5 punctuation and a #fragment around the same PR (review round 1 decision)' 13 - \
  "done [at=2]: PR $P/13 checks green" \
  "paused [at=3]: run starting for $P/13, waiting on drive call" \
  "paused [at=4]: waiting for review ($P/13#issuecomment-1) on \"$P/13\"."
scenario 'S5b another PR followed by a comma (review round 1 decision)' none - \
  "done [at=2]: PR $P/14 checks green" \
  "paused [at=3]: $P/14 waits on $P/15, until 2026-12-01T00:00Z"

scenario 'S6 draft refusal: the forge reports the PR behind the wait as a draft' none FM_TEST_GH_DRAFT=true \
  "done [at=2]: PR $P/9 checks green" \
  "paused [at=3]: waiting for review on $P/9"
printf '  then the forge reports it ready, same home, next scan:\n'
out=$(run_check_entry "$LAST_DIR" scan 2>&1); printf '  $ fm-pr-check.sh scan -> exit %s %s\n' "$?" "$out"
show "$LAST_DIR" task-a
grep -qxF "pr=$P/9" "$LAST_DIR/home/state/task-a.meta" || { printf '  RESULT: UNEXPECTED\n'; RC=1; }

scenario 'S7 replacement: first PR recorded from its ready line' 7 - \
  "done [at=2]: PR $P/7 checks green" \
  "paused [at=3]: waiting for review on $P/7"
printf '%s\n' "working [at=4]: PR 7 closed, reopening" "done [at=5]: PR $P/8 checks green" \
  "paused [at=6]: waiting for review on $P/8" >> "$LAST_DIR/home/state/task-a.status"
printf '  the lane then appends:\n'; tail -3 "$LAST_DIR/home/state/task-a.status" | sed 's/^/    /'
out=$(run_check_entry "$LAST_DIR" scan 2>&1); printf '  $ fm-pr-check.sh scan -> exit %s %s\n' "$?" "$out"
show "$LAST_DIR" task-a
{ grep -qxF "pr=$P/8" "$LAST_DIR/home/state/task-a.meta" && [ "$(grep -c '^pr=' "$LAST_DIR/home/state/task-a.meta")" = 1 ]; } \
  || { printf '  RESULT: UNEXPECTED\n'; RC=1; }

printf '\n### S8 the real watcher sweep (bin/fm-watch.sh, config/pr-register-scan present)\n'
dir=$(make_case watcher)
: > "$dir/home/config/pr-register-scan"
write_task_meta "$dir" task-a
write_task_meta "$dir" task-b
printf '%s\n' "done [at=2]: PR $P/7 checks green" "paused [at=3]: waiting for review on $P/7" > "$dir/home/state/task-a.status"
printf '%s\n' "done [at=2]: PR $P/8 checks green" "paused [at=3]: waiting for review on $P/9" > "$dir/home/state/task-b.status"
for t in task-a task-b; do printf '  state/%s.status:\n' "$t"; sed 's/^/    /' "$dir/home/state/$t.status"; done
add_stop_custom_check "$dir"
run_watcher_bounded "$dir/home" "$dir/fakebin" > "$dir/watch.out" 2> "$dir/watch.err"
printf '  $ fm-watch.sh -> exit %s\n' "$?"
show "$dir" task-a
show "$dir" task-b
{ grep -qxF "pr=$P/7" "$dir/home/state/task-a.meta" && fm_pr_poll_artifacts_valid "$dir/home/state" task-a "$POLL" \
  && ! grep -q '^pr=' "$dir/home/state/task-b.meta" && [ ! -e "$dir/home/state/task-b.check.sh" ]; } \
  || { printf '  RESULT: UNEXPECTED: %s\n' "$(cat "$dir/watch.err")"; RC=1; }

printf '\nDRIVER EXIT %s\n' "$RC"
exit "$RC"
