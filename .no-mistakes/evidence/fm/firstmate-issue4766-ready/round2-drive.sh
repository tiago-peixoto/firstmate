#!/usr/bin/env bash
# Live driver: real fm-captain-hold.sh + fm-crew-state.sh against a lab FM_HOME.
set -u
ROOT=$PWD; LAB=$1
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux FM_CREW_STATE_NO_FORGE=1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
hold() { (cd "$LAB" && "$ROOT/bin/fm-captain-hold.sh" "$@"); }
tasks() { (cd "$LAB" && tasks-axi "$@" --file data/backlog.md); }
lib() { bash -c '. "$1"; "$2" "$3"' _ "$ROOT/bin/fm-classify-lib.sh" "$1" "$LAB/state/$2.status"; }
meta() { mkdir -p "$LAB/projects/wt-$1" && git -C "$LAB/projects/wt-$1" init -q && git -C "$LAB/projects/wt-$1" -c user.email=l@l -c user.name=l commit -q --allow-empty -m init; tmux -L fm-lab new-window -d -t fm-lab -n "fm-$1" 2>/dev/null || tmux -L fm-lab new-session -d -s fm-lab -n "fm-$1"; printf 'window=fm-lab:fm-%s\nworktree=%s/projects/wt-%s\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=lab-%s\n' "$1" "$LAB" "$1" "$LAB" "$1" > "$LAB/state/$1.meta"; }
show() { local id=$1
  echo "--- status log ($id):"; sed 's/^/    /' "$LAB/state/$id.status"
  echo "    last_status_line:          $(lib last_status_line $id)"
  echo "    status_declared_wait_line: $(lib status_declared_wait_line $id)"
  echo "    status_current_line:       $(lib status_current_line $id)"
  echo "    fm-crew-state.sh:          $("$ROOT/bin/fm-crew-state.sh" "$id" 2>&1)"
}
step() { echo; echo "\$ $*"; }

echo "===== S1: hold a working lane -> reads captain-held ====="
id=lab-lane-a; tasks add $id "Lab lane A" --kind scout --repo sample >/dev/null; meta $id
printf 'working: implementing the sample\n' > "$LAB/state/$id.status"
step fm-captain-hold.sh hold $id --reason "operator review"; hold hold $id --reason "operator review"
show $id

echo; echo "===== S2: resolved line of another key lands on the standing mirror ====="
step "worker appends: resolved [key=api-shape]: answered"; printf 'resolved [key=api-shape]: answered\n' >> "$LAB/state/$id.status"
show $id

echo; echo "===== S3: worker writes done: while held -> reported done, not captain-held ====="
step "worker appends: done: shipped PR 12"; printf 'done: shipped PR 12\n' >> "$LAB/state/$id.status"
show $id

echo; echo "===== S4: answer settles the hold -> retraction appended once, readers see worker ====="
printf 'Approved.\n' > "$LAB/ok.txt"
step fm-captain-hold.sh answer $id --decision-file ok.txt; hold answer $id --decision-file "$LAB/ok.txt"
step "replay: fm-captain-hold.sh answer $id --decision-file ok.txt"; hold answer $id --decision-file "$LAB/ok.txt" >/dev/null && echo "    (idempotent retry ok)"
echo "    retraction lines: $(grep -c 'resolved \[key=captain-hold-lab-lane-a-1\]' "$LAB/state/$id.status")"
show $id

echo; echo "===== S5 (regression 86d95da): earlier settled transfer must not hide a later standing hold ====="
id=lab-lane-b; tasks add $id "Lab lane B" --kind scout --repo sample >/dev/null; meta $id
printf 'needs-decision [key=route]: pick north or south\n' > "$LAB/state/$id.status"
step fm-captain-hold.sh hold $id --reason "route choice"; hold hold $id --reason "route choice"
step fm-captain-hold.sh complete $id $id; hold complete $id $id
show $id
printf 'Go north.\n' > "$LAB/north.txt"
step fm-captain-hold.sh answer $id --decision-file north.txt --release; hold answer $id --decision-file "$LAB/north.txt" --release
show $id
step "worker appends: working: continuing north"; printf 'working: continuing north\n' >> "$LAB/state/$id.status"
step fm-captain-hold.sh hold $id --reason "second review"; hold hold $id --reason "second review"
show $id

echo; echo "===== S6: worker failed: past a standing hold -> failed reported ====="
step "worker appends: failed: build broke"; printf 'failed: build broke\n' >> "$LAB/state/$id.status"
show $id
step fm-captain-hold.sh answer $id --decision-file rel.txt; printf 'Release it.\n' > "$LAB/rel.txt"; hold answer $id --decision-file "$LAB/rel.txt"
show $id
