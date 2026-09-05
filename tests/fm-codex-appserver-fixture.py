"""Portable regression: a real private socket supplies recorded native responses.

The vendor process is the only double; the reader, binding checks, busy
classifier and crew-state mapping all execute through their public interfaces.
"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

root, lab = map(Path, sys.argv[1:3])
vendor_args = sys.argv[3:]
if vendor_args == ['--version']:
    print('codex-cli 0.153.2')
    sys.exit(0)
if vendor_args and vendor_args[0] == '--remote':
    (lab/'tui-started').touch()
    while not (lab/'tui-exit').exists():
        time.sleep(0.05)
    sys.exit(0)
vendor_server = bool(vendor_args)
scenario = os.environ.get('FM_FAKE_NATIVE_SCENARIO', 'direct') if vendor_server else 'direct'
state = lab / 'state'
if vendor_server:
    assert vendor_args[:2] == ['app-server', '--listen']
    path = Path(vendor_args[2][len('unix://'):])
else:
    state.mkdir()
    # Keep AF_UNIX paths short on macOS, even when the lab sits under a deep TMPDIR.
    path = Path(tempfile.mkdtemp(prefix='fm-codex-fixture-', dir='/tmp')) / 'a'
server = socket.socket(socket.AF_UNIX)
server.bind(str(path))
os.chmod(path, 0o600)
server.listen()
terminal_status = os.environ.get('FM_FAKE_NATIVE_STATUS', 'active') if vendor_server else 'active'
native = {'type': terminal_status if scenario == 'direct' else 'active', 'activeFlags': []}
turn = {'id': 'turn-a', 'status': 'inProgress', 'completedAt': None}
ids = ['thread-a']
if scenario in ('title-helper', 'helper-only'):
    ids.append('title-helper')
requests = []
snapshot_events = []

def send(conn, message):
    data = json.dumps(message).encode()
    head = bytes([129, len(data)]) if len(data) < 126 else bytes([129, 126]) + struct.pack('!H', len(data))
    conn.sendall(head + data)

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
                    result = {'data': [] if vendor_server and not (lab/'tui-started').exists() else ids[:],
                              'nextCursor': None}
                elif method == 'thread/read':
                    tid = msg['params']['threadId']
                    result = {'thread': {'id': tid, 'cwd': str(lab), 'parentThreadId': None,
                              'source': 'vscode', 'threadSource': 'system' if tid == 'title-helper' else 'user',
                              'status': native.copy(), 'turns': []}}
                    if vendor_server and scenario == 'direct':
                        send(conn, {'method': 'thread/status/changed',
                                    'params': {'threadId': tid, 'status': native.copy()}})
                    elif tid == 'title-helper' and scenario in ('title-helper', 'helper-only'):
                        send(conn, {'method': 'thread/status/changed',
                                    'params': {'threadId': 'thread-a' if scenario == 'title-helper' else tid,
                                               'status': {'type': 'systemError'}}})
                    if tid == 'title-helper':
                        for params in snapshot_events:
                            send(conn, {'method': 'thread/status/changed', 'params': params})
                elif method == 'thread/turns/list':
                    assert msg['params']['limit'] == 1 and msg['params']['itemsView'] == 'notLoaded'
                    result = {'data': [turn.copy()], 'nextCursor': None}
                else:
                    raise AssertionError('observer attempted mutation: ' + method)
                send(conn, {'id': msg['id'], 'result': result})
                if scenario == 'burst' and method == 'thread/read':
                    tid = msg['params']['threadId']
                    for _ in range(2000):
                        send(conn, {'method': 'item/agentMessage/delta', 'params': {'threadId': tid, 'delta': 'streamed'}})
                    send(conn, {'method': 'thread/status/changed', 'params': {'threadId': tid, 'status': {'type': terminal_status}}})
                if scenario == 'reconnect' and method == 'thread/read':
                    if (lab/'disconnect-observer').exists():
                        (lab/'reconnected-read').touch()
                    else:
                        while not (lab/'disconnect-observer').exists():
                            time.sleep(0.02)
                        native.update(type=terminal_status)
                        return
    except (BrokenPipeError, ConnectionResetError):
        pass

def accept_loop():
    while True:
        try:
            conn, _ = server.accept()
        except OSError:
            return
        threading.Thread(target=serve, args=(conn,), daemon=True).start()

if vendor_server:
    accept_loop()
    sys.exit(0)

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
(fakebin/'no-mistakes').write_text('#!/bin/sh\ncase "$1 $2" in\n'
    '"axi status") printf "%s\\n" "$FM_FAKE_NATIVE_RUN" ;;\n'
    '"runs --limit") printf "%s\\n" "$FM_FAKE_NATIVE_RUNS" ;;\nesac\n')
(fakebin/'no-mistakes').chmod(0o700)
(fakebin/'codex').write_text('#!/bin/sh\nexec '+shlex.join([sys.executable, str(Path(__file__).resolve()),
                                                        str(root), str(lab)])+' "$@"\n')
(fakebin/'codex').chmod(0o700)
for args in [['init', '-q', '-b', 'native-fixture'],
             ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
              '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=/dev/null',
              'commit', '-q', '--allow-empty', '-m', 'fixture']]:
    subprocess.run(['git', '-C', str(lab)] + args, check=True)
head = subprocess.check_output(['git', '-C', str(lab), 'rev-parse', 'HEAD'], text=True).strip()
consumer_env = {k: v for k, v in os.environ.items() if k not in ['FM_ROOT_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_STATE_OVERRIDE']}
consumer_env.update(FM_HOME=str(lab), FM_STATE_OVERRIDE=str(state), PATH=str(fakebin)+':'+os.environ['PATH'])
consumer_env.update(FM_FAKE_NATIVE_RUN='', FM_FAKE_NATIVE_RUNS='')

def classify(want):
    actual = subprocess.check_output(['bash', '-c', '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux mock codex worker "$2"',
                                      '_', str(root), str(state)], text=True)
    assert actual == want, (actual, want)
    print('ok - native classifier: ' + want, flush=True)

def consumers(expected_state, absorb):
    for kind in ['ship', 'scout', 'secondmate']:
        meta_path.write_text(meta_body+'kind='+kind+'\n')
        value = subprocess.check_output([str(root/'bin/fm-crew-state.sh'), 'worker'], env=consumer_env, text=True)
        assert value.startswith('state: '+expected_state+' '), (kind, value)
        value = subprocess.check_output(['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class worker', '_', str(root)],
                                        env=consumer_env, text=True)
        assert value == absorb, (kind, value)
    print('ok - ordinary/secondmate crew-state and supervision: '+expected_state, flush=True)


def ship_runs(expected_state, reason):
    meta_path.write_text(meta_body+'kind=ship\n')
    for run_status, outcome, run_state, detail, coarse_detail in [
        ('completed', 'checks-passed', 'done', 'checks green: PR ready for review', 'run completed'),
        ('failed', 'failed', 'failed', 'run failed', 'run failed'),
        ('running', '', 'working', 'validating (running)', 'validating (background run)'),
    ]:
        # A terminal run stays authoritative over unavailable observation.
        expected = run_state if expected_state == 'unknown' and run_state != 'working' else expected_state
        for coarse in [False, True]:
            consumer_env['FM_FAKE_NATIVE_RUN'] = ('run:\n  id: fixture\n  branch: '+
                ('other-branch' if coarse else 'native-fixture')+'\n  head: '+head+
                '\n  status: '+run_status+'\n  outcome: '+outcome+'\n')
            consumer_env['FM_FAKE_NATIVE_RUNS'] = run_status+' native-fixture '+head+' 2026-09-04 12:00\n'
            for log in ['done: earlier turn\n', 'done: PR checks green\n']:
                (state/'worker.status').write_text(log)
                value = subprocess.check_output([str(root/'bin/fm-crew-state.sh'), 'worker'],
                                                env=consumer_env, text=True)
                assert value.startswith('state: '+expected+' '), value
                if expected == expected_state:
                    assert reason in value and 'run state: '+run_state in value, value
                else:
                    assert reason not in value, value
                assert (coarse_detail if coarse else detail) in value, value
                value = subprocess.check_output(['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class worker',
                                                '_', str(root)], env=consumer_env, text=True)
                assert value == 'none', value
    if expected_state == 'failed':
        snapshot_events.clear()
        native.update(type='active', activeFlags=[])
        turn.update(status='inProgress', completedAt=None)
        value = subprocess.check_output([str(root/'bin/fm-crew-state.sh'), 'worker'], env=consumer_env, text=True)
        assert value.startswith('state: done ') and 'run still monitoring PR' in value, value
    consumer_env.update(FM_FAKE_NATIVE_RUN='', FM_FAKE_NATIVE_RUNS='')
    (state/'worker.status').write_text('done: earlier turn\n')
    print('ok - native ship '+expected_state+' preserves validation state and reaches supervision: '+reason, flush=True)


def initial_notification():
    for status, ordering in [('systemError', 'direct'), ('idle', 'direct'), ('active', 'direct'),
                             ('systemError', 'title-helper'), ('active', 'helper-only'),
                             ('systemError', 'reconnect'), ('idle', 'reconnect'), ('idle', 'burst')]:
        (lab/'tui-started').unlink(missing_ok=True)
        (lab/'tui-exit').unlink(missing_ok=True)
        (lab/'disconnect-observer').unlink(missing_ok=True)
        (lab/'reconnected-read').unlink(missing_ok=True)
        wake = state/'worker.turn-ended'
        wake.unlink(missing_ok=True)
        binding_path.unlink(missing_ok=True)
        launcher = subprocess.Popen([sys.executable, str(root/'bin/fm-codex-appserver.py'),
            'launch', str(state), 'worker', gen, '--', str(fakebin/'codex'), 'fixture prompt'], cwd=lab,
            env={**consumer_env, 'FM_FAKE_NATIVE_STATUS': status, 'FM_FAKE_NATIVE_SCENARIO': ordering})
        observed = None
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                assert launcher.poll() is None, 'launcher exited before binding'
                if binding_path.exists():
                    observed = json.loads(binding_path.read_text())
                    if observed['thread'] == 'thread-a' and ordering == 'reconnect' and not (lab/'disconnect-observer').exists():
                        assert not wake.exists(), 'active turn must not wake before disconnect'
                        (lab/'disconnect-observer').touch()
                    if observed['thread'] == 'thread-a' and (wake.exists() or status == 'active'):
                        break
                time.sleep(0.02)
            assert observed and observed['thread'] == 'thread-a', observed
            assert wake.exists() == (status != 'active'), (status, ordering, 'notification lost or spurious')
            if ordering == 'reconnect':
                assert (lab/'reconnected-read').exists(), 'bound observer must reconcile after reconnect'
            print('ok - binding notification: '+status+' / '+ordering, flush=True)
        finally:
            (lab/'tui-exit').touch()
            assert launcher.wait(timeout=10) == 0, 'launcher must return the exited TUI status'
        assert not binding_path.exists(), 'launcher left its binding behind'
        assert not Path(observed['socket']).parent.exists(), 'launcher left its transport behind'
        for key in ['server_pid', 'tui_pid']:
            try:
                os.kill(observed[key], 0)
            except ProcessLookupError:
                continue
            raise AssertionError('launcher orphaned '+key)


try:
    classify('busy codex-appserver')
    consumers('working', 'working')
    ids.append('title-helper')
    classify('busy codex-appserver')
    ids.pop()
    native = {'type': 'idle'}
    turn.update(status='completed', completedAt=1788557728)
    classify('idle codex-appserver')
    ids.append('title-helper')
    failure = {'threadId': 'thread-a', 'status': {'type': 'systemError'}}
    recovery = {'threadId': 'thread-a', 'status': {'type': 'active', 'activeFlags': []}}
    for events in [[failure], [recovery, failure]]:
        snapshot_events[:] = events
        classify('unknown codex-appserver-failed')
        settled = subprocess.run([sys.executable, str(root/'bin/fm-codex-appserver.py'),
                                  'settled', str(state), 'worker'], capture_output=True, text=True)
        assert settled.returncode == 1 and settled.stdout == '', settled
        consumers('failed', 'none')
    ship_runs('failed', 'Codex native turn failed')
    classify('busy codex-appserver')
    native = {'type': 'idle'}
    turn.update(status='completed', completedAt=1788557728)
    snapshot_events[:] = [failure, recovery]
    classify('busy codex-appserver')
    consumers('working', 'working')
    snapshot_events[:] = [{'threadId': 'title-helper', 'status': {'type': 'systemError'}}]
    classify('idle codex-appserver')
    snapshot_events[:] = [failure]
    native = {'type': 'active', 'activeFlags': []}
    ids.reverse()
    classify('busy codex-appserver')
    ids.reverse()
    ids.pop()
    snapshot_events.clear()
    native = {'type': 'idle'}
    print('ok - snapshot notifications preserve failure, recovery and thread identity', flush=True)
    turn.update(status='interrupted')
    classify('idle codex-appserver')
    native = {'type': 'systemError'}
    turn.update(status='failed')
    classify('unknown codex-appserver-failed')
    consumers('failed', 'none')
    ship_runs('failed', 'Codex native turn failed')
    native = {'type': 'active', 'activeFlags': []}
    turn.update(status='inProgress', completedAt=None)
    classify('busy codex-appserver')
    for flag, source in [('waitingOnApproval', 'approval'), ('waitingOnUserInput', 'input')]:
        native['activeFlags'] = [flag]
        classify('unknown codex-appserver-waiting-' + source)
        consumers('parked', 'none')
        ship_runs('parked', 'Codex waiting for '+('approval' if source == 'approval' else 'user input'))
    native = {'type': 'idle'}
    turn.update(status='completed', completedAt=1788557728)
    ids.append('other-root')
    classify('unknown codex-appserver-binding')
    ids.pop()
    binding['gen'] = 'retired'
    publish()
    classify('unknown codex-appserver-binding')
    ship_runs('unknown', 'codex-appserver-binding')
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
    ship_runs('unknown', 'codex-appserver-disconnected')
    initial_notification()
    consumers('unknown', 'none')
    ship_runs('unknown', 'codex-unverified')
    assert not any(m in requests for m in ['thread/resume', 'turn/start', 'turn/interrupt'])
finally:
    server.close()
    if not vendor_server:
        shutil.rmtree(path.parent, ignore_errors=True)
