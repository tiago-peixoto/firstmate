#!/usr/bin/env bash
# Live end-to-end drive of the issue-4768 named-head gate.
# Stands up an isolated firstmate home (real git origin, project clone,
# Treehouse-style linked worker worktrees, isolated tmux server, real busy
# records written the way fm-spawn + the Claude Stop hook write them) and runs
# the real bin/fm-crew-state.sh, bin/fm-pr-check.sh and
# bin/fm-inactive-reconcile.sh against it.
# Usage: drive-4768.sh <firstmate-checkout>
set -u
ROOT=$(cd "$1" && pwd)
W=$(mktemp -d "${TMPDIR:-/tmp}/fm4768-e2e.XXXXXX")
W=$(cd "$W" && pwd -P)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
export GIT_CONFIG_GLOBAL="$W/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" user.name fm4768
git config --file "$GIT_CONFIG_GLOBAL" user.email fm4768@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
FAILS=0

hdr() { printf '\n=== %s ===\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }
expect() {  # <desc> <haystack> <needle>
  if printf '%s' "$2" | grep -Fq -- "$3"; then printf 'PASS: %s\n' "$1"
  else printf 'FAIL: %s (wanted: %s)\n' "$1" "$3"; FAILS=$((FAILS+1)); fi
}
expect_not() {
  if printf '%s' "$2" | grep -Fq -- "$3"; then printf 'FAIL: %s (unwanted: %s)\n' "$1" "$3"; FAILS=$((FAILS+1))
  else printf 'PASS: %s\n' "$1"; fi
}

# --- shared forge-less origin + project clone ------------------------------
git init -q --bare "$W/origin.git"
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
git -C "$W/seed" commit -q --allow-empty -m 'main: initial'
git -C "$W/seed" push -q origin HEAD:main
tmux new-session -d -s fm -n shell 'sleep 100000'

new_home() {  # <home>
  mkdir -p "$1"/{state,data,config,projects}
}
# Treehouse-style linked worktree on fm/<id> off origin/main.
new_task() {  # <home> <id> <mode> [project]
  local home=$1 id=$2 mode=$3 project=${4:-$1/projects/proj}
  [ -d "$project" ] || git clone -q "$W/origin.git" "$project"
  git -C "$project" fetch -q origin
  git -C "$project" worktree add -q -b "fm/$id" "$W/wt/$id" origin/main
  tmux new-window -d -t fm: -n "fm-$id" 'sleep 100000'
  printf '%s\n' "window=fm:fm-$id" "worktree=$W/wt/$id" "project=$project" \
    "harness=claude" "kind=ship" "mode=$mode" > "$home/state/$id.meta"
  chmod 600 "$home/state/$id.meta"
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop
}
crew_state() { FM_HOME="$1" "$ROOT/bin/fm-crew-state.sh" "$2" 2>&1; }
pr_check() { FM_HOME="$1" "$ROOT/bin/fm-pr-check.sh" "$2" "$3" 2>&1; }

H="$W/home"; new_home "$H"
NOFORGE_PR=https://github.com/fm4768-e2e-nonexistent/nope/pull/1

# --- S1/S2: direct-PR, pushed branch is only a merge of main ----------------
hdr "S1 direct-PR: branch pushed at a merge of main, fix commit only in the copy"
new_task "$H" dpr direct-PR
git -C "$W/seed" commit -q --allow-empty -m 'main: someone else lands work'
git -C "$W/seed" push -q origin HEAD:main
git -C "$W/wt/dpr" fetch -q origin
git -C "$W/wt/dpr" merge -q --no-edit origin/main
git -C "$W/wt/dpr" push -q origin fm/dpr
git -C "$W/wt/dpr" commit -q --allow-empty -m 'the actual fix (never pushed)'
FIX=$(git -C "$W/wt/dpr" rev-parse HEAD)
printf 'remote fm/dpr = %s (merge of main), worker HEAD = %s (fix)\n' \
  "$(git -C "$W/wt/dpr" rev-parse origin/fm/dpr)" "$FIX"
printf 'done: PR %s\n' "$NOFORGE_PR" >> "$H/state/dpr.status"
out=$(crew_state "$H" dpr); printf '$ fm-crew-state.sh dpr\n%s\n' "$out"
expect "crew-state reads blocked" "$out" "state: blocked · source: status-log"
expect "refusal names the fix head, not the moved branch" "$out" "named head $FIX is unreachable outside the worker copy"
out=$(pr_check "$H" dpr "$NOFORGE_PR"); rc=$?; printf '$ fm-pr-check.sh dpr %s\n%s\n[exit %s]\n' "$NOFORGE_PR" "$out" "$rc"
expect "fm-pr-check refuses" "$out" "error: named head $FIX is unreachable outside the worker copy"
[ "$rc" != 0 ] && echo "PASS: fm-pr-check exit non-zero" || { echo "FAIL: fm-pr-check exit 0"; FAILS=$((FAILS+1)); }
expect_not "no pr= recorded" "$(cat "$H/state/dpr.meta")" "pr="
[ ! -e "$H/state/dpr.check.sh" ] && echo "PASS: no merge poll armed" || { echo "FAIL: poll armed"; FAILS=$((FAILS+1)); }

hdr "S2 direct-PR: worker pushes the fix, same done line"
run git -C "$W/wt/dpr" push -q origin fm/dpr
out=$(crew_state "$H" dpr); printf '$ fm-crew-state.sh dpr\n%s\n' "$out"
expect "crew-state reads done" "$out" "state: done · source: status-log · PR $NOFORGE_PR"
out=$(pr_check "$H" dpr "$NOFORGE_PR"); rc=$?; printf '$ fm-pr-check.sh dpr %s\n%s\n[exit %s]\n' "$NOFORGE_PR" "$out" "$rc"
[ "$rc" = 0 ] && echo "PASS: fm-pr-check exit 0" || { echo "FAIL: fm-pr-check exit $rc"; FAILS=$((FAILS+1)); }
expect "pr= recorded" "$(cat "$H/state/dpr.meta")" "pr=$NOFORGE_PR"
[ -e "$H/state/dpr.check.sh" ] && echo "PASS: merge poll armed" || { echo "FAIL: no poll armed"; FAILS=$((FAILS+1)); }
printf -- '--- state/dpr.meta after registration ---\n'; cat "$H/state/dpr.meta"

# --- S3: local-only, only copy on a detached HEAD in the Treehouse worktree -
hdr "S3 local-only: commit on a detached HEAD in the linked worktree"
new_task "$H" lo local-only
git -C "$W/wt/lo" checkout -q --detach
git -C "$W/wt/lo" commit -q --allow-empty -m 'local-only fix on detached HEAD'
LOFIX=$(git -C "$W/wt/lo" rev-parse HEAD)
printf 'done: ready in branch fm/lo\n' >> "$H/state/lo.status"
out=$(crew_state "$H" lo); printf '$ fm-crew-state.sh lo\n%s\n' "$out"
expect "detached-only local-only done is blocked" "$out" "state: blocked · source: status-log · named head $LOFIX is unreachable outside the worker copy"
run git -C "$W/wt/lo" checkout -q -B fm/lo
out=$(crew_state "$H" lo); printf '$ fm-crew-state.sh lo\n%s\n' "$out"
expect "on fm/lo (shared project refs/heads) it reads done" "$out" "state: done · source: status-log · ready in branch fm/lo"

hdr "S4 local-only: worker copy is a standalone clone, commit only there"
git clone -q "$W/origin.git" "$W/standalone"
git -C "$W/standalone" checkout -q -b fm/lo2
git -C "$W/standalone" commit -q --allow-empty -m 'fix in a standalone clone'
SAFIX=$(git -C "$W/standalone" rev-parse HEAD)
tmux new-window -d -t fm: -n fm-lo2 'sleep 100000'
printf '%s\n' "window=fm:fm-lo2" "worktree=$W/standalone" "project=$H/projects/proj" \
  "harness=claude" "kind=ship" "mode=local-only" > "$H/state/lo2.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$H/state" lo2)
