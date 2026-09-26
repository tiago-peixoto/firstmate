#!/usr/bin/env bash
# Live driver: real fm-captain-hold.sh / fm-crew-state.sh / fm-classify-lib.sh against a disposable lab home.
set -u
R=$1; LAB=$2
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME=$LAB FM_CREW_STATE_NO_FORGE=1
S=$LAB/state
meta(){ printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=lab-%s\n' "$1" "$LAB" "$1" "$LAB" "$1" > "$S/$1.meta"; }
show(){ local id=$1
  echo "--- $S/$id.status:"; sed 's/^/    /' "$S/$id.status"
  bash -c '. "$1/bin/fm-classify-lib.sh"; f=$2
    echo "  last_status_line:          $(last_status_line "$f")"
    echo "  status_declared_wait_line: $(status_declared_wait_line "$f")"
    echo "  status_current_line:       $(status_current_line "$f")"' _ "$R" "$S/$id.status"
  echo "  fm-crew-state.sh:          $("$R/bin/fm-crew-state.sh" "$id" 2>&1 | head -1)"
}
cap(){ "$R/bin/fm-captain-hold.sh" "$@"; }
cd "$LAB"
echo "===== S1: hold a working lane -> mirror declared, lane reads captain-held"
id=lab-lane-1; tasks-axi add $id "Scout the lab sample" --kind scout --repo sample >/dev/null; meta $id
printf 'working: start\n' > $S/$id.status
cap hold $id --reason "operator review" ; echo "hold exit=$?"; show $id
echo "===== S2: another key answered on top of the standing mirror -> declared wait stays the mirror"
printf 'resolved [key=api-shape]: use v2\n' >> $S/$id.status; show $id
echo "===== S3 (adversarial R2): worker writes done: past the standing mirror -> done wins everywhere"
printf 'done: shipped PR 12\n' >> $S/$id.status; show $id
echo "===== S4: answer the hold -> keyed retraction appended, reader returns to worker event"
printf 'Proceed.\n' > $LAB/go.txt
cap answer $id --decision-file $LAB/go.txt --release; echo "answer exit=$?"; show $id
echo "===== S4b: replay the answer -> no duplicate retraction"
before=$(wc -l < $S/$id.status); cap answer $id --decision-file $LAB/go.txt --release >/dev/null 2>&1; echo "replay exit=$? lines before=$before after=$(wc -l < $S/$id.status)"
echo "===== S5 (adversarial, round-1 fix): earlier settled transfer, then later standing hold -> mirror is the declared wait"
id=lab-lane-2; tasks-axi add $id "Scout the second lab sample" --kind scout --repo sample >/dev/null; meta $id
{ printf 'needs-decision [key=route]: pick\n'; printf 'captain-held [key=route]: tracked by T\n'; printf 'resolved [key=route]: captain call answered by fm-captain-hold\n'; printf 'working: continuing\n'; } > $S/$id.status
cap hold $id --reason "operator review"; echo "hold exit=$?"; show $id
echo "===== S6 (adversarial): working: after the hold replaces the declared wait"
printf 'working: resumed after nudge\n' >> $S/$id.status; show $id
echo "===== S7: paused lane held then released -> the pre-hold pause is found again"
id=lab-lane-3; tasks-axi add $id "Scout the third lab sample" --kind scout --repo sample >/dev/null; meta $id
printf 'paused: waiting on the sample upstream\n' > $S/$id.status
cap hold $id --reason "upstream choice"; printf 'resolved [key=other]: x\n' >> $S/$id.status
cap answer $id --decision-file $LAB/go.txt --release; echo "answer exit=$?"; show $id
