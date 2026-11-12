#!/usr/bin/env bash
# usage: sandbox.sh <herdr binary> <worktree> <mode>
# Disposable sandbox: no network, own pid/ipc namespaces, host HOME, /tmp and /run hidden,
# so no host Herdr session, socket or config is reachable. Everything dies with the sandbox.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
exec nice -n 10 bwrap --ro-bind / / --proc /proc --dev /dev \
  --tmpfs /tmp --tmpfs /run --tmpfs ~ \
  --dir /tmp/hbin --ro-bind "$1" /tmp/hbin/herdr \
  --ro-bind "$2" /tmp/worktree --ro-bind "$here" /tmp/evidence \
  --unshare-net --unshare-pid --unshare-ipc --unshare-uts --die-with-parent --new-session \
  --clearenv --setenv HOME ~ --setenv PATH /tmp/hbin:/usr/bin:/bin \
  --setenv TERM xterm-256color --setenv LANG C.UTF-8 --setenv FM_SANDBOX 1 \
  --setenv REPEATS "${REPEATS:-1}" --chdir /tmp \
  bash /tmp/evidence/entry.sh "$3"
