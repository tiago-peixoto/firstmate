#!/usr/bin/env bash
# Capture or receive a reviewed, non-secret document for a routed request.
# Usage:
#   FM_HOME=<source-home> fm-document-snapshot.sh capture <document-path>
#   FM_HOME=<receiving-home> fm-document-snapshot.sh receive <sha256> <bytes> < document
# Both print data/report-snapshots/<sha256>.md only after verified publication.
# Exit 1 refuses the document. Exit 2 means this home's storage failed, so a
# retry may succeed.
# capture accepts an absolute or home-relative .md/.txt file under data/.
# Hidden or key-file paths, symlinks, hardlinks, non-UTF-8 text, and
# recognizable secret formats are refused. These checks are not proof
# that arbitrary prose is non-secret: callers must review the document first.
# The snapshot is at most 1 MiB, the existing remote-file transport safety bound.
# A larger input must be reduced to the relevant non-secret document, never
# silently truncated. The source document is never modified.
# receive is the narrow artifact-copy endpoint for fm-on.sh --stdin; its hash
# and byte count commit to the exact reviewed bytes, including final newlines.
# Source-home and source-document provenance travel with the referring message.
set -eu
case "${1:-}" in
  --help|-h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
# Descriptor-relative IO keeps components confined across directory replacement.
python3 - "$@" 3<&0 <<'PY'
import hashlib
import os
import re
import stat
import sys
import uuid

MAX_BYTES = 1048576
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
FILE = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW


def refuse(message):
    raise ValueError(message)


def directory(parent, name, create=False):
    if create:
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
        except FileExistsError:
            pass
    return os.open(name, DIRECTORY, dir_fd=parent)


def read_file(parent, name):
    with os.fdopen(os.open(name, FILE, dir_fd=parent), 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            refuse('document must be an ordinary, non-hardlinked file')
        if info.st_size > MAX_BYTES:
            refuse('document exceeds the 1048576-byte safety bound')
        return source.read(MAX_BYTES + 1)


def check_content(content):
    if len(content) > MAX_BYTES:
        refuse('document exceeds the 1048576-byte safety bound')
    text = content.decode('utf-8')
    patterns = (
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----',
        r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
        r'\b(?:gh[pousr]_|github_pat_|xox[baprs]-|sk_live_|sk-proj-)[A-Za-z0-9_-]{20,}',
        r'://[^\s/:]+:[^\s/@]+@',
    )
    if any(re.search(pattern, text) for pattern in patterns):
        refuse('document contains possible credentials; provide a reviewed non-secret extract')


def publish(home, content, digest):
    data = directory(home, 'data', create=True)
    try:
        snapshots = directory(data, 'report-snapshots', create=True)
    finally:
        os.close(data)
    name = digest + '.md'
    temporary = '.' + uuid.uuid4().hex
    try:
        try:
            info = os.stat(name, dir_fd=snapshots, follow_symlinks=False)
        except FileNotFoundError:
            info = None
        if info is not None and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1):
            refuse('snapshot destination is unsafe')
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=snapshots)
        with os.fdopen(fd, 'wb') as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, name, src_dir_fd=snapshots, dst_dir_fd=snapshots)
        if read_file(snapshots, name) != content:
            refuse('snapshot read-back differs from the reviewed bytes')
    finally:
        try:
            os.unlink(temporary, dir_fd=snapshots)
        except FileNotFoundError:
            pass
        os.close(snapshots)
    print('data/report-snapshots/' + name)


def main():
    home_path = os.path.realpath(os.environ['FM_HOME'])
    home = os.open(home_path, DIRECTORY)
    try:
        args = sys.argv[1:]
        if len(args) == 2 and args[0] == 'capture':
            path = args[1]
            if re.search(r'[\x00-\x1f\x7f]', path):
                refuse('document path contains control bytes')
            if os.path.isabs(path):
                lexical = os.path.relpath(path, os.path.abspath(os.environ['FM_HOME']))
                path = lexical if lexical.startswith('data/') else os.path.relpath(path, home_path)
            parts = path.split('/')
            if parts[0] != 'data' or any(not part or part.startswith('.') for part in parts):
                refuse("document must be a non-hidden path under this home's data directory")
            if not path.endswith(('.md', '.txt')):
                refuse('document must be Markdown or plain text')
            if re.search(r'(?:id_rsa|id_ed25519|\.pem|\.key)', path, re.I):
                refuse('credential paths cannot be snapshotted')
            parent = os.dup(home)
            try:
                for part in parts[:-1]:
                    child = directory(parent, part)
                    os.close(parent)
                    parent = child
                content = read_file(parent, parts[-1])
            except OSError as error:
                refuse(str(error))
            finally:
                os.close(parent)
            digest = hashlib.sha256(content).hexdigest()
        elif len(args) == 3 and args[0] == 'receive':
            digest, size = args[1:]
            if not re.fullmatch(r'[a-f0-9]{64}', digest) or not re.fullmatch(r'\d{1,7}', size):
                refuse('invalid snapshot digest or byte count')
            if int(size) > MAX_BYTES:
                refuse('document exceeds the 1048576-byte safety bound')
            with os.fdopen(3, 'rb') as source:
                content = source.read(MAX_BYTES + 1)
            if len(content) != int(size) or hashlib.sha256(content).hexdigest() != digest:
                refuse('snapshot bytes do not match their commitment')
        else:
            refuse('usage: fm-document-snapshot.sh capture <path> | receive <sha256> <bytes>')
        check_content(content)
        try:
            publish(home, content, digest)
        except ValueError as error:
            raise OSError(str(error)) from error
    finally:
        os.close(home)


try:
    main()
except ValueError as error:
    sys.exit('error: cannot deliver document snapshot: ' + str(error))
except (OSError, KeyError) as error:
    print('error: cannot store document snapshot: ' + str(error), file=sys.stderr)
    sys.exit(2)
PY
