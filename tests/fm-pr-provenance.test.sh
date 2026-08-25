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
#   (j) provider-qualified models survive the untrusted-record parser
#   (k) concurrent linked-worktree stamps preserve both records
#   (l) stale fetch and base state never establish an identity
#   (m) a published commit cannot be reassigned after task relaunch
#   (n) invalid records anywhere in the change refuse the whole identity
#   (o) show accepts only an exact full head SHA and the forge's current base
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

wait_for_path() {
  local path=$1 remaining=${2:-500}
  while [ ! -e "$path" ] && [ "$remaining" -gt 0 ]; do
    /bin/sleep 0.01
    remaining=$((remaining - 1))
  done
  [ -e "$path" ]
}

test_help_renders_the_contract() {
  local out
  out=$("$PROVENANCE" --help) || fail "help: --help must exit 0"
  assert_contains "$out" "fm-pr-provenance.sh stamp <task-id>" "help: must document stamp"
  assert_contains "$out" "fm-pr-provenance.sh show <repo-dir> <head-sha>" "help: must document show"
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

test_identical_restamp_is_silent_and_idempotent() {
  local case_dir before_ref after_ref out
  case_dir=$(make_case identical-restamp)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  author_commit "$case_dir" >/dev/null
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "identical-restamp: first stamp failed"
  before_ref=$(git -C "$case_dir/project" ls-remote origin "$NOTES_REF" | cut -f1)

  out=$(run_stamp "$case_dir" task-b1 2>&1) \
    || fail "identical-restamp: an identical restamp must succeed"
  [ -z "$out" ] || fail "identical-restamp: an identical restamp must be silent"
  after_ref=$(git -C "$case_dir/project" ls-remote origin "$NOTES_REF" | cut -f1)
  [ "$after_ref" = "$before_ref" ] \
    || fail "identical-restamp: an identical restamp rewrote the forge ref"
  pass "fm-pr-provenance leaves an identical published record untouched"
}

test_relaunch_cannot_reassign_a_published_commit() {
  local case_dir head unchanged before_ref after_ref before_note after_note out rc shown
  case_dir=$(make_case immutable-record)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "immutable-record: first stamp failed"
  before_ref=$(git -C "$case_dir/project" ls-remote origin "$NOTES_REF" | cut -f1)
  before_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$head")

  write_task_meta "$case_dir" "harness=codex" "model=gpt-5" "effort=high"
  unchanged=$(git -C "$case_dir/wt" rev-parse HEAD)
  [ "$unchanged" = "$head" ] \
    || fail "immutable-record: relaunch fixture unexpectedly changed the worktree head"

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "immutable-record: changed relaunch metadata must not replace a record"
  assert_contains "$out" "family=claude" \
    "immutable-record: refusal must name the published builder"
  assert_contains "$out" "family=codex" \
    "immutable-record: refusal must name the replacement builder"
  after_ref=$(git -C "$case_dir/project" ls-remote origin "$NOTES_REF" | cut -f1)
  after_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$head")
  [ "$after_ref" = "$before_ref" ] \
    || fail "immutable-record: refused replacement still changed the forge ref"
  [ "$after_note" = "$before_note" ] \
    || fail "immutable-record: refused replacement still changed the persisted record"

  reviewer_fetch "$case_dir"
  shown=$(run_show "$case_dir/reviewer" "$head" 2> "$case_dir/show.err") \
    || fail "immutable-record: original identity no longer resolves"
  assert_contains "$shown" "family=claude" \
    "immutable-record: reviewer must retain the original builder"
  assert_not_contains "$shown" "family=codex" \
    "immutable-record: reviewer must never see the relaunch identity for the old commit"
  pass "fm-pr-provenance never reassigns a published commit after task relaunch"
}

test_provider_qualified_models_round_trip() {
  local case_dir harness model effort family head out
  while IFS='|' read -r harness model effort family; do
    case_dir=$(make_case "qualified-$harness")
    write_task_meta "$case_dir" "harness=$harness" "model=$model" "effort=$effort"
    head=$(author_commit "$case_dir")

    run_stamp "$case_dir" task-b1 > "$case_dir/stamp.out" 2>&1 \
      || fail "qualified-$harness: stamp rejected supported model $model"$'\n'"$(cat "$case_dir/stamp.out")"
    reviewer_fetch "$case_dir"
    out=$(run_show "$case_dir/reviewer" "$head" 2> "$case_dir/show.err") \
      || fail "qualified-$harness: show failed"$'\n'"$(cat "$case_dir/show.err")"

    assert_contains "$out" "family=$family" \
      "qualified-$harness: reviewer must read the verified adapter family"
    assert_contains "$out" "model=$model" \
      "qualified-$harness: provider-qualified model must survive the record"
    assert_contains "$out" "effort=$effort" \
      "qualified-$harness: effort must survive the record"
  done <<'EOF'
opencode|anthropic/claude-sonnet-4-5|high|opencode
pi|openai-codex/gpt-5.6-sol|max|pi
EOF
  pass "fm-pr-provenance carries supported provider-qualified model identifiers"
}

test_reviewer_fetches_an_unseen_remote_head() {
  local case_dir head out
  case_dir=$(make_case unseen-head)
  write_task_meta "$case_dir" "harness=codex" "model=gpt-5" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "unseen-head: stamp failed"

  git -C "$case_dir/reviewer" cat-file -e "$head^{commit}" 2>/dev/null \
    && fail "unseen-head: fixture already contains the requested head"
  out=$(run_show "$case_dir/reviewer" "$head" 2> "$case_dir/show.err") \
    || fail "unseen-head: show could not fetch the requested remote head"$'\n'"$(cat "$case_dir/show.err")"

  assert_contains "$out" "family=codex" \
    "unseen-head: reviewer must resolve the identity after fetching the requested head"
  pass "fm-pr-provenance resolves an unseen requested head from the forge"
}

test_mutable_head_name_refuses_stale_remote_tracking_state() {
  local case_dir stamped replacement local_head remote_head out rc
  case_dir=$(make_case mutable-head)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  stamped=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "mutable-head: stamp failed"
  reviewer_fetch "$case_dir"

  replacement=$(printf '%s\n' "force-pushed replacement" \
    | git -C "$case_dir/wt" commit-tree "main^{tree}" -p main)
  git -C "$case_dir/wt" push -q --force origin "$replacement:refs/heads/fm/task-b1"
  git -C "$case_dir/wt" merge-base --is-ancestor "$stamped" "$replacement" \
    && fail "mutable-head: replacement did not diverge from the stamped commit"
  local_head=$(git -C "$case_dir/reviewer" rev-parse origin/fm/task-b1)
  remote_head=$(git -C "$case_dir/reviewer" ls-remote origin refs/heads/fm/task-b1 | cut -f1)
  [ "$local_head" = "$stamped" ] \
    || fail "mutable-head: reviewer did not retain the stale stamped name"
  [ "$remote_head" = "$replacement" ] \
    || fail "mutable-head: forge did not receive the force-pushed replacement"

  set +e
  out=$(run_show "$case_dir/reviewer" origin/fm/task-b1 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "mutable-head: a remote-tracking name must refuse"
  assert_contains "$out" "exact full SHA" \
    "mutable-head: refusal must name the immutable head requirement"
  assert_not_contains "$out" "family=claude" \
    "mutable-head: a stale name must not supply the old commit's identity"
  pass "fm-pr-provenance refuses mutable head names after a force-push"
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

test_concurrent_linked_worktree_stamps_preserve_both_records() {
  local case_dir base a_head b_head fakebin real_git a_pid b_pid a_rc=0 b_rc=0
  local a_note b_note
  case_dir=$(make_case concurrent-stamps)
  base=$(git -C "$case_dir/project" rev-parse main)
  git -C "$case_dir/project" notes --ref="$NOTES_REF" add -m "family=claude" "$base"
  git -C "$case_dir/project" push -q origin "$NOTES_REF"

  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  a_head=$(author_commit "$case_dir" "first concurrent build")

  git -C "$case_dir/project" worktree add -q -b fm/task-b2 "$case_dir/wt-b2" main
  printf '%s\n' "second concurrent build" > "$case_dir/wt-b2/feature.txt"
  git -C "$case_dir/wt-b2" add feature.txt
  git -C "$case_dir/wt-b2" commit -qm "second concurrent build"
  git -C "$case_dir/wt-b2" push -q origin fm/task-b2
  b_head=$(git -C "$case_dir/wt-b2" rev-parse HEAD)
  [ "$a_head" != "$b_head" ] || fail "concurrent-stamps: fixture produced one shared head"
  fm_write_meta "$case_dir/state/task-b2.meta" \
    "window=fm-task-b2" \
    "worktree=$case_dir/wt-b2" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes" \
    "harness=codex" \
    "model=gpt-5" \
    "effort=high"

  fakebin=$(fm_fakebin "$case_dir/race")
  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u

wait_marker() {
  local path=$1 remaining=1000
  while [ ! -e "$path" ] && [ "$remaining" -gt 0 ]; do
    /bin/sleep 0.01
    remaining=$((remaining - 1))
  done
  [ -e "$path" ]
}

saw_fetch=0
saw_notes=0
saw_add=0
saw_provenance_refspec=0
for arg in "$@"; do
  case "$arg" in
    fetch) saw_fetch=1 ;;
    notes) saw_notes=1 ;;
    add) saw_add=1 ;;
    +refs/notes/build-provenance:*) saw_provenance_refspec=1 ;;
  esac
