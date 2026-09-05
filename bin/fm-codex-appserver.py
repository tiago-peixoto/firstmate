#!/usr/bin/env python3
"""Private native transport for fm-spawn's Codex TUI, not a fleet daemon.

launch STATE ID GEN -- CODEX ARGS starts an owned app-server and the unchanged
TUI arguments against its private Unix WebSocket. The launcher binds the sole
root thread and owns both children and its 0700 temporary socket directory.
read STATE ID prints the semantic verdict; settled STATE ID prints the native
terminal turn's epoch. Both are bounded, read-only protocol clients. They never
resume, subscribe to, interrupt or otherwise modify a thread. fm-busy-lib.sh
owns verdict semantics; fm-busy-event.sh still owns the incarnation token.

The private binding includes the generation, socket inode, child PIDs, cwd and
exact thread. Multiple root threads (including /new or /resume in the TUI)
are unsupported and read unknown rather than guessing which one is visible.
The binding contains no credentials, prompts or tool output.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time

VERIFIED_VERSION = 'codex-cli 0.153.2'
MAX_MESSAGE = 2 * 1024 * 1024


class NativeSocket:
    """RFC 6455 client over AF_UNIX using only Python's standard library."""
    def __init__(self, path, timeout=3):
        self.deadline = time.monotonic() + timeout
        self.sock = socket.socket(socket.AF_UNIX)
        self.buffer = bytearray()
        self.terminal_threads = set()
        self.seq = 0
        try:
            self.sock.settimeout(timeout)
            self.sock.connect(str(path))
            key = base64.b64encode(os.urandom(16)).decode()
            self.sock.sendall(('GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                              'Connection: Upgrade\r\nSec-WebSocket-Key: ' + key +
                              '\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
            header = bytearray()
            while not header.endswith(b'\r\n\r\n'):
                header.extend(self.exact(1))
                if len(header) > 8192:
                    raise ValueError('oversized upgrade')
            lines = header.decode('ascii').split('\r\n')
            headers = {k.lower(): v.strip() for k, v in (line.split(':', 1) for line in lines[1:] if line)}
            accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if (lines[0].split()[1] != '101' or headers.get('upgrade', '').strip() != 'websocket'
                    or headers.get('sec-websocket-accept', '') != accept):
                raise ValueError('invalid upgrade')
        except BaseException:
            self.close()
            raise

    def close(self):
        self.sock.close()

    def exact(self, count):
        while len(self.buffer) < count:
            remaining = self.deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('native read timed out')
            self.sock.settimeout(remaining)
            data = self.sock.recv(max(4096, count - len(self.buffer)))
            if not data:
                raise EOFError('native transport closed')
            self.buffer.extend(data)
        result = bytes(self.buffer[:count])
        del self.buffer[:count]
        return result

    def send(self, payload, opcode=1):
        data = json.dumps(payload).encode() if opcode == 1 else payload
        size = len(data)
        if size > MAX_MESSAGE:
            raise ValueError('oversized message')
        if size < 126:
            header = bytes([128 | opcode, 128 | size])
        elif size < 65536:
            header = bytes([128 | opcode, 254]) + struct.pack('!H', size)
        else:
            header = bytes([128 | opcode, 255]) + struct.pack('!Q', size)
        mask = os.urandom(4)
        self.sock.sendall(header + mask + bytes(v ^ mask[i % 4] for i, v in enumerate(data)))

    def receive(self):
        message = bytearray()
        started = False
        while True:
            first, second = self.exact(2)
            opcode, size = first & 15, second & 127
            if first & 112 or second & 128:
                raise ValueError('unsupported frame')
            if size == 126:
                size = struct.unpack('!H', self.exact(2))[0]
            elif size == 127:
                size = struct.unpack('!Q', self.exact(8))[0]
            if size + len(message) > MAX_MESSAGE:
                raise ValueError('oversized native response')
            payload = self.exact(size)
            if opcode == 8:
                raise EOFError('native transport closed')
            if opcode in (9, 10):
                if size > 125 or not first & 128:
                    raise ValueError('invalid control frame')
                if opcode == 9:
                    self.send(payload, 10)
                continue
            if (not started and opcode != 1) or (started and opcode != 0):
                raise ValueError('invalid text frame')
            started = True
            message.extend(payload)
            if first & 128:
                event = json.loads(message)
                params = event.get('params', {})
                if (event.get('method') == 'thread/status/changed'
                        and params.get('status', {}).get('type') in ('idle', 'systemError')):
                    self.terminal_threads.add(params['threadId'])
                return event

    def rpc(self, method, params=None):
        self.seq += 1
        self.send({'id': self.seq, 'method': method, 'params': params or {}})
        while True:
            message = self.receive()
            if message.get('id') == self.seq:
                if 'error' in message:
                    raise ValueError('native RPC refused')
                return message['result']

    def initialize(self):
        self.rpc('initialize', {'clientInfo': {'name': 'firstmate_activity', 'version': '1'},
                               'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized', 'params': {}})


def private(path, kind):
    info = path.lstat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077 or not kind(info.st_mode):
        raise ValueError('non-private binding or transport')
    if kind == stat.S_ISREG and info.st_nlink != 1:
        raise ValueError('linked binding')
    return info


def alive(pid):
    if not isinstance(pid, int) or pid <= 1:
        raise ValueError('invalid process binding')
    os.kill(pid, 0)


def task_identity(state, task):
    meta = dict(line.split('=', 1) for line in (state / (task + '.meta')).read_text().splitlines() if '=' in line)
    return {key: meta.get(key) for key in ('harness', 'worktree', 'busy_gen', 'spawn_gen', 'window', 'backend')}


def roots(client):
    loaded = client.rpc('thread/loaded/list', {'limit': 64})
    if loaded.get('nextCursor'):
        raise ValueError('ambiguous loaded threads')
    result = []
    for tid in loaded['data']:
        thread = client.rpc('thread/read', {'threadId': tid, 'includeTurns': False})['thread']
        if thread['id'] != tid:
            raise ValueError('thread mismatch')
        # The TUI's own title-generation thread is an independent root with
        # parentThreadId=null. Native threadSource, not ancestry alone,
        # distinguishes that system work from a visible user thread.
        if thread.get('parentThreadId') is None and thread.get('threadSource') == 'user':
            result.append(thread)
    return result


def snapshot(state, task):
    binding_path = state / (task + '.codex-appserver')
    if not binding_path.exists():
        return 'unknown codex-unverified', None
    client = None
    try:
        private(binding_path, stat.S_ISREG)
        original = binding_path.read_bytes()
        binding = json.loads(original)
        gen_path = state / (task + '.busy-gen')
        gen = gen_path.read_text().strip()
        if binding['format'] != 1 or binding['version'] != VERIFIED_VERSION or binding['gen'] != gen:
            raise ValueError('generation or capability mismatch')
        meta = task_identity(state, task)
        if (binding['task'] != task or binding['state'] != str(state.resolve()) or binding['identity'] != meta
                or meta.get('busy_gen') != gen or meta.get('harness') != 'codex' or meta.get('worktree') != binding['worktree']):
            raise ValueError('task mismatch')
        for key in ['owner_pid', 'server_pid', 'tui_pid']:
            alive(binding[key])
        path = Path(binding['socket'])
        if not path.is_absolute():
            raise ValueError('relative socket')
        private(path.parent, stat.S_ISDIR)
        info = private(path, stat.S_ISSOCK)
        if (info.st_dev, info.st_ino) != (binding['socket_dev'], binding['socket_ino']):
            raise ValueError('server mismatch')
        if not binding.get('thread'):
            raise ValueError('thread not yet bound')
        client = NativeSocket(path)
        client.initialize()
        turns = client.rpc('thread/turns/list', {'threadId': binding['thread'], 'limit': 1,
                                               'sortDirection': 'desc', 'itemsView': 'notLoaded'})['data']
        # Read runtime status after history: an old terminal turn cannot hide
        # a new active turn. No persisted transcript or rendered text is read.
        current = roots(client)
        if len(current) != 1 or current[0]['id'] != binding['thread'] or current[0]['cwd'] != binding['worktree']:
            raise ValueError('visible thread ambiguous')
        thread = current[0]
        if (binding_path.read_bytes() != original or gen_path.read_text().strip() != gen
                or task_identity(state, task) != meta):
            raise ValueError('binding changed during read')
        for key in ['owner_pid', 'server_pid', 'tui_pid']:
            alive(binding[key])
        status = thread['status']
        last = turns[0] if len(turns) == 1 else {}
        if status['type'] == 'active':
            flags = status['activeFlags']
            if 'waitingOnApproval' in flags:
                return 'unknown codex-appserver-waiting-approval', None
            if 'waitingOnUserInput' in flags:
                return 'unknown codex-appserver-waiting-input', None
            return 'busy codex-appserver', None
        if status['type'] == 'systemError' or last.get('status') == 'failed':
            return 'unknown codex-appserver-failed', None
        if status['type'] == 'idle' and last.get('status') in ('completed', 'interrupted'):
            epoch = last.get('completedAt')
            return 'idle codex-appserver', epoch if isinstance(epoch, int) and epoch > 0 else None
        return 'unknown codex-appserver', None
    except (OSError, EOFError, TimeoutError):
        return 'unknown codex-appserver-disconnected', None
    except (ValueError, KeyError, TypeError, IndexError):
        return 'unknown codex-appserver-binding', None
    finally:
        if client:
            client.close()


def stop(child, group=False):
    if child is None:
        return
    try:
        if group:
            os.killpg(child.pid, signal.SIGTERM)
        elif child.poll() is None:
            child.terminate()
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        if group:
            os.killpg(child.pid, signal.SIGKILL)
        else:
            child.kill()
        child.wait(timeout=3)
    except ProcessLookupError:
        pass


def launch(state, task, gen, argv):
    binary = shutil.which(argv[0])
    if not binary or subprocess.check_output([binary, '--version'], text=True).strip() != VERIFIED_VERSION:
        raise ValueError('Codex version has not passed the native activity guard')
    gen_path = state / (task + '.busy-gen')
    if gen_path.read_text().strip() != gen:
        raise ValueError('retired launch generation')
    binding_path = state / (task + '.codex-appserver')
    # AF_UNIX has a short platform path limit. mkdtemp provides an exclusive,
    # private directory; it is owned and removed by this exact launch only.
    directory = Path(tempfile.mkdtemp(prefix='fm-codex-', dir='/tmp')).resolve()
    transport = directory / 's'
    server = tui = observer = None
    binding = None
    previous_handlers = {}
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in [signal.SIGTERM, signal.SIGHUP]:
        previous_handlers[signum] = signal.signal(signum, terminate)
    # Ctrl-C belongs to the TUI. It shares our foreground process group.
    previous_handlers[signal.SIGINT] = signal.signal(signal.SIGINT, signal.SIG_IGN)
    server_args = [binary, 'app-server', '--listen', 'unix://' + str(transport)]
    index = 1
    while index < len(argv) - 1:
        arg = argv[index]
        if arg in ('-c', '--config'):
            server_args += ['-c', argv[index + 1]]
            index += 2
        elif arg in ('-m', '--model'):
            server_args += ['-c', 'model=' + json.dumps(argv[index + 1])]
            index += 2
        else:
            index += 1
    try:
        with (directory / 'server.log').open('w') as log:
            server = subprocess.Popen(server_args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=log, start_new_session=True)
        deadline = time.monotonic() + 15
        while not transport.exists():
            if server.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError('Codex private app-server did not start')
            time.sleep(0.05)
        os.chmod(transport, 0o600)
        observer = NativeSocket(transport)
        observer.initialize()
        if roots(observer):
            raise ValueError('new server unexpectedly has a loaded thread')
        tui = subprocess.Popen([binary, '--remote', 'unix://' + str(transport)] + argv[1:])
        info = transport.stat()
        binding = {'format': 1, 'version': VERIFIED_VERSION, 'gen': gen, 'socket': str(transport),
                   'socket_dev': info.st_dev, 'socket_ino': info.st_ino, 'worktree': str(Path.cwd()),
                   'owner_pid': os.getpid(), 'server_pid': server.pid, 'tui_pid': tui.pid, 'thread': None,
                   'task': task, 'state': str(state.resolve()), 'identity': task_identity(state, task)}
        def publish():
            # state and /tmp may be different filesystems.
            staging = binding_path.with_name(binding_path.name + '.' + gen)
            with os.fdopen(os.open(staging, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as out:
                out.write(json.dumps(binding) + '\n')
            os.replace(staging, binding_path)
        publish()
        while tui.poll() is None and server.poll() is None:
            if gen_path.read_text().strip() != gen:
                raise ValueError('launch generation retired')
            try:
                reconnected = observer is None
                if reconnected:
                    observer = NativeSocket(transport)
                    observer.initialize()
                observer.deadline = time.monotonic() + 3
                if not binding['thread'] or reconnected:
                    current = roots(observer)
                    if (len(current) == 1 and current[0]['cwd'] == binding['worktree']
                            and binding['thread'] in (None, current[0]['id'])):
                        if not binding['thread']:
                            binding['thread'] = current[0]['id']
                            publish()
                        if current[0]['status']['type'] in ('idle', 'systemError'):
                            observer.terminal_threads.add(binding['thread'])
                elif observer.buffer or select.select([observer.sock], [], [], 0.2)[0]:
                    observer.receive()
                else:
                    continue
                if binding['thread'] in observer.terminal_threads:
                    (state / (task + '.turn-ended')).touch()
                observer.terminal_threads.clear()
            except (OSError, EOFError, ValueError, KeyError):
                # Observation is optional to execution. A new read reconnects
                # to the same private socket; no thread/resume is ever sent.
                if observer:
                    observer.close()
                observer = None
                time.sleep(0.5)
            time.sleep(0.1)
        return tui.returncode if tui.returncode is not None else 1
    finally:
        if observer:
            observer.close()
        stop(tui)
        stop(server, group=True)
        try:
            if binding and json.loads(binding_path.read_text()).get('gen') == gen:
                binding_path.unlink()
        except (OSError, ValueError):
            pass
        shutil.rmtree(directory)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ('read', 'settled', 'launch'):
        raise SystemExit('usage: fm-codex-appserver.py read|settled STATE ID | launch STATE ID GEN -- CODEX ARGS')
    command, state, task = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    if not task or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in task):
        raise SystemExit('invalid task id')
    if command == 'launch':
        if len(sys.argv) < 8 or sys.argv[5] != '--':
            raise SystemExit('launch requires GEN -- CODEX ARGS')
        try:
            return launch(state, task, sys.argv[4], sys.argv[6:])
        except (OSError, ValueError, RuntimeError, EOFError) as exc:
            print('Codex native launch failed: ' + str(exc), file=sys.stderr)
            return 1
    verdict, epoch = snapshot(state, task)
    if command == 'read':
        print(verdict, end='')
    elif epoch:
        print(epoch, end='')
    else:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
