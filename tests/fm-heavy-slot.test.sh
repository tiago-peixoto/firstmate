#!/usr/bin/env bash
# Behavior tests for bin/fm-heavy-slot.sh: atomic directory claims in the listed
# order, an owner line whose pid lives for the whole heavy command, release that
# never touches another task's slot, the load bar, and claims that span several
# commands. Every slot lives under this suite's own temp root, never under the
# machine's real /tmp/fm-heavy-suite* slots.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-heavy-slot-test)
HELPER="$ROOT/bin/fm-heavy-slot.sh"
LOADAVG="$TMP_ROOT/loadavg"
printf '1.00 1.00 1.00 1/100 1\n' > "$LOADAVG"
export FM_HEAVY_SLOT_LOADAVG_OVERRIDE="$LOADAVG"
export FM_HEAVY_SLOT_POLL=0.05

# Iteration-counted so a loaded machine stretches the wait instead of failing it.
wait_for() {
  local i=0
  until "$@"; do
    i=$((i + 1))
    [ "$i" -lt 600 ] || return 1
    sleep 0.05
  done
}

path_exists() { [ -e "$1" ]; }
path_absent() { [ ! -e "$1" ]; }

new_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE"
  S1="$CASE/fm-heavy-suite.lock"
  S2="$CASE/fm-heavy-suite.lock-2"
}

test_run_claims_a_directory_and_releases_it() {
  local out rc owner pid first
  new_case run-basic
  "$HELPER" run --task t1 --load 5 --slot "$S1" --slot "$S2" -- \
    sh -c 'sleep 0.1 & echo $! > "$1/first"; wait; echo "$PPID" > "$1/parent"; touch "$1/between"; until [ -e "$1/go" ]; do sleep 0.05; done; exit 7' sh "$CASE" &
  pid=$!
  wait_for path_exists "$CASE/between" || fail "the wrapped command never ran"
  [ -d "$S1" ] && [ ! -L "$S1" ] || fail "run did not claim the first listed slot as a directory"
  path_absent "$S2" || fail "run claimed a second slot"
  owner=$(cat "$S1/owner")
  assert_equals "task=t1 pid=$(cat "$CASE/parent")" "$owner" "owner line does not record the wrapper that runs the command"
  first=$(cat "$CASE/first")
  ! kill -0 "$first" 2>/dev/null || fail "the suite's first short-lived process should be gone by now"
  kill -0 "${owner##*pid=}" 2>/dev/null || fail "the owner pid died between the suite's short-lived processes"
  touch "$CASE/go"
  wait "$pid"; rc=$?
  expect_code 7 "$rc" "run must exit with the command's own status"
  assert_absent "$S1" "run did not release its slot when the command ended"
  out=$(ls -A "$CASE")
  assert_not_contains "$out" "owner." "run left a temporary owner file behind"
  pass "fm-heavy-slot: run claims the first slot as a directory, records a pid alive for the whole command, and releases it"
}

test_run_skips_slots_it_cannot_claim_and_never_touches_them() {
  local before_dir before_file
  new_case run-skip
  mkdir "$S1"
  printf 'task=other pid=1\n' > "$S1/owner"
  "$HELPER" run --task t1 --load 5 --slot "$S1" --slot "$S2" -- sh -c 'cat "$1/owner" > "$2/seen"' sh "$S2" "$CASE" \
    || fail "run failed beside a held slot"
  case "$(cat "$CASE/seen")" in
    "task=t1 pid="[0-9]*) : ;;
    *) fail "run did not claim the second slot (owner: $(cat "$CASE/seen"))" ;;
  esac
  assert_equals "task=other pid=1" "$(cat "$S1/owner")" "run rewrote another task's slot"
  assert_absent "$S2" "run did not release the second slot"

  rm -rf "$S1"
  printf 'legacy holder\n' > "$S1"
  before_file=$(cat "$S1")
  "$HELPER" run --task t1 --load 5 --slot "$S1" --slot "$S2" -- touch "$CASE/ran-beside-file" \
    || fail "run failed beside a plain file at a slot path"
  [ -f "$S1" ] && [ "$(cat "$S1")" = "$before_file" ] || fail "run removed or changed a plain file at a slot path"
  assert_present "$CASE/ran-beside-file" "run did not use the next slot beside a plain file"

  rm -f "$S1"
  mkdir "$S1"
  printf 'upstream-task\n12345\n' > "$S1/owner"
  before_dir=$(cat "$S1/owner")
  "$HELPER" release --task upstream-task --slot "$S1" >/dev/null || fail "release exited non-zero"
  [ -d "$S1" ] && [ "$(cat "$S1/owner")" = "$before_dir" ] || fail "release removed a hand-written claim it cannot prove is its own"
  pass "fm-heavy-slot: a held slot or a plain file at a slot path is skipped and left exactly as it was"
}