"$ROOT/bin/fm-busy-event.sh" apply "$H/state" lo2 idle --gen "$gen" --source claude-hook --event stop
printf 'done: ready in branch fm/lo2\n' >> "$H/state/lo2.status"
out=$(crew_state "$H" lo2); printf '$ fm-crew-state.sh lo2\n%s\n' "$out"
expect "branch only in a standalone clone is blocked" "$out" "state: blocked · source: status-log · named head $SAFIX is unreachable outside the worker copy"

# --- S5: no-mistakes pre-validation handoff stays done ----------------------
hdr "S5 no-mistakes: pre-validation done: {summary} with an unpushed commit"
new_task "$H" nmpre no-mistakes
git -C "$W/wt/nmpre" commit -q --allow-empty -m 'implementation, pipeline not run yet'
printf 'done: implemented the widget fix\n' >> "$H/state/nmpre.status"
out=$(crew_state "$H" nmpre); printf '$ fm-crew-state.sh nmpre\n%s\n' "$out"
expect "pipeline handoff reads done" "$out" "state: done · source: status-log · implemented the widget fix"

# --- S6: no-mistakes CI-ready, worker committed after the run ---------------
hdr "S6 no-mistakes: CI-ready done while a commit made after the run is only in the copy"
new_task "$H" nmci no-mistakes
git -C "$W/wt/nmci" commit -q --allow-empty -m 'validated change'
git -C "$W/wt/nmci" push -q origin fm/nmci
git -C "$W/wt/nmci" commit -q --allow-empty -m 'commit after the run'
NMLATE=$(git -C "$W/wt/nmci" rev-parse HEAD)
printf 'done: PR %s checks green\n' "$NOFORGE_PR" >> "$H/state/nmci.status"
out=$(crew_state "$H" nmci); printf '$ fm-crew-state.sh nmci\n%s\n' "$out"
expect "CI-ready done with unpushed later commit is blocked" "$out" "state: blocked · source: status-log · named head $NMLATE is unreachable outside the worker copy"
out=$(pr_check "$H" nmci "$NOFORGE_PR"); rc=$?; printf '$ fm-pr-check.sh nmci %s\n%s\n[exit %s]\n' "$NOFORGE_PR" "$out" "$rc"
expect "no forge head -> fm-pr-check refuses" "$out" "error: named head $NMLATE is unreachable outside the worker copy"
expect_not "no pr= recorded" "$(cat "$H/state/nmci.meta")" "pr="

