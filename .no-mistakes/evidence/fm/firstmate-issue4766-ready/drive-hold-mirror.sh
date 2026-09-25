#!/usr/bin/env bash
# Live drive of fm-captain-hold.sh against a disposable lab FM_HOME.
set -u
R=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
bin/fm-lab-home.sh create "$LAB" >/dev/null
cp .tasks.toml "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
cap() { "$R/bin/fm-captain-hold.sh" "$@"; }
tasks() { (cd "$LAB" && tasks-axi "$@"); }
meta() { printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=lab-%s\n' "$1" "$LAB" "$LAB" "$1" > "$LAB/state/$1.meta"; }
rd() { bash -c '. "$1"; "$2" "$3"' _ "$R/bin/fm-classify-lib.sh" "$1" "$LAB/state/$2.status"; }
show() { echo "--- state/$1.status"; cat "$LAB/state/$1.status"; for f in last_status_line last_worker_status_line status_declared_wait_line status_current_line; do printf '%-26s= %s\n' "$f" "$(rd $f $1)"; done; }
printf 'Proceed as planned.\n' > "$LAB/go.txt"

echo "=== S1: hold a paused lane, repeat hold, release"
id=lab-paused; tasks add $id "Lab paused lane" --kind scout --repo sample >/dev/null; meta $id
printf 'paused: waiting on upstream\n' > "$LAB/state/$id.status"
cap hold $id --reason "operator review" >/dev/null; cap hold $id --reason "operator review" >/dev/null; show $id
cap answer $id --decision-file "$LAB/go.txt" --release >/dev/null; echo "(after release)"; show $id

echo; echo "=== S2: another key answered on top of standing mirror, then release (buried mirror retracted)"
id=lab-buried; tasks add $id "Lab buried lane" --kind scout --repo sample >/dev/null; meta $id
printf 'paused: waiting on upstream\n' > "$LAB/state/$id.status"
cap hold $id --reason "operator review" >/dev/null
printf 'resolved [key=api]: answered\n' >> "$LAB/state/$id.status"; echo "(held, api answered on top)"; show $id
cap answer $id --decision-file "$LAB/go.txt" --release >/dev/null; cap answer $id --decision-file "$LAB/go.txt" --release >/dev/null
echo "(after release + replay)"; show $id

echo; echo "=== S3: worker finishes while held (done replaces the mirror)"
id=lab-done; tasks add $id "Lab done lane" --kind scout --repo sample >/dev/null; meta $id
printf 'working: start\n' > "$LAB/state/$id.status"
cap hold $id --reason "operator review" >/dev/null
printf 'done: shipped PR 12\n' >> "$LAB/state/$id.status"; show $id
echo "(crew-state)"; FM_CREW_STATE_NO_FORGE=1 "$R/bin/fm-crew-state.sh" $id 2>&1 | head -3
id=lab-working; tasks add $id "Lab working lane" --kind scout --repo sample >/dev/null; meta $id
printf 'paused: upstream\n' > "$LAB/state/$id.status"
cap hold $id --reason "operator review" >/dev/null
printf 'working: resumed\n' >> "$LAB/state/$id.status"; show $id

echo; echo "=== S4: transfer key re-asked after complete stays open after settlement"
id=lab-reask; tasks add $id "Lab reask lane" --kind scout --repo sample >/dev/null; meta $id
printf 'needs-decision [key=route]: north or south\n' > "$LAB/state/$id.status"
cap hold lab-route-call --title "Choose lab route" --reason "route pending" >/dev/null
cap complete $id lab-route-call >/dev/null
printf 'needs-decision [key=route]: east or west\n' >> "$LAB/state/$id.status"
cap answer lab-route-call --decision-file "$LAB/go.txt" >/dev/null; show $id
printf 'status_open_decisions     = %s\n' "$(rd status_open_decisions $id | tr '\t' ' ')"

echo; echo "=== S5: transfer left as last line is retracted on settlement"
id=lab-top; tasks add $id "Lab top lane" --kind scout --repo sample >/dev/null; meta $id
printf 'needs-decision [key=scope]: wide or narrow\n' > "$LAB/state/$id.status"
cap hold lab-scope-call --title "Choose lab scope" --reason "scope pending" >/dev/null
cap complete $id lab-scope-call >/dev/null; echo "(transfer standing)"; show $id
cap answer lab-scope-call --decision-file "$LAB/go.txt" >/dev/null; echo "(after settle)"; show $id
echo; echo "diverged: [$(cap diverged)]"
rm -rf "$LAB"; echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
