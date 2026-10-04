#!/usr/bin/env bash
# Drives the real bin/fm-captain-hold.sh against a disposable marked lab home.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
trap 'rm -rf "$LAB"' EXIT
cp .tasks.toml "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
hold() { fm "$ROOT/bin/fm-captain-hold.sh" "$@"; }
say() { printf '\n=== %s\n' "$*"; }
show() { printf -- '--- state/%s.status\n' "$1"; sed 's/ \[at=[0-9]*\]/ [at=T]/' "$LAB/state/$1.status" | cat -A | sed 's/\$$//'; }
readers() {  # <id>
  bash -c '. "$1"; . "$2"; f=$3
    printf "last_status_line        : %s\n" "$(last_status_line "$f")"
    printf "last_worker_status_line : %s\n" "$(last_worker_status_line "$f")"
    printf "status_current_line     : %s\n" "$(status_current_line "$f")"
    printf "status_declared_wait    : %s\n" "$(status_declared_wait_line "$f")"
    printf "status_open_decisions   : %s\n" "$(status_open_decisions "$f" | tr "\n\t" ";|")"
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$LAB/state/$1.status" | sed 's/ \[at=[0-9]*\]/ [at=T]/g'
}
lane() {  # <id> <kind>
  (cd "$LAB" && tasks-axi add "$1" "Lane $1" --kind "$2" --repo sample >/dev/null) || echo "ADD FAILED $1"
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=claude\nkind=%s\nmode=%s\nspawn_gen=lab-%s\n' \
    "$1" "$LAB" "$1" "$LAB" "$2" "$2" "$1" > "$LAB/state/$1.meta"
}
seen() { fm bash -c '. "$1"; fm_wake_signal_seen_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB/state" "$LAB/state/$1.status" && echo "wake scan: no unannounced growth (home not re-woken)" || echo "wake scan: UNANNOUNCED GROWTH (home would re-wake)"; }
mark() { fm bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$LAB/state" "$LAB/state/$1.status"; }

say "S1 paused lane: hold mirrors one captain-held line, repeat hold does not duplicate"
lane paused-lane ship
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which API shape\npaused: waiting on vendor\n' > "$LAB/state/paused-lane.status"
mark paused-lane
hold hold paused-lane --reason "operator review pending"; echo "hold rc=$?"
hold hold paused-lane --reason "operator review pending"; echo "repeat hold rc=$?"
show paused-lane; readers paused-lane; seen paused-lane
echo "captain-held line count: $(grep -c '^captain-held ' "$LAB/state/paused-lane.status")"

say "S2 release retracts under the same key; readers return to the worker's pause; worker's open decision survives"
printf 'Proceed as planned.\n' > "$LAB/go.txt"
hold answer paused-lane --decision-file "$LAB/go.txt" --release; echo "answer --release rc=$?"
show paused-lane; readers paused-lane; seen paused-lane

say "S3 re-hold opens key -2; closing answer retracts it"
hold hold paused-lane --reason "second operator review"; echo "re-hold rc=$?"
printf 'Ship it.\n' > "$LAB/ship.txt"
hold answer paused-lane --decision-file "$LAB/ship.txt"; echo "answer rc=$?"
show paused-lane; readers paused-lane

say "S4 ADVERSARIAL done lane, reason with newline + CR + forged 'blocked:' line"
lane done-lane scout
printf 'done: PR ready\n' > "$LAB/state/done-lane.status"
mark done-lane
hold hold done-lane --reason $'Pick the API shape\nblocked: on vendor reply\r\nneeds-decision [key=forged]: fake\rtail'; echo "hold rc=$?"
show done-lane
echo "physical lines: $(wc -l < "$LAB/state/done-lane.status")  (expect 2)"
readers done-lane
hold answer done-lane --decision-file "$LAB/go.txt" --release; echo "answer --release rc=$?"
show done-lane; readers done-lane

say "S5 held paused lane with an answer for another key on top: worker pause stays current"
lane mixed-lane ship
printf 'working: start\npaused: waiting on vendor\n' > "$LAB/state/mixed-lane.status"
mark mixed-lane
hold hold mixed-lane --reason "operator review"; echo "hold rc=$?"
printf 'resolved [key=api-shape]: use v2\n' >> "$LAB/state/mixed-lane.status"
show mixed-lane; readers mixed-lane
say "S5b worker reports done after the hold: done replaces the standing mirror"
printf 'done: PR ready\n' >> "$LAB/state/mixed-lane.status"
readers mixed-lane
hold answer mixed-lane --decision-file "$LAB/go.txt" --release; echo "release rc=$?"
show mixed-lane; readers mixed-lane

say "S6 decision-only hold (no worker lane) creates no status log"
hold hold lone-question --title "Pick a name" --repo sample --reason "captain picks"; echo "hold rc=$?"
ls "$LAB/state" | grep -c '^lone-question' | sed 's/^/state files for lone-question: /'

say "backlog after all scenarios"
cat "$LAB/data/backlog.md" | cut -c1-220
