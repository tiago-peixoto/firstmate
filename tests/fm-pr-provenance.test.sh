#!/usr/bin/env bash
# Tests for bin/fm-pr-provenance.sh: the builder identity of an authored pull
# request must travel with the work on the forge, so a home that never held the
# authoring task can establish it without asking anyone.
#
# Every case runs two homes against one bare "forge" repo:
#   author   - has state/<id>.meta and the task worktree
#   reviewer - has only a clone and an exact head SHA
#
# Matrix:
#   (a) reviewer before any record is written -> refuses, names the head
#   (b) author stamps -> reviewer reads family/model/effort with no shared state
#   (c) head moves after the stamp -> reviewer still resolves from the branch
#   (d) reader surfaces (branch, commit messages, tree) carry no fleet words
#   (e) unrecognized harness -> stamp refuses instead of inventing a family
#   (f) commit not on the forge yet -> stamp refuses instead of writing a
#       record nobody can reach
#   (g) two different records inside one pull request -> show refuses
#   (h) malformed or unrecognized record -> show refuses
#   (i) a commit that is not part of the pull request -> show refuses
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PROVENANCE="$ROOT/bin/fm-pr-provenance.sh"
NOTES_REF=refs/notes/build-provenance
TMP_ROOT=$(fm_test_tmproot fm-pr-provenance-tests)

# One forge, one authoring home with a task worktree on fm/<id>, and one
# reviewer clone that shares nothing but the forge URL.
make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main

  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main >/dev/null 2>&1 || true
  git -C "$case_dir/project" worktree add -q -b fm/task-b1 "$case_dir/wt" main

  git clone -q "$case_dir/origin.git" "$case_dir/reviewer"
  git -C "$case_dir/reviewer" remote set-head origin main >/dev/null 2>&1 || true

  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-b1.meta" \
    "window=fm-task-b1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "$@"
}

# One implementation commit on the task branch, pushed to the forge.
author_commit() {
  local case_dir=$1 message=${2:-implement the requested change}
  printf '%s\n' "$message" > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "$message"
  git -C "$case_dir/wt" push -q origin fm/task-b1
  git -C "$case_dir/wt" rev-parse HEAD
}

run_stamp() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROVENANCE" stamp "$@"
}

# The reviewer side deliberately gets no FM_STATE_OVERRIDE: it must work with
# nothing but a clone and a SHA.
run_show() {
  FM_ROOT_OVERRIDE="$ROOT" "$PROVENANCE" show "$@"
}

# Refresh the reviewer clone the way a review lane does before an exact-head
# review.
reviewer_fetch() {
  git -C "$1/reviewer" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
}

test_help_renders_the_contract() {
  local out
  out=$("$PROVENANCE" --help) || fail "help: --help must exit 0"
  assert_contains "$out" "fm-pr-provenance.sh stamp <task-id>" "help: must document stamp"
  assert_contains "$out" "fm-pr-provenance.sh show <repo-dir> <commit-ish>" "help: must document show"
  assert_contains "$out" "refs/notes/build-provenance" "help: must name where the record lives"
  pass "fm-pr-provenance --help documents both verbs and where the record lives"
}

test_reviewer_refuses_before_any_record() {
  local case_dir head out rc
  case_dir=$(make_case no-record)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "no-record: an unestablished builder family must refuse"
  assert_contains "$out" "cannot establish builder family" \
    "no-record: refusal must say the identity could not be established"
  assert_contains "$out" "$head" "no-record: refusal must name the exact head"
  pass "fm-pr-provenance refuses rather than guessing when no record exists"
}

test_reviewer_reads_stamped_identity_without_shared_state() {
  local case_dir head out
  case_dir=$(make_case stamped)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")

  run_stamp "$case_dir" task-b1 > "$case_dir/stamp.out" 2>&1 \
    || fail "stamped: stamp failed"$'\n'"$(cat "$case_dir/stamp.out")"

  reviewer_fetch "$case_dir"
  out=$(run_show "$case_dir/reviewer" "$head" 2> "$case_dir/show.err") \
    || fail "stamped: show failed"$'\n'"$(cat "$case_dir/show.err")"

  assert_contains "$out" "family=claude" "stamped: reviewer must read the builder family"
  assert_contains "$out" "model=opus" "stamped: reviewer must read the builder model"
  assert_contains "$out" "effort=high" "stamped: reviewer must read the builder effort"
  pass "fm-pr-provenance carries builder identity from author to reviewer through the forge"
}

