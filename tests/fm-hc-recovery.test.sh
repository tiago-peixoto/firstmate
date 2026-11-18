#!/usr/bin/env bash
# Recovery contracts through public helpers with an isolated hc protocol fixture.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"
T=$(mktemp -d)
trap 'fm_test_remove_tree "$T"' EXIT
export FM_HOME="$T/home" FM_ROOT="$T/home" STATE="$T/home/state" FAKE_HC_DIR="$T"
export FM_HC_BIN="$T/hc" HC_SESSION=wrong-session
mkdir -p "$STATE" "$FM_ROOT/bin"
cat > "$FM_HC_BIN" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$HC_SESSION" "$*" >> "$FAKE_HC_DIR/log"
case "$1" in
 get)
  [ ! -f "$FAKE_HC_DIR/error" ] || exit 4
  [ -f "$FAKE_HC_DIR/terminal" ] || exit 3
  cat "$FAKE_HC_DIR/terminal" ;;
 kill) : ;;
 rm) [ -f "$FAKE_HC_DIR/retain" ] || rm -f "$FAKE_HC_DIR/terminal" ;;
 *) exit 9 ;;
esac
SH
cat > "$FM_ROOT/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$HC_SESSION" "$*" >> "$FAKE_HC_DIR/spawn"
SH
chmod +x "$FM_HC_BIN" "$FM_ROOT/bin/fm-spawn.sh"
fm_backend_source hc
META="$STATE/scout.meta"
reset_fixture() {
  rm -f "$T/terminal" "$T/error" "$T/retain" "$T/log" "$T/spawn"
  cat > "$META" <<META
backend=hc
window=recorded:t9
hc_session=recorded
hc_terminal=t9
endpoint_task_id=scout
worktree=$T/child
project=$T/project
harness=claude
kind=secondmate
META
}
terminal() {
  jq -n --arg state "$1" --arg name "${2:-bash}" --arg task "${3:-fm-scout}" \
    --arg home "${4:-$(fm_backend_hometag)}" \
    '{state:$state,labels:{"firstmate.task":$task,"firstmate.home":$home},foreground:{name:$name,argv:[$name]}}' > "$T/terminal"
}
verdict() {
  local out
  out=$(fm_control_endpoint_absence_verdict hc recorded:t9 "$META")
  printf '%s' "${out%%$'\t'*}"
}
test_capabilities() {
  fm_control_backend_state_verified hc || fail 'hc must support verified recovery'
  fm_control_backend_relaunch_supported hc || fail 'hc must support relaunch'
  fm_control_absence_recheck_applies hc unreadable && fail 'unreachable hc must not authorize recovery'
  pass 'hc recovery capabilities'
}
test_absence() {
  reset_fixture
  assert_equals "$(verdict)" gone 'structured absence'
  terminal finished
  assert_equals "$(verdict)" gone 'owned finished terminal'
  terminal live bash
  assert_equals "$(verdict)" dead 'existing shell'
  terminal live claude
  assert_equals "$(verdict)" alive 'existing agent'
  terminal finished bash fm-other
  assert_equals "$(verdict)" unproven 'foreign task'
  terminal finished bash fm-scout foreign-home
  assert_equals "$(verdict)" unproven 'foreign home'
  terminal live sleep
  assert_equals "$(verdict)" unproven 'unknown foreground process'
  touch "$T/error"
  assert_equals "$(verdict)" unproven 'transport failure'
  reset_fixture
  printf 'hc_session=other\n' >> "$META"
  assert_equals "$(verdict)" unproven 'ambiguous routing'
  pass 'hc absence proof preserves identity and refuses uncertainty'
}
test_local_recovery() {
  local state
  for state in live finished absent; do
    reset_fixture
    [ "$state" = absent ] || terminal "$state"
    fm_secondmate_liveness_probe "$META" scout poll
    assert_equals "$FM_SM_LIVE_STATUS" relaunchable "$state recovery"
    assert_equals "$FM_SM_LIVE_KILL" 1 "$state requires proven close"
    fm_secondmate_liveness_relaunch "$META" scout 5 || fail "$state relaunch failed: $FM_SM_LIVE_REASON"
    assert_equals "$(cat "$T/spawn")" 'recorded scout --secondmate --backend hc' 'no session or backend migration'
    [ ! -f "$T/terminal" ] || fail 'old endpoint survived'
  done
  pass 'hc recovery closes old endpoint and pins replacement session'
}
test_refusals() {
  reset_fixture
  terminal finished bash fm-other
  fm_secondmate_liveness_probe "$META" scout poll
  assert_equals "$FM_SM_LIVE_STATUS" skipped 'foreign endpoint must be preserved'
  reset_fixture
  terminal live
  fm_secondmate_liveness_probe "$META" scout poll
  touch "$T/retain"
  fm_secondmate_liveness_relaunch "$META" scout 5 && fail 'unproven close accepted'
  [ ! -f "$T/spawn" ] || fail 'spawn after failed close'
  reset_fixture
  terminal live
  fm_secondmate_liveness_probe "$META" scout poll
  terminal live claude
  fm_secondmate_liveness_relaunch "$META" scout 5 && fail 'revived agent accepted'
  [ ! -f "$T/spawn" ] || fail 'spawn beside revived agent'
  if grep -Eq ' (kill|rm) ' "$T/log"; then fail 'revived agent mutated'; fi
  pass 'hc recovery refuses foreign, retained, and revived endpoints'
}
test_remote_route() {
  reset_fixture
  printf 'remote_host=fixture\nremote_backend=hc\n' >> "$META"
  mkdir -p "$T/remote-bin"
  cat > "$T/remote-bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
case "$3" in state) echo alive ;; route) cat "$FAKE_HC_DIR/route" ;; *) exit 9 ;; esac
SH
  chmod +x "$T/remote-bin/fm-on.sh"
  # shellcheck disable=SC2034 # The sourced liveness helper reads this route.
  local FM_SM_LIVE_LIB_DIR="$T/remote-bin"
  # shellcheck disable=SC2329 # The sourced liveness probe invokes this replacement.
  fm_remote_readiness_ensure() { return 0; }
  printf 'backend=hc\n' > "$T/route"
  fm_secondmate_liveness_probe "$META" scout full
  assert_equals "$FM_SM_LIVE_STATUS" alive 'recorded remote hc route'
  printf 'backend=herdr\n' > "$T/route"
  fm_secondmate_liveness_probe "$META" scout full
  assert_equals "$FM_SM_LIVE_STATUS" skipped 'remote drift must not migrate'
  pass 'remote hc accepted only when recorded route matches'
}
test_public_worker_relaunch() { (
  # shellcheck source=tests/fixtures.sh
  . "$ROOT/tests/fixtures.sh"
  local dir="$T/public" mode id meta out tag kind task_tmp sockdir sockpid space attempt
  local -a task_tmps=()
  trap 'for task_tmp in "${task_tmps[@]}"; do fm_test_remove_tree "$task_tmp"; done' EXIT
  mkdir -p "$dir/bin" "$dir/user"
  export HOME="$dir/user" XDG_CONFIG_HOME="$dir/config" XDG_DATA_HOME="$dir/data"
  export FM_ROOT="$ROOT" FM_ROOT_OVERRIDE="$ROOT" FM_HC_BIN="$dir/bin/hc"
  unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  export FM_BACKEND=hc HC_SESSION=ambient-wrong FM_SPAWN_NO_GUARD=1
  fm_fake_exit0 "$dir/bin" codex
  export PATH="$dir/bin:$PATH"
  cat > "$FM_HC_BIN" <<'HC'
#!/usr/bin/env python3
import json, os, shlex, sys
from pathlib import Path
args = sys.argv[1:]
d = Path(os.environ['FAKE_HC_DIR'])
with (d / 'calls').open('a') as f:
    f.write(json.dumps([os.environ.get('HC_SESSION'), args]) + '\n')
cmd = args[0]
old = d / 'old.json'
new = d / 'new.json'
if cmd == '--version':
    print('hc 0.1.14')
elif cmd == 'server':
    if (d / 'revive').exists():
        t = json.loads(old.read_text())
        t['state'] = 'live'
        t['foreground'] = {'name': 'codex', 'argv': ['codex']}
        old.write_text(json.dumps(t))
    print('{}')
elif cmd == 'connect':
    print('{"result":{"generation":1}}')
elif cmd == 'get':
    path = d / 'own.json' if 'own' in args else old if args[-1] == 't9' else new
    if not path.exists(): sys.exit(3)
    print(path.read_text())
elif cmd == 'kill':
    path = old if args[-1] == 't9' else new
    t = json.loads(path.read_text())
    t['state'] = 'finished'
    path.write_text(json.dumps(t))
    print('{}')
elif cmd == 'rm':
    path = old if args[-1] == 't9' else new
    if not (d / 'retain').exists(): path.unlink(missing_ok=True)
    print('{}')
elif cmd == 'ls':
    print('{"terminals":[]}')
elif cmd == 'run':
    labels = dict(args[i+1].split('=', 1) for i, x in enumerate(args) if x == '--label')
    cwd = args[args.index('--cwd')+1]
    t = dict(address='t10', state='live', labels=labels, cwd=cwd,
             foreground=dict(name='bash', argv=['bash'], cwd=cwd))
    new.write_text(json.dumps(t))
    print(json.dumps(t))
elif cmd == 'read':
    print('❯')
elif cmd in ('send', 'keys'):
    if (d / 'send-fail').exists(): sys.exit(1)
    if cmd == 'send' and args[-1].startswith(". '"):
        if (d / 'late-fail').exists(): sys.exit(1)
        (d / 'launch').write_text(Path(shlex.split(args[-1])[1]).read_text())
    print('{"started":true}')
else:
    sys.exit('unexpected hc mutation: ' + repr(args))
HC
  chmod +x "$FM_HC_BIN"
  # The finished case also opts into config/hc-own-space from a readable own
  # terminal. AF_UNIX paths cap near 104 bytes, hence the short /tmp dir.
  sockdir=$(mktemp -d /tmp/fm-hcr.XXXXXX)
  python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5); time.sleep(300)' \
    "$sockdir/core.sock" >/dev/null 2>&1 &
  sockpid=$!
  for mode in absent finished scout-absent scout-finished retained revived foreign send-fail late-fail; do
    id="hc-rebind-$mode-$$"
    task_tmps+=("/tmp/fm-$id")
    export FM_HOME="$dir/$mode/home" FAKE_HC_DIR="$dir/$mode/core"
    mkdir -p "$FAKE_HC_DIR"
    fm_test_spawn_home "$FM_HOME" codex
    fm_test_spawn_brief "$FM_HOME" "$id"
    fm_git_worktree "$dir/$mode/project" "$dir/$mode/worktree" "task-$id"
    printf 'unfinished work\n' > "$dir/$mode/worktree/keep.txt"
    kind=ship
    case "$mode" in scout-*) kind=scout ;; esac
    meta="$FM_HOME/state/$id.meta"
    cat > "$meta" <<META
