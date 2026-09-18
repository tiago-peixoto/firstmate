#!/usr/bin/env bash
# Live driver for issue 4768: stands up an isolated firstmate home with a real
# bare "GitHub" origin, a real project clone, real linked worker worktrees (the
# layout treehouse gives a crew), and a private tmux server holding the crew
# windows. It then plays the worker's git actions and status lines and runs the
# real firstmate entrypoints against that state:
#   bin/fm-crew-state.sh, bin/fm-pr-check.sh, bin/fm-watch.sh (merge poll),
#   bin/fm-inactive-reconcile.sh (secondmate ledger publish), bin/fm-brief.sh.
# Only external services are stubbed: `gh` (the forge API) and `no-mistakes`
# (no pipeline run attributed, so crew-state uses its status-log path).
set -u
REPO=${REPO:?}
T=$(mktemp -d "${TMPDIR:-/tmp}/fm4768-live.XXXXXX")
T=$(cd "$T" && pwd -P)
export GIT_AUTHOR_NAME=worker GIT_AUTHOR_EMAIL=worker@example.invalid
export GIT_COMMITTER_NAME=worker GIT_COMMITTER_EMAIL=worker@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset TMUX
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"
HOME_FM="$T/home"; mkdir -p "$HOME_FM"/{state,data,config}
FORGE="$T/forge"; mkdir -p "$FORGE"
BIN="$T/stubbin"; mkdir -p "$BIN"

cat > "$BIN/gh" <<SH
#!/usr/bin/env bash
# Forge stub. PR head from $FORGE/<n>.head, state from $FORGE/<n>.state.
num=""
for a in "\$@"; do case "\$a" in number=*) num=\${a#number=} ;; https://github.com/*/pull/*) num=\${a##*/} ;; esac; done
printf 'gh %s\n' "\$*" >> "$FORGE/gh.log"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *" state "*) cat "$FORGE/\$num.state" 2>/dev/null || echo OPEN; exit 0 ;;
    esac
    [ -f "$FORGE/\$num.head" ] || exit 1; cat "$FORGE/\$num.head"; exit 0 ;;
  "api graphql")
    st=\$(cat "$FORGE/\$num.state" 2>/dev/null || echo OPEN)
    m=false; [ "\$st" = MERGED ] && m=true
    printf 'state=%s\nmerged=%s\nqueued=false\nbase=main\n' "\$st" "\$m"; exit 0 ;;
esac
exit 1
SH
cat > "$BIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
# No pipeline run is attributed to any branch in this sandbox.
case "${1:-}" in
  axi) printf 'runs: []\n' ;;
  daemon) printf 'daemon running\n' ;;
esac
exit 0
SH
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

# "GitHub": a bare origin with main.
git init -q --bare -b main "$T/origin.git"
git init -q -b main "$T/seed"
git -C "$T/seed" commit -q --allow-empty -m 'initial main'
git -C "$T/seed" push -q "$T/origin.git" main
# The project clone firstmate registers; crews are linked worktrees of it.
git clone -q "$T/origin.git" "$T/project"
tmux new-session -d -s firstmate -n placeholder 'sleep 36000'

hr() { printf '\n==================== %s ====================\n' "$*"; }
say() { printf '$ %s\n' "$*"; }
run() { say "$*"; "$@" 2>&1; printf '[exit %s]\n' "$?"; }

