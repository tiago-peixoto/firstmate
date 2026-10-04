#!/usr/bin/env bash
# S6: real bin/fm-teardown.sh on an owned ship task whose task copy is already
# gone, in an opted-in disposable lab home. The record is windowless, which
# teardown accepts only for a task its markdown backlog carries as in flight,
# so the backlog row is seeded with the real tasks-axi.
# Usage: drive-gone-copy.sh <lab-home> <fixture-dir> <evidence-dir>
set -u
LAB=$1 FX=$2 EV=$3
LEDGER="$LAB/data/pipeline-spend.jsonl"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
snap() {
  echo "task records=[$(cd "$LAB/state" && ls -- *.meta 2>/dev/null | tr '\n' ' ')]" \
    "ledger lines=$(wc -l < "$LEDGER")"
}

[ -e "$LAB/config/pipeline-spend" ] || mv "$LAB/pipeline-spend.flag-removed" "$LAB/config/pipeline-spend"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-s3 "gone task copy fixture" --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-s3 --file "$LAB/data/backlog.md" >/dev/null
printf '%s\n' "worktree=$FX/missing-wt" "project=$FX/project" kind=ship mode=no-mistakes harness=codex \
  > "$LAB/state/task-s3.meta"

{
  echo "### S6: owned ship task whose task copy is already gone, home opted in"
  echo "config dir: [$(ls -A "$LAB/config")]  task copy exists: $([ -d "$FX/missing-wt" ] && echo yes || echo no)"
  echo "before: $(snap)"
  out="$LAB/teardown-task-s3b.out" done_flag="$LAB/teardown-task-s3b.done"
  T send-keys -t firstmate:driver \
    "bin/fm-teardown.sh task-s3 > $out 2>&1; echo exit=\$? >> $out; touch $done_flag" Enter
  for _ in $(seq 1 120); do
    [ -e "$done_flag" ] && break
    python3 -c 'import time; time.sleep(2)'
  done
  echo "\$ fm-teardown.sh task-s3   (inside the lab tmux pane; FM_HOME=lab home, NM_HOME=disposable)"
  sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -v '^●\|treehouse is available\|treehouse update\|^$\|^Backlog:'
  echo "after:  $(snap)"
  echo "new ledger line:"
  tail -1 "$LEDGER" | jq -c .
} 2>&1 | tee "$EV/teardown-gone-copy-transcript.txt"
cp "$LEDGER" "$EV/teardown-ledger.jsonl"
