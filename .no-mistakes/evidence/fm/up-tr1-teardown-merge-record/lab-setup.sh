#!/usr/bin/env bash
# Builds a disposable lab home with a published ship task whose worker is a real
# `claude` CLI in a window on the lab's private tmux socket. Prints the lab dir.
# Usage: lab-setup.sh <worktree-root>
set -eu
R=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/data/task-x1"
g() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$LAB/origin.git"; git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/project" 2>/dev/null
g -C "$LAB/project" commit -q --allow-empty -m baseline
git -C "$LAB/project" push -q origin HEAD:main
git -C "$LAB/project" remote set-head origin main
git -C "$LAB/project" worktree add -q -b fm/task-x1 "$LAB/wt" main
printf 'hello\n' > "$LAB/wt/feature.txt"; git -C "$LAB/wt" add feature.txt
g -C "$LAB/wt" commit -q -m "ready PR"
git init -q --bare "$LAB/fork.git"; git -C "$LAB/project" remote add fork "$LAB/fork.git"
git -C "$LAB/wt" push -q fork fm/task-x1; git -C "$LAB/project" fetch -q fork
printf '# brief\n' > "$LAB/data/task-x1/brief.md"
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$LAB/wt" \
  "project=$LAB/project" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off" \
  "model=default" "effort=default" "spawn_gen=lab-task-x1" \
  "pr=https://github.com/example/repo/pull/7" > "$LAB/state/task-x1.meta"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-x1 "lab ship task" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-x1 --file "$LAB/data/backlog.md" >/dev/null
touch "$LAB/state/.last-watcher-beat"
# Forge emulator: answers from $LAB/forge-state (OPEN or MERGED) for PR 7.
HEAD_SHA=$(git -C "$LAB/wt" rev-parse HEAD)
echo OPEN > "$LAB/forge-state"
cat > "$LAB/fakebin/gh" <<SH
#!/usr/bin/env bash
s=\$(cat "$LAB/forge-state")
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' "\$s" '$HEAD_SHA' 'https://github.com/example/repo/pull/7'; exit 0 ;;
      *headRefOid*) printf '%s\n' '$HEAD_SHA'; exit 0 ;;
    esac ;;
esac
exit 1
SH
cat > "$LAB/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
s=\$(tr 'A-Z' 'a-z' < "$LAB/forge-state")
case "\${1:-} \${2:-}" in
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: \$s" ;;
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/treehouse"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/no-mistakes"
chmod +x "$LAB/fakebin/"*
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s firstmate -n fm-task-x1 -x 160 -y 45 \
  -c "$LAB/wt" -e FM_HOME="$LAB"
echo "$LAB"
