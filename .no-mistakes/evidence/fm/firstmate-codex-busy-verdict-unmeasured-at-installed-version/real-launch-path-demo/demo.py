"""Credential-free product demo of native Codex activity visibility.

Drives the REAL Firstmate launch path (bin/fm-spawn.sh -> bin/fm-codex-appserver.py
-> the installed codex-cli 0.153.2 TUI) inside an isolated Herdr lab, and prints
the operator-visible surfaces: the native verdict reader and `fm-crew-state.sh`.

The account's Codex message quota is exhausted, so model turns are served by a
disposable local Responses provider injected through a CLI overlay on this
project only. The binary, the launch path, the app-server transport, the crew
state reader and the supervision classifier are all the real production ones.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time

root = Path(sys.argv[1]).resolve()
helper = os.environ['HERDR_LAB_HELPER']
session = os.environ['HERDR_LAB_SESSION']
lab = Path(os.environ['FM_CODEX_NATIVE_LAB']).resolve()
assert session.startswith('fm-lab-') and session != 'default'
spec = importlib.util.spec_from_file_location('native', root / 'bin/fm-codex-appserver.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
base_env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}


def say(text=''):
    print(text, flush=True)


def command(args, env=None, timeout=90, check=True):
    args = list(map(str, args))
    r = subprocess.run(args, env=env or base_env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=timeout)
    if check and r.returncode:
        raise AssertionError(shlex.join(args) + '\n' + r.stdout)
    return r.stdout


def herdr(*args):
    return command([helper, 'run', session, *args])


class Responses(http.server.BaseHTTPRequestHandler):
    """Disposable Responses provider. mode='error' reproduces an API failure."""
    mode = 'success'

    def log_message(self, *_a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"models":[]}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        if self.mode == 'error':
            self.send_response(400)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"error":{"message":"FIRSTMATE_DEMO_HTTP_ERROR","type":"invalid_request_error"}}')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        item = {'id': 'msg_demo', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                'content': [{'type': 'output_text', 'text': 'NATIVE_DEMO_OK', 'annotations': []}]}
        response = {'id': 'resp_demo', 'object': 'response', 'status': 'in_progress', 'output': []}
        for kind, values in [('response.created', {'response': response}),
                             ('response.output_item.done', {'output_index': 0, 'item': item}),
                             ('response.completed', {'response': dict(response, status='completed', output=[item],
                              usage={'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2})})]:
            self.wfile.write(('event: ' + kind + '\ndata: ' + json.dumps({'type': kind, **values}) + '\n\n').encode())
            self.wfile.flush()


version = command(['codex', '--version']).strip()
assert version == 'codex-cli 0.153.2', version
say('installed Codex: ' + version)

home = lab / 'parent'
for p in ['config', 'state', 'data', 'projects']:
    (home / p).mkdir(parents=True)
(home / 'config/backlog-backend').write_text('manual\n')
(home / 'config/herdr-presentation-spaces').write_text('off\n')

fault = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Responses)
threading.Thread(target=fault.serve_forever, daemon=True).start()
real_codex = shutil.which('codex', path=base_env['PATH'])
overlay = ['-c', 'model_provider="firstmate_demo"', '-c', 'model="firstmate-fixture"',
           '-c', 'model_providers.firstmate_demo.name="Disposable demo provider"',
           '-c', 'model_providers.firstmate_demo.base_url="http://127.0.0.1:' + str(fault.server_port) + '/v1"',
           '-c', 'model_providers.firstmate_demo.wire_api="responses"',
           '-c', 'model_providers.firstmate_demo.requires_openai_auth=false',
           '-c', 'model_providers.firstmate_demo.request_max_retries=0',
           '-c', 'model_providers.firstmate_demo.stream_max_retries=0']

shim = lab / 'shim'
shim.mkdir()
(shim / 'herdr').write_text('#!/usr/bin/env bash\nset -eu\na=("$@")\nn=${#a[@]}\n'
    'if [ "$*" != "status --json" ]; then\n'
    '[ "${a[$((n-2))]}" = --session ] && [ "${a[$((n-1))]}" = ' + shlex.quote(session) + ' ] || exit 91\n'
    'unset \'a[$((n-1))]\' \'a[$((n-2))]\'\nfi\nPATH=' + shlex.quote(base_env['PATH']) +
    ' exec ' + shlex.quote(helper) + ' run ' + shlex.quote(session) + ' "${a[@]}"\n')
(shim / 'herdr').chmod(0o700)
(shim / 'codex').write_text('#!/usr/bin/env bash\nset -eu\n'
    'if [ "${1:-}" = --version ]; then exec ' + shlex.quote(real_codex) + ' "$@"; fi\n'
    'exec ' + shlex.quote(real_codex) + ' "$@" ' + shlex.join(overlay) + '\n')
(shim / 'codex').chmod(0o700)

env = dict(base_env, PATH=str(shim) + ':' + base_env['PATH'], FM_HOME=str(home),
           FM_SPAWN_NO_GUARD='1', FM_GATE_REFUSE_BYPASS='1', HERDR_SESSION=session)
project, wt = lab / 'project', lab / 'worker'
command(['git', 'init', '-q', project])
command(['git', '-C', project, '-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'demo'])
command(['git', '-C', project, 'worktree', 'add', '-q', '--detach', wt])

task = 'codex-native-demo'
(home / 'data' / task).mkdir()
(home / 'data' / task / 'brief.md').write_text(
    "# Task\n## Captain's intent\nDisposable activity-visibility demo. Reply and wait.\n"
    "\n## Firstmate spec\nReply and wait.\n")
workspace = json.loads(herdr('workspace', 'create', '--label', 'native-demo', '--cwd', str(wt)))['result']
pane = workspace['root_pane']['pane_id']
meta = {'window': session + ':' + pane, 'endpoint_task_id': task, 'worktree': str(wt), 'project': str(project),
        'harness': 'codex', 'kind': 'scout', 'model': 'default', 'effort': 'default', 'spawn_gen': 'demo',
        'backend': 'herdr', 'herdr_session': session,
        'herdr_workspace_id': workspace['workspace']['workspace_id'],
        'herdr_tab_id': workspace['tab']['tab_id'], 'herdr_pane_id': pane}
(home / 'state' / f'{task}.meta').write_text(''.join(k + '=' + v + '\n' for k, v in meta.items()))
(home / 'state' / f'{task}.status').write_text('done: earlier fixture turn\n')
binding_path = home / 'state' / f'{task}.codex-appserver'
herdr('pane', 'rename', pane, 'fm-' + task)


def verdict():
    return command([sys.executable, root / 'bin/fm-codex-appserver.py', 'read', home / 'state', task], env)


def crew():
    return command([root / 'bin/fm-crew-state.sh', task], env).strip()


def show(label):
    v, c = verdict(), crew()
    say('  %-34s native=%-38s %s' % (label, v, c))
    return v, c


def wait_verdict(expected, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if verdict() == expected:
            return
        time.sleep(0.4)
    say(herdr('pane', 'read', pane, '--lines', '40'))
    raise AssertionError('expected ' + expected + ', got ' + verdict())


def input_text(text):
    herdr('pane', 'send-text', pane, text)
    time.sleep(1.3)
    herdr('pane', 'send-keys', pane, 'Enter')


def turn():
    b = json.loads(binding_path.read_text())
    c = native.NativeSocket(b['socket'])
    try:
        c.initialize()
        thread = c.rpc('thread/read', {'threadId': b['thread'], 'includeTurns': False})['thread']
        turns = c.rpc('thread/turns/list', {'threadId': b['thread'], 'limit': 1,
                                            'sortDirection': 'desc', 'itemsView': 'notLoaded'})['data']
        return thread, turns[0] if turns else {}
    finally:
        c.close()


say()
say('== 1. before the native launch: the defect this change fixes ==')
show('no arming yet')

say()
say('== 2. real fm-spawn.sh launch, then live activity ==')
command([root / 'bin/fm-spawn.sh', task, '--relaunch', '--harness', 'codex'], env)
wait_verdict('busy codex-appserver')
show('turn running')
b = json.loads(binding_path.read_text())
say('  binding: gen=%s thread=%s cwd=%s' % (b['gen'], b['thread'][:24], b['worktree']))
say('  transport: dir mode 0%o socket mode 0%o' % (
    Path(b['socket']).parent.stat().st_mode & 0o777, Path(b['socket']).stat().st_mode & 0o777))

wait_verdict('idle codex-appserver')
thread, last = turn()
show('turn completed')
say('  native turn status=%s thread=%s provider=%s' % (last.get('status'), thread['id'][:24], thread.get('modelProvider')))

say()
say('== 3. observation loss reports unknown, never idle or success ==')
os.kill(b['server_pid'], signal.SIGSTOP)
try:
    show('observer stopped')
finally:
    os.kill(b['server_pid'], signal.SIGCONT)
wait_verdict('idle codex-appserver')
show('observer recovered')

say()
say('== 4. an API failure is a native failure, distinct from a disconnect ==')
Responses.mode = 'error'
input_text('Reply DEMO_FAIL.')
wait_verdict('unknown codex-appserver-failed')
thread, last = turn()
v, c = show('API error')
say('  native thread status=%s last turn status=%s' % (thread['status']['type'], last.get('status')))
absorb = command(['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class "$2"', '_', root, task], env).strip()
say('  supervision crew_absorb_class -> %s (a failure is never absorbed as working)' % absorb)

say()
say('== 5. a later turn recovers on the same thread ==')
Responses.mode = 'success'
input_text('Reply DEMO_RECOVERED.')
wait_verdict('idle codex-appserver')
thread2, last2 = turn()
show('recovery turn')
say('  same thread=%s recovery turn status=%s' % (thread2['id'] == thread['id'], last2.get('status')))

say()
say('== 6. operator pane (the actual end-user surface) ==')
for line in herdr('pane', 'read', pane, '--lines', '26').splitlines():
    say('  | ' + line)

say()
say('== 7. exit: cleanup with no orphaned processes ==')
command([root / 'bin/fm-control.sh', task, 'exit'], env)
say('  binding removed: %s' % (not binding_path.exists()))
say('  private transport dir removed: %s' % (not Path(b['socket']).parent.exists()))
orphans = []
for key in ['owner_pid', 'server_pid', 'tui_pid']:
    try:
        os.kill(b[key], 0)
        orphans.append(key)
    except ProcessLookupError:
        pass
say('  orphaned launcher/server/TUI processes: %s' % (orphans or 'none'))
show('after exit')

say()
say('== 8. an observability failure never vetoes the worker (this round) ==')
task = 'codex-degrade-demo'
(home / 'data' / task).mkdir()
(home / 'data' / task / 'brief.md').write_text("# Task\n## Captain's intent\nDegrade demo.\n\n## Firstmate spec\nWait.\n")
proof = lab / 'plain-codex-started'
# Same verified --version (so the capability gate opens and fm-spawn arms), but
# its app-server never starts - exactly the launch failure this round degrades.
(shim / 'codex').write_text('#!/usr/bin/env bash\nset -eu\n'
    'if [ "${1:-}" = --version ]; then exec ' + shlex.quote(real_codex) + ' "$@"; fi\n'
    'if [ "${1:-}" = app-server ]; then echo "demo: app-server refused" >&2; exit 1; fi\n'
    'printf %s "$*" > ' + shlex.quote(str(proof)) + '\n'
    'exec ' + shlex.quote(real_codex) + ' "$@" ' + shlex.join(overlay) + '\n')
workspace = json.loads(herdr('workspace', 'create', '--label', 'native-degrade', '--cwd', str(wt)))['result']
pane = workspace['root_pane']['pane_id']
meta.update({'window': session + ':' + pane, 'endpoint_task_id': task, 'herdr_pane_id': pane,
             'herdr_workspace_id': workspace['workspace']['workspace_id'],
             'herdr_tab_id': workspace['tab']['tab_id']})
(home / 'state' / f'{task}.meta').write_text(''.join(k + '=' + v + '\n' for k, v in meta.items()))
herdr('pane', 'rename', pane, 'fm-' + task)
binding_path = home / 'state' / f'{task}.codex-appserver'
command([root / 'bin/fm-spawn.sh', task, '--relaunch', '--harness', 'codex'], env)
say('  fm-spawn armed the incarnation: busy_gen=%s' %
    ((home / 'state' / f'{task}.meta').read_text().count('busy_gen=') == 1))
deadline = time.monotonic() + 60
while not proof.exists() and time.monotonic() < deadline:
    time.sleep(0.3)
say('  the pane started plain Codex anyway: %s' % proof.exists())
say('  pane argv: %s' % (proof.read_text() if proof.exists() else '(never started)'))
deadline = time.monotonic() + 30
while 'busy_gen=' in (home / 'state' / f'{task}.meta').read_text() and time.monotonic() < deadline:
    time.sleep(0.3)
say('  arming retired from meta: %s' % ('busy_gen=' not in (home / 'state' / f'{task}.meta').read_text()))
say('  arming sidecars left behind: %s' % ([n for n in ['busy-gen', 'busy-state', 'codex-appserver']
                                            if (home / 'state' / f'{task}.{n}').exists()] or 'none'))
say('  status log:')
for line in (home / 'state' / f'{task}.status').read_text().splitlines():
    say('    | ' + line)
show('degraded worker')
say()
say('  operator pane after degrade:')
for line in herdr('pane', 'read', pane, '--lines', '14').splitlines():
    say('  | ' + line)
command([root / 'bin/fm-control.sh', task, 'exit'], env, check=False)

fault.shutdown()
fault.server_close()
say()
say('demo complete: ' + version)
