#!/usr/bin/env bash
# Live driver: launch secondmates through the real bin/fm-spawn.sh on a
# private tmux server with a plain `bash` launch command standing in for the
# runtime, then type into that pane the git commands a secondmate runs:
#   A. a commit, with a Cursor --trailer, in a separate project clone the
#      secondmate manages (not its home) that has its own pre-commit hook;
#   B. a hook-manager-style install into the hooks dir git reports in the pane;
#   C. a spawn whose secondmate home is not a git checkout (must fail closed).
# usage: drive-secondmate-pane.sh <firstmate-tree-under-test> <out-dir>
set -u
RUT=$(cd "$1" && pwd -P)
OUT=$2
mkdir -p "$OUT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-strip-sm.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
SOCK="fm-strip-sm-$$"
REAL_TMUX=$(command -v tmux)
T() { "$REAL_TMUX" -L "$SOCK" "$@"; }
log() { printf '%s\n' "$*" | tee -a "$OUT/transcript.txt"; }
: >"$OUT/transcript.txt"
echo "$LAB" >"$OUT/lab.path"
echo "$SOCK" >"$OUT/socket"
mkdir -p "$LAB/shim"
cat >"$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$LAB/shim/tmux"

seed_home() {  # <dir> <id> <git:yes|no>
  local sm=$1 id=$2
  mkdir -p "$sm/bin" "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
  printf '# Firstmate\n' >"$sm/AGENTS.md"
  printf '%s\n' "$id" >"$sm/.fm-secondmate-home"
  printf 'charter\n' >"$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' >"$sm/.gitignore"
  [ "$3" = yes ] && git -C "$sm" init -q -b main
  return 0
}

PARENT="$LAB/parent"
mkdir -p "$PARENT/state" "$PARENT/config" "$PARENT/data"
touch "$PARENT/state/.last-watcher-beat"
SM="$LAB/sm-git"
seed_home "$SM" sm-strip-probe yes
SMNG="$LAB/sm-nogit"
seed_home "$SMNG" sm-nogit-probe no

# A project clone the secondmate manages, with its own pre-commit hook.
P="$SM/projects/managed"
mkdir -p "$P"
git -C "$P" init -q -b main
git -C "$P" config commit.gpgsign false
printf 'managed\n' >"$P/README.md"
git -C "$P" add README.md
git -C "$P" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm initial
cat >"$P/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
echo "managed-project pre-commit ran in $PWD" >"$PWD/.git/managed-pre-commit.ran"
SH
chmod +x "$P/.git/hooks/pre-commit"

env -u NO_MISTAKES_GATE PATH="$LAB/shim:$PATH" "$REAL_TMUX" -L "$SOCK" new-session -d -s fleet -n ctl -x 200 -y 50 -c "$LAB"

run_ctl() {  # <name> <command>
  T send-keys -t fleet:ctl "$2 >'$LAB/$1.out' 2>&1; echo \$? >'$LAB/$1.rc'" Enter
  until [ -s "$LAB/$1.rc" ]; do sleep 1; done
}

log "== A/B: secondmate spawn with a git home (fm-spawn --secondmate, launch command: bash)"
run_ctl spawn-git "FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME='$PARENT' FM_ROOT_OVERRIDE='$RUT' '$RUT/bin/fm-spawn.sh' sm-strip-probe '$SM' 'bash --noprofile --norc' --secondmate --backend tmux"
log "fm-spawn exit: $(cat "$LAB/spawn-git.rc")"
sed 's/^/  spawn| /' "$LAB/spawn-git.out" | tee -a "$OUT/transcript.txt" >/dev/null
W=fleet:fm-sm-strip-probe
sleep 2
T send-keys -t "$W" "clear" Enter
cmds=(
  'env | grep ^GIT_CONFIG_ | sort'
  "cd '$P'"
  'echo change >> README.md && git add README.md'
  "git commit -q --trailer 'Co-authored-by: Cursor <cursoragent@cursor.com>' --trailer 'Co-authored-by: Jane Doe <jane@example.com>' -m 'fix: secondmate commit in a managed clone'"
  'git cat-file commit HEAD'
  'cat .git/managed-pre-commit.ran'
  'H=$(git rev-parse --path-format=absolute --git-path hooks); echo "hooks dir git reports in this pane: $H"'
  'printf "#!/bin/sh\nexit 0\n" > "$H/commit-msg"; echo "overwrite commit-msg exit=$?"'
  'mv "$H/commit-msg" "$H/commit-msg.old"; echo "rename commit-msg exit=$?"'
  'git config --get core.hooksPath; echo "(repo-local core.hooksPath above, if any)"'
  'echo DONE-SM-PANE'
)
for c in "${cmds[@]}"; do
  T send-keys -t "$W" "$c" Enter
  sleep 1
done
for _ in $(seq 1 30); do T capture-pane -p -t "$W" | grep -q '^DONE-SM-PANE' && break; sleep 1; done
T capture-pane -p -J -S -200 -t "$W" | sed '/^[[:space:]]*$/d' >"$OUT/secondmate-pane.txt"
log "-- secondmate pane transcript:"
sed 's/^/  pane| /' "$OUT/secondmate-pane.txt" | tee -a "$OUT/transcript.txt" >/dev/null
log "-- managed clone commit object (read from outside the pane):"
git -C "$P" cat-file commit HEAD | sed 's/^/  obj| /' | tee -a "$OUT/transcript.txt" >/dev/null
log "-- strip dir after the hook-manager attempt: $(ls -ld "$PARENT/state/sm-strip-probe.git-hooks" | awk '{print $1}') commit-msg head: $(sed -n 3p "$PARENT/state/sm-strip-probe.git-hooks/commit-msg" | cut -c1-80)"

log ""
log "== C: secondmate spawn with a non-git home must fail closed"
run_ctl spawn-nogit "FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME='$PARENT' FM_ROOT_OVERRIDE='$RUT' '$RUT/bin/fm-spawn.sh' sm-nogit-probe '$SMNG' 'bash --noprofile --norc' --secondmate --backend tmux"
log "fm-spawn exit: $(cat "$LAB/spawn-nogit.rc")"
sed 's/^/  spawn| /' "$LAB/spawn-nogit.out" | tee -a "$OUT/transcript.txt" >/dev/null
log "tmux windows: $(T list-windows -t fleet -F '#W' | tr '\n' ' ')"
log "parent state entries for sm-nogit-probe: $(ls "$PARENT/state" | grep sm-nogit-probe | tr '\n' ' ')"
