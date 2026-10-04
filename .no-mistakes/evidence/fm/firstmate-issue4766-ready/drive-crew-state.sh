#!/usr/bin/env bash
# Reads bin/fm-crew-state.sh for lanes held through the real fm-captain-hold.sh,
# with real idle panes on the lab's private tmux socket.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
trap 'T kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
cp .tasks.toml "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
E=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux")
T new-session -d -s firstmate -n fm-done-lane -x 120 -y 30 -c "$LAB" 'sleep 600'
T new-window -t firstmate -n fm-paused-lane -c "$LAB" 'sleep 600'
SOCK=$(T display-message -p -t firstmate:fm-done-lane '#{socket_path},#{pid},0')
crew() { "${E[@]}" TMUX="$SOCK" "$ROOT/bin/fm-crew-state.sh" "$1" 2>&1 | sed 's/ \[at=[0-9]*\]/ [at=T]/g'; }
hold() { "${E[@]}" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
lane() {
  (cd "$LAB" && tasks-axi add "$1" "Lane $1" --kind "$2" --repo sample >/dev/null)
  mkdir -p "$LAB/projects/wt-$1"
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=%s\nmode=%s\n' "$1" "$LAB" "$1" "$LAB" "$2" "$2" > "$LAB/state/$1.meta"
  gen=$("${E[@]}" "$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$1")
  "${E[@]}" "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$1" idle --gen "$gen" --source claude-hook --event stop
}
say() { printf '\n=== %s\n' "$*"; }
log() { sed 's/ \[at=[0-9]*\]/ [at=T]/' "$LAB/state/$1.status" | sed 's/^/    | /'; }
printf 'Proceed.\n' > "$LAB/go.txt"

lane done-lane scout
printf 'done: report ready\n' > "$LAB/state/done-lane.status"
say "done lane before hold"; crew done-lane
hold hold done-lane --reason $'Pick the API shape\nblocked: on vendor reply' >/dev/null; echo "hold rc=$?"
say "done lane held with a two-line reason whose 2nd line starts 'blocked:'"; log done-lane; crew done-lane
hold answer done-lane --decision-file "$LAB/go.txt" --release >/dev/null; echo "release rc=$?"
say "done lane after release"; log done-lane; crew done-lane

lane paused-lane ship
printf 'working: start\npaused: waiting on vendor\n' > "$LAB/state/paused-lane.status"
say "paused lane before hold"; crew paused-lane
hold hold paused-lane --reason "operator review" >/dev/null; echo "hold rc=$?"
printf 'resolved [key=api-shape]: use v2\n' >> "$LAB/state/paused-lane.status"
say "paused lane held, with an answer for another key on top"; log paused-lane; crew paused-lane
hold answer paused-lane --decision-file "$LAB/go.txt" --release >/dev/null; echo "release rc=$?"
say "paused lane after release"; log paused-lane; crew paused-lane
