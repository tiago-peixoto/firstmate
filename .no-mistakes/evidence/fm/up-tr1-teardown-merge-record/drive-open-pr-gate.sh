#!/usr/bin/env bash
# Drives the real bin/fm-teardown.sh against disposable homes built with the
# fixtures of tests/fm-teardown.test.sh. Forge clients (gh, tea, glab) are
# logging stubs. Usage: drive-open-pr-gate.sh <worktree> <base-tree>
W=$1; BASE=$2
LIBSRC=$(mktemp); trap 'rm -f "$LIBSRC"' EXIT
# Helpers only: drop the top-level test invocations and pin the tests dir.
grep -vE '^test_[a-z0-9_]+$' "$W/tests/fm-teardown.test.sh" \
  | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$W/tests|" > "$LIBSRC"
# shellcheck disable=SC1090
. "$LIBSRC"
HEAD_ROOT=$ROOT

build() { # name forge flag variant(pushed|unlanded|unreadable)
  local name=$1 forge=$2 flag=$3 variant=$4 c head
  c=$(make_case "$name")
  write_meta "$c" no-mistakes ship
  if [ "$variant" = unlanded ]; then wt_commit_file "$c" f.txt hi "work"; else
    wt_commit "$c" "ready"; add_fork_with_pushed_branch "$c"; fi
  case "$forge" in
    github) URL=https://github.com/example/repo/pull/7; LOG=gh ;;
    forgejo) URL=https://git.example.org/team/repo/pulls/7; LOG=tea ;;
    gitlab) URL=https://gitlab.example.com/team/sub/repo/-/merge_requests/7; LOG=glab ;;
  esac
  printf 'pr=%s\n' "$URL" >> "$c/state/task-x1.meta"
  seed_backlog_in_flight "$c"
  head=$(git -C "$c/wt" rev-parse HEAD)
  case "$forge" in
    github) add_gh_pr_open_for_head "$c" "$head" ;;
    forgejo) add_tea_pull_for_head "$c" false "$head" git.example.org open ;;
    gitlab) add_glab_mr_for_head "$c" opened "$head" ;;
  esac
  if [ "$variant" = unreadable ]; then
    for b in gh gh-axi; do printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh.log"\nexit 1\n' "$c" > "$c/fakebin/$b"; done
  fi
  [ "$flag" = none ] || : > "$c/config/$flag"
  CASE=$c
}

run() { # root -> sets RC OUT FLOG META WT
  ROOT=$1; TEARDOWN=$1/bin/fm-teardown.sh
  local sha; sha=$(git -C "$CASE/wt" rev-parse --short HEAD)  # differs per fixture
  RC=0; OUT=$(run_teardown "$CASE" 2>&1) || RC=$?
  OUT=$(printf '%s' "$OUT" | sed "s|$CASE|<home>|g; s|$sha|<sha>|g")
  if [ -e "$CASE/$LOG.log" ]; then FLOG=$(cat "$CASE/$LOG.log"); else FLOG="(no $LOG call)"; fi
  META=removed; [ -e "$CASE/state/task-x1.meta" ] && META=kept
  WTS=removed; [ -d "$CASE/wt" ] && WTS=kept
  ROOT=$HEAD_ROOT
}

show() {
  printf 'exit=%s  task record=%s  isolated copy=%s  backlog=%s\n' "$RC" "$META" "$WTS" "$(backlog_row_state "$CASE")"
  printf 'forge client calls:\n%s\n' "$FLOG" | sed 's/^/    /'
  printf 'teardown output (last 4 lines):\n'; printf '%s\n' "$OUT" | tail -4 | sed 's/^/    /'
}

compare_with_base() { # name forge variant
  build "h-$1" "$2" none "$3"; run "$HEAD_ROOT"; show
  local h="$RC|$META|$WTS|$FLOG|$OUT"
  build "b-$1" "$2" none "$3"; run "$BASE"
  local b="$RC|$META|$WTS|$FLOG|$OUT"
  if [ "$h" = "$b" ]; then echo "SAME AS BASE 427056c4: exit, records, forge calls and output are identical"
  else echo "DIFFERS FROM BASE 427056c4:"; diff <(printf '%s\n' "$b") <(printf '%s\n' "$h"); FAILS=$((FAILS+1)); fi
}

FAILS=0
for forge in github forgejo gitlab; do
  echo "=== $forge, open PR, branch pushed, NO opt-in file ==="
  compare_with_base "$forge-none" "$forge" pushed
  { [ "$RC" = 0 ] && [ "$META" = removed ] && [ "$FLOG" = "(no $LOG call)" ]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }
  for flag in park-on-review auto-land; do
    echo "=== $forge, open PR, branch pushed, config/$flag ==="
    build "h-$forge-$flag" "$forge" "$flag" pushed; run "$HEAD_ROOT"; show
    { [ "$RC" = 1 ] && [ "$META" = kept ] && [ "$WTS" = kept ] && [ "$FLOG" != "(no $LOG call)" ] \
      && [[ "$OUT" == *"open or unreadable PR at $URL"* ]]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }
  done
done
echo "=== github, open PR, work on no remote, NO opt-in file (main's unlanded-work refusal) ==="
compare_with_base github-unlanded github unlanded
{ [ "$RC" = 1 ] && [[ "$OUT" != *"open or unreadable PR"* ]]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }
echo "=== github, forge read fails, branch pushed, NO opt-in file ==="
compare_with_base github-unreadable-none github unreadable
{ [ "$RC" = 0 ] && [ "$FLOG" = "(no gh call)" ]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }
echo "=== github, forge read fails, branch pushed, config/park-on-review ==="
build h-github-unreadable github park-on-review unreadable; run "$HEAD_ROOT"; show
{ [ "$RC" = 1 ] && [ "$META" = kept ] && [[ "$OUT" == *"open or unreadable PR at $URL"* ]]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }
echo "=== same home, then --force ==="
run "$HEAD_ROOT" 2>/dev/null; ROOT=$HEAD_ROOT TEARDOWN=$HEAD_ROOT/bin/fm-teardown.sh
RC=0; OUT=$(run_teardown "$CASE" --force 2>&1) || RC=$?
META=removed; [ -e "$CASE/state/task-x1.meta" ] && META=kept
echo "exit=$RC  task record=$META"
{ [ "$RC" = 0 ] && [ "$META" = removed ]; } || { echo "UNEXPECTED"; FAILS=$((FAILS+1)); }

echo "=== repository tests for the configured merged / forced / closed / dirty / unlanded paths ==="
test_open_pr_gate_follows_the_opt_in
test_unmerged_pr_refuses_cleanup_until_merge_is_confirmed
test_forced_cleanup_discards_an_open_pr
test_closed_pr_takes_the_existing_landed_work_checks
echo "driver expectation failures: $FAILS"
exit "$FAILS"
