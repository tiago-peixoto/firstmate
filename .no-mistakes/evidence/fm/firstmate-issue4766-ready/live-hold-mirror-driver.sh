#!/usr/bin/env bash
# Live drive of the captain-hold status-log mirror against a disposable lab home.
# Runs the real bin/fm-captain-hold.sh and bin/fm-crew-state.sh from the worktree.
set -u
ROOT=$PWD
export PATH=~/.local/share/mise/installs/node/22.23.1/bin:$PATH
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'tmux kill-server >/dev/null 2>&1; rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
mkdir -p "$LAB/fakebin"
for tool in treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/$tool"; chmod +x "$LAB/fakebin/$tool"; done
run_captain() { PATH="$LAB/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" FM_CONFIG_OVERRIDE="$LAB/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
run_crew_state() { PATH="$LAB/fakebin:$PATH" FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-crew-state.sh" "$1"; }
show_log() { echo "--- state/$1.status:"; sed 's/^/    /' "$LAB/state/$1.status"; }

id=lab-gated-work
echo "# S1: hold a task that has a worker lane"
(cd "$LAB" && tasks-axi add "$id" "Ship the lab sample" --kind ship --repo sample) >/dev/null || { echo "tasks-axi add failed"; exit 1; }
printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=claude\nkind=ship\nmode=ship\nspawn_gen=lab-%s\n' "$id" "$LAB" "$id" "$LAB" "$id" > "$LAB/state/$id.meta"
mkdir -p "$LAB/projects/missing-$id"
tmux new-session -d -s firstmate -n "fm-$id" -c "$LAB" "sleep 600" || { echo "lab tmux session failed"; exit 1; }
echo "lab tmux (private socket $TMUX_TMPDIR): $(tmux list-windows -a -F '#S:#W')"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id") && "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" idle --gen "$gen" --source claude-hook --event stop >/dev/null || { echo "could not arm the idle record"; exit 1; }
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which sample API shape\npaused: waiting on the sample upstream release\n' > "$LAB/state/$id.status"
show_log "$id"
echo "\$ fm-captain-hold hold $id --reason \$'operator review pending\\nsecond line of the reason'"
run_captain hold "$id" --reason $'operator review pending\nsecond line of the reason'; echo "exit=$?"
show_log "$id"
echo "\$ fm-captain-hold hold $id --reason 'operator review pending' (repeat)"
run_captain hold "$id" --reason 'operator review pending'; echo "exit=$?"
echo "captain-held line count: $(grep -c '^captain-held ' "$LAB/state/$id.status")"
echo "\$ fm-crew-state $id (while held)"
run_crew_state "$id"
echo "\$ tasks-axi show $id (backlog)"
(cd "$LAB" && tasks-axi show "$id") | head -12

echo; echo "# S2: release retracts the declaration and readers see the worker's own last event"
printf 'Proceed as planned.\n' > "$LAB/go.txt"
echo "\$ fm-captain-hold answer $id --decision-file go.txt --release"
run_captain answer "$id" --decision-file "$LAB/go.txt" --release; echo "exit=$?"
show_log "$id"
echo "\$ fm-crew-state $id (after release)"
run_crew_state "$id"
echo "last_status_line (watcher read): $(bash -c '. "$1"; . "$2"; last_status_line "$3"' _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$LAB/state/$id.status")"
echo "status_open_decisions: $(bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$LAB/state/$id.status" | tr '\t' ' ')"

echo; echo "# S3: a decision-only hold (no worker lane) creates no status log"
echo "\$ fm-captain-hold hold lab-decision-only --title 'Pick the vendor' --reason 'captain must pick' --repo sample"
run_captain hold lab-decision-only --title 'Pick the vendor' --reason 'captain must pick' --repo sample; echo "exit=$?"
ls "$LAB/state/" | sed 's/^/    state\//'
[ -e "$LAB/state/lab-decision-only.status" ] && echo "UNEXPECTED: status log minted for a lane-less hold" || echo "no state/lab-decision-only.status (expected)"

echo; echo "# S4: adversarial - the worker keeps writing over a standing hold; the later worker line wins, the hold is still retracted on close"
run_captain hold "$id" --reason 'second operator review' >/dev/null; echo "re-hold exit=$?"
printf 'done: PR https://example.test/pull/7 checks green\n' >> "$LAB/state/$id.status"
echo "last_status_line while held with a later done line: $(bash -c '. "$1"; . "$2"; last_status_line "$3"' _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$LAB/state/$id.status")"
printf 'Ship it as reviewed.\n' > "$LAB/ship.txt"
run_captain answer "$id" --decision-file "$LAB/ship.txt"; echo "answer (close) exit=$?"
show_log "$id"
echo "\$ fm-crew-state $id (after closing answer)"
run_crew_state "$id"
echo "retraction count for key 2: $(grep -c 'resolved \[key=captain-hold-'"$id"'-2\]' "$LAB/state/$id.status")"
echo "lab home removed on exit: $LAB"