backend=hc
window=recorded:t9
hc_session=recorded
hc_terminal=t9
endpoint_task_id=$id
worktree=$dir/$mode/worktree
project=$dir/$mode/project
harness=codex
kind=$kind
branch=task-$id
mode=no-mistakes
yolo=off
model=default
effort=default
META
    cp "$meta" "$FAKE_HC_DIR/before.meta"
    tag=$(fm_backend_hometag)
    if [ "$mode" != absent ] && [ "$mode" != scout-absent ]; then
      jq -n --arg home "$tag" --arg task "fm-$id" \
        '{state:"finished",labels:{"firstmate.home":$home,"firstmate.task":$task}}' > "$FAKE_HC_DIR/old.json"
    fi
    case "$mode" in
      late-fail) touch "$FAKE_HC_DIR/late-fail" ;;
      send-fail) touch "$FAKE_HC_DIR/send-fail" ;;
      retained) touch "$FAKE_HC_DIR/retain" ;;
      revived) touch "$FAKE_HC_DIR/revive" ;;
      foreign) sed 's/firstmate.home/foreign.home/' "$FAKE_HC_DIR/old.json" > "$FAKE_HC_DIR/x"; mv "$FAKE_HC_DIR/x" "$FAKE_HC_DIR/old.json" ;;
    esac
    out="$dir/$mode/output"
    unset FM_HC_SOCKET HC_TERMINAL_ID HC_TERMINAL_SOCKET
    if [ "$mode" = finished ]; then
      mkdir -p "$FM_HOME/config"
      : > "$FM_HOME/config/hc-own-space"
      printf '{"labels":{"herdr.space":"own-space"}}\n' > "$FAKE_HC_DIR/own.json"
      for ((attempt=0; attempt<100; attempt++)); do [ -S "$sockdir/core.sock" ] && break; sleep 0.05; done
      export FM_HC_SOCKET="$sockdir/core.sock" HC_TERMINAL_ID=own HC_TERMINAL_SOCKET="$sockdir/core.sock"
    fi
    if "$ROOT/bin/fm-spawn.sh" "$id" --relaunch > "$out" 2>&1; then
      case "$mode" in retained|revived|foreign|send-fail|late-fail) fail "$mode recovery accepted" ;; esac
    else
      case "$mode" in absent|finished|scout-absent|scout-finished) cat "$out"; fail "$mode public relaunch failed" ;; esac
    fi
    if [ "$mode" = absent ] || [ "$mode" = finished ] || [ "$kind" = scout ] || [ "$mode" = late-fail ]; then
      assert_grep 'window=recorded:t10' "$meta" 'replacement target not published'
      assert_grep 'hc_session=recorded' "$meta" 'recorded session changed'
      assert_grep 'hc_terminal=t10' "$meta" 'replacement address not published'
      assert_grep "worktree=$dir/$mode/worktree" "$meta" 'worktree changed'
      assert_grep 'unfinished work' "$dir/$mode/worktree/keep.txt" 'local work lost'
      assert_absent "$FAKE_HC_DIR/old.json" 'finished terminal retained'
      [ "$mode" = late-fail ] || [ -s "$FAKE_HC_DIR/launch" ] || fail 'replacement launch not delivered'
      jq -e --arg home "$tag" --arg task "fm-$id" --arg cwd "$dir/$mode/worktree" \
        '.labels["firstmate.home"]==$home and .labels["firstmate.task"]==$task and .cwd==$cwd' \
        "$FAKE_HC_DIR/new.json" >/dev/null || fail 'replacement ownership or cwd changed'
      space="fm-$tag"
      [ "$mode" != finished ] || space=own-space
      jq -e --arg space "$space" '.labels["herdr.space"]==$space' "$FAKE_HC_DIR/new.json" >/dev/null \
        || fail "$mode replacement must open in space $space"
    else
      cmp "$meta" "$FAKE_HC_DIR/before.meta" || fail 'refusal changed metadata'
      assert_absent "$FAKE_HC_DIR/new.json" 'unsafe replacement created'
    fi
    python3 - "$FAKE_HC_DIR/calls" "$mode" <<'CHECK'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert all(session == 'recorded' for session, args in calls if args[0] != '--version' and 'own' not in args), calls
runs = [args for _, args in calls if args[0] == 'run']
assert len(runs) == (0 if sys.argv[2] in ('retained', 'revived', 'foreign') else 1), calls
for args in runs:
    assert all(flag in args for flag in ('--no-parent', '--outlive-parent', '--no-notify')), args
if sys.argv[2] in ('revived', 'foreign'):
    assert not any(args[0] in ('kill', 'rm') for _, args in calls), calls
CHECK
  done
  kill "$sockpid" 2>/dev/null || true
  rm -rf "$sockdir"
  pass 'hc public ship/scout relaunch: missing/finished recovery, config/hc-own-space placement, and unsafe refusals and pre/post-publication failures'
) || exit 1; }

fm_test_run test_capabilities test_absence test_local_recovery test_refusals test_remote_route test_public_worker_relaunch
