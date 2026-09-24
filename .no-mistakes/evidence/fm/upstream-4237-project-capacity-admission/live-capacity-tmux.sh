#!/usr/bin/env bash
# Live validation of project capacity admission (issue #4237) against the real
# bin/fm-spawn.sh / bin/fm-teardown.sh, the tmux backend on a private
# tmux server (TMUX_TMPDIR-scoped; the Herdr lab refused: default session stopped), real treehouse worktree allocation, and a real
# tasks-axi markdown backlog. Usage: live-capacity-tmux.sh <repo-root>
set -u
ROOT=$1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-cap-live.XXXXXX")
cleanup() {
  for h in "$T/root" "$T/mate"; do
    for m in "$h"/state/*.meta; do
      [ -f "$m" ] || continue
      FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
        "$ROOT/bin/fm-teardown.sh" "$(basename "$m" .meta)" --force >/dev/null 2>&1 || :
    done
  done
  [ "${TMUX_TMPDIR:-}" = "$T/tmux" ] && tmux kill-server 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
# A private tmux server: TMUX_TMPDIR scopes the default socket to this run.
export TMUX_TMPDIR="$T/tmux"; mkdir -p "$TMUX_TMPDIR"
tmux -f /dev/null new-session -d -s firstmate -x 200 -y 50 || { echo "tmux start failed"; exit 1; }
export TMUX="$(tmux display-message -p '#{socket_path},0,0')"
echo "## private tmux server: $(tmux display-message -p '#{socket_path}')"

step() { printf '\n## %s\n' "$*"; }
brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the heavy suite for $2.

## Firstmate spec
Live capacity admission check.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}
mkhome() {  # <home>
  mkdir -p "$1/state" "$1/config" "$1/data" "$1/projects"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$1/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$1/.tasks.toml"
}
row() { tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
tabs() { tmux list-windows -a -F '#{window_name}' | paste -sd, -; }
spawn() {  # <home> <id> <project> [extra...]
  local home=$1 id=$2 proj=$3 rc
  shift 3
  [ "$#" -gt 0 ] || set -- --mode no-mistakes --yolo off
  FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" "sh -c 'echo worker-$id-running; sleep 600'" \
    --backend tmux "$@" > "$T/$id.out" 2>&1
  rc=$?
  echo "\$ fm-spawn.sh $id $(basename "$proj") ... -> exit $rc"
  grep -E '^(deferred|error|batch):' "$T/$id.out" || tail -3 "$T/$id.out"
  return $rc
}
show_state() {  # <home> <id>
  echo "   record: $([ -f "$1/state/$2.meta" ] && echo present || echo absent);" \
    "launch-brief: $([ -f "$1/data/$2/launch-brief.md" ] && echo present || echo absent);" \
    "backlog: $(row "$1" "$2"); tmux windows: [$(tabs)]"
}

ROOTH="$T/root"; MATE="$T/mate"
mkhome "$ROOTH"; mkhome "$MATE"
mkdir -p "$T/src"
git init -q "$T/src/proj"; git -C "$T/src/proj" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
git clone -q --bare "$T/src/proj" "$T/proj.origin.git"
git clone -q "file://$T/proj.origin.git" "$ROOTH/projects/proj"
git clone -q "file://$T/proj.origin.git" "$MATE/projects/proj"          # same origin, same dir name
git clone -q "file://$T/proj.origin.git" "$MATE/projects/proj-alt"      # same origin, different dir name
printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$ROOTH" > "$MATE/.fm-secondmate-parent"
printf -- '- mate - local mate (home: %s; scope: proj work; projects: proj; added 2026-09-24)\n' "$MATE" > "$ROOTH/data/secondmates.md"
for id in a b c d e f g; do brief "$ROOTH" "$id"; done
for id in m n; do brief "$MATE" "$id"; done
P="$ROOTH/projects/proj"

step "S1 no declaration: dispatch stays uncapped (two ships on proj both launch)"
spawn "$ROOTH" a "$P"; show_state "$ROOTH" a
spawn "$ROOTH" b "$P"; show_state "$ROOTH" b
FM_HOME="$ROOTH" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-teardown.sh" b --force >/dev/null 2>&1 && echo "   (tore down b)"

step "S2 declare 'proj 1' with a holder (a) live: fresh ship c is deferred, nothing created"
printf '# heavy suite\nproj 1\n' > "$ROOTH/config/project-capacity"
before=$(tabs)
spawn "$ROOTH" c "$P"; show_state "$ROOTH" c
echo "   windows before=[$before] after=[$(tabs)]"

step "S3 fresh scout d is deferred too"
spawn "$ROOTH" d "$P" --scout; show_state "$ROOTH" d

step "S4 local secondmate home spawning on a same-origin clone with the same dir name is deferred, counting root's holder"
spawn "$MATE" m "$MATE/projects/proj"; show_state "$MATE" m

step "S5 same-origin clone under a different dir name finds no declaration and launches"
spawn "$MATE" n "$MATE/projects/proj-alt"; show_state "$MATE" n

step "S6 now root has cap 1 but holders are a (root) and n (mate, proj-alt clone): root spawn e deferred naming both"
FM_HOME="$ROOTH" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-teardown.sh" a --force >/dev/null 2>&1 && echo "   (tore down a)"
spawn "$ROOTH" e "$P"; show_state "$ROOTH" e

step "S7 cleanup frees the place: tear down n, then e launches"
FM_HOME="$MATE" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-teardown.sh" n --force >/dev/null 2>&1 && echo "   (tore down n)"
spawn "$ROOTH" e "$P"; show_state "$ROOTH" e

step "S8 recorded PR handoff frees the place: pr= recorded on e, then f launches"
printf 'pr=https://github.com/example/proj/pull/1\n' >> "$ROOTH/state/e.meta"
echo "   (appended the pr= line bin/fm-pr-check.sh records)"
spawn "$ROOTH" f "$P"; show_state "$ROOTH" f

step "S9 malformed declaration refuses the fresh spawn (exit 1), nothing created"
printf 'proj two\n' > "$ROOTH/config/project-capacity"
spawn "$ROOTH" g "$P"; show_state "$ROOTH" g
rm -f "$ROOTH/config/project-capacity"; mkdir "$ROOTH/config/project-capacity"
echo "   (declaration replaced by a directory = unreadable)"
spawn "$ROOTH" g "$P"; show_state "$ROOTH" g
rmdir "$ROOTH/config/project-capacity"; printf 'proj 1\n' > "$ROOTH/config/project-capacity"

step "S10 secondmate spawn is never counted: at capacity (f holds), a --secondmate spawn still launches"
mkdir -p "$T/sm2/state" "$T/sm2/data" "$T/sm2/config" "$T/sm2/bin"
printf '# placeholder\n' > "$T/sm2/AGENTS.md"; printf 'sm2\n' > "$T/sm2/.fm-secondmate-home"
printf 'charter\n' > "$T/sm2/data/charter.md"
printf -- '- sm2 - second local mate (home: %s; scope: other work; projects: none; added 2026-09-24)\n' "$T/sm2" >> "$ROOTH/data/secondmates.md"
FM_SPAWN_NO_GUARD=1 FM_HOME="$ROOTH" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" sm2 "$T/sm2" "sh -c 'echo sm2; sleep 600'" --secondmate --backend tmux > "$T/sm2.out" 2>&1
echo "\$ fm-spawn.sh sm2 <home> --secondmate -> exit $?"; grep -E '^(deferred|error):' "$T/sm2.out" || echo "   (no deferred/error line)"
echo "   record: $([ -f "$ROOTH/state/sm2.meta" ] && echo present || echo absent); windows [$(tabs)]"

step "S11 relaunch is never counted: f holds the only place; its agent dies; fm-spawn.sh f --relaunch is admitted"
for pid in $(tmux list-panes -t firstmate:fm-f -F '#{pane_pid}'); do pkill -KILL -P "$pid"; done
sleep 1
tmux send-keys -t firstmate:fm-f "cd '$(sed -n 's/^worktree=//p' "$ROOTH/state/f.meta")'" Enter
sleep 1
echo "   fm-f pane: cmd=$(tmux list-panes -t firstmate:fm-f -F '#{pane_current_command}') cwd=$(tmux list-panes -t firstmate:fm-f -F '#{pane_current_path}')"
FM_SPAWN_NO_GUARD=1 FM_HOME="$ROOTH" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" f --relaunch --harness "sh -c 'echo relaunched-f; sleep 600'" > "$T/f-relaunch.out" 2>&1
echo "\$ fm-spawn.sh f --relaunch -> exit $?"; grep -E '^(deferred|error|spawned|relaunched)' "$T/f-relaunch.out" || tail -5 "$T/f-relaunch.out"
sleep 2; echo "   fm-f pane after relaunch: $(tmux capture-pane -p -t firstmate:fm-f | grep -c relaunched-f) line(s) show relaunched-f"

step "final records"
for h in "$ROOTH" "$MATE"; do for m in "$h"/state/*.meta; do [ -f "$m" ] && echo "   $(basename "$h")/$(basename "$m"): kind=$(sed -n 's/^kind=//p' "$m") pr=$(sed -n 's/^pr=//p' "$m")"; done; done
