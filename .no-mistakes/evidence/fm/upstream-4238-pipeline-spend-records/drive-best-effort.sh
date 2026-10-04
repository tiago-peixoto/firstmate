#!/usr/bin/env bash
# S8: the recorder cannot write its ledger (the ledger path is a symlink, which
# the recorder refuses to follow); the real bin/fm-teardown.sh must warn and
# still finish cleanup.
# S9: fm_nm_state_db with NM_HOME and HOME both unset.
# Usage: drive-best-effort.sh <lab-home> <fixture-dir> <evidence-dir>
set -u
LAB=$1 FX=$2 EV=$3
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TREEHOUSE_ROOT="$FX/pool"
LEDGER="$LAB/data/pipeline-spend.jsonl"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
id=task-s5

{
  echo "### S8: recorder cannot write the ledger; teardown must still clean up"
  mv "$LEDGER" "$LAB/data/ledger-kept.jsonl"
  ln -s "$LAB/data/ledger-kept.jsonl" "$LEDGER"
  before=$(sha256sum "$LAB/data/ledger-kept.jsonl" | cut -d' ' -f1)
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
  tasks-axi add "$id" "best effort fixture" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  echo "ledger path is: $(ls -l "$LEDGER" | sed 's/.* \(pipeline-spend.jsonl -> .*\)/\1/')"
  out="$LAB/teardown-$id.out" done_flag="$LAB/teardown-$id.done"
  T send-keys -t firstmate:driver \
    "TREEHOUSE_ROOT=$TREEHOUSE_ROOT bin/fm-teardown.sh $id > $out 2>&1; echo exit=\$? >> $out; touch $done_flag" Enter
  for _ in $(seq 1 120); do
    [ -e "$done_flag" ] && break
    python3 -c 'import time; time.sleep(2)'
  done
  echo "\$ fm-teardown.sh $id   (inside the lab tmux pane; FM_HOME=lab home, NM_HOME=disposable)"
  sed 's/\x1b\[[0-9;]*m//g' "$out" | grep -v '^●\|treehouse is available\|treehouse update\|^$\|^Backlog:'
  echo "after: task records=[$(cd "$LAB/state" && ls -- *.meta 2>/dev/null | tr '\n' ' ')]" \
    "project branches=[$(git -C "$FX/project" branch --format='%(refname:short)' | tr '\n' ' ')]"
  echo "symlink target sha256 before: $before"
  echo "symlink target sha256 after:  $(sha256sum "$LAB/data/ledger-kept.jsonl" | cut -d' ' -f1)"

  echo
  echo "### S9: state database location with NM_HOME and HOME both unset"
  echo "account home from the password database: $(getent passwd "$(id -u)" | cut -d: -f6)"
  echo '$ env -u NM_HOME -u HOME bash -c ". bin/fm-nm-run-lib.sh; fm_nm_state_db /some/worktree"'
  env -u NM_HOME -u HOME bash -c '. bin/fm-nm-run-lib.sh; fm_nm_state_db /some/worktree'
  echo '$ NM_HOME=rel/nm ... fm_nm_state_db /some/worktree'
  NM_HOME=rel/nm bash -c '. bin/fm-nm-run-lib.sh; fm_nm_state_db /some/worktree'
} 2>&1 | tee "$EV/best-effort-transcript.txt"