test_concurrent_runs_never_share_a_slot() {
  local i pids=() count
  new_case exclusive
  for i in 1 2 3 4; do
    "$HELPER" run --task "t$i" --load 5 --slot "$S1" -- \
      sh -c 'mkdir "$1/inside" 2>/dev/null || touch "$1/overlap"; sleep 0.2; rmdir "$1/inside" 2>/dev/null; touch "$1/done-$2"' sh "$CASE" "$i" 2>/dev/null &
    pids+=("$!")
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent run exited non-zero"
  done
  assert_absent "$CASE/overlap" "two runs held the same slot at once"
  count=$(find "$CASE" -name 'done-*' | wc -l | tr -d ' ')
  assert_equals 4 "$count" "not every concurrent run completed"
  assert_absent "$S1" "the slot was left held after every run ended"
  pass "fm-heavy-slot: concurrent runs on one slot take turns and never overlap"
}

test_run_waits_for_the_load_bar() {
  local pid i
  new_case load
  printf '12.50 9.00 8.00 1/100 1\n' > "$LOADAVG"
  "$HELPER" run --task t1 --load 10 --slot "$S1" -- touch "$CASE/ran" 2> "$CASE/err" &
  pid=$!
  wait_for grep -q "waiting for the 1-minute load (12.50) to fall to 10 or below" "$CASE/err" \
    || fail "run did not report that it waits for the load"
  for i in 1 2 3 4 5; do
    sleep 0.05
    path_absent "$S1" || fail "run claimed a slot while the load was above the bar"
  done
  assert_absent "$CASE/ran" "run started the command while the load was above the bar"
  printf '10.00 9.00 8.00 1/100 1\n' > "$LOADAVG"
  wait "$pid" || fail "run failed once the load reached the bar"
  assert_present "$CASE/ran" "run never started once the load reached the bar"
  printf 'busy\n' > "$LOADAVG"
  "$HELPER" run --task t1 --load 10 --slot "$S1" -- touch "$CASE/blind" 2>/dev/null
  expect_code 1 "$?" "an unreadable load must refuse rather than admit blind"
  assert_absent "$CASE/blind" "an unreadable load still ran the command"
  printf '1.00 1.00 1.00 1/100 1\n' > "$LOADAVG"
  pass "fm-heavy-slot: run starts only once the 1-minute load is at or below the bar"
}