done

if [ "${FM_RACE_ROLE:-}" = B ] \
  && [ "$saw_fetch" = 1 ] \
  && [ "$saw_provenance_refspec" = 1 ]; then
  wait_marker "$FM_RACE_DIR/a-added" || exit 96
  "$REAL_GIT_FOR_TEST" "$@"
  rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  : > "$FM_RACE_DIR/b-fetched"
  wait_marker "$FM_RACE_DIR/release-b" || exit 97
  exit 0
fi

"$REAL_GIT_FOR_TEST" "$@"
rc=$?
if [ "${FM_RACE_ROLE:-}" = A ] \
  && [ "$saw_notes" = 1 ] \
  && [ "$saw_add" = 1 ] \
  && [ "$rc" -eq 0 ]; then
  : > "$FM_RACE_DIR/a-added"
  wait_marker "$FM_RACE_DIR/b-fetched" || exit 98
fi
exit "$rc"
SH
  chmod +x "$fakebin/git"

  env FM_RACE_ROLE=A \
    FM_RACE_DIR="$case_dir/race" \
    REAL_GIT_FOR_TEST="$real_git" \
    PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROVENANCE" stamp task-b1 > "$case_dir/a.out" 2>&1 &
  a_pid=$!
  wait_for_path "$case_dir/race/a-added" \
    || fail "concurrent-stamps: first stamp never reached its recorded note"

  env FM_RACE_ROLE=B \
    FM_RACE_DIR="$case_dir/race" \
    REAL_GIT_FOR_TEST="$real_git" \
    PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    "$PROVENANCE" stamp task-b2 > "$case_dir/b.out" 2>&1 &
  b_pid=$!
  wait_for_path "$case_dir/race/b-fetched" \
    || fail "concurrent-stamps: second stamp never refreshed from the forge"

  wait "$a_pid" || a_rc=$?
  : > "$case_dir/race/release-b"
  wait "$b_pid" || b_rc=$?

  expect_code 0 "$a_rc" \
    "concurrent-stamps: first stamp must complete after the forced overlap"
  expect_code 0 "$b_rc" \
    "concurrent-stamps: second stamp must retry and complete after the overlap"
  a_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$a_head" 2>/dev/null || true)
  b_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$b_head" 2>/dev/null || true)
  assert_contains "$a_note" "family=claude" \
    "concurrent-stamps: first successful stamp must remain present on the forge"
  assert_contains "$b_note" "family=codex" \
    "concurrent-stamps: second successful stamp must remain present on the forge"
  pass "fm-pr-provenance preserves both records across concurrent linked-worktree stamps"
}

