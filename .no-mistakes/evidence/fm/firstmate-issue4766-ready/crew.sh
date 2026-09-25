#!/usr/bin/env bash
set -u; ROOT=$PWD; LAB=$1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux FM_CREW_STATE_NO_FORGE=1 TMUX="$LAB/tmux/tmux-$(id -u)/fm-lab,1,0"
hold() { (cd "$LAB" && "$ROOT/bin/fm-captain-hold.sh" "$@"); }
idle() { local g; g=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$1"); "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$1" idle --gen "$g" --source claude-hook --event stop >/dev/null; }
lane() { local id=$1; tmux -L fm-lab new-window -d -t fm-lab -n "fm-$id" 2>/dev/null
  mkdir -p "$LAB/projects/wt-$id"; git -C "$LAB/projects/wt-$id" init -q; git -C "$LAB/projects/wt-$id" -c user.email=l@l -c user.name=l commit -q --allow-empty -m init
  printf 'window=fm-lab:fm-%s\nworktree=%s/projects/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=scout\nmode=scout\nspawn_gen=lab-%s\n' "$id" "$LAB" "$id" "$LAB" "$id" > "$LAB/state/$id.meta"
  (cd "$LAB" && tasks-axi add $id "Lab $id" --kind scout --repo sample >/dev/null); idle $id; }
cs() { echo "    fm-crew-state.sh $1 -> $("$ROOT/bin/fm-crew-state.sh" "$1" 2>&1)"; }
log() { sed 's/^/    | /' "$LAB/state/$1.status"; }

echo "===== C1: worker done:, then held -> crew state still reports done (hold never changes reported state) ====="
id=lab-lane-c; lane $id; printf 'working: building\ndone: report complete\n' > "$LAB/state/$id.status"
echo "\$ fm-captain-hold.sh hold $id --reason 'operator review'"; hold hold $id --reason "operator review"; log $id; cs $id

echo; echo "===== C2: standing hold, idle pane, worker was working -> crew state reads the worker line, not captain-held ====="
id=lab-lane-d; lane $id; printf 'working: mid implementation\n' > "$LAB/state/$id.status"
hold hold $id --reason "scope question" >/dev/null; log $id; cs $id
echo "  worker appends failed: while held"; printf 'failed: tests broke\n' >> "$LAB/state/$id.status"; log $id; cs $id

echo; echo "===== C3: lanes from the classification transcript (settled holds) ====="
for id in lab-lane-a lab-lane-b; do tmux -L fm-lab new-window -d -t fm-lab -n "fm-$id" 2>/dev/null; sed -i 's/^harness=codex/harness=claude/' "$LAB/state/$id.meta"; idle $id; log $id; cs $id; done
