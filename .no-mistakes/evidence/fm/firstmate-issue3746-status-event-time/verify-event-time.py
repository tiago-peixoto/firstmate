"""Run from the gate worktree; exercise public CLIs and retain their output."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

root = Path.cwd()
assert str(root) == '/Users/tiago/.no-mistakes/worktrees/5dfc3e2f8f7a/01M1Z67MNFFBNB2N62JQ3XVDJ4'
evidence = Path('/Users/tiago/.no-mistakes/evidence/01M1Z67MNFFBNB2N62JQ3XVDJ4')
scratch = root / '.test-phase-tmp' / 'event-time-demo'
scratch.mkdir()
parent, mate, remote, fake = [scratch / x for x in ('parent', 'mate', 'remote', 'fakebin')]
for home in (parent, mate, remote):
    for d in ('state', 'data', 'config', 'projects'):
        (home / d).mkdir(parents=True)
fake.mkdir()
for name, code in [('tmux', 1), ('no-mistakes', 0)]:
    p = fake / name
    p.write_text(f'#!/bin/sh\nexit {code}\n')
    p.chmod(0o755)
env = dict(os.environ, PATH=f'{fake}:/bin:/usr/bin:' + os.environ['PATH'],
           TMPDIR=str(root / '.test-phase-tmp'), FM_GATE_REFUSE_BYPASS='1',
           FM_HOME=str(parent), FM_ROOT_OVERRIDE=str(root),
           FM_STATE_OVERRIDE=str(parent / 'state'), FM_DATA_OVERRIDE=str(parent / 'data'),
           FM_CONFIG_OVERRIDE=str(parent / 'config'), FM_PROJECTS_OVERRIDE=str(parent / 'projects'))
transcript = (evidence / 'event-time-cli.txt').open('w')
def note(text):
    transcript.write(text + '\n')
    transcript.flush()

def run(args, *, home=parent, extra=None, output=None, expect=0):
    args = [str(x) for x in args]
    current = dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state'),
                   FM_DATA_OVERRIDE=str(home / 'data'), FM_CONFIG_OVERRIDE=str(home / 'config'),
                   FM_PROJECTS_OVERRIDE=str(home / 'projects'))
    current.update(extra or {})
    note(f'\n$ FM_HOME={home} ' + shlex.join(args))
    result = subprocess.run(args, cwd=root, env=current, text=True, capture_output=True, timeout=45)
    if output:
        (evidence / output).write_text(result.stdout)
        note(f'[stdout saved as {output}]')
    else:
        note(result.stdout.rstrip())
    if result.stderr:
        note(result.stderr.rstrip())
    if args[0].endswith('fm-remote-entrypoint.sh'):
        assert 'remote root and home must be separate, non-overlapping directories' in result.stderr
    if 'classify-before.sh' in args:
        assert not result.stderr
    assert result.returncode == expect, (args, result.returncode, result.stderr)
    return result.stdout

def meta(task):
    absent = scratch / ('unavailable-' + task)
    (parent / 'state' / (task + '.meta')).write_text(
        f'window=firstmate:fm-{task}\nworktree={absent}\nproject={absent}\n'
        f'home={absent}\nharness=codex\nkind=secondmate\nmode=secondmate\n')

try:
    note('Emission-time CLI verification. Real report, brief, delta-read, ingest, snapshot, and drain commands; isolated homes; endpoint and gate lookups stubbed. Stock macOS Bash is first on PATH. Snapshot time is explicitly fixed for deterministic ages.')
    # Confirm the earlier test setup failure without starting a worker.
    encoded = lambda text: base64.b64encode(text.encode()).decode()
    rejected = run([root / 'bin/fm-remote-entrypoint.sh', '1', encoded(str(root)),
                    encoded(str(remote)), encoded('fm-remote-delta-read.sh\0')], expect=64)
    # A correlated report writes to the bound parent's channel, then the snapshot reads it.
    (mate / '.fm-secondmate-home').write_text('local-mate\n')
    (mate / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n')
    start = int(time.time())
    run([root / 'bin/fm-secondmate-report.sh', 'done', '0123456789abcdef', 'audit delivered'], home=mate)
    end = int(time.time())
    local = parent / 'state/local-mate.status'
    line = local.read_text()
    stamp = int(re.search(r'\[at=(\d+)\]', line)[1])
    assert start <= stamp <= end
    now = stamp + 120
    os.utime(local, (1577836800, 1577836800))
    (parent / 'state/local-mate.turn-ended').touch()
    meta('local-mate')
    records = {
        'legacy': 'done: imported historical report\n',
        'malformed': 'done [at=bad]: terminal notification\n',
        'literal': 'needs-decision [at=$(date +%s)]: choose the release branch\n',
        'duplicate': 'failed [at=1] [at=2]: duplicate time stays unknown\n',
        'future': f'working [at={now + 200}]: future clock\n',
    }
    for task, raw in records.items():
        path = parent / 'state' / (task + '.status')
        path.write_text(raw)
        os.utime(path, (now, now))
        meta(task)
    note(f'Fixture: local event file mtime=1577836800, later turn-ended marker present; other mtimes={now}; snapshot now={now}.')
    snapshot = json.loads(run([root / 'bin/fm-fleet-snapshot.sh', '--json'],
                             extra={'FM_SNAPSHOT_NOW_EPOCH': str(now)}, output='event-time-snapshot.json'))
    events = {x['id']: x['paths']['status_log']['last_event'] for x in snapshot['tasks']}
    expected = {'local-mate': (stamp, 120), 'future': (now + 200, None)}
    for task in events:
        epoch, age = expected.get(task, (None, None))
        assert events[task]['emitted_at_epoch'] == epoch and events[task]['age_seconds'] == age
    for row in snapshot['secondmate_current']['records']:
        task = row['id']
        assert row['parent_event']['emitted_at_epoch'] == events[task]['emitted_at_epoch']
        assert row['parent_event']['age_seconds'] == events[task]['age_seconds']
        assert row['current']['state'] == 'unknown'
    run(['jq', '{tasks: [.tasks[] | {id, event: .paths.status_log.last_event}], secondmates: [.secondmate_current.records[] | {id, current, parent_event: (.parent_event | {emitted_at_epoch, age_seconds})}]}', evidence / 'event-time-snapshot.json'])
    drain = run([root / 'bin/fm-wake-drain.sh'], extra={
        'FM_CAPTAIN_RE': 'done:|needs-decision:|blocked:|failed:', 'FM_ROOT_OVERRIDE': str(scratch)}, output='event-time-drain.txt')
    assert 'choose the release branch' in drain
    assert local.read_text() == line
    for task, raw in records.items():
        assert (parent / 'state' / (task + '.status')).read_text() == raw
    # Run the generated append command for each supported scaffold, after generation.
    for kind, flags in [('ship', ['firstmate', '--mode', 'no-mistakes']), ('scout', ['firstmate', '--scout']), ('secondmate', ['--secondmate', '--no-projects'])]:
        task = 'brief-' + kind
        run([root / 'bin/fm-brief.sh', task, *flags])
        generated = (parent / 'data' / task / 'brief.md').read_text()
        append = re.search(r'`(echo "\{state\}[^`]+)`', generated)[1]
        append = append.replace('{state}', 'done').replace('{one short line}', 'generated command executed')
        time.sleep(1.1)
        start = int(time.time())
        run(['/bin/bash', '-c', append])
        end = int(time.time())
        actual = (parent / 'state' / (task + '.status')).read_text()
        epoch = int(re.search(r'\[at=(\d+)\]', actual)[1])
        assert start <= epoch <= end
        note(actual.rstrip())
    # Transport source bytes through the real delta reader and mirror consumer.
    source = remote / 'state/parent-replies.status'
    source.write_text('needs-decision [at=1700000000]: which base branch?\ndone: historical audit\n')
    first = run([root / 'bin/fm-remote-delta-read.sh', 'state/parent-replies.status', 0, hashlib.sha256(b'').hexdigest(), 0], home=remote, output='remote-first.delta')
    run([root / 'bin/fm-procevent-remote-reply.sh', 'ingest', 'remote-mate', evidence / 'remote-first.delta'])
    mirror = parent / 'state/remote-mate.status'
    assert mirror.read_bytes() == source.read_bytes()
    previous = source.read_bytes()
    source.write_bytes(previous + b'needs-decision [at=1700086400]: which base branch?\n')
    run([root / 'bin/fm-remote-delta-read.sh', 'state/parent-replies.status', len(previous), hashlib.sha256(previous).hexdigest(), 0], home=remote, output='remote-second.delta')
    run([root / 'bin/fm-procevent-remote-reply.sh', 'ingest', 'remote-mate', evidence / 'remote-second.delta'])
    retry = run([root / 'bin/fm-procevent-remote-reply.sh', 'ingest', 'remote-mate', evidence / 'remote-second.delta'])
    assert 'appended=0' in retry
    assert mirror.read_bytes() == source.read_bytes()
    shutil.copyfile(mirror, evidence / 'remote-mirrored.status')
    shutil.copyfile(parent / 'state/remote-replies/remote-mate.cursor', evidence / 'remote-mirror.cursor')
    run(['cat', mirror])
    meta('remote-mate')
    remote_snapshot = json.loads(run([root / 'bin/fm-fleet-snapshot.sh', '--json'], extra={'FM_SNAPSHOT_NOW_EPOCH': '1700086500'}, output='remote-snapshot.json'))
    event = next(x for x in remote_snapshot['tasks'] if x['id'] == 'remote-mate')['paths']['status_log']['last_event']
    assert event['emitted_at_epoch'] == 1700086400 and event['age_seconds'] == 100
    note(json.dumps(event, indent=2))
    # Reproduce the fixed malformed-tag failure against the immediately prior revision.
    before = subprocess.check_output(['git', 'show', '8bdc586cb530ebe0947636e7d5df66fb96a47743^:bin/fm-classify-lib.sh'], text=True)
    old_lib = scratch / 'classify-before.sh'
    old_lib.write_text(before)
    (scratch / 'fm-timeout-lib.sh').symlink_to(root / 'bin/fm-timeout-lib.sh')
    check = '. "$1"; FM_CAPTAIN_RE="done:|needs-decision:|blocked:|failed:"; status_span_first_actionable "$2" 0'
    run(['/bin/bash', '-c', check, '_', old_lib, parent / 'state/malformed.status'], expect=1)
    fixed = run(['/bin/bash', '-c', check, '_', root / 'bin/fm-classify-lib.sh', parent / 'state/malformed.status'])
    assert fixed == records['malformed'].rstrip('\n')
    note('\nVerified: append-time stamping, mtime-independent ages, unknown legacy/malformed/duplicate age, future-time preservation, unchanged current-state fallback, actionable malformed tags, byte-preserving relay, distinct repeated events, and quiet replay.')
    print('CLI verification completed; transcript and persisted output saved in the evidence directory.')
finally:
    transcript.close()
    shutil.rmtree(scratch)
