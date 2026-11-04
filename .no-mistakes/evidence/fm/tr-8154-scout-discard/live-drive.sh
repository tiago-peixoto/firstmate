#!/usr/bin/env bash
# live-drive.sh <firstmate-root> <label> <report: missing|partial|finished> <force: yes|no>
# Drives the real bin/fm-teardown.sh on a scout in a disposable fm-lab-home, with a
# real tmux window on the lab's private socket, then reads the real landed
# projection from bin/fm-bearings-snapshot.sh --json.
set -u
ROOT=$1 label=$2 report=$3 force=$4
WT={run-worktree}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TD=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
sock="$TD/tmux-$(id -u)/fm-lab"
id="lab-scout-$label"
cleanup() { [ -S "$sock" ] && tmux -S "$sock" kill-server 2>/dev/null; "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
printf 'claude\n' > "$LAB/config/crew-harness"
touch "$LAB/state/.last-watcher-beat"
tasks-axi add "$id" "Investigate something" --kind scout --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
mkdir -p "$LAB/data/$id"
case $report in
  partial) printf 'unfinished findings\n' > "$LAB/data/$id/report.md" ;;
  finished) printf '# Findings\nDone.\n' > "$LAB/data/$id/report.md" ;;
esac
TMUX_TMPDIR="$TD" tmux -L fm-lab new-session -d -s firstmate -n "fm-$id" 'sleep 600'
export TMUX="$sock,0,0"
cat > "$LAB/state/$id.meta" <<META
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$LAB/absent-worktree
project=$LAB/absent-project
harness=claude
kind=scout
mode=
yolo=off
spawn_gen=spawn-live-$label
META
echo "--- windows before teardown:"; TMUX_TMPDIR="$TD" tmux -L fm-lab list-windows -F '#W'
if [ "$report" = finished ] && [ "$force" = no ]; then echo "--- $ fm-captain-hold.sh complete $id --none"; FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none 2>&1; fi
args=("$id"); [ "$force" = yes ] && args+=(--force)
echo "--- root=$ROOT"; echo "--- \$ fm-teardown.sh ${args[*]}"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "${args[@]}" 2>&1; echo "teardown exit=$?"
echo "--- windows after teardown:"; TMUX_TMPDIR="$TD" tmux -L fm-lab list-windows -F '#W' 2>&1
echo "--- backlog row:"; tasks-axi show "$id" --full --file "$LAB/data/backlog.md"
echo "--- landed projection (fm-bearings-snapshot.sh --json | .landed):"
FM_HOME="$LAB" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -c '[.landed[]? | {id, kind, report_path: (.report_path // null)}]'
