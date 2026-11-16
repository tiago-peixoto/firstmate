#!/usr/bin/env bash
# Actual secondmate spawn with a recording core. No terminal commands execute.
set -eu
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-hc)
export HOME="$TMP_ROOT/user" XDG_CONFIG_HOME="$TMP_ROOT/xdg-config" XDG_DATA_HOME="$TMP_ROOT/xdg-data"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
FAKEBIN=$(make_fake_tmux "$TMP_ROOT/fake")
fm_fake_exit0 "$FAKEBIN" codex
export PATH="$FAKEBIN:$PATH" FM_HC_BIN="$FAKEBIN/hc" HC_SESSION=fleet-test
export FM_FAKE_TMUX_LOG="$TMP_ROOT/tmux.log" FM_SKIP_SECONDMATE_SYNC=1
cat > "$FM_HC_BIN" <<'PY'
#!/usr/bin/env python3
import json
import os
import shlex
import sys
from pathlib import Path
args = sys.argv[1:]
store = Path(os.environ['FM_FAKE_HC_DIR'])
with (store / 'calls.jsonl').open('a') as log:
    log.write(json.dumps(args) + '\n')
cmd = args[0]
if cmd == '--version':
    print('hc 0.1.14')
elif cmd == 'server':
    print('{}')
elif cmd == 'connect':
    print('{"result":{"generation":1}}')
elif cmd == 'ls':
    print('{"terminals":[]}')
elif cmd == 'run':
    labels = dict(args[i + 1].split('=', 1) for i, arg in enumerate(args) if arg == '--label')
    cwd = args[args.index('--cwd') + 1]
    terminal = dict(address='t1', state='live', labels=labels, cwd=cwd,
                    foreground=dict(name='codex', argv=['codex'], cwd=cwd))
    (store / 'terminal.json').write_text(json.dumps(terminal))
    print(json.dumps(terminal))
elif cmd == 'get':
    if not (store / 'terminal.json').exists():
        sys.exit(3)
    print((store / 'terminal.json').read_text())
elif cmd == 'read':
    print('❯')
elif cmd in ('send', 'keys'):
    if cmd == 'send' and args[-1].startswith(". '"):
        (store / 'launch.sh').write_text(Path(shlex.split(args[-1])[1]).read_text())
    print('{"started":true}')
else:
    sys.exit('unexpected hc call: ' + repr(args))
PY
chmod +x "$FM_HC_BIN"

setup_world() {
  local name=$1
  PRIMARY="$TMP_ROOT/$name/parent home"
  CHILD="$TMP_ROOT/$name/child home"
  fm_test_spawn_home "$PRIMARY" codex
  fm_test_spawn_home "$CHILD" codex
  seed_secondmate_home_marker "$CHILD" design
  fm_git_init_commit "$CHILD"
  scaffold_secondmate_charter "$PRIMARY" design 'Own the design fleet' --no-projects || fail 'brief scaffold failed'
  printf 'Own the design fleet\n' > "$CHILD/data/charter.md"
  printf -- '- design - design fleet (home: %s; scope: design; projects: ; added 2026-11-15)\n' "$CHILD" > "$PRIMARY/data/secondmates.md"
  export FM_FAKE_HC_DIR="$TMP_ROOT/$name/core"
  mkdir -p "$FM_FAKE_HC_DIR"
  : > "$FM_FAKE_HC_DIR/calls.jsonl"
}

spawn() {
  FM_HOME="$PRIMARY" FM_BACKEND=hc FM_HC_SPACE=parent-custom \
    "$ROOT/bin/fm-spawn.sh" design "$CHILD" codex --secondmate
}

assert_line() {
  grep -Fx -- "$1" "$2" >/dev/null || fail "$3"
}

# The runtime the child's own workers select under the delivered launch line.
child_backend() {
  local launched
  launched=$(grep -o 'FM_BACKEND=[a-z]*' "$FM_FAKE_HC_DIR/launch.sh" || true)
  # shellcheck disable=SC2016 # Expanded by the child shell.
  env -u FM_BACKEND -u HC_SESSION -u HERDR_ENV ${launched:+"$launched"} FM_HOME="$CHILD" \
    bash -c '. "$1/bin/fm-backend.sh" && fm_backend_name' _ "$ROOT"
}

