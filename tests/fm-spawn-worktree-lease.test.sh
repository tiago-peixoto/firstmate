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
  local repo pool first second leased leased2
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
  grep -E '(^|[[:space:]])return([[:space:]]|$)' "$log" >/dev/null \
    && fail "successful spawn returned its own lease"$'\n'"$(cat "$log")"
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

test_spawn_prepublish_failure_returns_the_lease() {
  local rec id out status log
  id=lease-prepub-d4
  rec=$(make_lease_case prepublish "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  : > "$log"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_TREEHOUSE_PATH="$WT_DIR" \
    FM_SPAWN_SEAT_POLLS=2 FM_SPAWN_SEAT_INTERVAL=0.01 \
    fm_test_run_spawn "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJ_DIR" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "pre-publish seating failure should abort"$'\n'"$out"
  assert_contains "$out" "did not enter leased worktree" \
    "pre-publish seating failure lacked a loud diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" "pre-publish abort must not leave a task record"
  grep -F "get --lease --lease-holder $id" "$log" >/dev/null \
    || fail "pre-publish abort never acquired a lease"$'\n'"$(cat "$log")"
  grep -F "return --force $WT_DIR" "$log" >/dev/null \
    || fail "pre-publish abort did not return the leased path"$'\n'"$(cat "$log")"
  pass "a seating failure before publish returns the leased copy"
}

test_spawn_postpublish_failure_returns_the_lease() {
  local rec id out status log seq spawn_home
  id=lease-postpub-e5
  rec=$(make_lease_case postpublish "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  seq="$CASE_DIR/seq.log"
  : > "$log"
  : > "$seq"
  spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home/.kimi-code"
  printf 'default_model = "test"\n' > "$spawn_home/.kimi-code/config.toml"
  fm_fake_exit0 "$FAKEBIN_DIR" kimi
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.real"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
printf 'tmux %s\\n' "\$*" >> "$seq"
if [ "\${1:-}" = capture-pane ]; then
  printf 'shell starting\\n\$ \\n'
  exit 0
fi
exec "\$(dirname "\$0")/tmux.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.real"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
set -u
printf 'treehouse %s\\n' "\$*" >> "$seq"
exec "\$(dirname "\$0")/treehouse.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
    run_lease_spawn "$id" --harness kimi --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "post-publish kimi readiness failure should abort"$'\n'"$out"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "post-publish kimi readiness failure lacked a loud diagnostic"
  assert_contains "$out" "closing window firstmate:fm-$id" \
    "post-publish abort did not report the window close"
  assert_contains "$out" "returned copy $WT_DIR" \
    "post-publish abort did not report the returned copy"
  assert_absent "$HOME_DIR/state/$id.meta" "post-publish abort must remove the published record"
  grep -F "get --lease --lease-holder $id" "$log" >/dev/null \
    || fail "post-publish abort never acquired a lease"$'\n'"$(cat "$log")"
  grep -F "return --force $WT_DIR" "$log" >/dev/null \
    || fail "post-publish abort did not return the leased path"$'\n'"$(cat "$log")"
  grep -E "tmux kill-window.*fm-$id" "$seq" >/dev/null \
    || fail "post-publish abort did not kill the task window"$'\n'"$(cat "$seq")"
  awk -v id="$id" '
    $1 == "tmux" && /kill-window/ && index($0, id) { kill_at = NR }
    $1 == "treehouse" && /return --force/ { ret_at = NR }
    END {
      if (!kill_at) { print "no kill-window"; exit 1 }
      if (!ret_at) { print "no return --force"; exit 1 }
      if (kill_at > ret_at) { print "kill-window after return --force"; exit 1 }
    }
  ' "$seq" || fail "task window was not killed before treehouse return"$'\n'"$(cat "$seq")"
  pass "a launch failure after publish returns the leased copy"
}

test_spawn_kimi_relaunch_delivery_failure_does_not_close_the_window() {
  local rec id out status seq spawn_home
  id=lease-relaunch-kimi-h8
  rec=$(make_lease_case relaunch-kimi "$id")
  read_lease_record "$rec"
  seq="$CASE_DIR/seq.log"
  : > "$seq"
  spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home/.kimi-code"
  printf 'default_model = "test"\n' > "$spawn_home/.kimi-code/config.toml"
  fm_fake_exit0 "$FAKEBIN_DIR" kimi
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=kimi" \
    "kind=scout"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.real"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
printf 'tmux %s\\n' "\$*" >> "$seq"
case "\$*" in
  *"#{pane_current_command}"*) printf 'zsh\\n'; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\\n' "$WT_DIR"; exit 0 ;;
esac
if [ "\${1:-}" = capture-pane ]; then
  printf 'shell starting\\n\$ \\n'
  exit 0
fi
if [ "\${1:-}" = list-windows ]; then
  printf '%s\\n' "fm-$id"
  exit 0
fi
exec "\$(dirname "\$0")/tmux.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"

  out=$(FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" --relaunch "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "kimi relaunch delivery failure should abort"$'\n'"$out"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "kimi relaunch delivery failure lacked a loud diagnostic"
  printf '%s\n' "$out" | grep -E 'clos(ed|ing) window' >/dev/null \
    && fail "kimi relaunch abort reported a window close"$'\n'"$out"
  grep -E "tmux kill-window" "$seq" >/dev/null \
    && fail "kimi relaunch abort killed the task window"$'\n'"$(cat "$seq")"
  assert_present "$HOME_DIR/state/$id.meta" "kimi relaunch abort must keep the task record"
  pass "a kimi relaunch delivery failure leaves the window open"
}

test_spawn_failed_rollback_does_not_close_the_window() {
  local rec id out status log seq spawn_home real_rm meta
  id=lease-rollback-fail-i9
  rec=$(make_lease_case rollback-fail "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  seq="$CASE_DIR/seq.log"
  : > "$log"
  : > "$seq"
  spawn_home="$HOME_DIR/user-home"
  mkdir -p "$spawn_home/.kimi-code"
  printf 'default_model = "test"\n' > "$spawn_home/.kimi-code/config.toml"
  fm_fake_exit0 "$FAKEBIN_DIR" kimi
  meta="$HOME_DIR/state/$id.meta"
  real_rm=$(command -v rm)
  cat > "$FAKEBIN_DIR/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != "$meta" ] || exit 1
done
exec "$real_rm" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/rm"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.real"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
printf 'tmux %s\\n' "\$*" >> "$seq"
if [ "\${1:-}" = capture-pane ]; then
  printf 'shell starting\\n\$ \\n'
  exit 0
fi
exec "\$(dirname "\$0")/tmux.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  mv "$FAKEBIN_DIR/treehouse" "$FAKEBIN_DIR/treehouse.real"
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
set -u
printf 'treehouse %s\\n' "\$*" >> "$seq"
exec "\$(dirname "\$0")/treehouse.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" FM_KIMI_READY_POLLS=1 FM_KIMI_POLL_INTERVAL=0 \
    run_lease_spawn "$id" --harness kimi --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "failed-rollback abort should fail"$'\n'"$out"
  assert_contains "$out" "kimi did not show a verified ready signal" \
    "failed-rollback abort lacked the launch diagnostic"
  printf '%s\n' "$out" | grep -E 'clos(ed|ing) window' >/dev/null \
    && fail "failed rollback reported a window close"$'\n'"$out"
  printf '%s\n' "$out" | grep -F "returned copy" >/dev/null \
    && fail "failed rollback reported a returned copy"$'\n'"$out"
  grep -E "tmux kill-window" "$seq" >/dev/null \
    && fail "failed rollback killed the task window"$'\n'"$(cat "$seq")"
  grep -F "return --force" "$seq" >/dev/null \
    && fail "failed rollback returned the leased copy"$'\n'"$(cat "$seq")"
  assert_present "$meta" "failed rollback must keep the task record"
  pass "a failed record rollback leaves the window and copy with the record"
}

test_spawn_refuses_a_copy_another_local_home_records() {
  local rec id out status log other root mate_abs root_abs
  id=lease-crosshome-f6
  other=live-owner-f6
  rec=$(make_lease_case crosshome "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  : > "$log"
  root="$CASE_DIR/root"
  mkdir -p "$root/state" "$root/data"
  touch "$root/state/.last-watcher-beat"
  mate_abs=$(CDPATH='' cd -- "$HOME_DIR" && pwd -P)
  root_abs=$(CDPATH='' cd -- "$root" && pwd -P)
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root_abs" \
    > "$HOME_DIR/.fm-secondmate-parent"
  printf -- '- mate - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-10)\n' \
    "$mate_abs" > "$root/data/secondmates.md"
  fm_write_meta "$root/state/$other.meta" \
    "window=firstmate:fm-$other" \
    "endpoint_task_id=$other" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=scout"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" run_lease_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn used a copy another local home already records"$'\n'"$out"
  assert_contains "$out" "$other" "the refusal did not name the live task that owns the copy"
  assert_contains "$out" "$WT_DIR" "the refusal did not name the occupied copy"
  assert_absent "$HOME_DIR/state/$id.meta" "cross-home occupied spawn must not publish a task record"
  grep -F "return --force $WT_DIR" "$log" >/dev/null \
    && fail "spawn released the occupied copy instead of leaving it leased"$'\n'"$(cat "$log")"
  pass "fm-spawn refuses a copy another local home already records"
}

test_spawn_refuses_before_endpoint_when_a_registered_home_is_missing() {
  local rec id out status log tmux_log
  id=lease-missing-home-g7
  rec=$(make_lease_case missing-home "$id")
  read_lease_record "$rec"
  log="$CASE_DIR/treehouse.log"
  tmux_log="$CASE_DIR/tmux.log"
  : > "$log"
  : > "$tmux_log"
  printf -- '- gone - fixture (home: %s; scope: fixture; projects: sample; added 2026-09-10)\n' \
    "$CASE_DIR/gone-home" > "$HOME_DIR/data/secondmates.md"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.real"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" >> "$tmux_log"
exec "\$(dirname "\$0")/tmux.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" run_lease_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn proceeded with a missing registered home"$'\n'"$out"
  assert_contains "$out" "could not enumerate local Firstmate homes for worktree occupancy" \
    "missing registered home did not refuse occupancy enumeration"
  assert_contains "$out" "registered local Firstmate home is unavailable" \
    "missing registered home was not named"
  grep -F new-window "$tmux_log" >/dev/null \
    && fail "missing registered home created a task window"$'\n'"$(cat "$tmux_log")"
  [ ! -s "$log" ] \
    || fail "missing registered home acquired a treehouse copy"$'\n'"$(cat "$log")"
  pass "spawn enumerates local homes before creating an endpoint or acquiring a copy"
}

# A secondmate home keeps its own clone of a project, but Treehouse names a pool
# by directory name and origin URL, so that clone shares the pool of every other
# home's clone of the same origin. The case sets up the main home's clone and a
# secondmate home's clone of one origin, each named "project".
make_other_clone_case() {
  local name=$1 id=$2 case_dir home main mate fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  main="$case_dir/main/projects/project"
  mate="$home/projects/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_fake_sleep_noop "$fakebin"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" "$id"
  fm_git_init_commit "$main"
  fm_git_add_origin "$main" "$case_dir/origin.git"
  git clone --quiet "$(git -C "$main" remote get-url origin)" "$mate"
  printf '%s\n' "$case_dir|$home|$main|$mate|$fakebin"
}

read_other_clone_record() {
  IFS='|' read -r CASE_DIR HOME_DIR MAIN_DIR PROJ_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

common_dir_of() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir) || return 1
  CDPATH='' cd -- "$common" && pwd -P
}

test_spawn_skips_a_copy_of_another_clone() {
  local rec id out status log queue foreign own
  id=lease-other-clone-j10
  rec=$(make_other_clone_case other-clone "$id")
  read_other_clone_record "$rec"
  foreign="$CASE_DIR/pool/1/project"
  own="$CASE_DIR/pool/2/project"
  git -C "$MAIN_DIR" worktree add --quiet --detach "$foreign"
  git -C "$PROJ_DIR" worktree add --quiet --detach "$own"
  queue="$CASE_DIR/queue"
  printf '%s\n%s\n' "$foreign" "$own" > "$queue"
  log="$CASE_DIR/treehouse.log"
  : > "$log"

  out=$(FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_TREEHOUSE_QUEUE="$queue" \
    fm_test_run_spawn "$HOME_DIR" "$own" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a claude spawn should skip a copy of another clone and launch in its own"$'\n'"$out"
  assert_grep "worktree=$own" "$HOME_DIR/state/$id.meta" \
    "the spawn did not publish the copy of its own clone"
  grep -F "return --force $foreign" "$log" >/dev/null \
    || fail "spawn did not return the copy of the other clone"$'\n'"$(cat "$log")"
  grep -F "return --force $own" "$log" >/dev/null \
    && fail "spawn returned its own copy"$'\n'"$(cat "$log")"
  pass "fm-spawn skips and returns a pooled copy of another clone of the same origin"
}

# The same case end to end against the installed tool: the main home's clone
# leaves an idle copy in the shared pool, and a secondmate home's claude spawn
# must still launch in a copy of its own clone.
test_spawn_with_real_treehouse_launches_in_its_own_clone() {
  local rec id out status log queue pool real foreign wt
  command -v treehouse >/dev/null 2>&1 || {
    pass "skipped: treehouse is not installed"
    return 0
  }
  real=$(command -v treehouse)
  id=lease-real-other-clone-k11
  rec=$(make_other_clone_case real-other-clone "$id")
  read_other_clone_record "$rec"
  pool="$CASE_DIR/pool"
  log="$CASE_DIR/treehouse.log"
  queue="$CASE_DIR/queue"
  : > "$log"
  # Records each call and the leased path the fake tmux reports as the pane's.
  cat > "$FAKEBIN_DIR/treehouse" <<SH
#!/usr/bin/env bash
set -u
printf '%s\\n' "\$*" >> "$log"
out=\$("$real" "\$@") || exit
case " \$* " in *" --lease "*) printf '%s\\n' "\$out" > "$queue.last" ;; esac
printf '%s\\n' "\$out"
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  foreign=$(CDPATH='' cd -- "$MAIN_DIR" &&
    TREEHOUSE_ROOT="$pool" "$real" get --lease --lease-holder main-task 2>/dev/null)
  [ -n "$foreign" ] || fail "the main clone could not lease a copy"
  TREEHOUSE_ROOT="$pool" "$real" return --force "$foreign" >/dev/null 2>&1 \
    || fail "the main clone could not return its copy"

  out=$(TREEHOUSE_ROOT="$pool" FM_FAKE_TREEHOUSE_QUEUE="$queue" \
    fm_test_run_spawn "$HOME_DIR" "" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "a claude spawn from a secondmate clone should launch despite a shared pool"$'\n'"$out"$'\n'"$(cat "$log")"
  wt=$(grep '^worktree=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  assert_equals "$(common_dir_of "$PROJ_DIR")" "$(common_dir_of "$wt")" \
    "the published worktree is not a copy of the spawning home's clone"
  grep -F "return --force $foreign" "$log" >/dev/null \
    || fail "spawn did not return the main clone's copy"$'\n'"$(cat "$log")"
  pass "fm-spawn launches in its own clone's copy from a pool shared with another clone"
}

# A task recorded before spawns skipped other clones' copies still sits in one.
# Relaunching it on claude must register trust against the clone that copy
# belongs to, while a copy of an unrelated repository stays refused.
run_other_clone_relaunch() {  # <id> <worktree>
  local id=$1 wt=$2
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=scout"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux.real"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\$*" in
  *"#{pane_current_command}"*) printf 'zsh\\n'; exit 0 ;;
  *"#{pane_current_path}"*) printf '%s\\n' "$wt"; exit 0 ;;
esac
if [ "\${1:-}" = list-windows ]; then
  printf '%s\\n' "fm-$id"
  exit 0
fi
exec "\$(dirname "\$0")/tmux.real" "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  fm_test_run_spawn "$HOME_DIR" "$wt" "$FAKEBIN_DIR" --relaunch "$id" --harness claude
}

test_relaunch_trusts_a_recorded_copy_of_another_clone() {
  local rec id out status foreign store
  id=lease-relaunch-other-clone-l12
  rec=$(make_other_clone_case relaunch-other-clone "$id")
  read_other_clone_record "$rec"
  foreign="$CASE_DIR/pool/1/project"
  git -C "$MAIN_DIR" worktree add --quiet --detach "$foreign"

  out=$(run_other_clone_relaunch "$id" "$foreign")
  status=$?
  printf '%s\n' "$out" | grep -F "refusing to pre-register Claude trust" >/dev/null \
    && fail "relaunch refused trust for a recorded copy of another clone of the same origin"$'\n'"$out"
  store="$HOME_DIR/user-home/.claude.json"
  grep -F "\"$(CDPATH='' cd -- "$foreign" && pwd -P)\"" "$store" >/dev/null 2>&1 \
    || fail "relaunch did not register trust for the recorded copy (exit $status)"$'\n'"$out"
  pass "a claude relaunch trusts a recorded copy of another clone of the same origin"
}

test_relaunch_still_refuses_a_copy_of_an_unrelated_repository() {
  local rec id out status other
  id=lease-relaunch-unrelated-m13
  rec=$(make_other_clone_case relaunch-unrelated "$id")
  read_other_clone_record "$rec"
  fm_git_worktree "$CASE_DIR/unrelated" "$CASE_DIR/unrelated-wt" unrelated
  other="$CASE_DIR/unrelated-wt"

  out=$(run_other_clone_relaunch "$id" "$other")
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch launched claude in a copy of an unrelated repository"$'\n'"$out"
  assert_contains "$out" "is not a worktree of project" \
    "relaunch did not refuse trust for a copy of an unrelated repository"
  pass "a claude relaunch still refuses a copy of an unrelated repository"
}

test_plain_treehouse_get_reuses_a_processless_copy
test_spawn_acquires_with_task_lifetime_lease
test_spawn_refuses_a_copy_another_live_task_records
test_spawn_retries_after_protecting_an_occupied_copy
test_spawn_prepublish_failure_returns_the_lease
test_spawn_postpublish_failure_returns_the_lease
test_spawn_kimi_relaunch_delivery_failure_does_not_close_the_window
test_spawn_failed_rollback_does_not_close_the_window
test_spawn_refuses_a_copy_another_local_home_records
test_spawn_refuses_before_endpoint_when_a_registered_home_is_missing
test_spawn_skips_a_copy_of_another_clone
test_spawn_with_real_treehouse_launches_in_its_own_clone
test_relaunch_trusts_a_recorded_copy_of_another_clone
test_relaunch_still_refuses_a_copy_of_an_unrelated_repository

echo "# all fm-spawn-worktree-lease tests passed"
