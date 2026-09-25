#!/usr/bin/env bash
set -u; ROOT=$PWD; LAB=$1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux FM_CREW_STATE_NO_FORGE=1 TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,1,0"
hold() { (cd "$LAB" && "$ROOT/bin/fm-captain-hold.sh" "$@"); }
idle() { local g; g=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$1"); "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$1" idle --gen "$g" --source claude-hook --event stop >/dev/null; }
for pre in "working: mid implementation" "paused: waiting on upstream release" "blocked: need API token" "needs-decision [key=shape]: which shape"; do
  id=lab-base-$(echo "$pre" | cut -d: -f1 | cut -d' ' -f1)
  tmux -L fm-lab new-window -d -t fm-lab: -n fm-$id; mkdir -p "$LAB/projects/wt-$id"; git -C "$LAB/projects/wt-$id" init -q
  sed "s/lab-lane-d/$id/g" "$LAB/state/lab-lane-d.meta" > "$LAB/state/$id.meta"
  (cd "$LAB" && tasks-axi add $id "Lab $id" --kind scout --repo sample --file data/backlog.md >/dev/null)
  printf '%s\n' "$pre" > "$LAB/state/$id.status"; idle $id
  echo "log: '$pre'"
  echo "   before hold: $("$ROOT/bin/fm-crew-state.sh" $id)"
  hold hold $id --reason "operator review" >/dev/null; idle $id
  echo "   while held:  $("$ROOT/bin/fm-crew-state.sh" $id)"
  printf 'ok\n' > "$LAB/a.txt"; hold answer $id --decision-file "$LAB/a.txt" --release >/dev/null; idle $id
  echo "   after release: $("$ROOT/bin/fm-crew-state.sh" $id)"
done
