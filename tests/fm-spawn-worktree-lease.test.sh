#!/usr/bin/env bash
# Regression tests for task-lifetime Treehouse leases on ship/scout spawn.
#
# A process-bound `treehouse get` hold lapses when no process remains in the
# copy, so a later get can be handed a live task's recorded worktree. Installed
# `treehouse get --help` says `get --lease` never hands that copy out and never
# prunes it until `treehouse return`, even with no process inside it.
# These tests pin that fm-spawn acquires with --lease --lease-holder <task-id>
# and refuses a copy another live task in the home already records.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

make_lease_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_lease_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_lease_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJ_DIR" "$@"
}

# The installed tool still hands out a process-less copy on a plain get, and
# a durable lease is the thing that makes the same copy unreachable.
test_plain_treehouse_get_reuses_a_processless_copy() {
  local repo pool shell first second leased leased2
  command -v treehouse >/dev/null 2>&1 || {
    pass "skipped: treehouse is not installed"
    return 0
  }
  repo="$TMP_ROOT/tool-repo"
  pool="$TMP_ROOT/tool-pool"
  mkdir -p "$repo" "$pool"
  git init --quiet -b main "$repo"
  printf 'base\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm initial
  cat > "$TMP_ROOT/print-pwd-shell" <<'EOF'
#!/bin/sh
pwd -P
exit 0
EOF
  chmod +x "$TMP_ROOT/print-pwd-shell"

  first=$(
    CDPATH='' cd -- "$repo" &&
      SHELL="$TMP_ROOT/print-pwd-shell" treehouse get --root "$pool" 2>/dev/null | tail -n 1
  )
  first=$(CDPATH='' cd -- "$first" && pwd -P)
  second=$(
    CDPATH='' cd -- "$repo" &&
      SHELL="$TMP_ROOT/print-pwd-shell" treehouse get --root "$pool" 2>/dev/null | tail -n 1
  )
  second=$(CDPATH='' cd -- "$second" && pwd -P)
  [ -n "$first" ] && [ "$first" = "$second" ] \
    || fail "plain treehouse get did not reissue the process-less copy (first='$first' second='$second')"

  leased=$(CDPATH='' cd -- "$repo" && treehouse get --root "$pool" --lease --lease-holder live-task-a)
  leased2=$(CDPATH='' cd -- "$repo" && treehouse get --root "$pool" --lease --lease-holder other-task-b)
  [ -n "$leased" ] && [ "$leased" != "$leased2" ] \
    || fail "treehouse get --lease handed out a copy already leased (leased='$leased' leased2='$leased2')"
  treehouse return --force --root "$pool" "$leased" >/dev/null 2>&1 || true
  treehouse return --force --root "$pool" "$leased2" >/dev/null 2>&1 || true
  pass "plain treehouse get reissues a process-less copy; get --lease does not"
}

test_spawn_acquires_with_task_lifetime_lease() {
  local rec id out status log
  id=lease-acquire-a1
  rec=$(make_lease_case acquire "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  : > "$log"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" run_lease_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a scout spawn should acquire a leased worktree"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the spawn did not publish the leased worktree"
  grep -F "get --lease --lease-holder $id" "$log" >/dev/null \
    || fail "spawn did not acquire with treehouse get --lease --lease-holder $id"$'\n'"$(cat "$log")"
  grep -E '(^| )get( |$)' "$log" | grep -v -- '--lease' >/dev/null \
    && fail "spawn still invoked a process-bound treehouse get"$'\n'"$(cat "$log")"
  pass "fm-spawn acquires a ship/scout copy with a task-lifetime treehouse lease"
}

test_spawn_refuses_a_copy_another_live_task_records() {
  local rec id out status log other
  id=lease-occupied-b2
  other=live-owner-b2
  rec=$(make_lease_case occupied "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  : > "$log"
  fm_write_meta "$HOME_DIR/state/$other.meta" \
    "window=firstmate:fm-$other" \
    "endpoint_task_id=$other" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=direct-PR" \
    "yolo=off"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" run_lease_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn used a copy another live task already records"$'\n'"$out"
  assert_contains "$out" "$other" "the refusal did not name the live task that owns the copy"
  assert_contains "$out" "$WT_DIR" "the refusal did not name the occupied copy"
  assert_absent "$HOME_DIR/state/$id.meta" "occupied-copy spawn must not publish a task record"
  grep -F "return --force $WT_DIR" "$log" >/dev/null \
    && fail "spawn released the occupied copy instead of leaving it leased"$'\n'"$(cat "$log")"
  pass "fm-spawn refuses a copy another live task in the home already records"
}

test_spawn_retries_after_protecting_an_occupied_copy() {
  local rec id out status log other free queue
  id=lease-retry-c3
  other=live-owner-c3
  rec=$(make_lease_case retry "$id")
  read_lease_record "$rec"
  free="$CASE_DIR/free"
  git -C "$PROJ_DIR" worktree add --quiet -b "free-$id" "$free"
  queue="$CASE_DIR/queue"
  printf '%s\n%s\n' "$WT_DIR" "$free" > "$queue"
  log="$CASE_DIR/treehouse.log"
  : > "$log"
  fm_write_meta "$HOME_DIR/state/$other.meta" \
    "window=firstmate:fm-$other" \
    "endpoint_task_id=$other" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=scout"
  WT_DIR=$free

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_TREEHOUSE_QUEUE="$queue" \
    run_lease_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn should take the next unrecorded copy after protecting the occupied one"$'\n'"$out"
  assert_grep "worktree=$free" "$HOME_DIR/state/$id.meta" \
    "the spawn did not publish the unrecorded copy"
  assert_no_grep "worktree=$CASE_DIR/wt" "$HOME_DIR/state/$id.meta" \
    "the spawn published the occupied copy as the new task's worktree"
  grep -c -- '--lease --lease-holder '"$id" "$log" | grep -qx 2 \
    || fail "spawn should acquire twice when the first copy is occupied"$'\n'"$(cat "$log")"
  pass "fm-spawn leaves an occupied copy leased and launches in an unrecorded slot"
}

test_plain_treehouse_get_reuses_a_processless_copy
test_spawn_acquires_with_task_lifetime_lease
test_spawn_refuses_a_copy_another_live_task_records
test_spawn_retries_after_protecting_an_occupied_copy

echo "# all fm-spawn-worktree-lease tests passed"