hdr "S7 no-mistakes: CI-ready done where the forge reports the pipeline-pushed head"
REAL_PR=https://github.com/kunchenguid/firstmate/pull/4882
new_task "$H" nmforge no-mistakes
git -C "$W/wt/nmforge" commit -q --allow-empty -m 'worker commit the pipeline rebased and pushed'
printf 'done: PR %s checks green\n' "$REAL_PR" >> "$H/state/nmforge.status"
out=$(crew_state "$H" nmforge); printf '$ fm-crew-state.sh nmforge (before registration)\n%s\n' "$out"
expect "before registration the copy HEAD is tested and blocked" "$out" "state: blocked"
out=$(pr_check "$H" nmforge "$REAL_PR"); rc=$?; printf '$ fm-pr-check.sh nmforge %s\n%s\n[exit %s]\n' "$REAL_PR" "$out" "$rc"
[ "$rc" = 0 ] && echo "PASS: forge-reported head registers" || { echo "FAIL: fm-pr-check exit $rc"; FAILS=$((FAILS+1)); }
expect "pr_head= from the forge recorded" "$(cat "$H/state/nmforge.meta")" "pr_head="
printf -- '--- state/nmforge.meta after registration ---\n'; cat "$H/state/nmforge.meta"
out=$(crew_state "$H" nmforge); printf '$ fm-crew-state.sh nmforge (after registration)\n%s\n' "$out"
expect "after registration it reads done" "$out" "state: done · source: status-log · PR $REAL_PR checks green"

