"""Portable regression: a real private socket supplies recorded native responses.

The vendor process is the only double; the reader, binding checks, busy
classifier and crew-state mapping all execute through their public interfaces.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import threading

root, lab = map(Path, sys.argv[1:])
state = lab / 'state'
state.mkdir()
# Keep AF_UNIX paths short on macOS, even when TMPDIR is long.
sockdir = lab / 's'
sockdir.mkdir(mode=0o700)
path = sockdir / 'a'
server = socket.socket(socket.AF_UNIX)
server.bind(str(path))
os.chmod(path, 0o600)
server.listen()
native = {'type': 'active', 'activeFlags': []}
turn = {'id': 'turn-a', 'status': 'inProgress', 'completedAt': None}
ids = ['thread-a']
requests = []

def serve(conn):
    try:
        with conn, conn.makefile('rb') as f:
            headers = {}
            f.readline()
            while True:
                line = f.readline()
                if line == b'\r\n':
                    break
                if not line:
                    return
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            accept = base64.b64encode(hashlib.sha1((headers['sec-websocket-key'] +
                '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
                          'Connection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
            while True:
                h = f.read(2)
                if not h:
                    return
                opcode, length = h[0] & 15, h[1] & 127
                if length == 126:
                    length = struct.unpack('!H', f.read(2))[0]
                elif length == 127:
                    length = struct.unpack('!Q', f.read(8))[0]
                assert h[1] & 128
                mask = f.read(4)
                payload = bytes(v ^ mask[i % 4] for i, v in enumerate(f.read(length)))
                if opcode == 8:
                    return
                msg = json.loads(payload)
                method = msg['method']
                requests.append(method)
                if method == 'initialized':
                    continue
                if method == 'initialize':
                    result = {'userAgent': 'firstmate/0.153.2'}
                elif method == 'thread/loaded/list':
                    result = {'data': ids[:], 'nextCursor': None}
                elif method == 'thread/read':
                    tid = msg['params']['threadId']
                    result = {'thread': {'id': tid, 'cwd': str(lab), 'parentThreadId': None,
                              'source': 'vscode', 'threadSource': 'system' if tid == 'title-helper' else 'user',
                              'status': native.copy(), 'turns': []}}
                elif method == 'thread/turns/list':
                    assert msg['params']['limit'] == 1 and msg['params']['itemsView'] == 'notLoaded'
                    result = {'data': [turn.copy()], 'nextCursor': None}
                else:
                    raise AssertionError('observer attempted mutation: ' + method)
                data = json.dumps({'id': msg['id'], 'result': result}).encode()
                head = bytes([129, len(data)]) if len(data) < 126 else bytes([129, 126]) + struct.pack('!H', len(data))
                conn.sendall(head + data)
    except (BrokenPipeError, ConnectionResetError):
        pass

def accept_loop():
    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=serve, args=(conn,), daemon=True).start()

threading.Thread(target=accept_loop, daemon=True).start()
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(state), 'worker'], text=True).strip()
st = path.stat()
binding = {'format': 1, 'version': 'codex-cli 0.153.2', 'gen': gen,
           'socket': str(path), 'socket_dev': st.st_dev, 'socket_ino': st.st_ino,
           'worktree': str(lab), 'thread': 'thread-a', 'server_pid': os.getpid(),
           'tui_pid': os.getpid(), 'owner_pid': os.getpid(), 'task': 'worker', 'state': str(state.resolve()),
           'identity': {'harness': 'codex', 'worktree': str(lab), 'busy_gen': gen,
                        'spawn_gen': 'fixture', 'window': 'mock', 'backend': None}}
binding_path = state/'worker.codex-appserver'
def publish():
    binding_path.write_text(json.dumps(binding))
    binding_path.chmod(0o600)
publish()
meta_path = state/'worker.meta'
meta_body = 'harness=codex\nbusy_gen='+gen+'\nworktree='+str(lab)+'\nspawn_gen=fixture\nwindow=mock\n'
meta_path.write_text(meta_body+'kind=scout\n')
(state/'worker.status').write_text('done: earlier turn\n')
fakebin = lab/'fakebin'
fakebin.mkdir()
(fakebin/'tmux').write_text('#!/bin/sh\nprintf \'%s\\n\' \'%1\'\n')
(fakebin/'tmux').chmod(0o700)
consumer_env = {k: v for k, v in os.environ.items() if k not in ['FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE']}
consumer_env.update(FM_HOME=str(lab), FM_STATE_OVERRIDE=str(state), PATH=str(fakebin)+':'+os.environ['PATH'])

def classify(want):
    actual = subprocess.check_output(['bash', '-c', '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux mock codex worker "$2"',
                                      '_', str(root), str(state)], text=True)
    assert actual == want, (actual, want)
    print('ok - native classifier: ' + want, flush=True)

def consumers(expected_state, absorb):
    for kind in ['scout', 'secondmate']:
        meta_path.write_text(meta_body+'kind='+kind+'\n')
        value = subprocess.check_output([str(root/'bin/fm-crew-state.sh'), 'worker'], env=consumer_env, text=True)
        assert value.startswith('state: '+expected_state+' '), (kind, value)
        value = subprocess.check_output(['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class worker', '_', str(root)],
                                        env=consumer_env, text=True)
        assert value == absorb, (kind, value)
    print('ok - ordinary/secondmate crew-state and supervision: '+expected_state, flush=True)


try:
    classify('busy codex-appserver')
    consumers('working', 'working')
    ids.append('title-helper')
    classify('busy codex-appserver')
    ids.pop()
    native = {'type': 'idle'}
    turn.update(status='completed', completedAt=1788557728)
    classify('idle codex-appserver')
    turn.update(status='interrupted')
    classify('idle codex-appserver')
    native = {'type': 'systemError'}
    turn.update(status='failed')
    classify('unknown codex-appserver-failed')
    consumers('failed', 'none')
    native = {'type': 'active', 'activeFlags': []}
    turn.update(status='inProgress', completedAt=None)
    classify('busy codex-appserver')
    for flag, source in [('waitingOnApproval', 'approval'), ('waitingOnUserInput', 'input')]:
        native['activeFlags'] = [flag]
        classify('unknown codex-appserver-waiting-' + source)
        consumers('parked', 'none')
    native = {'type': 'idle'}
    turn.update(status='completed', completedAt=1788557728)
    ids.append('other-root')
    classify('unknown codex-appserver-binding')
    ids.pop()
    binding['gen'] = 'retired'
    publish()
    classify('unknown codex-appserver-binding')
    binding['gen'] = gen
    publish()
    binding_path.chmod(0o644)
    classify('unknown codex-appserver-binding')
    publish()
    binding['socket_ino'] += 1
    publish()
    classify('unknown codex-appserver-binding')
    binding['socket_ino'] -= 1
    publish()
    binding['task'] = 'different-task'
    publish()
    classify('unknown codex-appserver-binding')
    binding['task'] = 'worker'
    binding['identity']['spawn_gen'] = 'old-launch'
    publish()
    classify('unknown codex-appserver-binding')
    binding['identity']['spawn_gen'] = 'fixture'
    publish()
    path.unlink()
    classify('unknown codex-appserver-disconnected')
    consumers('unknown', 'none')
    binding_path.unlink()
    consumers('unknown', 'none')
    assert not any(m in requests for m in ['thread/resume', 'turn/start', 'turn/interrupt'])
finally:
    server.close()
