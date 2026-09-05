"""Credentialed Firstmate launch and activity guard, scoped to the shell's lab.

Never use a shared Herdr session. All calls, including backend calls made by
Firstmate itself, are routed through the guarded helper. No user config changes
or synthetic model responses are used by the credentialed cases.
"""
import importlib.util
import http.server
import threading
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import time

root = Path(sys.argv[1]).resolve()
helper = os.environ['HERDR_LAB_HELPER']
session = os.environ['HERDR_LAB_SESSION']
assert session.startswith('fm-lab-') and session != 'default'
spec = importlib.util.spec_from_file_location('native', root/'bin/fm-codex-appserver.py')
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
base_env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'HERDR_'))}
base_env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='commit.gpgsign', GIT_CONFIG_VALUE_0='false')
evidence = Path(os.environ.get('FM_CODEX_NATIVE_EVIDENCE_DIR', str(root/'.no-mistakes/codex-native-live'))).resolve()
evidence.mkdir(parents=True, exist_ok=True)
log = evidence/'commands.jsonl'

def record(command, result):
    with log.open('a') as f:
        f.write(json.dumps({'at': time.time(), 'command': command, 'result': result}) + '\n')


def command(args, env=None, timeout=60):
    args = list(map(str, args))
    result = subprocess.run(args, env=env or base_env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    record(args, {'exit': result.returncode, 'output': result.stdout})
    if result.returncode:
        raise AssertionError(shlex.join(args) + '\n' + result.stdout)
    return result.stdout


def herdr(*args):
    return command([helper, 'run', session, *args])


def input_text(pane, text):
    herdr('pane', 'send-text', pane, text)
    time.sleep(1.3)
    herdr('pane', 'send-keys', pane, 'Enter')


def check(label, condition):
    record(label, bool(condition))
    assert condition, label
    print('ok - ' + label, flush=True)


class ResponsesFixture(http.server.BaseHTTPRequestHandler):
    mode = 'error'

    def log_message(self, *_args):
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
            self.wfile.write(b'{"error":{"message":"FIRSTMATE_TEST_HTTP_ERROR","type":"invalid_request_error"}}')
            return
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        item = {'id': 'msg_fixture', 'type': 'message', 'role': 'assistant', 'status': 'completed',
                'content': [{'type': 'output_text', 'text': 'NATIVE_HTTP_RECOVERED', 'annotations': []}]}
        response = {'id': 'resp_fixture', 'object': 'response', 'status': 'in_progress', 'output': []}
        for kind, values in [('response.created', {'response': response}),
                             ('response.output_item.done', {'output_index': 0, 'item': item}),
                             ('response.completed', {'response': dict(response, status='completed', output=[item],
                                usage={'input_tokens': 1, 'output_tokens': 1, 'total_tokens': 2})})]:
            self.wfile.write(('event: '+kind+'\ndata: '+json.dumps({'type': kind, **values})+'\n\n').encode())
            self.wfile.flush()


version = command(['codex', '--version']).strip()
check('installed Codex version ' + version, version == 'codex-cli 0.153.2')
lab = Path(os.environ['FM_CODEX_NATIVE_LAB']).resolve()
home = lab/'parent'
for p in ['config', 'state', 'data', 'projects']:
    (home/p).mkdir(parents=True)
(home/'config/backlog-backend').write_text('manual\n')
(home/'config/herdr-presentation-spaces').write_text('off\n')
# Keep real Codex, accounts, model, effort and approvals. Only the backend
# CLI route is wrapped so production calls obey this guard's lab contract.
shim = lab/'shim'
shim.mkdir()
(shim/'herdr').write_text('#!/usr/bin/env bash\nset -eu\na=("$@")\nn=${#a[@]}\n'
    'if [ "$*" != "status --json" ]; then\n'
    '[ "${a[$((n-2))]}" = --session ] && [ "${a[$((n-1))]}" = ' + shlex.quote(session) + ' ] || exit 91\n'
    'unset \'a[$((n-1))]\' \'a[$((n-2))]\'\nfi\nPATH=' + shlex.quote(base_env['PATH']) +
    ' exec ' + shlex.quote(helper) + ' run ' + shlex.quote(session) + ' "${a[@]}"\n')
(shim/'herdr').chmod(0o700)
env = dict(base_env, PATH=str(shim)+':'+base_env['PATH'], FM_HOME=str(home),
           FM_SPAWN_NO_GUARD='1', FM_GATE_REFUSE_BYPASS='1', HERDR_SESSION=session)
task = 'codex-native-live'
project, wt = lab/'project', lab/'worker'
command(['git', 'init', '-q', project])
command(['git', '-C', project, 'commit', '-q', '--allow-empty', '-m', 'fixture'])
command(['git', '-C', project, 'worktree', 'add', '-q', '--detach', wt])
(home/'data'/task).mkdir()
(home/'data'/task/'brief.md').write_text("# Task\n## Captain's intent\n"
    "Run exactly one foreground shell call: python3 -c 'import time; time.sleep(12)'. "
    "Wait at least 15000 ms for this command. Then reply NATIVE_INITIAL_OK. "
    "Do not edit files, run other tools, delegate, or inspect the project. "
    "This is a disposable activity lifecycle test. Later prompts are additional test instructions.\n"
    "\n## Firstmate spec\nComplete the specified probe and wait.\n")
workspace = json.loads(herdr('workspace', 'create', '--label', 'native-live', '--cwd', str(wt)))['result']
pane = workspace['root_pane']['pane_id']
tab, ws = workspace['tab']['tab_id'], workspace['workspace']['workspace_id']
herdr('pane', 'rename', pane, 'fm-'+task)
meta = {'window': session+':'+pane, 'endpoint_task_id': task, 'worktree': str(wt), 'project': str(project),
        'harness': 'codex', 'kind': 'scout', 'model': 'default', 'effort': 'default', 'spawn_gen': 'fixture',
        'backend': 'herdr', 'herdr_session': session, 'herdr_workspace_id': ws, 'herdr_tab_id': tab, 'herdr_pane_id': pane}
(home/'state'/f'{task}.meta').write_text(''.join(k+'='+v+'\n' for k, v in meta.items()))
(home/'state'/f'{task}.status').write_text('done: earlier fixture turn\n')
binding_path = home/'state'/f'{task}.codex-appserver'

def binding():
    return json.loads(binding_path.read_text())

def verdict():
    return command(['python3', root/'bin/fm-codex-appserver.py', 'read', home/'state', task], env)

def crew():
    return command([root/'bin/fm-crew-state.sh', task], env)

def turn():
    b = binding()
    c = native.NativeSocket(b['socket'])
    try:
        c.initialize()
        thread = c.rpc('thread/read', {'threadId': b['thread'], 'includeTurns': False})['thread']
        turns = c.rpc('thread/turns/list', {'threadId': b['thread'], 'limit': 1,
                                           'sortDirection': 'desc', 'itemsView': 'notLoaded'})['data']
        result = {'thread': {k: thread.get(k) for k in ['id', 'status', 'cwd', 'model', 'modelProvider',
                                                       'reasoningEffort', 'threadSource']}, 'turns': turns}
        record('native snapshot', result)
        return result
    finally:
        c.close()

def wait_verdict(expected, timeout=90):
    deadline = time.monotonic()+timeout
    previous = None
    while time.monotonic() < deadline:
        actual = verdict()
        if actual != previous:
            print('native: ' + actual, flush=True)
            previous = actual
        if actual == expected:
            return
        time.sleep(0.4)
    record('pane at timeout', herdr('pane', 'read', pane, '--lines', '40'))
    raise AssertionError('expected '+expected+', got '+str(previous))

try:
    command([root/'bin/fm-spawn.sh', task, '--relaunch', '--harness', 'codex'], env)
    wait_verdict('busy codex-appserver')
    check('crew-state proves initial activity over an old done event', 'state: working' in crew())
    wait_verdict('idle codex-appserver')
    first = turn()
    check('native initial turn completed', first['turns'][0]['status'] == 'completed')
    check('exact user thread and cwd', first['thread']['id'] == binding()['thread'] and first['thread']['cwd'] == str(wt))
    check('crew-state permits the status log only after native completion', 'state: done' in crew())
    b = binding()
    check('private directory and socket', Path(b['socket']).parent.stat().st_mode & 0o777 == 0o700
          and Path(b['socket']).stat().st_mode & 0o777 == 0o600)
    # Fresh reader connections are intentional: reconnect never resumes a
    # thread, and must retain the same exact native turn identity.
    check('read-only observer reconnect', turn()['turns'][0]['id'] == first['turns'][0]['id'])
    os.kill(b['server_pid'], signal.SIGSTOP)
    try:
        check('observation loss is unknown, not idle or failure', verdict() == 'unknown codex-appserver-disconnected')
    finally:
        os.kill(b['server_pid'], signal.SIGCONT)
    wait_verdict('idle codex-appserver')
    check('observation recovery retains the exact thread', turn()['thread']['id'] == first['thread']['id'])

    input_text(pane, "Run python3 -c 'import time; time.sleep(30)' in one foreground tool call; wait at least 30000 ms. Then reply NATIVE_LATER_OK.")
    wait_verdict('busy codex-appserver')
    time.sleep(5)
    check('long foreground tool remains native busy', verdict() == 'busy codex-appserver')
    check('crew-state proves later input is working', 'state: working' in crew())
    command([root/'bin/fm-control.sh', task, 'interrupt'], env)
    wait_verdict('idle codex-appserver')
    check('interrupt is a native interrupted turn', turn()['turns'][0]['status'] == 'interrupted')
    input_text(pane, 'Reply NATIVE_RECOVERED without tools.')
    wait_verdict('busy codex-appserver')
    wait_verdict('idle codex-appserver')
    check('a subsequent turn recovers after interruption', turn()['turns'][0]['status'] == 'completed')

    input_text(pane, '/plan')
    input_text(pane, 'Use request_user_input to ask me to choose between Left and Right for this disposable test. Do not infer an answer; wait for my selection.')
    wait_verdict('unknown codex-appserver-waiting-input')
    check('native input wait is parked in crew-state', 'state: parked' in crew())
    record('input wait pane', herdr('pane', 'read', pane, '--lines', '30'))
    herdr('pane', 'send-keys', pane, 'Enter')
    wait_verdict('idle codex-appserver')
    record('after input pane', herdr('pane', 'read', pane, '--lines', '30'))
    old_binding = binding_path.read_text()
    old_gen = b['gen']
    command([root/'bin/fm-control.sh', task, 'exit'], env)
    check('normal exit removes the binding', not binding_path.exists())
    check('normal exit removes private transport', not Path(b['socket']).parent.exists())
    for key in ['owner_pid', 'server_pid', 'tui_pid']:
        try:
            os.kill(b[key], 0)
        except ProcessLookupError:
            continue
        raise AssertionError('orphaned '+key)
    print('ok - owned launcher, server and TUI all exited', flush=True)
    command([root/'bin/fm-spawn.sh', task, '--relaunch', '--harness', 'codex'], env)
    wait_verdict('busy codex-appserver')
    check('restart mints a fresh task incarnation', binding()['gen'] != old_gen)
    fresh = binding_path.read_text()
    binding_path.write_text(old_binding)
    try:
        check('stale launch binding cannot classify replacement', verdict() == 'unknown codex-appserver-binding')
    finally:
        binding_path.write_text(fresh)
    wait_verdict('idle codex-appserver')
    check('replacement activity resumes after stale-binding rejection', turn()['turns'][0]['status'] == 'completed')
    # Fault injection changes only this disposable project's provider.
    # Normal account/model/permission parity is exercised above.
    command([root/'bin/fm-control.sh', task, 'exit'], env)
    fault_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), ResponsesFixture)
    threading.Thread(target=fault_server.serve_forever, daemon=True).start()
    # A CLI overlay injects a deterministic HTTP failure without trusting
    # new project configuration or changing the user's configuration store.
    # Every command still executes the real installed Codex binary.
    real_codex = shutil.which('codex', path=base_env['PATH'])
    overlay = ['-c', 'model_provider="firstmate_test"', '-c', 'model="firstmate-fixture"',
               '-c', 'model_providers.firstmate_test.name="Disposable lifecycle fixture"',
               '-c', 'model_providers.firstmate_test.base_url="http://127.0.0.1:'+str(fault_server.server_port)+'/v1"',
               '-c', 'model_providers.firstmate_test.wire_api="responses"',
               '-c', 'model_providers.firstmate_test.requires_openai_auth=false',
               '-c', 'model_providers.firstmate_test.request_max_retries=0',
               '-c', 'model_providers.firstmate_test.stream_max_retries=0']
    (shim/'codex').write_text('#!/usr/bin/env bash\nset -eu\n'
        'if [ "${1:-}" = --version ]; then exec '+shlex.quote(real_codex)+' "$@"; fi\n'
        'exec '+shlex.quote(real_codex)+' "$@" '+shlex.join(overlay)+'\n')
    (shim/'codex').chmod(0o700)
    try:
        command([root/'bin/fm-spawn.sh', task, '--relaunch', '--harness', 'codex'], env)
        wait_verdict('unknown codex-appserver-failed')
        failed = turn()
        check('fault injection uses only the disposable provider', failed['thread']['modelProvider'] == 'firstmate_test')
        check('HTTP failure is native failed/systemError', failed['thread']['status']['type'] == 'systemError'
              and failed['turns'][0]['status'] == 'failed')
        check('crew-state preserves failure over prior done', 'state: failed' in crew())
        absorb = command(['bash', '-c', '. "$1/bin/fm-classify-lib.sh"; crew_absorb_class "$2"', '_', root, task], env)
        check('supervision does not absorb the native failure as working', absorb == 'none')
        ResponsesFixture.mode = 'success'
        input_text(pane, 'Reply NATIVE_HTTP_RECOVERED.')
        wait_verdict('idle codex-appserver')
        check('same thread recovers after API error', turn()['thread']['id'] == failed['thread']['id']
              and turn()['turns'][0]['status'] == 'completed')
        b = binding()
        os.kill(b['server_pid'], signal.SIGKILL)
        deadline = time.monotonic()+15
        while binding_path.exists() and time.monotonic() < deadline:
            time.sleep(0.2)
        check('server process exit removes the observation binding', not binding_path.exists())
        check('process exit cannot report historical success', verdict().startswith('unknown '))
    finally:
        fault_server.shutdown()
        fault_server.server_close()
        (shim/'codex').unlink()