# --- S8: keyed done line cannot slip past the gate --------------------------
hdr "S8 adversarial: keyed done [key=...] line with the fix unpushed (direct-PR)"
new_task "$H" keyed direct-PR
git -C "$W/wt/keyed" commit -q --allow-empty -m 'fix only in the copy'
KFIX=$(git -C "$W/wt/keyed" rev-parse HEAD)
printf 'done [key=fix]: PR %s\n' "$NOFORGE_PR" >> "$H/state/keyed.status"
out=$(crew_state "$H" keyed); printf '$ fm-crew-state.sh keyed\n%s\n' "$out"
expect "keyed done is gated too" "$out" "state: blocked · source: status-log · named head $KFIX is unreachable outside the worker copy"

# --- S9/S10: secondmate ledger publish -------------------------------------
hdr "S9 secondmate: unpushed CI-ready child done is not published upstream"
MAIN="$W/main"; MATE="$W/mate"
new_home "$MAIN"; new_home "$MATE"; mkdir -p "$MATE/bin"; : > "$MATE/AGENTS.md"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
new_task "$MATE" child no-mistakes "$MATE/projects/proj"
git -C "$W/wt/child" commit -q --allow-empty -m 'validated change'
git -C "$W/wt/child" push -q origin fm/child
git -C "$W/wt/child" commit -q --allow-empty -m 'commit after the run'
printf 'done: PR %s checks green, risk low\n' "$NOFORGE_PR" >> "$MATE/state/child.status"
reconcile() { FM_HOME="$MATE" "$ROOT/bin/fm-inactive-reconcile.sh" "$@" 2>&1; }
run reconcile scan
printf -- '--- parent state/mate.status ---\n'; cat "$MAIN/state/mate.status" 2>/dev/null || echo '(absent)'
[ ! -s "$MAIN/state/mate.status" ] && echo "PASS: nothing published upstream" || { echo "FAIL: published upstream"; FAILS=$((FAILS+1)); }
out=$(crew_state "$MATE" child); printf '$ fm-crew-state.sh child (in mate home)\n%s\n' "$out"
expect "mate's crew-state reads the child blocked" "$out" "state: blocked"

hdr "S10 secondmate: after the push, the same done line is published once"
run git -C "$W/wt/child" push -q origin fm/child
run reconcile scan
run reconcile scan
printf -- '--- parent state/mate.status ---\n'; cat "$MAIN/state/mate.status" 2>/dev/null || echo '(absent)'
n=$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status" 2>/dev/null || echo 0)
[ "$n" = 1 ] && echo "PASS: published exactly once" || { echo "FAIL: published $n times"; FAILS=$((FAILS+1)); }

hdr "S11 secondmate: pending delivery survives teardown removing the worktree"
new_task "$MATE" child2 no-mistakes "$MATE/projects/proj"
git -C "$W/wt/child2" commit -q --allow-empty -m 'validated change'
git -C "$W/wt/child2" push -q origin fm/child2
printf 'done: PR %s checks green\n' "$NOFORGE_PR" >> "$MATE/state/child2.status"
cp "$MATE/.fm-secondmate-parent" "$W/parent-binding"
printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
run reconcile scan
ls "$MATE/state/terminal-outcomes" | sed 's/^/terminal-outcomes: /'
ls "$MATE/state/terminal-outcomes" | grep -q '\.pending$' && echo "PASS: pending record left" || { echo "FAIL: no pending"; FAILS=$((FAILS+1)); }
run git -C "$MATE/projects/proj" worktree remove --force "$W/wt/child2"
cp "$W/parent-binding" "$MATE/.fm-secondmate-parent"
run reconcile report child2
printf -- '--- parent state/mate.status ---\n'; cat "$MAIN/state/mate.status"
expect "pending done delivered after worktree removal" "$(cat "$MAIN/state/mate.status")" "child child2 done: PR $NOFORGE_PR checks green"

hdr "RESULT"
printf 'failures: %s\n' "$FAILS"
tmux kill-server 2>/dev/null || true
rm -rf "$W"
[ "$FAILS" = 0 ]