test_claim_spans_commands_until_release() {
  local out
  new_case claim
  out=$("$HELPER" claim --task t2 --load 5 --slot "$S1" --slot "$S2") || fail "claim failed"
  assert_contains "$out" "claimed $S1" "claim did not report its slot"
  assert_equals "task=t2 pid=-" "$(cat "$S1/owner")" "a claim with no command running must record pid -"
  out=$("$HELPER" claim --task t2 --load 5 --slot "$S1" --slot "$S2") || fail "a repeated claim failed"
  assert_contains "$out" "already holds $S1" "a repeated claim did not keep the task's one slot"
  assert_absent "$S2" "a task claimed a second slot"

  printf '50.00 50.00 50.00 1/100 1\n' > "$LOADAVG"
  "$HELPER" run --task t2 --load 5 --slot "$S1" --slot "$S2" -- sh -c 'cat "$1/owner" > "$2/seen"; echo "$PPID" > "$2/parent"' sh "$S1" "$CASE" \
    || fail "run inside the task's own claim failed"
  printf '1.00 1.00 1.00 1/100 1\n' > "$LOADAVG"
  assert_equals "task=t2 pid=$(cat "$CASE/parent")" "$(cat "$CASE/seen")" "run inside a claim did not record its own pid"
  assert_absent "$S2" "run inside a claim claimed another slot"
  assert_equals "task=t2 pid=-" "$(cat "$S1/owner")" "run inside a claim did not leave it held with pid -"

  "$HELPER" release --task other --slot "$S1" --slot "$S2" >/dev/null || fail "release by another task exited non-zero"
  [ -d "$S1" ] || fail "another task's release removed this task's claim"
  out=$("$HELPER" release --task t2 --slot "$S1" --slot "$S2") || fail "release failed"
  assert_contains "$out" "released $S1" "release did not report the slot"
  assert_absent "$S1" "release did not remove the task's own slot"
  pass "fm-heavy-slot: a claim spans commands without a second slot or a load wait, until its own release"
}

test_term_never_releases_under_a_running_command() {
  local pid rc
  new_case term
  "$HELPER" run --task t1 --load 5 --slot "$S1" -- \
    sh -c 'touch "$1/started"; until [ -e "$1/go" ]; do sleep 0.05; done' sh "$CASE" &
  pid=$!
  wait_for path_exists "$CASE/started" || fail "the wrapped command never started"
  kill -TERM "$pid"
  sleep 0.3
  [ -d "$S1" ] || fail "TERM released the slot while the command was still running"
  touch "$CASE/go"
  wait "$pid"; rc=$?
  expect_code 143 "$rc" "a TERMed run must report the TERM once the command ends"
  assert_absent "$S1" "the slot was not released after the TERMed command ended"
  pass "fm-heavy-slot: TERM takes effect only after the command ends, then releases the slot"
}

test_usage_refuses_inexact_slots() {
  local out rc
  new_case usage
  out=$("$HELPER" run --task t1 --load 5 --slot -2 -- true 2>&1); rc=$?
  expect_code 2 "$rc" "a bare suffix must be refused"
  assert_contains "$out" "never a bare suffix" "bare suffix refusal did not explain itself"
  "$HELPER" run --task t1 --load 5 --slot fm-heavy-suite.lock -- true 2>/dev/null
  expect_code 2 "$?" "a relative slot path must be refused"
  "$HELPER" run --task t1 --load 5 --slot "$CASE/missing/fm-heavy-suite.lock" -- true 2>/dev/null
  expect_code 2 "$?" "a slot in a missing directory must be refused"
  "$HELPER" run --load 5 --slot "$S1" -- true 2>/dev/null
  expect_code 2 "$?" "a missing task id must be refused"
  "$HELPER" run --task 'a b' --load 5 --slot "$S1" -- true 2>/dev/null
  expect_code 2 "$?" "an invalid task id must be refused"
  "$HELPER" run --task t1 --load high --slot "$S1" -- true 2>/dev/null
  expect_code 2 "$?" "a non-numeric load bar must be refused"
  "$HELPER" run --task t1 --load 5 --slot "$S1" 2>/dev/null
  expect_code 2 "$?" "run without a command must be refused"
  "$HELPER" claim --task t1 --load 5 --slot "$S1" -- true 2>/dev/null
  expect_code 2 "$?" "claim with a command must be refused"
  assert_absent "$S1" "a refused call claimed a slot"
  pass "fm-heavy-slot: bare suffixes, relative paths, and malformed calls are refused before any claim"
}

test_run_claims_a_directory_and_releases_it
test_run_skips_slots_it_cannot_claim_and_never_touches_them
test_concurrent_runs_never_share_a_slot
test_run_waits_for_the_load_bar
test_claim_spans_commands_until_release
test_term_never_releases_under_a_running_command
test_usage_refuses_inexact_slots