test_later_head_resolves_from_the_branch() {
  local case_dir first second out
  case_dir=$(make_case moved-head)
  write_task_meta "$case_dir" "harness=codex" "model=gpt-5" "effort=medium"
  first=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "moved-head: stamp failed"

  # A validation fix round pushes a new head without re-stamping.
  second=$(author_commit "$case_dir" "apply pipeline fix")
  [ "$first" != "$second" ] || fail "moved-head: fixture did not move the head"
  reviewer_fetch "$case_dir"

  out=$(run_show "$case_dir/reviewer" "$second" 2> "$case_dir/show.err") \
    || fail "moved-head: show failed"$'\n'"$(cat "$case_dir/show.err")"

  assert_contains "$out" "family=codex" \
    "moved-head: a later head must still resolve to the branch's builder"
  pass "fm-pr-provenance resolves a moved head from the pull request's own commits"
}

test_reader_surfaces_stay_free_of_fleet_vocabulary() {
  local case_dir head refs subject tree note
  case_dir=$(make_case reader-surfaces)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "reader-surfaces: stamp failed"

  refs=$(git -C "$case_dir/project" ls-remote origin)
  subject=$(git -C "$case_dir/wt" log --format=%B -n 5 fm/task-b1)
  tree=$(git -C "$case_dir/wt" ls-tree -r --name-only HEAD)

  assert_contains "$refs" "$NOTES_REF" \
    "reader-surfaces: the record must reach the forge on its own ref"
  for word in firstmate crewmate task-b1 brief; do
    assert_not_contains "$subject" "$word" \
      "reader-surfaces: commit messages must not carry '$word'"
    assert_not_contains "$tree" "$word" \
      "reader-surfaces: the tree must not carry '$word'"
  done

  # The record itself is on a ref no forge UI renders, and still names nothing
  # fleet-internal.
  note=$(git -C "$case_dir/project" fetch -q origin "+$NOTES_REF:$NOTES_REF" \
    && git -C "$case_dir/project" notes --ref="$NOTES_REF" show "$head")
  for word in firstmate crewmate task-b1 brief; do
    assert_not_contains "$note" "$word" "reader-surfaces: the record must not carry '$word'"
  done
  pass "fm-pr-provenance keeps fleet vocabulary off every surface a reader sees"
}

test_unrecognized_harness_refuses() {
  local case_dir out rc refs
  case_dir=$(make_case unknown-harness)
  write_task_meta "$case_dir" "harness=mystery-tool" "model=x" "effort=high"
  author_commit "$case_dir" >/dev/null

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "unknown-harness: stamp must refuse an unverified harness"
  assert_contains "$out" "mystery-tool" "unknown-harness: refusal must name the recorded value"
  refs=$(git -C "$case_dir/project" ls-remote origin)
  assert_not_contains "$refs" "$NOTES_REF" \
    "unknown-harness: nothing may be published when the family is unknown"
  pass "fm-pr-provenance refuses to publish a guessed builder family"
}

test_unpushed_commit_refuses() {
  local case_dir out rc
  case_dir=$(make_case unpushed)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  printf 'local only\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "not pushed yet"

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "unpushed: stamp must refuse a commit the forge does not have"
  assert_contains "$out" "not on the forge" \
    "unpushed: refusal must say the commit has not been pushed"
  pass "fm-pr-provenance refuses to record provenance for an unreachable commit"
}

