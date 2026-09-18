#!/usr/bin/env bash
# Live drive of the issue 4768 named-head gate.
# Real firstmate CLIs (bin/fm-crew-state.sh, bin/fm-pr-check.sh,
# bin/fm-inactive-reconcile.sh, bin/fm-brief.sh) run against real git repos:
# a bare "origin" standing in for GitHub's git storage, a project clone, and
# linked worker worktrees made with `git worktree add`, the way a crew copy is.
# Only the pieces with no local equivalent are stubbed: tmux (an idle pane),
# the no-mistakes daemon (no run for the task), and `gh pr view` (the forge's
# PR head, served from a file the script updates when it "pushes" to GitHub).
# Usage: drive-4768.sh <firstmate-root>
set -u
ROOT=${1:?firstmate root}
SB=$(mktemp -d /tmp/fm4768-live.XXXXXX)
trap 'rm -rf "$SB"' EXIT
umask 022
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid
export GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
export NM_HOME="$SB/nm-home-unused"
unset FM_TASK_ID TMUX

FAKE="$SB/fakebin"
HOME_DIR="$SB/home"
STATE="$HOME_DIR/state"
mkdir -p "$FAKE" "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$SB/forge" "$SB/wt" "$SB/nm"

cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
cat > "$FAKE/no-mistakes" <<SH
#!/usr/bin/env bash
# No run for the task unless $SB/nm/axi-status holds one (scenario 7).
case "\${1:-}" in
  daemon) printf 'daemon running (pid 4242)\\n' ;;
  axi)
    case "\${2:-}" in
      ''|status) [ -f "$SB/nm/axi-status" ] && cat "$SB/nm/axi-status" ;;
      logs) [ -f "$SB/nm/ci-logs" ] && cat "$SB/nm/ci-logs" ;;
    esac ;;