finally:
    record('final pane', herdr('pane', 'read', pane, '--lines', '35'))
    command([root/'bin/fm-control.sh', task, 'exit'], env)
    check('final cleanup removes binding', not binding_path.exists())

# A real secondmate home retains its tracked primary hooks and distinct
# FM_HOME wiring. Copy the repository as-is; never edit AGENTS.md.
task = 'codex-native-mate'
wt = lab/'secondmate'
command(['git', 'clone', '-q', '--shared', root, wt])
(wt/'.fm-secondmate-home').write_text(task+'\n')
(home/'data'/task).mkdir()
(home/'data'/task/'brief.md').write_text("# Task\n## Captain's intent\n"
    "This is a disposable native activity lifecycle test. Run exactly one foreground shell call: "
    "python3 -c 'import time; time.sleep(12)'. Wait at least 15000 ms. Then reply NATIVE_MATE_OK. "
    "Do not edit files, dispatch work, delegate, inspect projects, or operate any other home. "
    "The root AGENTS.md is the production supervisor contract, not your role for this bounded test.\n"
    "\n## Firstmate spec\nComplete this test and wait. Hooks and existing startup behavior remain enabled.\n")
(home/'state'/f'{task}.status').write_text('done: earlier fixture turn\n')
binding_path = home/'state'/f'{task}.codex-appserver'
try:
    command([root/'bin/fm-spawn.sh', task, wt, '--secondmate', '--harness', 'codex', '--backend', 'herdr'], env)
    meta = dict(line.split('=', 1) for line in (home/'state'/f'{task}.meta').read_text().splitlines() if '=' in line)
    check('secondmate uses only the named Herdr lab', meta.get('backend') == 'herdr' and meta.get('herdr_session') == session)
    pane = meta['herdr_pane_id']
    wait_verdict('busy codex-appserver')
    check('secondmate has parent-owned generation and native activity', meta.get('busy_gen') == binding()['gen']
          and 'state: working' in crew())
    wait_verdict('idle codex-appserver')
    check('secondmate native turn completed', turn()['turns'][0]['status'] == 'completed')
    b = binding()
    os.kill(b['server_pid'], signal.SIGSTOP)
    try:
        check('secondmate observation loss is unknown', 'state: unknown' in crew())
    finally:
        os.kill(b['server_pid'], signal.SIGCONT)
    wait_verdict('idle codex-appserver')
    check('secondmate still permits its routed reply after settling', 'state: done' in crew())
    command([root/'bin/fm-control.sh', task, 'exit'], env)
    check('secondmate exit loses activity instead of trusting old done', 'state: unknown' in crew())
    check('secondmate cleanup removes native transport', not Path(b['socket']).parent.exists())
    for key in ['owner_pid', 'server_pid', 'tui_pid']:
        try:
            os.kill(b[key], 0)
        except ProcessLookupError:
            continue
        raise AssertionError('secondmate orphaned '+key)
finally:
    if (home/'state'/f'{task}.meta').exists():
        record('secondmate final pane', herdr('pane', 'read', pane, '--lines', '35'))
        command([root/'bin/fm-control.sh', task, 'exit'], env)
        check('secondmate final cleanup removes binding', not binding_path.exists())
print('credentialed native lifecycle guard passed: ' + version, flush=True)
