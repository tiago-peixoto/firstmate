#!/usr/bin/env bash
# Live driver: real bin/ scripts from the run worktree against a disposable lab home.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
trap 'env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
# Private tmux server (default socket inside $LAB/tmux) holding one idle pane per fixture lane.
env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s fm-lab -n base -x 120 -y 40 "sleep 900"
cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" NM_HOME="$LAB/nm-unused" FM_CREW_STATE_NO_FORGE=1 "$@"; }
run() { printf '\n$ %s\n' "$*" | sed "s#$LAB#\$LAB#g"; fm "$@" 2>&1 | sed "s#$LAB#\$LAB#g"; printf '[rc=%s]\n' "${PIPESTATUS[0]}"; }
show() { printf -- '--- state/%s.status\n' "$1"; if [ -e "$LAB/state/$1.status" ]; then cat "$LAB/state/$1.status"; else echo '(no status log)'; fi; }
reader() { printf '%s -> ' "$1"; bash -c '. "$1"; . "$2"; "$3" "$4"' _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$1" "$LAB/state/$2.status"; echo; }
lane() { # <id> <kind> ; status lines on stdin
  (cd "$LAB" && tasks-axi add "$1" "Lane $1" --kind "$2" --repo sample >/dev/null) || echo "ADD FAILED $1"
  mkdir -p "$LAB/projects/wt-$1"
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux new-window -d -t fm-lab -n "fm-$1" "sleep 900"
  printf 'window=fm-lab:fm-%s\nworktree=%s/projects/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=%s\nmode=%s\nspawn_gen=fixture-%s\n' "$1" "$LAB" "$1" "$LAB" "$2" "$2" "$1" > "$LAB/state/$1.meta"
  cat > "$LAB/state/$1.status"
  # The idle verdict a Claude Stop hook records, written through the product's own recorder.
  gen=$(fm bin/fm-busy-event.sh arm "$LAB/state" "$1")
  fm bin/fm-busy-event.sh apply "$LAB/state" "$1" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}
sec() { printf '\n==================== %s\n' "$*"; }

sec "S1 paused lane: hold mirrors one line, repeat hold does not duplicate, crew state stays paused"
lane s1 ship <<'X'
working: mid implementation
needs-decision [key=api-shape]: which sample API shape
paused: waiting on the sample upstream release
X
run bin/fm-crew-state.sh s1
run bin/fm-captain-hold.sh hold s1 --reason "operator review pending"
run bin/fm-captain-hold.sh hold s1 --reason "operator review pending"
show s1
reader last_status_line s1; reader last_worker_status_line s1; reader status_current_line s1; reader status_declared_wait_line s1; reader status_open_decisions s1
run bin/fm-crew-state.sh s1

sec "S2 release retracts with no worker alive; re-hold uses key -2; closing answer retracts; replay appends nothing"
printf 'Proceed as planned.\n' > "$LAB/go.txt"
run bin/fm-captain-hold.sh answer s1 --decision-file "$LAB/go.txt" --release
show s1
reader last_status_line s1; reader status_open_decisions s1
run bin/fm-crew-state.sh s1
run bin/fm-captain-hold.sh hold s1 --reason "second operator review"
show s1
printf 'Ship it as reviewed.\n' > "$LAB/ship.txt"
run bin/fm-captain-hold.sh answer s1 --decision-file "$LAB/ship.txt"
run bin/fm-captain-hold.sh answer s1 --decision-file "$LAB/ship.txt"
show s1
reader last_status_line s1
run bin/fm-crew-state.sh s1

sec "S3 adversarial: multi-line reason whose second line is 'blocked: on vendor reply' on a done lane"
lane s3 scout <<'X'
done: report ready
X
run bin/fm-crew-state.sh s3
run bin/fm-captain-hold.sh hold s3 --reason $'Pick the API shape\nblocked: on vendor reply\r\nthird line'
show s3
echo "physical lines: $(wc -l < "$LAB/state/s3.status")"
reader last_worker_status_line s3; reader status_current_line s3; reader status_open_decisions s3
run bin/fm-crew-state.sh s3

sec "S4 adversarial: paused lane held, then an answer for another key lands on top"
lane s4 scout <<'X'
working: start
paused: waiting on vendor
X
run bin/fm-captain-hold.sh hold s4 --reason "operator review"
printf 'resolved [key=api-shape]: use v2\n' >> "$LAB/state/s4.status"
show s4
reader status_declared_wait_line s4; reader status_current_line s4
run bin/fm-crew-state.sh s4

sec "S5 adversarial: decision already answered, then held (keyed and keyless)"
lane s5 scout <<'X'
needs-decision [key=q]: pick
resolved [key=q]: use a
X
run bin/fm-crew-state.sh s5
run bin/fm-captain-hold.sh hold s5 --reason "review"
show s5
reader status_current_line s5; reader status_open_decisions s5
run bin/fm-crew-state.sh s5
lane s5b scout <<'X'
blocked: daemon socket refused
resolved [key=default]: restarted
X
run bin/fm-crew-state.sh s5b
run bin/fm-captain-hold.sh hold s5b --reason "review"
reader status_current_line s5b
run bin/fm-crew-state.sh s5b

sec "S6 worker reports after the hold: its line replaces the mirror"
lane s6 scout <<'X'
working: start
X
run bin/fm-captain-hold.sh hold s6 --reason "review"
printf 'blocked [key=tok]: token expired\n' >> "$LAB/state/s6.status"
reader last_status_line s6; reader status_declared_wait_line s6
run bin/fm-crew-state.sh s6

sec "S7 decision-only hold (no lane) creates no status log"
run bin/fm-captain-hold.sh hold s7-call --title "Pick a vendor" --reason "captain must pick" --repo sample
show s7-call

sec "S8 failed lane held: return brief still lists the failure"
lane t1 ship <<'X'
working: start
failed: build broke
X
run bin/fm-captain-hold.sh hold t1 --reason "retry or drop?"
show t1
run bin/fm-crew-state.sh t1
run bin/fm-afk-contract.sh enter --words "keep the fleet moving"
touch "$LAB/state/.last-watcher-beat"
run bin/fm-afk-return.sh begin