esac
exit 0
SH
cat > "$FAKE/gh" <<SH
#!/usr/bin/env bash
# gh pr view <url> --json headRefOid -q .headRefOid -> the forge's PR head.
if [ "\${1:-} \${2:-}" = "pr view" ]; then
  n=\${3##*/}
  [ -f "$SB/forge/pr-\$n.head" ] || exit 1
  cat "$SB/forge/pr-\$n.head"
  exit 0
fi
exit 1
SH
chmod +x "$FAKE"/*

say() { printf '\n%s\n' "$*"; }
step() { printf '\n### %s\n' "$*"; }
# Show a command as the user types it, then its output and exit code.
show() {  # <label> <cmd...>
  local label=$1 rc
  shift
  printf '$ %s\n' "$label"
  "$@" 2>&1 | sed 's/^/  /'
  rc=${PIPESTATUS[0]}
  printf '  [exit %s]\n' "$rc"
}
crew() { PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-crew-state.sh" "$1"; }
prcheck() { PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-pr-check.sh" "$1" "$2"; }
meta_pr() { grep -E '^(pr|pr_head)=' "$STATE/$1.meta" || echo "(no pr= / pr_head= recorded)"; }
armed() { if [ -e "$STATE/$1.check.sh" ]; then echo "merge poll armed: state/$1.check.sh"; else echo "no merge poll armed"; fi; }
forge_head() { printf '%s\n' "$2" > "$SB/forge/pr-$1.head"; }

# origin (GitHub stand-in) with main, the project clone, and a second clone
# standing in for other people landing work on main.
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/seed" 2>/dev/null
printf 'v1\n' > "$SB/seed/app.txt"
git -C "$SB/seed" add app.txt
git -C "$SB/seed" commit -q -m 'initial'
git -C "$SB/seed" push -q origin main
git clone -q "$SB/origin.git" "$SB/project"
git clone -q "$SB/origin.git" "$SB/other"

new_task() {  # <id> <mode> [home]
  local id=$1 mode=$2 home=${3:-$HOME_DIR} gen
  git -C "$SB/project" worktree add -q -b "fm/$id" "$SB/wt/$id" origin/main 2>/dev/null
  printf '%s\n' "window=fm:fm-$id" "endpoint_task_id=$id" "worktree=$SB/wt/$id" \
    "project=$SB/project" kind=ship "mode=$mode" harness=claude yolo=off \
    > "$home/state/$id.meta"
  chmod 600 "$home/state/$id.meta"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" "$id" idle --gen "$gen" \
    --source claude-hook --event stop >/dev/null
}
commit_fix() {  # <wt> <msg>
  printf '%s\n' "$2" >> "$1/app.txt"
  git -C "$1" commit -q -am "$2"
  git -C "$1" rev-parse HEAD
}
status_line() {  # <id> <line> [home]
  printf '%s\n' "$2" >> "${3:-$HOME_DIR}/state/$1.status"
  printf '$ echo %q >> state/%s.status\n' "$2" "$1"
}

say "# Note: bin/fm-pr-check.sh runs the supervision guard first. This sandbox home has no watcher running,"
say "# so its WATCHER DOWN / queued-wakes warnings below are expected here and unrelated to the gate."
step "Scenario 1 - direct-PR: pushed branch is only a merge of main; the fix commit is unpushed (issue case: branch moved, named head not on it)"
new_task a1 direct-PR
WT="$SB/wt/a1"
say "# main advances on origin while the worker is busy"
printf 'other\n' > "$SB/other/other.txt"; git -C "$SB/other" add other.txt
git -C "$SB/other" commit -q -m 'someone else lands on main'; git -C "$SB/other" push -q origin main
git -C "$WT" fetch -q origin
git -C "$WT" merge -q --no-ff origin/main -m 'Merge main into fm/a1'
git -C "$WT" push -q -u origin fm/a1 2>/dev/null
MERGE_SHA=$(git -C "$WT" rev-parse HEAD)
forge_head 41 "$MERGE_SHA"
say "# worker pushed fm/a1 at the merge commit $MERGE_SHA and opened PR 41 (forge head = that merge)"
FIX_SHA=$(commit_fix "$WT" 'fix: retry backoff')
say "# worker then commits the real fix $FIX_SHA locally and does NOT push it"
show "git -C wt/a1 status -sb" git -C "$WT" status -sb
status_line a1 'done: PR https://github.com/acme/widget/pull/41'
show "bin/fm-crew-state.sh a1" crew a1
show "bin/fm-pr-check.sh a1 https://github.com/acme/widget/pull/41" prcheck a1 https://github.com/acme/widget/pull/41
show "recorded PR metadata" meta_pr a1
show "merge poll" armed a1
say "# worker pushes the fix; the forge's PR head moves to it"
show "git -C wt/a1 push origin fm/a1" git -C "$WT" push -q origin fm/a1
forge_head 41 "$FIX_SHA"
show "bin/fm-crew-state.sh a1" crew a1
show "bin/fm-pr-check.sh a1 https://github.com/acme/widget/pull/41" prcheck a1 https://github.com/acme/widget/pull/41
show "recorded PR metadata" meta_pr a1
show "merge poll" armed a1

step "Scenario 2 - direct-PR: squash-merged PR whose branch fleet sync pruned"
say "# PR 41 is squash-merged on origin and GitHub deletes the head branch"
git -C "$SB/other" fetch -q origin
git -C "$SB/other" merge -q --squash origin/fm/a1
git -C "$SB/other" commit -q -m 'fix: retry backoff (#41)'
git -C "$SB/other" push -q origin main
git -C "$SB/other" push -q origin --delete fm/a1
show "git -C project fetch origin --prune   (what fleet sync runs)" git -C "$SB/project" fetch -q origin --prune
show "git -C project branch -r --contains $FIX_SHA" git -C "$SB/project" branch -r --contains "$FIX_SHA"
show "bin/fm-crew-state.sh a1   (merge not yet observed by the poll)" crew a1
say "# the watcher's poll sees the merge and records it through fm_merge_outcome_report (the same call bin/fm-watch.sh makes)"
show "fm_merge_outcome_report home state a1 <url> poll" env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" bash -c \
  '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" a1 https://github.com/acme/widget/pull/41 poll ""' _ "$ROOT"
show "ls state/a1.pr-poll-merge-notified" ls "$STATE/a1.pr-poll-merge-notified"
show "bin/fm-crew-state.sh a1" crew a1
say "# adversarial: a done naming a different PR than the recorded pr= does not inherit the merge"
status_line a1 'done: PR https://github.com/acme/widget/pull/99'
show "bin/fm-crew-state.sh a1" crew a1

step "Scenario 3 - no-mistakes: pre-validation handoff is not gated; CI-ready done is"
new_task n1 no-mistakes
WT="$SB/wt/n1"
N_FIX=$(commit_fix "$WT" 'feat: cache warmup')
say "# worker commits $N_FIX locally (the pipeline owns the push)"
status_line n1 'done: implemented cache warmup, ready to validate'
show "bin/fm-crew-state.sh n1   (pre-validation handoff)" crew n1
say "# adversarial: CI-ready done while HEAD is still only in this copy and no PR is registered"
status_line n1 'done: PR https://github.com/acme/widget/pull/42 checks green'
show "bin/fm-crew-state.sh n1" crew n1
show "bin/fm-pr-check.sh n1 https://github.com/acme/widget/pull/42   (forge gives no head)" prcheck n1 https://github.com/acme/widget/pull/42
show "recorded PR metadata" meta_pr n1
say "# the /no-mistakes run pushes the worker branch to its gate remote"
git init -q --bare "$SB/gate.git"
git -C "$WT" remote add no-mistakes "$SB/gate.git"
show "git -C wt/n1 push no-mistakes fm/n1" git -C "$WT" push -q no-mistakes fm/n1
show "bin/fm-crew-state.sh n1" crew n1
say "# the pipeline adds a review-fix commit the worker copy never fetches, and pushes it to origin as PR 42's head"
git clone -q "$SB/gate.git" "$SB/pipeline" 2>/dev/null
git -C "$SB/pipeline" checkout -q fm/n1
P_SHA=$(commit_fix "$SB/pipeline" 'no-mistakes(review): tighten warmup')
git -C "$SB/pipeline" push -q "$SB/origin.git" fm/n1
forge_head 42 "$P_SHA"
show "git -C wt/n1 cat-file -e $P_SHA   (worker copy never saw the pipeline head)" git -C "$WT" cat-file -e "$P_SHA"
show "bin/fm-pr-check.sh n1 https://github.com/acme/widget/pull/42" prcheck n1 https://github.com/acme/widget/pull/42
show "recorded PR metadata" meta_pr n1
show "bin/fm-crew-state.sh n1" crew n1

step "Scenario 4 - local-only: shared branch vs detached copy vs standalone clone"
new_task l1 local-only
WT="$SB/wt/l1"
L_SHA=$(commit_fix "$WT" 'feat: local tweak')
status_line l1 'done: ready in branch fm/l1'
show "git -C project rev-parse fm/l1   (linked worktree shares refs/heads)" git -C "$SB/project" rev-parse fm/l1
show "bin/fm-crew-state.sh l1" crew l1
say "# adversarial: the worker commits on a detached HEAD in the copy instead of its branch"
new_task l2 local-only
WT="$SB/wt/l2"
git -C "$WT" checkout -q --detach
D_SHA=$(commit_fix "$WT" 'feat: detached tweak')
status_line l2 'done: ready in branch fm/l2'
show "git -C wt/l2 branch --contains $D_SHA" git -C "$WT" branch --contains "$D_SHA"
show "bin/fm-crew-state.sh l2" crew l2
say "# adversarial: the copy is a standalone clone, so its fm/l3 branch is not the project's"
git clone -q "$SB/project" "$SB/wt/l3" 2>/dev/null
git -C "$SB/wt/l3" checkout -q -b fm/l3
S_SHA=$(commit_fix "$SB/wt/l3" 'feat: clone-only tweak')
printf '%s\n' "window=fm:fm-l3" "endpoint_task_id=l3" "worktree=$SB/wt/l3" \
  "project=$SB/project" kind=ship mode=local-only harness=claude yolo=off > "$STATE/l3.meta"
chmod 600 "$STATE/l3.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" l3)
"$ROOT/bin/fm-busy-event.sh" apply "$STATE" l3 idle --gen "$gen" --source claude-hook --event stop >/dev/null
status_line l3 'done: ready in branch fm/l3'
show "bin/fm-crew-state.sh l3" crew l3
show "git -C project fetch wt/l3 fm/l3:fm/l3   (branch now on the project)" git -C "$SB/project" fetch -q "$SB/wt/l3" fm/l3:fm/l3
show "bin/fm-crew-state.sh l3" crew l3

step "Scenario 5 - secondmate home: a child's unpushed ship done is not published to the parent"
MAIN="$SB/main"; MATE="$SB/mate"
mkdir -p "$MAIN/state" "$MAIN/data" "$MAIN/config" "$MATE/state" "$MATE/data" "$MATE/config"
: > "$MATE/AGENTS.md"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
printf '%s\n' "window=fm:fm-mate" endpoint_task_id=mate "worktree=$MATE" "project=$MATE" harness=claude \
  kind=secondmate mode=secondmate yolo=off "home=$MATE" projects=widget > "$MAIN/state/mate.meta"
printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
new_task c1 direct-PR "$MATE"
WT="$SB/wt/c1"
git -C "$WT" push -q -u origin fm/c1 2>/dev/null
C_SHA=$(commit_fix "$WT" 'fix: child fix')
status_line c1 'done: PR https://github.com/acme/widget/pull/43' "$MATE"
recon() { PATH="$FAKE:$PATH" FM_HOME="$MATE" FM_INACTIVE_RECONCILE_SECS=60 "$ROOT/bin/fm-inactive-reconcile.sh" scan; }
show "(mate home) bin/fm-inactive-reconcile.sh scan" recon
show "cat main/state/mate.status   (parent channel)" cat "$MAIN/state/mate.status"
say "# child pushes its fix"
show "git -C wt/c1 push origin fm/c1" git -C "$WT" push -q origin fm/c1
show "(mate home) bin/fm-inactive-reconcile.sh scan" recon
show "cat main/state/mate.status   (parent channel)" cat "$MAIN/state/mate.status"

step "Scenario 7 - no-mistakes run still monitoring CI: the CI-ready done is gated on the run-step path too"
say "# the no-mistakes run status below is served by the stub (no live daemon); the CI step is running with no conclusive log yet"
write_run() {  # <branch> <head> <pr>
  cat > "$SB/nm/axi-status" <<EOF
run:
  id: "01RUN$1"
  branch: fm/$1
  status: running
  head: "$2"
  pr: "https://github.com/acme/widget/pull/$3"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}
new_task n2 no-mistakes
WT="$SB/wt/n2"
R_SHA=$(commit_fix "$WT" 'feat: run path change')
show "git -C wt/n2 push no-mistakes fm/n2" git -C "$WT" push -q no-mistakes fm/n2
write_run n2 "$R_SHA" 44
status_line n2 'done: PR https://github.com/acme/widget/pull/44 checks green'
show "bin/fm-crew-state.sh n2   (run head $R_SHA pushed to the gate)" crew n2
say "# adversarial: a run is monitoring CI for a head that was never pushed anywhere outside the copy"
new_task n3 no-mistakes
WT="$SB/wt/n3"
U_SHA=$(commit_fix "$WT" 'feat: never pushed')
write_run n3 "$U_SHA" 45
status_line n3 'done: PR https://github.com/acme/widget/pull/45 checks green'
show "git -C wt/n3 branch -r --contains $U_SHA" git -C "$WT" branch -r --contains "$U_SHA"
show "bin/fm-crew-state.sh n3" crew n3
rm -f "$SB/nm/axi-status"

step "Scenario 6 - worker-facing Definition of done wording in each mode"
for m in direct-PR local-only no-mistakes; do
  id="brief-$(printf '%s' "$m" | tr 'A-Z' 'a-z')"
  PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" widget --mode "$m" >/dev/null 2>&1
  printf '\n$ bin/fm-brief.sh %s widget --mode %s   (Definition of done excerpt)\n' "$id" "$m"
  awk '/^Delivery contract:/{p=1} p&&/^## /{exit} p' "$HOME_DIR/data/$id/brief.md" \
    | grep -nE 'Delivery contract|push|done:|accepted|handoff|HEAD' | sed 's/^/  /'
done