setup_world success
spawn > "$TMP_ROOT/spawn.out" 2>&1 || { cat "$TMP_ROOT/spawn.out"; fail 'hc secondmate spawn failed'; }
meta="$PRIMARY/state/design.meta"
assert_line 'kind=secondmate' "$meta" 'secondmate kind missing'
assert_line 'projects=' "$meta" 'project-less scope missing'
assert_line 'backend=hc' "$meta" 'hc backend missing'
assert_line "home=$CHILD" "$meta" 'child home missing'
assert_line 'hc_session=fleet-test' "$meta" 'session missing'
assert_line 'hc_terminal=t1' "$meta" 'terminal missing'
assert_line 'window=fleet-test:t1' "$meta" 'routing endpoint missing'
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"
parent_tag=$(FM_HOME="$PRIMARY" FM_ROOT="$ROOT" fm_backend_hometag)
child_tag=$(FM_HOME="$CHILD" FM_ROOT="$CHILD" fm_backend_hometag)
jq -e --arg parent "$parent_tag" --arg child "$child_tag" --arg cwd "$CHILD" '
  .labels["firstmate.home"] == $parent and
  .labels["firstmate.task"] == "fm-design" and
  .labels["herdr.space"] == ("fm-" + $child) and
  .labels["herdr.tab"] == ($parent + "-fm-design") and .cwd == $cwd
' "$FM_FAKE_HC_DIR/terminal.json" >/dev/null || fail 'placement transferred parent ownership or used parent space'
assert_line 'hc' "$CHILD/state/fleet-backend" 'child runtime not persisted'
assert_grep 'FM_BACKEND=hc' "$FM_FAKE_HC_DIR/launch.sh" 'child launch lost runtime'
assert_grep "FM_HOME='$CHILD'" "$FM_FAKE_HC_DIR/launch.sh" 'child launch lost home'
assert_grep "$CHILD/data/charter.md" "$FM_FAKE_HC_DIR/launch.sh" 'child launch lost charter'
pass 'hc secondmate: metadata, child placement, parent ownership, runtime persistence and launch'

setup_world conflict
printf 'tmux\n' > "$CHILD/config/backend"
if spawn > "$TMP_ROOT/conflict.out" 2>&1; then
  fail 'spawn accepted conflicting child backend'
fi
assert_grep 'refusing runtime change' "$TMP_ROOT/conflict.out" 'missing conflict diagnosis'
assert_line 'tmux' "$CHILD/config/backend" 'conflicting child configuration overwritten'
assert_absent "$PRIMARY/state/design.meta" 'conflict published task metadata'
assert_absent "$FM_FAKE_HC_DIR/terminal.json" 'conflict created terminal'
assert_absent "$CHILD/state/fleet-backend" 'conflict pinned child runtime'
assert_absent "$PRIMARY/state/fleet-backend" 'refused creation pinned the primary runtime'
pass 'hc secondmate: child runtime conflict refuses before terminal creation'

setup_world pinned-conflict
printf 'herdr\n' > "$CHILD/state/fleet-backend"
if spawn > "$TMP_ROOT/pinned-conflict.out" 2>&1; then
  fail 'spawn accepted conflicting persisted child runtime'
fi
assert_grep 'refusing runtime change' "$TMP_ROOT/pinned-conflict.out" 'missing persisted conflict diagnosis'
assert_line 'herdr' "$CHILD/state/fleet-backend" 'persisted child runtime overwritten'
assert_absent "$PRIMARY/state/design.meta" 'persisted conflict published task metadata'
assert_absent "$FM_FAKE_HC_DIR/terminal.json" 'persisted conflict created terminal'
pass 'hc secondmate: persisted child runtime conflict refuses before terminal creation'

setup_world recovery
spawn > "$TMP_ROOT/recovery-first.out" 2>&1 || { cat "$TMP_ROOT/recovery-first.out"; fail 'hc secondmate spawn before recovery failed'; }
rm -f "$PRIMARY/state/fleet-backend" "$CHILD/state/fleet-backend" "$FM_FAKE_HC_DIR/terminal.json"
printf 'window=firstmate:fm-w1\nkind=ship\n' > "$PRIMARY/state/w1.meta"
cp "$PRIMARY/state/design.meta" "$TMP_ROOT/recovery-before.meta"
FM_HOME="$PRIMARY" "$ROOT/bin/fm-spawn.sh" design "$CHILD" codex --secondmate --backend hc \
  > "$TMP_ROOT/recovery.out" 2>&1 || { cat "$TMP_ROOT/recovery.out"; fail 'legacy recovery on the recorded runtime was refused'; }
