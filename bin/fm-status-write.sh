#!/usr/bin/env bash
# Append one validated, timestamped status event.
# Usage: fm-status-write.sh <status-file> <verb> [--key <slug>] [--corr <16-hex>] -- <body>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "Usage: fm-status-write.sh <status-file> <verb> [--key <slug>] [--corr <16-hex>] -- <body>" >&2; exit 2; }
[ "$#" -ge 4 ] || usage
status_file=$1 verb=$2
shift 2
key= corr=
while [ "${1:-}" != -- ]; do
  case "${1:-}" in
    --key) [ "$#" -ge 3 ] || usage; key=$2; shift 2 ;;
    --corr) [ "$#" -ge 3 ] || usage; corr=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ "$#" -eq 2 ] || usage
shift
body=$1
[ -n "$body" ] || { echo 'error: status body must not be empty' >&2; exit 2; }
case "$verb" in
  working|needs-decision|blocked|done|failed|note|"${FM_CLASSIFY_PAUSED_VERB:-paused}"|"${FM_CLASSIFY_RESOLVE_VERB:-resolved}"|captain-held) ;;
  *) echo "error: invalid status verb '$verb'" >&2; exit 2 ;;
esac
if [ -n "$key" ]; then
  case "$key" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid status key '$key'" >&2; exit 2 ;; esac
fi
if [ -n "$corr" ]; then
  case "$corr" in [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;; *) echo 'error: corr must be 16 hex characters' >&2; exit 2 ;; esac
fi
case "$status_file" in '') usage ;; esac
if [ -e "$status_file" ] || [ -L "$status_file" ]; then
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || { echo 'error: status path must be a regular non-symlink file' >&2; exit 1; }
else
  mkdir -p "$(dirname "$status_file")"
fi
python3 - "$status_file" "$verb" "$key" "$corr" "$body" <<'PY'
import fcntl
import os
import re
import sys
import time

path, verb, key, corr, body = sys.argv[1:]
body = re.sub(r"[\s\x00-\x1f\x7f]+", " ", body).strip()
if not body:
    raise SystemExit("error: status body must not be empty")
head = verb
if key:
    head += f" [key={key}]"
if corr:
    head += f" [corr={corr.lower()}]"
line = f"{head} [at={int(time.time())}]: {body}\n".encode()
flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
fd = os.open(path, flags, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX)
    view = memoryview(line)
    while view:
        written = os.write(fd, view)
        view = view[written:]
finally:
    os.close(fd)
PY
