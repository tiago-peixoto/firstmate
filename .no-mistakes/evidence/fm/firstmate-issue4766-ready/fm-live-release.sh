#!/usr/bin/env bash
set -u
BIN=$1; LAB=$2
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_CREW_STATE_NO_FORGE=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
cd "$LAB"; lane=lab-rel-lane
tasks-axi add "$lane" "Ship the lab lane" --kind ship --repo sample >/dev/null
printf '%s\n' "window=firstmate:fm-$lane" "worktree=$LAB/projects/wt-$lane" "project=$LAB/projects/sample" harness=claude kind=scout mode=scout "spawn_gen=lab-$lane" > "$LAB/state/$lane.meta"
mkdir -p "$LAB/projects/wt-$lane"; tmux new-session -d -s firstmate -n "fm-$lane" -c "$LAB/projects/wt-$lane" "sleep 600"
g=$("$BIN/fm-busy-event.sh" arm "$LAB/state" "$lane"); "$BIN/fm-busy-event.sh" apply "$LAB/state" "$lane" idle --gen "$g" --source claude-hook --event stop >/dev/null
S="$LAB/state/$lane.status"; printf 'working: start\npaused: waiting on vendor\n' > "$S"
"$BIN/fm-captain-hold.sh" hold "$lane" --reason "operator review" >/dev/null
echo "## held, mirror is last line:"; "$BIN/fm-crew-state.sh" "$lane"
printf 'resolved [key=api-shape]: use v2\n' >> "$S"
echo "## held + unrelated resolved:"; "$BIN/fm-crew-state.sh" "$lane"
printf 'Proceed as planned.\n' > "$LAB/go.txt"
echo "## fm-captain-hold.sh answer --release:"; "$BIN/fm-captain-hold.sh" answer "$lane" --decision-file "$LAB/go.txt" --release 2>&1 | tail -2
echo "--- status log:"; cat "$S"
echo "## after release:"; "$BIN/fm-crew-state.sh" "$lane"