assert_absent "$PRIMARY/state/fleet-backend" 'recovery selected the primary fleet runtime'
assert_absent "$CHILD/state/fleet-backend" 'recovery selected the child fleet runtime'
assert_line 'backend=hc' "$PRIMARY/state/design.meta" 'recovery changed the recorded runtime'
pass 'hc secondmate: recovery in an unbound home keeps the recorded runtime and records no fleet choice'

setup_world bound-recovery
spawn > "$TMP_ROOT/bound-recovery-first.out" 2>&1 || { cat "$TMP_ROOT/bound-recovery-first.out"; fail 'hc secondmate spawn before bound recovery failed'; }
assert_line 'hc' "$PRIMARY/state/fleet-backend" 'creation did not bind the primary'
rm -f "$CHILD/state/fleet-backend" "$FM_FAKE_HC_DIR/terminal.json" "$FM_FAKE_HC_DIR/launch.sh"
printf 'window=firstmate:fm-w1\nkind=ship\n' > "$CHILD/state/w1.meta"
FM_HOME="$PRIMARY" "$ROOT/bin/fm-spawn.sh" design "$CHILD" codex --secondmate --backend hc \
  > "$TMP_ROOT/bound-recovery.out" 2>&1 || { cat "$TMP_ROOT/bound-recovery.out"; fail 'legacy child recovery under a bound primary was refused'; }
assert_absent "$CHILD/state/fleet-backend" 'recovery under a bound primary pinned the legacy child'
assert_line 'backend=hc' "$PRIMARY/state/design.meta" 'bound recovery changed the recorded runtime'
[ "$(child_backend)" = tmux ] || fail 'recovery launch overrode the legacy child runtime'
pass 'hc secondmate: legacy child recovery under a bound primary records no child fleet choice'

setup_world unbound-classic
printf 'tmux\n' > "$PRIMARY/config/backend"
FM_HOME="$PRIMARY" "$ROOT/bin/fm-spawn.sh" design "$CHILD" codex --secondmate --backend hc \
  > "$TMP_ROOT/unbound-classic.out" 2>&1 || { cat "$TMP_ROOT/unbound-classic.out"; fail 'unbound hc secondmate spawn failed'; }
assert_absent "$PRIMARY/state/fleet-backend" 'unbound spawn pinned the primary'
assert_absent "$CHILD/state/fleet-backend" 'unbound spawn pinned the child'
printf 'tmux\n' > "$CHILD/config/backend"
[ "$(child_backend)" = tmux ] || fail 'unbound child lost its configured runtime'
setup_world managed-child
spawn > "$TMP_ROOT/managed-child.out" 2>&1 || { cat "$TMP_ROOT/managed-child.out"; fail 'managed hc secondmate spawn failed'; }
[ "$(child_backend)" = hc ] || fail 'managed child did not keep the fleet runtime'
pass 'hc secondmate: unbound children keep their configured runtime and managed children keep hc'

for selection in config detected; do
  setup_world "primary-selection-$selection"
  selection_env=()
  if [ "$selection" = config ]; then
    printf 'herdr\n' > "$PRIMARY/config/backend"
  else
    selection_env=(HERDR_ENV=1)
  fi
  if env "${selection_env[@]}" FM_HOME="$PRIMARY" "$ROOT/bin/fm-spawn.sh" design "$CHILD" codex --secondmate --backend hc \
    > "$TMP_ROOT/primary-selection.out" 2>&1; then
    fail "a secondmate flag redefined the $selection primary runtime"
  fi
  assert_grep 'refusing' "$TMP_ROOT/primary-selection.out" "missing $selection primary selection diagnosis"
  assert_absent "$PRIMARY/state/fleet-backend" "child flag pinned the $selection primary"
  assert_absent "$CHILD/state/fleet-backend" "child flag pinned the $selection child"
  assert_absent "$PRIMARY/state/design.meta" "$selection primary selection conflict published task metadata"
  assert_absent "$FM_FAKE_HC_DIR/terminal.json" "$selection primary selection conflict created terminal"
done
pass 'hc secondmate: configured and detected primary selections win over a conflicting secondmate flag'
