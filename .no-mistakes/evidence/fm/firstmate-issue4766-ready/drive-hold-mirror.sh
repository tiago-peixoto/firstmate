#!/usr/bin/env bash
# Live drive of fm-captain-hold.sh status-log mirror in a disposable lab home.
set -u
ROOT=$1 LAB=$2
cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
mkdir -p "$LAB/fakebin"
for b in tmux treehouse no-mistakes gh gh-axi herdr; do printf '#!/bin/sh\nexit 0\n' > "$LAB/fakebin/$b"; chmod +x "$LAB/fakebin/$b"; done
export PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX
CH="$ROOT/bin/fm-captain-hold.sh"
meta() { printf '%s\n' "window=firstmate:fm-$1" "worktree=$LAB/projects/missing-$1" "project=$LAB/projects/sample" harness=codex "kind=$2" "mode=$2" "spawn_gen=lab-$1" > "$LAB/state/$1.meta"; }
lib() { bash -c '. "$1"; shift; "$@"' _ "$ROOT/bin/fm-classify-lib.sh" "$@"; }
show() { # <id>
  local f="$LAB/state/$1.status"
  echo "  --- $1.status ---"; sed 's/^/  | /' "$f"
  echo "  last_status_line         = $(lib last_status_line "$f")"
  echo "  status_declared_wait_line= $(lib status_declared_wait_line "$f")"
  echo "  status_current_line      = $(lib status_current_line "$f")"
  echo "  crew-state row           = $("$ROOT/bin/fm-crew-state.sh" 2>&1 | grep -F "$1" | head -1)"
}
step() { echo; echo "### $*"; }
cd "$LAB"

step "S1: hold a ship lane whose worker last wrote paused:"
id=lab-gated; tasks-axi add $id "Gated lab work" --kind ship --repo sample >/dev/null; meta $id ship
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which API shape\npaused: waiting on upstream release\n' > state/$id.status
"$CH" hold $id --reason "operator review pending"; echo "exit=$?"
show $id
step "S1b: repeat the hold (must not duplicate)"
"$CH" hold $id --reason "operator review pending" >/dev/null; echo "captain-held lines: $(grep -c '^captain-held' state/$id.status)"
step "S2: another key's answer lands on top -> mirror stays declared wait"
echo 'resolved [key=other-q]: answered elsewhere' >> state/$id.status
show $id
step "S3: release the hold -> retraction; lane reads back as worker's paused; api-shape stays open"
printf 'Proceed.\n' > go.txt; "$CH" answer $id --decision-file go.txt --release; echo "exit=$?"
show $id
echo "  open decisions: $(lib status_open_decisions state/$id.status | tr '\t' ' ')"

step "S4: worker writes done: while held -> crew state/current report done, not captain-held"
id2=lab-finisher; tasks-axi add $id2 "Finisher" --kind ship --repo sample >/dev/null; meta $id2 ship
printf 'working: start\n' > state/$id2.status
"$CH" hold $id2 --reason "operator review" >/dev/null
echo 'done: shipped PR 12' >> state/$id2.status
show $id2
step "S5: worker done: BEFORE the hold -> current reads done past standing mirror; declared wait is mirror"
id3=lab-done-first; tasks-axi add $id3 "Done first" --kind ship --repo sample >/dev/null; meta $id3 ship
printf 'working: start\ndone: PR ready\n' > state/$id3.status
"$CH" hold $id3 --reason "captain to merge" >/dev/null
show $id3

step "S6 (adversarial): earlier settled transfer must not hide a later standing hold"
id4=lab-late-hold; tasks-axi add $id4 "Late hold" --kind ship --repo sample >/dev/null; meta $id4 ship
printf 'needs-decision [key=route]: pick\ncaptain-held [key=route]: tracked by T\nresolved [key=route]: captain call answered by fm-captain-hold\nworking: continuing\n' > state/$id4.status
"$CH" hold $id4 --reason "operator review later" >/dev/null
show $id4
step "S7: decision-only hold (no lane meta) creates no status log"
"$CH" hold lab-question --title "Pick a colour" --reason "captain picks" >/dev/null; echo "exit=$? status file exists: $([ -e state/lab-question.status ] && echo yes || echo no)"
