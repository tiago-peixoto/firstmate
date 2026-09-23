#!/usr/bin/env bash
# Live driver: real fm-crew-state.sh / fm-pr-check.sh against a real project
# clone, a real bare origin, and a real `git worktree` worker copy in an
# isolated throwaway FM_HOME. Only the forge CLI (gh) and the no-mistakes
# daemon CLI are shimmed so nothing reaches GitHub or the live daemon.
set -u
REPO=${1:?repo}
T=$(mktemp -d /tmp/fm-dod-live.XXXXXX)
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"
mkdir -p "$T/shim" "$T/home/state" "$T/home/data" "$T/home/config"
cat > "$T/shim/gh" <<'SH'
#!/usr/bin/env bash
# forge shim: headRefOid comes from $FAKE_FORGE_HEAD, isDraft false
case "$*" in
  *headRefOid*) [ -n "${FAKE_FORGE_HEAD:-}" ] && { echo "$FAKE_FORGE_HEAD"; exit 0; }; exit 1 ;;
  *isDraft*) echo '{"isDraft":false}'; exit 0 ;;
esac
exit 1
SH
printf '#!/bin/sh\nexit 1\n' > "$T/shim/no-mistakes"
chmod +x "$T/shim/gh" "$T/shim/no-mistakes"
export PATH="$T/shim:$PATH" FM_HOME="$T/home"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$T/project" 2>/dev/null
git -C "$T/project" commit -q --allow-empty -m init
git -C "$T/project" push -q origin HEAD:main 2>/dev/null
git -C "$T/project" fetch -q origin

section() { printf '\n===== %s =====\n' "$*"; }
new_task() { # id mode
  local id=$1 mode=$2
  git -C "$T/project" worktree add -q -b "fm/$id" "$T/wt-$id" origin/main 2>/dev/null
  printf '%s\n' "window=fm:fm-$id" "worktree=$T/wt-$id" "project=$T/project" \
    "kind=ship" "mode=$mode" "harness=claude" > "$T/home/state/$id.meta"
  # a real (isolated-server) tmux pane for the worker, marked idle the way the
  # Claude Stop hook does via bin/fm-busy-event.sh
  if tmux has-session -t fm 2>/dev/null; then tmux new-window -d -t fm: -n "fm-$id" -c "$T/wt-$id"
  else tmux new-session -d -s fm -n "fm-$id" -x 160 -y 40 -c "$T/wt-$id"; fi
  local gen; gen=$("$REPO/bin/fm-busy-event.sh" arm "$T/home/state" "$id")
  "$REPO/bin/fm-busy-event.sh" apply "$T/home/state" "$id" idle --gen "$gen" --source claude-hook --event stop
}
crew() { echo "\$ bin/fm-crew-state.sh $1"; "$REPO/bin/fm-crew-state.sh" "$1" 2>&1; echo "(exit $?)"; }
prcheck() { echo "\$ bin/fm-pr-check.sh $1 $2"; "$REPO/bin/fm-pr-check.sh" "$1" "$2" 2>&1 | grep -v -i 'guard\|watcher\|supervis\|^ *$\|^[=!#*]' ; echo "(exit ${PIPESTATUS[0]})"; grep '^pr' "$T/home/state/$1.meta" | sed 's/^/  meta: /'; [ -e "$T/home/state/$1.check.sh" ] && echo "  poll armed: yes" || echo "  poll armed: no"; }

section "S1 no-mistakes CI-ready done with fix only in worker copy"
new_task nmun no-mistakes
git -C "$T/wt-nmun" commit -q --allow-empty -m 'fix only in the worker copy'
echo "worker HEAD: $(git -C "$T/wt-nmun" rev-parse HEAD)"
echo 'done: PR https://github.com/o/r/pull/41 checks green' > "$T/home/state/nmun.status"
crew nmun
prcheck nmun https://github.com/o/r/pull/41

section "S2 same task after the head is pushed to origin"
git -C "$T/wt-nmun" push -q origin HEAD:fm/nmun 2>/dev/null
crew nmun

section "S3 no-mistakes pre-validation handoff done (not gated)"
new_task nmpre no-mistakes
git -C "$T/wt-nmpre" commit -q --allow-empty -m 'implementation, unpushed'
echo 'done: implementation complete' > "$T/home/state/nmpre.status"
crew nmpre

section "S4 direct-PR: branch pushed, then a later fix committed only in copy (forge still reports old head)"
new_task dpr direct-PR
git -C "$T/wt-dpr" commit -q --allow-empty -m 'first push'
git -C "$T/wt-dpr" push -q origin HEAD:fm/dpr 2>/dev/null
OLD=$(git -C "$T/wt-dpr" rev-parse HEAD)
git -C "$T/wt-dpr" commit -q --allow-empty -m 'later fix only in copy'
echo "forge head: $OLD  worker HEAD: $(git -C "$T/wt-dpr" rev-parse HEAD)"
echo 'done: PR https://github.com/o/r/pull/42' > "$T/home/state/dpr.status"
crew dpr
FAKE_FORGE_HEAD=$OLD prcheck dpr https://github.com/o/r/pull/42
section "S4b direct-PR after pushing the later fix"
git -C "$T/wt-dpr" push -q origin HEAD:fm/dpr 2>/dev/null
FAKE_FORGE_HEAD=$(git -C "$T/wt-dpr" rev-parse HEAD) prcheck dpr https://github.com/o/r/pull/42
crew dpr

section "S5 local-only: named head on a detached copy only vs committed on fm/<id> in project"
new_task loc local-only
git -C "$T/wt-loc" checkout -q --detach
git -C "$T/wt-loc" commit -q --allow-empty -m 'detached work'
echo 'done: ready in branch fm/loc' > "$T/home/state/loc.status"
crew loc
git -C "$T/wt-loc" branch -f fm/loc HEAD 2>&1 || git -C "$T/project" branch -f fm/loc "$(git -C "$T/wt-loc" rev-parse HEAD)"
git -C "$T/wt-loc" checkout -q fm/loc 2>/dev/null
echo "-- after committing on fm/loc --"
crew loc

section "S6 adversarial: remote branch moved to a different tip, named head still unpushed"
new_task mov direct-PR
git -C "$T/wt-mov" commit -q --allow-empty -m 'real fix'
git -C "$T/project" push -q origin origin/main:refs/heads/fm/mov 2>/dev/null
git -C "$T/wt-mov" fetch -q origin
echo "origin/fm/mov: $(git -C "$T/wt-mov" rev-parse origin/fm/mov) worker HEAD: $(git -C "$T/wt-mov" rev-parse HEAD)"
echo 'done: PR https://github.com/o/r/pull/43' > "$T/home/state/mov.status"
crew mov

section "S7 no-mistakes: forge-reported head registers even though worker never fetched it"
new_task nmf no-mistakes
git -C "$T/wt-nmf" commit -q --allow-empty -m 'worker-local'
FAKE_FORGE_HEAD=0123456789abcdef0123456789abcdef01234567 prcheck nmf https://github.com/o/r/pull/44
echo 'done: PR https://github.com/o/r/pull/44 checks green' > "$T/home/state/nmf.status"
crew nmf

tmux kill-server 2>/dev/null
rm -rf "$T"
echo; echo "lab $T removed"
