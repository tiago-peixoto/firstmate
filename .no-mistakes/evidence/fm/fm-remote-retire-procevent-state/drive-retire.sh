#!/usr/bin/env bash
# drive-retire.sh <code-root> <label>: retire a drained second mate home from a lab parent
# whose environment carries the supervision-injected FM_STATE_OVERRIDE=$LAB/state.
set -u
ROOT=$1; label=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
TM=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
CHILD=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm-solo-dev-hz.XXXXXX"); CHILD=$(cd "$CHILD" && pwd -P)
CLAIMS="$LAB/claims"
mkdir -p "$CHILD/bin" "$CHILD/state"; chmod 700 "$CHILD/state"
printf '# Firstmate\n' > "$CHILD/AGENTS.md"
printf 'solo-dev-hz\n' > "$CHILD/.fm-secondmate-home"
cp -R "$ROOT/bin/." "$CHILD/bin/"
# The drained second mate still holds one registered process-event source (a watcher wait).
FM_HOME="$CHILD" FM_STATE_OVERRIDE="$CHILD/state" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  "$CHILD/bin/fm-procevent.sh" register lavish source -- "$(command -v true)" >/dev/null
cat > "$LAB/state/solo-dev-hz.meta" <<M
window=firstmate:fm-solo-dev-hz
endpoint_task_id=solo-dev-hz
worktree=$CHILD
project=$CHILD
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$CHILD
projects=alpha
M
printf '%s\n' "- solo-dev-hz - server solo dev (home: $CHILD; scope: solo dev; projects: alpha; added 2026-06-22)" > "$LAB/data/secondmates.md"
if [ "${3:-}" = parent-source ]; then
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" "$ROOT/bin/fm-procevent.sh" register lavish parentsrc -- "$(command -v true)" >/dev/null
  cp "$LAB/state/procevent/parentsrc.source" "$LAB/parentsrc.before"
fi
# Real tmux on the lab's private socket dir, idle composer in the second mate window.
TMUX_TMPDIR="$TM" tmux new-session -d -s firstmate -n fm-solo-dev-hz "printf '❯\n'; sleep 600"
echo "== [$label] before: child home contents"; ls -A "$CHILD"; ls "$CHILD/state/procevent"
echo "== [$label] before: tmux windows"; TMUX_TMPDIR="$TM" tmux list-windows -a -F '#S:#W'
echo "== [$label] run: FM_HOME=\$LAB FM_STATE_OVERRIDE=\$LAB/state bin/fm-teardown.sh solo-dev-hz"
env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$TM" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  "$ROOT/bin/fm-teardown.sh" solo-dev-hz 2>&1
echo "== [$label] exit=$?"
echo "== [$label] after: child home exists? $([ -d "$CHILD" ] && echo yes || echo no)"
[ -d "$CHILD/state/procevent" ] && { echo "child procevent:"; ls "$CHILD/state/procevent"; }
echo "== [$label] after: parent meta exists? $([ -e "$LAB/state/solo-dev-hz.meta" ] && echo yes || echo no)"
echo "== [$label] after: parent state/procevent: $(ls "$LAB/state/procevent" 2>/dev/null || echo '(none)')"
[ -f "$LAB/parentsrc.before" ] && { cmp -s "$LAB/parentsrc.before" "$LAB/state/procevent/parentsrc.source" && echo "== [$label] parent source registration unchanged" || echo "== [$label] PARENT SOURCE CHANGED OR REMOVED"; }
echo "== [$label] after: secondmates.md:"; cat "$LAB/data/secondmates.md"
echo "== [$label] after: tmux windows"; TMUX_TMPDIR="$TM" tmux list-windows -a -F '#S:#W' 2>&1
TMUX_TMPDIR="$TM" tmux kill-server 2>/dev/null
"$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
rm -rf "$LAB" "$CHILD"
