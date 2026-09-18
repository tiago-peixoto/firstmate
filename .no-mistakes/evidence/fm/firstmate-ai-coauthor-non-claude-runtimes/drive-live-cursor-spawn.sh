#!/usr/bin/env bash
# Live end-to-end driver: spawn a REAL Cursor crewmate through bin/fm-spawn.sh
# on a private tmux server, let it commit in its treehouse-leased worktree, and
# read the commit OBJECT. Cursor runs with commit attribution ON through a
# temporary CURSOR_CONFIG_DIR (a copy of the operator's cli-config with only
# attribution flipped), which reproduces the mesaTCG PR 55 injection path
# without touching the operator's global Cursor config.
#
# usage: drive-live-cursor-spawn.sh <label> <firstmate-tree-under-test> <out-dir>
set -u
LABEL=$1
RUT=$(cd "$2" && pwd -P)
OUT=$3
mkdir -p "$OUT"
ID="strip-probe-$LABEL"; HARNESS=${HARNESS:-cursor}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-strip-$LABEL.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCK="fm-strip-$LABEL-$$"
REAL_TMUX=$(command -v tmux)
TIMEOUT=${TIMEOUT:-600}
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/transcript.txt"; }
: >"$OUT/transcript.txt"
echo "$LAB" >"$OUT/lab.path"
echo "$SOCK" >"$OUT/socket"

mkdir -p "$LAB/shim" "$LAB/cursor-config" "$LAB/treehouse"
cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$LAB/shim/tmux"
jq '.attribution = {"attributeCommitsToAgent": true, "attributePRsToAgent": true}' \
  "$HOME/.cursor/cli-config.json" >"$LAB/cursor-config/cli-config.json"

# Scratch project with a bare origin (treehouse fetches origin), signing off
# locally so a commit never waits on a pinentry, and a project-owned commit-msg
# hook that records the message it sees, to prove chaining still runs it.
P="$LAB/project"
mkdir -p "$P"
git -C "$P" init -q -b main
git -C "$P" config commit.gpgsign false
printf '# strip probe project\n' >"$P/README.md"
git -C "$P" add README.md
git -C "$P" -c user.name='Fixture' -c user.email='fixture@example.invalid' commit -qm initial
git clone -q --bare "$P" "$P.origin.git"
git -C "$P" remote add origin "file://$P.origin.git"
git -C "$P" fetch -q origin
cat >"$P/.git/hooks/commit-msg" <<SH
#!/usr/bin/env bash
cp "\$1" "$LAB/project-commit-msg-hook.saw"
SH
chmod +x "$P/.git/hooks/commit-msg"

H="$LAB/home"
mkdir -p "$H/state" "$H/config" "$H/data/$ID"
touch "$H/state/.last-watcher-beat"
cat >"$H/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Add one line to README.md and commit it locally.

## Firstmate spec
1. Append the exact line \`strip probe\` to README.md in your task worktree.
2. Commit that change with git, using the commit message "docs: add strip probe line".
3. Do not push and do not open a pull request. Stop once the commit exists.
EOF

log "tree under test: $RUT ($(git -C "$RUT" rev-parse --short HEAD 2>/dev/null || echo archive))"
log "harness=$HARNESS; codex: $(codex --version 2>/dev/null)"; log "cursor-agent $(cursor-agent --version) with attributeCommitsToAgent=$(jq -r .attribution.attributeCommitsToAgent "$LAB/cursor-config/cli-config.json")"

env -u NO_MISTAKES_GATE PATH="$LAB/shim:$PATH" CURSOR_CONFIG_DIR="$LAB/cursor-config" \
  TREEHOUSE_ROOT="$LAB/treehouse" "$REAL_TMUX" -L "$SOCK" new-session -d -s fleet -n ctl -x 220 -y 50 -c "$LAB"

"$REAL_TMUX" -L "$SOCK" send-keys -t fleet:ctl \
  "FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME='$H' FM_ROOT_OVERRIDE='$RUT' '$RUT/bin/fm-spawn.sh' '$ID' '$P' --harness '${HARNESS:-cursor}' --mode local-only --yolo on --backend tmux >'$LAB/spawn.out' 2>&1; echo \$? >'$LAB/spawn.rc'" Enter

for _ in $(seq 1 180); do [ -s "$LAB/spawn.rc" ] && break; sleep 1; done
log "fm-spawn exit: $(cat "$LAB/spawn.rc" 2>/dev/null || echo timeout)"
sed 's/^/  spawn| /' "$LAB/spawn.out" | tee -a "$OUT/transcript.txt" >/dev/null
cp "$LAB/spawn.out" "$OUT/spawn.out"
[ "$(cat "$LAB/spawn.rc" 2>/dev/null)" = 0 ] || { log "spawn failed"; exit 1; }

WT=$(sed -n 's/^worktree=//p' "$H/state/$ID.meta")
log "task worktree: $WT"
log "pane launch env (from ps):"
ps -axo pid=,command= | grep -F "$HARNESS" | grep -F "$WT" | grep -v grep | head -2 | cut -c1-300 | sed 's/^/  ps| /' | tee -a "$OUT/transcript.txt" >/dev/null
if [ -d "$H/state/$ID.git-hooks" ]; then
  log "strip dir: $(stat -f '%Sp' "$H/state/$ID.git-hooks") $(ls "$H/state/$ID.git-hooks" | wc -l | tr -d ' ') hooks"
else
  log "strip dir: absent"
fi

base=$(git -C "$WT" rev-parse HEAD)
start=$(date +%s)
while :; do
  head=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if [ "$head" != "$base" ]; then
    sleep 5
    break
  fi
  [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ] || { log "no commit within ${TIMEOUT}s"; break; }
  sleep 3
done

"$REAL_TMUX" -L "$SOCK" capture-pane -p -J -S -3000 -t "fleet:fm-$ID" >"$OUT/cursor-pane.txt" 2>/dev/null ||
  "$REAL_TMUX" -L "$SOCK" capture-pane -p -J -S -3000 -t "fleet:1" >"$OUT/cursor-pane.txt" 2>/dev/null
"$REAL_TMUX" -L "$SOCK" list-windows -t fleet >>"$OUT/transcript.txt" 2>&1

log "commit object (git cat-file commit HEAD) in the task worktree:"
git -C "$WT" cat-file commit HEAD | tee "$OUT/commit-object.txt" | sed 's/^/  obj| /' | tee -a "$OUT/transcript.txt" >/dev/null
log "project commit-msg hook ran (chained): $([ -f "$LAB/project-commit-msg-hook.saw" ] && echo yes || echo no)"
[ -f "$LAB/project-commit-msg-hook.saw" ] && sed 's/^/  saw| /' "$LAB/project-commit-msg-hook.saw" | tee -a "$OUT/transcript.txt" >/dev/null
if grep -qi 'co-authored-by' "$OUT/commit-object.txt"; then
  log "RESULT: AI co-author trailer IS on the commit object"
else
  log "RESULT: no Co-authored-by trailer on the commit object"
fi
