#!/usr/bin/env bash
# Runs as the tmux session command inside the disposable lab primary pane.
# Spawns one real Kimi crewmate per case through bin/fm-spawn.sh and records
# the spawn log, the worker pane, the task status, and the MCP marker log.
set -u
LAB=$FM_HOME
ROOT=$FM_LAB_WORKTREE
for case_name in "$@"; do
  id="kimi230-$case_name"
  : > "$LAB/spawn-$case_name.log"
  "$ROOT/bin/fm-spawn.sh" "$id" "$LAB/projects/$case_name" --mode local-only --yolo off --harness kimi \
    >> "$LAB/spawn-$case_name.log" 2>&1
  printf 'spawn exit code: %s\n' "$?" >> "$LAB/spawn-$case_name.log"
  sleep 2
  : > "$LAB/pane-$case_name.txt"
  for wid in $(tmux list-windows -F '#{window_id} #{window_name}' | awk '$2 != "primary" {print $1}'); do
    printf '=== window %s (%s) %sx%s ===\n' "$wid" "$(tmux display-message -p -t "$wid" '#{window_name}')" \
      "$(tmux display-message -p -t "$wid" '#{pane_width}')" "$(tmux display-message -p -t "$wid" '#{pane_height}')" >> "$LAB/pane-$case_name.txt"
    tmux capture-pane -p -t "$wid" >> "$LAB/pane-$case_name.txt"
  done
  printf -- '--- state/%s.status ---\n' "$id" >> "$LAB/pane-$case_name.txt"
  cat "$LAB/state/$id.status" >> "$LAB/pane-$case_name.txt" 2>&1
  printf -- '--- marker.log (%s bytes) ---\n' "$(wc -c < "$LAB/marker.log")" >> "$LAB/pane-$case_name.txt"
  cat "$LAB/marker.log" >> "$LAB/pane-$case_name.txt"
done
touch "$LAB/driver.done"
sleep 900