test_successful_push_without_a_forge_record_refuses() {
  local case_dir out rc
  case_dir=$(make_case missing-after-push)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  author_commit "$case_dir" >/dev/null
  cat > "$case_dir/origin.git/hooks/post-receive" <<'SH'
#!/bin/sh
git update-ref -d refs/notes/build-provenance
SH
  chmod +x "$case_dir/origin.git/hooks/post-receive"

  set +e
  out=$(run_stamp "$case_dir" task-b1 2>&1)
  rc=$?
  set -e

  [ "$rc" -ne 0 ] \
    || fail "missing-after-push: stamp must not report success when the forge has no record"
  assert_contains "$out" "could not verify" \
    "missing-after-push: refusal must name the failed publication verification"
  [ -z "$(git -C "$case_dir/project" ls-remote origin "$NOTES_REF")" ] \
    || fail "missing-after-push: fixture did not remove the forge record"
  pass "fm-pr-provenance verifies that a successful push left its record on the forge"
}

test_failed_head_fetch_ignores_stale_fetch_head() {
  local case_dir head stale requested out rc
  case_dir=$(make_case stale-fetch-head)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "stale-fetch-head: stamp failed"

  git -C "$case_dir/reviewer" fetch -q origin refs/heads/fm/task-b1
  stale=$(git -C "$case_dir/reviewer" rev-parse FETCH_HEAD)
  [ "$stale" = "$head" ] || fail "stale-fetch-head: fixture did not seed the stamped head"
  requested=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  git -C "$case_dir/reviewer" rev-parse --verify "$requested^{commit}" >/dev/null 2>&1 \
    && fail "stale-fetch-head: missing requested head unexpectedly resolves"

  set +e
  out=$(run_show "$case_dir/reviewer" "$requested" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "stale-fetch-head: an unresolvable requested head must refuse"
  assert_contains "$out" "$requested" \
    "stale-fetch-head: refusal must name the head that could not be fetched"
  assert_not_contains "$out" "family=claude" \
    "stale-fetch-head: a prior FETCH_HEAD must never supply another request's identity"
  pass "fm-pr-provenance ignores stale FETCH_HEAD after a failed requested-head fetch"
}

test_stale_base_is_refreshed_before_searching_records() {
  local case_dir stamped_head unstamped_head stale_base remote_base out rc
  case_dir=$(make_case stale-base)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  stamped_head=$(author_commit "$case_dir" "build merged change")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "stale-base: stamp failed"
  git -C "$case_dir/wt" push -q origin HEAD:main
  unstamped_head=$(author_commit "$case_dir" "build unrelated later change")

  git -C "$case_dir/reviewer" fetch -q origin refs/heads/fm/task-b1
  git -C "$case_dir/reviewer" cat-file -e "$unstamped_head^{commit}" \
    || fail "stale-base: reviewer did not receive the later head"
  stale_base=$(git -C "$case_dir/reviewer" rev-parse origin/main)
  remote_base=$(git -C "$case_dir/reviewer" ls-remote origin refs/heads/main | cut -f1)
  [ "$remote_base" = "$stamped_head" ] \
    || fail "stale-base: forge main did not advance to the stamped commit"
  [ "$stale_base" != "$remote_base" ] \
    || fail "stale-base: reviewer base was refreshed before the behavior under test"

  set +e
  out=$(run_show "$case_dir/reviewer" "$unstamped_head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "stale-base: an unstamped later change must refuse"
  assert_not_contains "$out" "family=claude" \
    "stale-base: a merged record must not be attributed to later work"
  pass "fm-pr-provenance refreshes the base before selecting pull-request commits"
}

test_default_base_follows_the_forges_current_head() {
  local case_dir stamped unstamped local_default remote_default out rc
  case_dir=$(make_case changed-default)
  git -C "$case_dir/project" push -q origin main:master
  git --git-dir="$case_dir/origin.git" symbolic-ref HEAD refs/heads/master
  git -C "$case_dir/reviewer" fetch -q origin \
    refs/heads/master:refs/remotes/origin/master
  git -C "$case_dir/reviewer" remote set-head origin master
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  stamped=$(author_commit "$case_dir" "build change before default switch")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "changed-default: stamp failed"
  git -C "$case_dir/wt" push -q origin HEAD:main
  git --git-dir="$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  unstamped=$(author_commit "$case_dir" "build after default switch")

  local_default=$(git -C "$case_dir/reviewer" symbolic-ref --short refs/remotes/origin/HEAD)
  remote_default=$(git -C "$case_dir/reviewer" ls-remote --symref origin HEAD | sed -n 's/^ref: \([^[:space:]]*\)[[:space:]]*HEAD$/\1/p')
  [ "$local_default" = origin/master ] \
    || fail "changed-default: reviewer did not retain the stale default branch"
  [ "$remote_default" = refs/heads/main ] \
    || fail "changed-default: forge did not switch its default branch to main"
  [ "$stamped" != "$unstamped" ] \
    || fail "changed-default: fixture did not create an unstamped later head"

  set +e
  out=$(run_show "$case_dir/reviewer" "$unstamped" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "changed-default: an unstamped head on the new default must refuse"
  assert_not_contains "$out" "family=claude" \
    "changed-default: a stale default must not widen the search to a merged record"
  pass "fm-pr-provenance follows the forge when its default branch changes"
}

test_unrefreshable_base_refuses_stale_local_state() {
  local case_dir head out rc
  case_dir=$(make_case unrefreshable-base)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "unrefreshable-base: stamp failed"
  reviewer_fetch "$case_dir"
  git -C "$case_dir/reviewer" fetch -q origin "+$NOTES_REF:$NOTES_REF"
  git -C "$case_dir/reviewer" notes --ref="$NOTES_REF" show "$head" >/dev/null \
    || fail "unrefreshable-base: fixture did not seed a stale local record"
  git -C "$case_dir/reviewer" remote set-url origin "$case_dir/gone.git"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "unrefreshable-base: an offline reviewer must refuse"
  assert_contains "$out" "base" \
    "unrefreshable-base: refusal must name the authoritative base refresh"
  assert_not_contains "$out" "family=claude" \
    "unrefreshable-base: stale local notes must not establish an identity"
  pass "fm-pr-provenance refuses when the authoritative base cannot be refreshed"
}

test_deleted_forge_record_refuses_stale_local_note() {
  local case_dir head out rc
  case_dir=$(make_case deleted-forge-record)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "deleted-forge-record: stamp failed"
  reviewer_fetch "$case_dir"
  git -C "$case_dir/reviewer" fetch -q origin "+$NOTES_REF:$NOTES_REF"
  git --git-dir="$case_dir/origin.git" update-ref -d "$NOTES_REF"
  [ -z "$(git -C "$case_dir/reviewer" ls-remote origin "$NOTES_REF")" ] \
    || fail "deleted-forge-record: fixture did not delete the forge record"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "deleted-forge-record: an absent forge record must refuse"
  assert_not_contains "$out" "family=claude" \
    "deleted-forge-record: stale local notes must not replace forge state"
  pass "fm-pr-provenance refuses a stale local note deleted from the forge"
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

test_invalid_descendant_record_refuses_a_valid_ancestor() {
  local case_dir first second first_note second_note out rc
  case_dir=$(make_case invalid-descendant)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  first=$(author_commit "$case_dir" "validly recorded commit")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "invalid-descendant: stamp failed"
  second=$(author_commit "$case_dir" "descendant with invalid record")
  git -C "$case_dir/project" fetch -q origin "+$NOTES_REF:$NOTES_REF"
  git -C "$case_dir/project" notes --ref="$NOTES_REF" \
    add -f -m "family=totally-made-up" "$second"
  git -C "$case_dir/project" push -q origin "$NOTES_REF"
  first_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$first")
  second_note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$second")
  assert_contains "$first_note" "family=claude" \
    "invalid-descendant: fixture lost the valid ancestor record"
  assert_contains "$second_note" "family=totally-made-up" \
    "invalid-descendant: fixture did not publish the invalid descendant record"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$second" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "invalid-descendant: a present invalid record must refuse the range"
  assert_contains "$out" "$second" \
    "invalid-descendant: refusal must name the exact reviewed head"
  assert_not_contains "$out" "family=claude" \
    "invalid-descendant: a valid ancestor must not mask an invalid descendant"
  pass "fm-pr-provenance refuses a valid ancestor when a descendant record is invalid"
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

test_record_value_with_whitespace_refuses() {
  local case_dir head out rc
  case_dir=$(make_case whitespace-value)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")

  git -C "$case_dir/project" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$case_dir/project" notes --ref="$NOTES_REF" \
    add -f -m $'family=claude\nmodel=bad value' "$head"
  git -C "$case_dir/project" push -q origin "$NOTES_REF"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "whitespace-value: a format-breaking value must refuse"
  assert_not_contains "$out" "family=claude" \
    "whitespace-value: no partial identity may print from an invalid record"
  pass "fm-pr-provenance keeps whitespace outside the record value allowlist"
}

test_embedded_blank_record_line_refuses() {
  local case_dir head note out rc
  case_dir=$(make_case blank-line)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")

  git -C "$case_dir/project" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  git -C "$case_dir/project" notes --ref="$NOTES_REF" \
    add -f -m $'family=claude\n\nmodel=opus' "$head"
  git -C "$case_dir/project" push -q origin "$NOTES_REF"
  note=$(git --git-dir="$case_dir/origin.git" notes --ref="$NOTES_REF" show "$head")
  [ "$note" = $'family=claude\n\nmodel=opus' ] \
    || fail "blank-line: fixture did not persist an embedded empty line"
  reviewer_fetch "$case_dir"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "blank-line: an empty record line must refuse"
  assert_not_contains "$out" "family=claude" \
    "blank-line: a structurally invalid record must not print a partial identity"
  pass "fm-pr-provenance refuses records containing embedded empty lines"
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
  local case_dir head out rc
  case_dir=$(make_case outside-range)
  write_task_meta "$case_dir" "harness=claude" "model=opus" "effort=high"
  head=$(author_commit "$case_dir")
  run_stamp "$case_dir" task-b1 >/dev/null 2>&1 || fail "outside-range: stamp failed"
  git -C "$case_dir/wt" push -q origin HEAD:main
  reviewer_fetch "$case_dir"
  [ "$(git -C "$case_dir/reviewer" rev-parse origin/main)" = "$head" ] \
    || fail "outside-range: fixture did not move the stamped head into the base"

  set +e
  out=$(run_show "$case_dir/reviewer" "$head" 2>&1)
  rc=$?
  set -e

  expect_code 3 "$rc" "outside-range: a base commit must not inherit a branch record"
  assert_not_contains "$out" "family=claude" \
    "outside-range: a commit outside the pull request must not resolve"
  pass "fm-pr-provenance does not attribute a commit outside the pull request"
}

test_help_renders_the_contract
test_reviewer_refuses_before_any_record
test_reviewer_reads_stamped_identity_without_shared_state
test_identical_restamp_is_silent_and_idempotent
test_relaunch_cannot_reassign_a_published_commit
test_provider_qualified_models_round_trip
test_reviewer_fetches_an_unseen_remote_head
test_mutable_head_name_refuses_stale_remote_tracking_state
test_later_head_resolves_from_the_branch
test_reader_surfaces_stay_free_of_fleet_vocabulary
test_unrecognized_harness_refuses
test_unpushed_commit_refuses
test_unreachable_forge_refuses_the_publish
test_unconfirmable_commit_names_the_failed_fetch
test_concurrent_linked_worktree_stamps_preserve_both_records
test_successful_push_without_a_forge_record_refuses
test_failed_head_fetch_ignores_stale_fetch_head
test_stale_base_is_refreshed_before_searching_records
test_default_base_follows_the_forges_current_head
test_unrefreshable_base_refuses_stale_local_state
test_deleted_forge_record_refuses_stale_local_note
test_conflicting_records_refuse
test_invalid_descendant_record_refuses_a_valid_ancestor
test_malformed_record_refuses
test_record_value_with_whitespace_refuses
test_embedded_blank_record_line_refuses
test_repeated_key_in_a_record_refuses
test_commit_outside_the_pull_request_refuses
