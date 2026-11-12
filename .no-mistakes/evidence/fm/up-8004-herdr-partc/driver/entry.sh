#!/usr/bin/env bash
# Runs only inside the bwrap sandbox (private HOME, /tmp, /run, pid and net namespaces).
# usage: entry.sh <mode>   mode: plain | slow-base | slow-target | no-restore
set -euo pipefail
[ "${FM_SANDBOX:-}" = 1 ] || exit 2
[ ! -e ~/.config ] || exit 2
mode=$1
printf 'herdr version: %s\n' "$(herdr --version)"
T=/tmp/worktree/tests/fm-backend-herdr-focus-flash-e2e.test.sh
if [ "$mode" != plain ]; then
  mkdir -p /tmp/scratch && cp -a /tmp/worktree/tests /tmp/scratch/tests
  cp -a /tmp/worktree/bin /tmp/scratch/bin
  T=/tmp/scratch/tests/fm-backend-herdr-focus-flash-e2e.test.sh
  case "$mode" in
    slow-base) cp /tmp/evidence/base-test.sh "$T" ;;
    *) cp /tmp/worktree/tests/fm-backend-herdr-focus-flash-e2e.test.sh "$T" ;;
  esac
  chmod +x "$T"
  MODE=$mode TEST=$T python3 - <<'PY'
import os
from pathlib import Path
mode = os.environ['MODE']
if mode.startswith('slow-'):
    p = Path(os.environ['TEST'])
    line = '    if [ -e "$C_OPERATION_ACTIVE" ]; then\n'
    new = line + '      sleep 10\n'
else:
    p = Path('/tmp/scratch/bin/backends/herdr.sh')
    line = '    fm_backend_herdr_projection_focus_restore "$session" "$before" "pane close" || return 2\n'
    new = '    : # mutation: omit the restore backstop\n'
s = p.read_text()
assert s.count(line) == 1
p.write_text(s.replace(line, new))
print('scratch mutation applied:', mode)
PY
fi
herdr server --session default >/tmp/default-server.log 2>&1 &
for ((i=0; i<100; i++)); do
  if herdr status --json --session default | jq -e '.server.running == true' >/dev/null 2>&1; then
    rc=0
    for ((round=1; round<=${REPEATS:-1}; round++)); do
      printf 'Validation round %s\n' "$round"
      nice -n 10 bash "$(dirname "$(dirname "$T")")/bin/fm-test-run.sh" "$T" || { rc=$?; printf 'round %s exit status %s\n' "$round" "$rc"; }
    done
    printf 'final exit status %s\n' "$rc"
    exit "$rc"
  fi
  sleep 0.1
done
printf 'Sandbox default session failed to start:\n' >&2
tail -50 /tmp/default-server.log >&2
exit 3
