#!/usr/bin/env bash
# Prints what each real status reader returns for <status-file>.
# usage: readers.sh <worktree> <status-file>
. "$1/bin/fm-classify-lib.sh"
printf 'plain(upstream) last_status_line : %s\n' "$(last_status_line "$2")"
. "$1/bin/fm-hold-status-lib.sh"
for f in last_status_line status_declared_wait_line status_current_line last_worker_status_line; do
  printf '%-33s: %s\n' "hold-aware $f" "$($f "$2")"
done
if status_hold_settled "$2" 2>/dev/null; then echo "status_hold_settled: yes"; else echo "status_hold_settled: no"; fi