test_unreachable_forge_refuses_the_publish() {
  local case_dir out rc
  case_dir=$(make_case unreachable-forge)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  author_commit "$case_dir" >/dev/null
  git -C "$case_dir/wt" remote set-url origin "$case_dir/gone.git"

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "unreachable-forge: stamp must refuse when the record cannot be published"
  assert_contains "$out" "could not publish the build record" \
    "unreachable-forge: refusal must say the record never reached the forge"
  assert_not_contains "$out" "Overwriting existing notes" \
    "unreachable-forge: re-stamping chatter must not surface as a diagnostic"
  pass "fm-pr-provenance refuses when the record cannot reach the forge"
}

test_unconfirmable_commit_names_the_failed_fetch() {
  local case_dir out rc
  case_dir=$(make_case unconfirmable)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  printf 'local only\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "not pushed yet"
  git -C "$case_dir/wt" remote set-url origin "$case_dir/gone.git"

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "unconfirmable: stamp must refuse when the forge cannot be consulted"
  assert_contains "$out" "the fetch from origin failed" \
    "unconfirmable: refusal must name the unreachable forge, not blame the branch"
  pass "fm-pr-provenance names an unreachable forge instead of blaming the branch"
}

test_conflicting_records_refuse() {
  local case_dir first second out rc
  case_dir=$(make_case conflicting)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  first=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "conflicting: first stamp failed"

  second=$(author_commit "$case_dir" "second commit")
  write_task_meta "$case_dir" "harness=codex" "model=gpt-5" "effort=high"
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "conflicting: second stamp failed"
  [ "$first" != "$second" ] || fail "conflicting: fixture did not produce two commits"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$second" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "conflicting: disagreeing records must refuse"
  assert_contains "$out" "conflicting" "conflicting: refusal must say the records disagree"
  pass "fm-pr-provenance refuses when one pull request carries disagreeing records"
}

test_malformed_record_refuses() {
  local case_dir head out rc
  case_dir=$(make_case malformed)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")

  git -C "$case_dir/project" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$case_dir/project" notes --ref="$NOTES_REF" \
    add -f -m "family=totally-made-up" "$head"
  git -C "$case_dir/project" push -q origin "$NOTES_REF"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "malformed: an unrecognized family must refuse"
  assert_contains "$out" "cannot establish builder family" \
    "malformed: refusal must say the identity could not be established"
  pass "fm-pr-provenance refuses a record whose builder family is not a verified one"
}

test_repeated_key_in_a_record_refuses() {
  local case_dir head out rc
  case_dir=$(make_case repeated-key)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")

  git -C "$case_dir/project" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$case_dir/project" notes --ref="$NOTES_REF" \
    add -f -m "family=claude"$'\n'"family=codex" "$head" >/dev/null 2>&1
  git -C "$case_dir/project" push -q origin "$NOTES_REF"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "repeated-key: a record naming two families must refuse"
  assert_not_contains "$out" "family=claude" \
    "repeated-key: no identity may be printed from a record that answers twice"
  pass "fm-pr-provenance refuses a record that names the builder family twice"
}

test_commit_outside_the_pull_request_refuses() {
  local case_dir head base out rc
  case_dir=$(make_case outside-range)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "outside-range: stamp failed"
  reviewer_fetch "$case_dir"
  base=$(git -C "$case_dir/reviewer" rev-parse origin/main)

  set +e
  out=$(run_show "$case_dir/reviewer" "$base" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "outside-range: a base commit must not inherit a branch record"
  assert_not_contains "$out" "family=claude" \
    "outside-range: a commit outside the pull request must not resolve"
  [ -n "$head" ] || fail "outside-range: fixture head missing"
  pass "fm-pr-provenance does not attribute a commit outside the pull request"
}

test_help_renders_the_contract
test_reviewer_refuses_before_any_record
test_reviewer_reads_stamped_identity_without_shared_state
test_later_head_resolves_from_the_branch
test_reader_surfaces_stay_free_of_fleet_vocabulary
test_unrecognized_harness_refuses
test_unpushed_commit_refuses
test_unreachable_forge_refuses_the_publish
test_unconfirmable_commit_names_the_failed_fetch
test_conflicting_records_refuse
test_malformed_record_refuses
test_repeated_key_in_a_record_refuses
test_commit_outside_the_pull_request_refuses
