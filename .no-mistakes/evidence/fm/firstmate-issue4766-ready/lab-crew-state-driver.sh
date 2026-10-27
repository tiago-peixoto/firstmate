#!/usr/bin/env bash
# Live crew-state scenarios: real bin/fm-crew-state.sh over real tmux panes on
# the lab socket, with a real idle harness record armed through
# bin/fm-busy-event.sh, before, under, and after a real fm-captain-hold.sh hold.
set -u
ROOT=$PWD
EV=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
T="$EV/lab-crew-state-transcript.txt"
: > "$T"
FAILS=0
say() { printf '%s\n' "$*" | tee -a "$T"; }
run() { local label=$1; shift; { printf '\n$ %s\n' "$label"; "$@" 2>&1; printf '[exit %s]\n' "$?"; } | tee -a "$T"; }
check() { local d=$1; shift; if "$@"; then say "CHECK PASS: $d"; else say "CHECK FAIL: $d"; FAILS=$((FAILS+1)); fi; }
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true; rm -rf "$LAB"; say "lab home removed: $LAB"; }
trap cleanup EXIT

bin/fm-lab-home.sh create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/projects/sample" "$LAB/projects/wt"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
say "lab home: $LAB"
FM() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$@"; }
hold() { FM "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks() { (cd "$LAB" && tasks-axi "$@"); }
log() { sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/$1.status"; }
crew() { FM "$ROOT/bin/fm-crew-state.sh" "$1"; }
lane() {  # <id> <status-lines...>
  local id=$1 gen; shift
  tasks add "$id" "Scout $id" --kind scout --repo sample >/dev/null
  printf 'window=firstmate:fm-%s\nworktree=%s\nproject=%s\nharness=claude\nkind=scout\nmode=scout\nbackend=tmux\nspawn_gen=lab-%s\n' \
    "$id" "$LAB/projects/wt" "$LAB/projects/sample" "$id" > "$LAB/state/$id.meta"
  printf '%s\n' "$@" > "$LAB/state/$id.status"
  TMUX_TMPDIR="$LAB/tmux" tmux new-window -t firstmate -n "fm-$id" -c "$LAB/projects/wt" bash
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n shell -c "$LAB/projects/wt" bash
printf 'Proceed as planned.\n' > "$LAB/go.txt"

cycle() {  # <id> <expect-substring>
  local id=$1 want=$2 c0 c1 c2
  say; say "===== $id ====="
  run "status log $id (worker's own lines)" log "$id"
  run "crew-state $id (before hold)" crew "$id"; c0=$(crew "$id" 2>&1)
  check "$id before hold reads '$want'" bash -c 'case "$1" in *"$2"*) ;; *) exit 1 ;; esac' _ "$c0" "$want"
  run "hold $id --reason 'captain review pending'" hold hold "$id" --reason "captain review pending"
  run "crew-state $id (under hold)" crew "$id"; c1=$(crew "$id" 2>&1)
  check "$id under hold equals before" [ "$c1" = "$c0" ]
  run "answer $id --release" hold answer "$id" --decision-file "$LAB/go.txt" --release
  run "status log $id (after release)" log "$id"
  run "crew-state $id (after release)" crew "$id"; c2=$(crew "$id" 2>&1)
  check "$id after release equals before" [ "$c2" = "$c0" ]
}
lane lab-done 'working: scouting' 'done: report ready'
cycle lab-done 'state: done'
lane lab-failed 'working: scouting' 'failed: build broke'
cycle lab-failed 'state: failed'
lane lab-open 'working: mid implementation' 'needs-decision [key=api-shape]: which sample API shape' 'paused: waiting on the sample upstream release'
cycle lab-open 'state: parked · source: status-log · which sample API shape'
lane lab-answered 'needs-decision [key=q]: pick one' 'resolved [key=q]: use a'
cycle lab-answered 'state:'
lane lab-paused 'working: scouting' 'paused: waiting on the vendor reply'
cycle lab-paused 'state: paused'
say; say "===== RESULT: $FAILS check failure(s) ====="
exit "$FAILS"
