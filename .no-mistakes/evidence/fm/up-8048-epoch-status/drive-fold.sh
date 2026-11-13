#!/usr/bin/env bash
# Usage: drive-fold.sh <repo-root> <status-file>
# Sources the real classify library and runs the whole-file fold, printing
# stdout (open set) and stderr (format reports) separately.
. "$1/bin/fm-classify-lib.sh"
out=$(status_open_decisions "$2" 2>"$2.stderr"); rc=$?
printf -- '--- open set (stdout), rc=%s ---\n%s\n--- reports (stderr) ---\n' "$rc" "$out"
cat "$2.stderr"; rm -f "$2.stderr"
printf -- '--- end ---\n'
