#!/usr/bin/env bash
# Live driver: real bin/ CLIs + real tasks-axi against a disposable home.
set -u
REPO=$1
. "$REPO/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-live)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
eval "$(sed -n '/^new_home() {/,/^}/p;/^record() {/,/^}/p;/^forge_home() {/,/^}/p;/^with_home() {/,/^}/p' "$REPO/tests/fm-contributions.test.sh")"
reader() { bash -c '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-hold-status-lib.sh"; last_status_line "$2"' bash "$ROOT" "$1"; }
plain() { bash -c '. "$1/bin/fm-classify-lib.sh"; last_status_line "$2"' bash "$ROOT" "$1"; }
opens() { bash -c '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-hold-status-lib.sh"; status_open_decisions "$2"' bash "$ROOT" "$1"; }
show() { echo "--- $1"; sed -E 's/ \[at=[0-9]+\]/ [at=T]/' "$1"; }
FAILS=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: got [$2] want [$3]"; FAILS=$((FAILS+1)); fi; }
H="$ROOT/bin/fm-captain-hold.sh"; T="$ROOT/bin/fm-tasks-axi.sh"

echo "=== S1 hold then release on a worker lane"
home=$(new_home s1)
printf 'kind=ship\n' > "$home/state/lane.meta"
printf 'done: PR ready https://github.com/o/r/pull/8\n' > "$home/state/lane.status"
with_home "$home" "$T" add lane 'Ship the thing' >/dev/null
with_home "$home" "$H" hold lane --reason 'Merge now or wait?'; echo "hold rc=$?"
show "$home/state/lane.status"
check 's1 held lane reads as captain-held' "$(reader "$home/state/lane.status" | sed -E 's/ \[at=[0-9]+\]//')" 'captain-held [key=captain-hold-lane-1]: Merge now or wait?'
with_home "$home" "$H" hold lane --reason 'Merge now or wait?' >/dev/null; 
check 's1 repeated hold adds no second declaration' "$(grep -c captain-held "$home/state/lane.status")" 1
printf 'merge it\n' > "$home/ans"
with_home "$home" "$H" answer lane --decision-file "$home/ans" --release; echo "answer rc=$?"
show "$home/state/lane.status"
check 's1 retraction written' "$(grep -c '^resolved \[key=captain-hold-lane-1\]' "$home/state/lane.status")" 1
check 's1 hold-aware reader returns worker line' "$(reader "$home/state/lane.status")" 'done: PR ready https://github.com/o/r/pull/8'
if with_home "$home" "$H" open lane; then echo "FAIL s1 still open"; FAILS=$((FAILS+1)); else echo "PASS s1 hold no longer open"; fi
with_home "$home" "$H" answer lane --decision-file "$home/ans" --release >/dev/null 2>&1
check 's1 retried answer appends no second retraction' "$(grep -c '^resolved \[key=captain-hold-lane-1\]' "$home/state/lane.status")" 1

echo "=== S2 lane-less decision-only hold mints no status log"
with_home "$home" "$H" hold q-only --title 'Pick a colour' --reason 'Blue or green?' --repo sample >/dev/null; echo "hold rc=$?"
check 's2 no status log for lane-less hold' "$(ls "$home/state" | grep -c '^q-only')" 0

echo "=== S3 worker re-asks while hold settles (adversarial)"
home=$(new_home s3)
printf 'kind=ship\n' > "$home/state/lane.meta"
printf 'working: started\n' > "$home/state/lane.status"
with_home "$home" "$T" add lane 'Ship the thing' >/dev/null
with_home "$home" "$H" hold lane --reason 'Which route?' >/dev/null
printf 'needs-decision [key=route]: A or B?\n' >> "$home/state/lane.status"
printf 'route A\n' > "$home/ans"
with_home "$home" "$H" answer lane --decision-file "$home/ans" --release >/dev/null; echo "answer rc=$?"
show "$home/state/lane.status"
check 's3 worker question still open after hold settlement' "$(opens "$home/state/lane.status")" $'route\tneeds-decision\tA or B?'
check 's3 latest event is the worker question' "$(reader "$home/state/lane.status")" 'needs-decision [key=route]: A or B?'
check 's3 no retraction under the worker key' "$(grep -c '^resolved \[key=route\]' "$home/state/lane.status")" 0

echo "=== S4 forge settlement (fm-contributions.sh poll, local gh emulator)"
for mode in merged closed; do
  home=$(new_home "s4-$mode"); forge_home "$home"; rm "$home/state/delivery.meta"
  touch "$home/config/hold-pr-settle"
  for action in close release; do
    id="question-$action"
    printf 'kind=ship\n' > "$home/state/$id.meta"
    printf 'done: PR ready\n' > "$home/state/$id.status"
    with_home "$home" "$T" add "$id" 'Decide this PR' --pr https://github.com/o/r/pull/8 >/dev/null
    with_home "$home" "$H" hold "$id" --reason 'Decide this PR' >/dev/null
    with_home "$home" "$H" pr-policy "$id" https://github.com/o/r/pull/8 terminal "$action" >/dev/null
  done
  printf '%s\n' "$mode" > "$home/forge/state"
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll; echo "poll($mode) rc=$?"
  for action in close release; do
    id="question-$action"; show "$home/state/$id.status"
    check "s4 $mode/$action retraction names the PR event" "$(grep -c "^resolved \[key=captain-hold-$id-1\] \[at=[0-9]*\]: captain call PR $mode: https://github.com/o/r/pull/8 ($action) by fm-captain-hold" "$home/state/$id.status")" 1
    check "s4 $mode/$action hold-aware reader returns done" "$(reader "$home/state/$id.status")" 'done: PR ready'
    echo "    (plain classifier reader, for contrast: $(plain "$home/state/$id.status" | sed -E 's/ \[at=[0-9]+\]//'))"
    if with_home "$home" "$H" open "$id"; then echo "FAIL s4 $id still open"; FAILS=$((FAILS+1)); else echo "PASS s4 $mode/$action hold closed"; fi
  done
  with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null
  check "s4 $mode repeat poll appends nothing" "$(cat "$home"/state/question-*.status | grep -c '^resolved')" 2
done

echo "=== S5 forge settlement opt-in absent (adversarial)"
home=$(new_home s5); forge_home "$home"; rm "$home/state/delivery.meta"
printf 'kind=ship\n' > "$home/state/q.meta"; printf 'done: PR ready\n' > "$home/state/q.status"
with_home "$home" "$T" add q 'Decide this PR' --pr https://github.com/o/r/pull/8 >/dev/null
with_home "$home" "$H" hold q --reason 'Decide this PR' >/dev/null
with_home "$home" "$H" pr-policy q https://github.com/o/r/pull/8 terminal close; echo "pr-policy without opt-in rc=$?"
printf 'merged\n' > "$home/forge/state"
with_home "$home" "$ROOT/bin/fm-contributions.sh" poll >/dev/null; echo "poll rc=$?"
with_home "$home" "$H" settle-pr q https://github.com/o/r/pull/8; echo "settle-pr rc=$?"
show "$home/state/q.status"
check 's5 no retraction without config/hold-pr-settle' "$(grep -c '^resolved' "$home/state/q.status")" 0
if with_home "$home" "$H" open q; then echo "PASS s5 hold stays open"; else echo "FAIL s5 hold closed without opt-in"; FAILS=$((FAILS+1)); fi

echo "FAILS=$FAILS"
exit $FAILS
