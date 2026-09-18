#!/usr/bin/env bash
# Stage 1: isolated herdr lab session + scratch firstmate home with a pi ship
# task record, then REAL pi launched idle in that task's pane.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
SESSION="fm-lab-pidollar-$$"
export HERDR_SESSION="$SESSION"
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-pidollar-live.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/pidollar"
cat > "$HOME_DIR/data/pidollar/brief.md" <<'B'
# Task
## Captain's intent
Lifecycle smoke test only. Reply with the single word ready and end your turn. Do not run any tool, do not read or edit any file.

## Firstmate spec
Do nothing else.
B
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b pidollar "$WT"
. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr || exit 1
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || { echo container_ensure failed; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}; WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-pidollar" "$WT" "$SEEDED_TAB_ID") || { echo create_task failed; exit 1; }
read -r TAB_ID PANE_ID <<X
$TASK_IDS
X
{
  echo "window=$SESSION:$PANE_ID"; echo "endpoint_task_id=pidollar"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=pi"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=off"; echo "model=default"; echo "effort=default"
  echo "backend=herdr"; echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WORKSPACE_ID"; echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/pidollar.meta"
printf 'SESSION=%q\nSCRATCH=%q\nHOME_DIR=%q\nPROJ=%q\nWT=%q\nPANE_ID=%q\nTARGET=%q\n' \
  "$SESSION" "$SCRATCH" "$HOME_DIR" "$PROJ" "$WT" "$PANE_ID" "$SESSION:$PANE_ID" > "$STATEF"
lab pane run "$PANE_ID" "pi --no-session" >/dev/null 2>&1 || { echo "pane run pi failed"; exit 1; }
for _ in $(seq 1 150); do
  st=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$st" = idle ] && break; sleep 0.4
done
echo "session=$SESSION pane=$PANE_ID agent_status=${st:-none}"
echo "pi $(pi --version 2>/dev/null | head -1), $(herdr --version | head -1)"