# spawn_crew <id> <mode>: a linked worktree on fm/<id>, a tmux window, a
# ship meta record like bin/fm-spawn.sh writes, and an idle harness record
# like the Claude Stop hook leaves.
spawn_crew() {
  local id=$1 mode=$2 wt="$T/wt-$1" gen
  git -C "$T/project" worktree add -q --detach "$wt" origin/main
  git -C "$wt" checkout -q -b "fm/$id"
  tmux new-window -d -t firstmate -n "fm-$id" 'sleep 36000'
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$T/project" "harness=claude" "kind=ship" "mode=$mode" "yolo=off" \
    "tasktmp=$T/tmp-$id" "model=default" "effort=default" "spawn_gen=s1" \
    > "$HOME_FM/state/$id.meta"
  gen=$(FM_HOME="$HOME_FM" "$REPO/bin/fm-busy-event.sh" arm "$HOME_FM/state" "$id")
  FM_HOME="$HOME_FM" "$REPO/bin/fm-busy-event.sh" apply "$HOME_FM/state" "$id" idle \
    --gen "$gen" --source claude-hook --event stop
}
wt() { printf '%s\n' "$T/wt-$1"; }
worker_status() { say "echo '$2' >> state/$1.status   # worker appends"; printf '%s\n' "$2" >> "$HOME_FM/state/$1.status"; }
crew() { say "bin/fm-crew-state.sh $1"; FM_HOME="$HOME_FM" "$REPO/bin/fm-crew-state.sh" "$1" 2>&1; printf '[exit %s]\n' "$?"; }
prcheck() { say "bin/fm-pr-check.sh $1 $2"; FM_HOME="$HOME_FM" "$REPO/bin/fm-pr-check.sh" "$1" "$2" 2>&1 | grep -v '^$' | grep -iv 'watcher\|supervision\|banner\|^=\+$\|^ *$' ; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
meta_pr() { say "grep '^pr' state/$1.meta"; grep '^pr' "$HOME_FM/state/$1.meta" || echo '(no pr= / pr_head= recorded)'; }

echo "sandbox: $T"
echo "firstmate under test: $REPO @ $(git -C "$REPO" rev-parse --short HEAD)"

########################################################################
hr "S1 direct-PR: fix only in the disposable copy, never pushed"
spawn_crew a direct-PR
W=$(wt a)
run git -C "$W" commit -q --allow-empty -m 'fix: the actual fix'
FIX=$(git -C "$W" rev-parse HEAD); echo "worker HEAD (the fix) = $FIX"
worker_status a 'done: PR https://github.com/o/r/pull/11'
crew a
echo "$FIX" > "$FORGE/11.head"   # forge claims the head (worker lied / pushed elsewhere)
prcheck a https://github.com/o/r/pull/11
meta_pr a

hr "S2 direct-PR: branch pushed, then a later fix committed but NOT pushed (issue case: pushed branch lacks the named fix)"
spawn_crew b direct-PR
W=$(wt b)
run git -C "$W" commit -q --allow-empty -m 'merge main into fm/b'
run git -C "$W" push -q origin fm/b
PUSHED=$(git -C "$W" rev-parse HEAD); echo "pushed branch tip = $PUSHED"; echo "$PUSHED" > "$FORGE/12.head"
run git -C "$W" commit -q --allow-empty -m 'fix: the actual fix, unpushed'
FIX=$(git -C "$W" rev-parse HEAD); echo "worker HEAD (the fix) = $FIX"
worker_status b 'done: PR https://github.com/o/r/pull/12'
crew b
prcheck b https://github.com/o/r/pull/12
meta_pr b
hr "S2b same worker now pushes the fix -> accepted everywhere"
run git -C "$W" push -q origin fm/b
echo "$FIX" > "$FORGE/12.head"
crew b
prcheck b https://github.com/o/r/pull/12
meta_pr b

hr "S3 adversarial: remote branch moved to a merge of main, fix not on it; done note cites an already-pushed SHA"
spawn_crew c direct-PR
W=$(wt c)
MAIN_SHA=$(git -C "$W" rev-parse origin/main)
run git -C "$W" commit -q --allow-empty -m 'fix: only here'
FIX=$(git -C "$W" rev-parse HEAD)
run git -C "$W" push -q origin "$MAIN_SHA:refs/heads/fm/c"
run git -C "$W" fetch -q origin
say "git -C wt-c branch -r --contains $FIX"; git -C "$W" branch -r --contains "$FIX"; echo "(none above = fix not on any remote branch)"
worker_status c "done: PR https://github.com/o/r/pull/13 reverted $MAIN_SHA and fixed the retry"
crew c

hr "S4 no-mistakes: pre-validation handoff done is NOT gated; CI-ready done is"
spawn_crew d no-mistakes
W=$(wt d)
run git -C "$W" commit -q --allow-empty -m 'fix: implemented, not pushed (pipeline owns push)'
C1=$(git -C "$W" rev-parse HEAD)
worker_status d 'done: implemented the retry fix, ready to validate'
crew d
worker_status d 'done: PR https://github.com/o/r/pull/14 checks green'
crew d
hr "S4b no-mistakes: the pipeline pushed the worker HEAD to its gate remote -> CI-ready done accepted"
git init -q --bare -b main "$T/gate.git"
run git -C "$W" remote add no-mistakes "$T/gate.git"
run git -C "$W" push -q no-mistakes fm/d
crew d
hr "S4c no-mistakes: worker commits after the run (not pushed) -> CI-ready done refused again"
run git -C "$W" commit -q --allow-empty -m 'post-run tweak, never pushed'
worker_status d 'done: PR https://github.com/o/r/pull/14 checks green'
crew d
hr "S4d no-mistakes: pipeline added commits the worker never fetched; forge reports that head -> pr-check registers it"
spawn_crew e no-mistakes
W=$(wt e)
run git -C "$W" commit -q --allow-empty -m 'fix'
git clone -q "$T/origin.git" "$T/pipeline-e"; git -C "$T/pipeline-e" fetch -q "$W" "fm/e:fm/e"
git -C "$T/pipeline-e" checkout -q fm/e; git -C "$T/pipeline-e" commit -q --allow-empty -m 'no-mistakes: review fix'
git -C "$T/pipeline-e" push -q origin fm/e
FORGE_HEAD=$(git -C "$T/pipeline-e" rev-parse HEAD); echo "$FORGE_HEAD" > "$FORGE/15.head"
echo "forge head (pipeline-created) = $FORGE_HEAD; worker HEAD = $(git -C "$W" rev-parse HEAD)"
say "git -C wt-e cat-file -e $FORGE_HEAD"; git -C "$W" cat-file -e "$FORGE_HEAD" 2>&1 || echo "(worker copy never fetched the forge head)"
worker_status e 'done: PR https://github.com/o/r/pull/15 checks green'
crew e
prcheck e https://github.com/o/r/pull/15
meta_pr e
crew e

hr "S5 local-only: commit on shared branch fm/f accepted; detached-HEAD commit refused"
spawn_crew f local-only
W=$(wt f)
run git -C "$W" commit -q --allow-empty -m 'fix on fm/f'
worker_status f 'done: ready in branch fm/f'
crew f
say "git -C project branch --contains HEAD-of-wt-f"; git -C "$T/project" branch --contains "$(git -C "$W" rev-parse HEAD)"
run git -C "$W" checkout -q --detach
run git -C "$W" commit -q --allow-empty -m 'fix only on a detached HEAD'
say "git -C project branch --contains HEAD-of-wt-f"; git -C "$T/project" branch --contains "$(git -C "$W" rev-parse HEAD)"; echo "(none = only the worker copy's HEAD holds it)"
worker_status f 'done: ready in branch fm/f'
crew f

hr "S6 direct-PR squash-merged, branch deleted on forge and pruned by fleet sync"
spawn_crew g direct-PR
W=$(wt g)
run git -C "$W" commit -q --allow-empty -m 'fix g'
run git -C "$W" push -q origin fm/g
G=$(git -C "$W" rev-parse HEAD); echo "$G" > "$FORGE/16.head"
worker_status g 'done: PR https://github.com/o/r/pull/16'
crew g
prcheck g https://github.com/o/r/pull/16
meta_pr g
# The forge squash-merges onto main and deletes fm/g.
git -C "$T/seed" pull -q "$T/origin.git" main; git -C "$T/seed" commit -q --allow-empty -m 'fix g (#16) squashed'
git -C "$T/seed" push -q "$T/origin.git" main; git --git-dir="$T/origin.git" branch -q -D fm/g
echo MERGED > "$FORGE/16.state"
say "git -C project fetch origin --prune   # what bin/fm-fleet-sync.sh does"; git -C "$T/project" fetch -q origin --prune
say "git -C wt-g branch -r --contains $G"; git -C "$W" branch -r --contains "$G"; echo "(none = pruned; squash left it off main)"
echo "-- before the merge poll has recorded the merge:"
crew g
echo "-- run the real watcher once so the armed PR poll (bin/fm-pr-poll.sh) sees MERGED:"
printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$HOME_FM/state/z-stop.check.sh"; chmod 0700 "$HOME_FM/state/z-stop.check.sh"
FM_HOME="$HOME_FM" "$REPO/bin/fm-check-register.sh" z-stop >/dev/null
for cycle in 1 2 3 4 5 6; do
  succ=0; [ "$cycle" -gt 1 ] && succ=1   # later cycles relaunch like bin/fm-watch-arm.sh does after a wake
  say "FM_WATCH_HANDLING_SUCCESSOR=$succ bin/fm-watch.sh   # watcher cycle $cycle (returns on the first wake)"
  perl -e 'my $pid=fork; if(!$pid){exec @ARGV} local $SIG{ALRM}=sub{kill "TERM",$pid; waitpid $pid,0; exit 124}; alarm 120; waitpid $pid,0; exit($?>>8)' \
    env FM_WATCH_HANDLING_SUCCESSOR=$succ FM_HOME="$HOME_FM" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=20 FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$REPO/bin/fm-watch.sh" 2>&1 | head -5
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  [ -e "$HOME_FM/state/g.pr-poll-merge-notified" ] && break
done
say "grep 'merge landed' state/.wake-queue"; grep -o 'check: merge landed: g [^	]*' "$HOME_FM/state/.wake-queue" 2>&1
say "ls state/g.pr-poll-merge-notified"; ls "$HOME_FM/state/g.pr-poll-merge-notified" 2>&1
crew g
echo "-- adversarial: a done naming a different PR URL than the recorded, merged pr= gets no merge credit"
worker_status g 'done: PR https://github.com/o/r/pull/99'
crew g

hr "S7 secondmate home: child's unpushed done is not published upstream; after push it is"
MAIN="$T/main"; MATE="$T/mate"; mkdir -p "$MAIN"/{state,data,config} "$MATE"/{state,data,config}
: > "$MATE/AGENTS.md"; printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
printf '%s\n' "window=firstmate:fm-mate" "endpoint_task_id=mate" "worktree=$MATE" "project=$MATE" "harness=claude" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=$MATE" "projects=alpha" > "$MAIN/state/mate.meta"
printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
git -C "$T/project" worktree add -q --detach "$T/wt-h" origin/main; git -C "$T/wt-h" checkout -q -b fm/h
printf '%s\n' "window=firstmate:fm-h" "endpoint_task_id=h" "worktree=$T/wt-h" "project=$T/project" "harness=claude" \
  "kind=ship" "mode=direct-PR" "yolo=off" "spawn_gen=s1" > "$MATE/state/h.meta"
run git -C "$T/wt-h" commit -q --allow-empty -m 'child fix, unpushed'
say "echo 'done: PR https://github.com/o/r/pull/17' >> mate/state/h.status   # child appends"
printf 'done: PR https://github.com/o/r/pull/17\n' >> "$MATE/state/h.status"
recon() { say "FM_HOME=mate bin/fm-inactive-reconcile.sh scan"; FM_HOME="$MATE" FM_INACTIVE_RECONCILE_SECS=60 "$REPO/bin/fm-inactive-reconcile.sh" scan 2>&1; printf '[exit %s]\n' "$?"; }
recon
say "cat main/state/mate.status   # parent channel"; cat "$MAIN/state/mate.status"
say "ls mate/state/terminal-outcomes"; ls "$MATE/state/terminal-outcomes" 2>/dev/null || echo '(none)'
run git -C "$T/wt-h" push -q origin fm/h
recon
say "cat main/state/mate.status   # parent channel"; cat "$MAIN/state/mate.status"
say "ls mate/state/terminal-outcomes"; ls "$MATE/state/terminal-outcomes" 2>/dev/null || echo '(none)'

hr "S8 fleet snapshot (captured-meta path firstmate reads) over the same crews"
worker_status g 'done: PR https://github.com/o/r/pull/16'
say "bin/fm-fleet-snapshot.sh --json | jq '.tasks[] | {id, mode, state: .current_state.state, detail: .current_state.detail}'"
FM_HOME="$HOME_FM" "$REPO/bin/fm-fleet-snapshot.sh" --json 2>"$T/snap.err" > "$T/snap.json"; echo "[exit $?]"
jq -c '.tasks[] | {id, state: .current_state.state, source: .current_state.source, detail: (.current_state.detail // .current_state.note // null)}' "$T/snap.json" 2>&1 || { head -c 2000 "$T/snap.json"; cat "$T/snap.err"; }

hr "cleanup"
tmux kill-server 2>/dev/null
for w in "$T"/wt-*; do git -C "$T/project" worktree remove --force "$w" 2>/dev/null; done
rm -rf "$T"
echo "sandbox removed"
