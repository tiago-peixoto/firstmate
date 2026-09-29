#!/usr/bin/env bash
# Live scenario: real fm-captain-hold.sh hold mirror + real fm-crew-state.sh read, in a disposable lab home.
set -u
BIN=$1; LAB=$2; tag=$3
export FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_CREW_STATE_NO_FORGE=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
cd "$LAB"
lane=lab-$tag-lane
tasks-axi add "$lane" "Ship the lab lane" --kind ship --repo sample >/dev/null || { echo "task add failed"; exit 1; }
printf '%s\n' "window=firstmate:fm-$lane" "worktree=$LAB/projects/wt-$lane" "project=$LAB/projects/sample" \
  harness=claude kind=scout mode=scout "spawn_gen=lab-$lane" > "$LAB/state/$lane.meta"
mkdir -p "$LAB/projects/wt-$lane"; tmux new-session -d -s firstmate -n "fm-$lane" -c "$LAB/projects/wt-$lane" "sleep 600"; g=$("$BIN/fm-busy-event.sh" arm "$LAB/state" "$lane"); "$BIN/fm-busy-event.sh" apply "$LAB/state" "$lane" idle --gen "$g" --source claude-hook --event stop >/dev/null; S="$LAB/state/$lane.status"
printf 'working: start\npaused: waiting on vendor\n' > "$S"
echo "## [$tag] step 1: worker paused; crew state:"
"$BIN/fm-crew-state.sh" "$lane" 2>&1
echo "## [$tag] step 2: fm-captain-hold.sh hold $lane"
"$BIN/fm-captain-hold.sh" hold "$lane" --reason "operator review" 2>&1 | tail -2
echo "## [$tag] step 3: firstmate answers an unrelated key on the lane log"
printf 'resolved [key=api-shape]: use v2\n' >> "$S"
echo "--- status log:"; cat "$S"
echo "--- crew state:"; "$BIN/fm-crew-state.sh" "$lane" 2>&1
echo "--- classify: declared_wait / current:"
bash -c '. "$1/fm-classify-lib.sh"; printf "wait=%s\ncurrent=%s\n" "$(status_declared_wait_line "$2")" "$(status_current_line "$2" ship)"' _ "$BIN" "$S"
echo "## [$tag] step 4: worker declares done while still held"
printf 'done: shipped PR 12\n' >> "$S"
echo "--- crew state:"; "$BIN/fm-crew-state.sh" "$lane" 2>&1
bash -c '. "$1/fm-classify-lib.sh"; printf "wait=%s\ncurrent=%s\n" "$(status_declared_wait_line "$2")" "$(status_current_line "$2" ship)"' _ "$BIN" "$S"
