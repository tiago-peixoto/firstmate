#!/usr/bin/env bash
# Drives three real bin/fm-teardown.sh runs in a disposable lab home:
#   S5 opted-in ship task, S6 ship task whose task copy is gone, S7 opted-out home.
# Usage: drive-teardowns.sh <lab-home> <fixture-dir> <evidence-dir>
# Run from the worktree under test. Teardown itself runs inside a pane of the
# lab's private tmux server, so it inherits that server's $TMUX.
set -u
LAB=$1 FX=$2 EV=$3
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TREEHOUSE_ROOT="$FX/pool"
LEDGER="$LAB/data/pipeline-spend.jsonl"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }

# mk_task <id>: a real treehouse-leased task copy on branch fm/<id> with one
# landed commit, a real window, a task record, and one seeded pipeline run.
mk_task() {
  local id=$1 wt base
  wt=$(cd "$FX/project" && treehouse get --lease --lease-holder "$id" 2>/dev/null)
  git -C "$wt" checkout -q -b "fm/$id"
  echo "$id" > "$wt/$id.txt"
  git -C "$wt" add .
  git -C "$wt" commit -q -m "work $id"
  git -C "$wt" push -q origin "fm/$id"
  git -C "$FX/project" fetch -q origin
  T new-window -d -t firstmate -n "fm-$id" -c "$wt" bash --norc
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$FX/project" kind=ship mode=no-mistakes harness=claude \
    "spawn_gen=s$(date +%s).1.$id" > "$LAB/state/$id.meta"
  base=$(git -C "$wt" reflog show --date=unix --format=%gd "refs/heads/fm/$id" | tail -1 | sed 's/.*@{\([0-9]*\)}/\1/')
  python3 - "$FX/nm/state.sqlite" "fm/$id" "$base" "$id" <<'PY'
import sqlite3, sys
d, br, base, tid = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
db = sqlite3.connect(d)
db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, status, created_at, updated_at)"
           " VALUES (?, 'r1', ?, 'h', 'b', 'completed', ?, ?)", ("RUN-" + tid, br, base + 1, base + 1))
rows = [("cold", "ok", (100, 20, 50, 5), (100, 20, 50)),
        ("resumed", "ok", (1000, 200, 500, 7), (300, 60, 100)),
        ("cold", "cancelled", (None,) * 4, (None,) * 3)]
for i, (mode, ex, raw, delta) in enumerate(rows):
    db.execute("INSERT INTO agent_invocations (id, run_id, step_name, round, purpose, agent, session_mode,"
               " started_at, completed_at, duration_ms, exit_status, input_tokens, output_tokens,"
               " cache_read_tokens, cache_creation_tokens, delta_input_tokens, delta_output_tokens,"
               " delta_cache_read_tokens) VALUES (?, ?, 'review', 1, 'review', 'claude', ?, ?, ?, 100, ?,"
               " ?, ?, ?, ?, ?, ?, ?)",
               ("%s-i%d" % (tid, i), "RUN-" + tid, mode, base + 2 + i, base + 2 + i, ex) + raw + delta)
db.commit()
PY
}

td() {  # <id>
  local done_flag="$LAB/teardown-$1.done" out="$LAB/teardown-$1.out"
  T send-keys -t firstmate:driver \
    "TREEHOUSE_ROOT=$TREEHOUSE_ROOT bin/fm-teardown.sh $1 > $out 2>&1; echo exit=\$? >> $out; touch $done_flag" Enter
  for _ in $(seq 1 120); do
    [ -e "$done_flag" ] && break
    python3 -c 'import time; time.sleep(2)'
  done
  echo "\$ fm-teardown.sh $1   (inside the lab tmux pane; FM_HOME=lab home, NM_HOME=disposable)"
  sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -v '^●\|treehouse is available\|treehouse update\|^$\|^Backlog:'
}

snap() {
  echo "task records=[$(cd "$LAB/state" && ls -- *.meta 2>/dev/null | tr '\n' ' ')]" \
    "project branches=[$(git -C "$FX/project" branch --format='%(refname:short)' | tr '\n' ' ')]" \
    "ledger lines=$(wc -l < "$LEDGER")"
}

{
  echo "### S5: teardown of an owned ship task, home opted in (config/pipeline-spend present)"
  mk_task task-s2
  echo "before: $(snap)"
  td task-s2
  echo "after:  $(snap)"
  echo "new ledger line:"
  tail -1 "$LEDGER" | jq -c '{task,spawn_gen,source,branch,since,runs:[.runs[].id],total}'

  echo
  echo "### S6: owned ship task whose task copy is already gone, home opted in"
  printf '%s\n' "worktree=$FX/missing-wt" "project=$FX/project" kind=ship mode=no-mistakes harness=codex \
    > "$LAB/state/task-s3.meta"
  echo "before: $(snap)"
  td task-s3
  echo "after:  $(snap)"
  echo "new ledger line:"
  tail -1 "$LEDGER" | jq -c .

  echo
  echo "### S7: same teardown with the opt-in flag removed"
  mv "$LAB/config/pipeline-spend" "$LAB/pipeline-spend.flag-removed"
  before=$(sha256sum "$LEDGER" | cut -d' ' -f1)
  mk_task task-s4
  echo "config dir: [$(ls -A "$LAB/config")]"
  echo "before: $(snap)"
  td task-s4
  echo "after:  $(snap)"
  echo "ledger sha256 before: $before"
  echo "ledger sha256 after:  $(sha256sum "$LEDGER" | cut -d' ' -f1)"
} 2>&1 | tee "$EV/teardown-transcript.txt"
cp "$LEDGER" "$EV/teardown-ledger.jsonl"
