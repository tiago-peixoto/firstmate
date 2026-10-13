#!/usr/bin/env bash
# tests/fm-control-herdr-relaunch-space-e2e.test.sh - real-Herdr regression for
# where `fm-control relaunch` re-creates a worker whose pane was closed.
#
# A second mate runs fm-control from its own Herdr pane, so its launcher
# workspace is "2ndmate-<id>". The relaunched worker must get its own
# presentation space under that workspace, exactly as a fresh spawn does, and
# never a tab inside the second mate's own workspace.
# tests/fm-control-relaunch.test.sh pins the same placement portably against a
# stand-in Herdr; this proves it against the real binary.
#
# The worker harness is an inert stand-in named opencode. It registers itself
# with Herdr the way a real integration does, then idles as an agent-named
# process. It reaches the worker's pane only through the lab server's PATH, so
# the test skips when a shell startup file would put another opencode ahead of
# it rather than risk launching a real agent.
#
# The lab's fleet-state tripwire needs exactly one running default Herdr
# session, so the test skips where there is none. Every Herdr call, including
# the ones the code under test makes, goes through bin/fm-herdr-lab.sh.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v treehouse >/dev/null 2>&1 || { echo "skip: treehouse not found (required by fm-spawn.sh)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-relaunch-space) \
  || fail "could not generate an isolated Herdr lab session name"
fm_herdr_lab_session_list "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || fail "could not read the Herdr session list"
fm_herdr_lab_fleet_state "$HERDR_LAB_SESSION" >/dev/null 2>&1 \
  || { echo "skip: no running default Herdr session for the lab's fleet-state tripwire"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-control-herdr-relaunch-space.XXXXXX")
WRAPBIN="$TMP_ROOT/wrapbin"
HARNESSBIN="$TMP_ROOT/harnessbin"
SM_ID=rsmate
SM_HOME="$TMP_ROOT/secondmate-home"
TASK="rspace$$"
PROJ="$TMP_ROOT/scratch-project"
export TREEHOUSE_ROOT="$TMP_ROOT/pool"
LAB_PROVISIONED=0

meta() { grep "^$1=" "$SM_HOME/state/$TASK.meta" 2>/dev/null | tail -1 | cut -d= -f2-; }

cleanup_all() {
  local status=$? wt
  wt=$(meta worktree)
  [ -z "$wt" ] || treehouse return --force "$wt" >/dev/null 2>&1
  if [ "$LAB_PROVISIONED" = 1 ]; then
    PATH=$HERDR_ORIGINAL_PATH "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || {
      printf 'not ok - isolated Herdr lab teardown failed or the default fleet session changed\n' >&2
      status=1
    }
  fi
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  chmod -R u+rwx "$TMP_ROOT" "/tmp/fm-$TASK" "/tmp/fm-$TASK+"* 2>/dev/null
  rm -rf "$TMP_ROOT" "/tmp/fm-$TASK" "/tmp/fm-$TASK+"*
  exit "$status"
}
trap cleanup_all EXIT

mkdir -p "$WRAPBIN" "$HARNESSBIN"
cat > "$WRAPBIN/herdr" <<SH
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[n-2]}" = --session ] && [ "\${args[n-1]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[n-1]" "args[n-2]"
fi
set -- "\${args[@]}"
if [ "\${1:-}" = --version ]; then
  exec env PATH="$HERDR_ORIGINAL_PATH" herdr --version
fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\$@"
SH
chmod +x "$WRAPBIN/herdr"
# The agent-named process is bash rather than sleep: a multi-call coreutils
# build dispatches on the name it was run as and refuses a renamed sleep.
BASH_BIN=$(command -v bash) || fail "bash not found"
ln -s "$BASH_BIN" "$HARNESSBIN/opencode-agent"
cat > "$HARNESSBIN/opencode" <<SH
#!/usr/bin/env bash
env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane report-agent "\$HERDR_PANE_ID" \\
  --source fm-relaunch-space-e2e --agent opencode --state idle >/dev/null 2>&1
exec "$HARNESSBIN/opencode-agent" -c 'sleep 86400; :'
SH
chmod +x "$HARNESSBIN/opencode"

PATH="$HARNESSBIN:$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not provision isolated Herdr lab session"
LAB_PROVISIONED=1

lab() { PATH=$HERDR_ORIGINAL_PATH "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

workspace_of_pane() {  # <pane_id>
  lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty' 2>/dev/null
}

label_of_workspace() {  # <workspace_id>
  lab workspace list 2>/dev/null \
    | jq -r --arg id "$1" '.result.workspaces[]? | select(.workspace_id == $id) | .label' 2>/dev/null
}

tab_labels_of_workspace() {  # <workspace_id>
  lab tab list --workspace "$1" 2>/dev/null \
    | jq -r '[.result.tabs[]?.label] | sort | join(",")' 2>/dev/null
}

focused_workspace() {
  lab workspace list 2>/dev/null \
    | jq -r '[.result.workspaces[]? | select(.focused == true) | .workspace_id][0] // empty' 2>/dev/null
}

workspace_offset() {  # <from_workspace_id> <to_workspace_id>
  lab workspace list 2>/dev/null | jq -r --arg from "$1" --arg to "$2" '
    [range(0; (.result.workspaces | length)) as $i | {i: $i, id: .result.workspaces[$i].workspace_id}]
    | ((map(select(.id == $to)) | .[0].i) - (map(select(.id == $from)) | .[0].i))' 2>/dev/null
}

journal_field() {  # <key>
  grep "^$1=" "$SM_HOME/state/$TASK.herdr-presentation" 2>/dev/null | head -1 | cut -d= -f2-
}

wait_agent_idle() {  # <pane_id>
  for _ in $(seq 1 100); do
    [ "$(lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null)" != idle ] || return 0
    sleep 0.2
  done
  return 1
}

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$HERDR_LAB_SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

# --- scratch world ----------------------------------------------------------

mkdir -p "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects" "$SM_HOME/bin" "$SM_HOME/data/$TASK"
printf 'on\n' > "$SM_HOME/config/herdr-presentation-spaces"
printf '# scratch secondmate home AGENTS.md placeholder\n' > "$SM_HOME/AGENTS.md"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
printf 'trivial e2e secondmate charter: nothing to do.\n' > "$SM_HOME/data/charter.md"
cat > "$SM_HOME/data/$TASK/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise where a relaunched worker is placed.

## Firstmate spec
Nothing to build.
EOF

mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"
git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

# The second mate's own workspace and the pane its agent runs in, then an
# unrelated workspace that stays focused as whatever the captain is viewing.
SM_WS_OUT=$(lab workspace create --cwd "$SM_HOME" --label "2ndmate-$SM_ID" --no-focus 2>/dev/null)
SM_WS=$(printf '%s' "$SM_WS_OUT" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
SM_PANE=$(printf '%s' "$SM_WS_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
[ -n "$SM_WS" ] && [ -n "$SM_PANE" ] || fail "could not create the second mate's workspace"
CAP_OUT=$(lab workspace create --cwd "$TMP_ROOT" --label captain-view --no-focus 2>/dev/null)
CAP_WS=$(printf '%s' "$CAP_OUT" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
CAP_TAB=$(printf '%s' "$CAP_OUT" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
CAP_PANE=$(printf '%s' "$CAP_OUT" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
[ -n "$CAP_WS" ] && [ -n "$CAP_TAB" ] && [ -n "$CAP_PANE" ] || fail "could not create the captain's workspace"
lab tab focus "$CAP_TAB" >/dev/null 2>&1 || fail "could not focus the captain's workspace"

cat > "$TMP_ROOT/probe.sh" <<SH
#!/bin/sh
command -v opencode > "$TMP_ROOT/probe.tmp" 2>/dev/null
mv "$TMP_ROOT/probe.tmp" "$TMP_ROOT/probe.out"
SH
chmod +x "$TMP_ROOT/probe.sh"
lab pane run "$CAP_PANE" "$TMP_ROOT/probe.sh" >/dev/null 2>&1 || fail "could not run the PATH probe in a lab pane"
for _ in $(seq 1 100); do
  [ ! -f "$TMP_ROOT/probe.out" ] || break
  sleep 0.2
done
[ -f "$TMP_ROOT/probe.out" ] || fail "the PATH probe never finished in a lab pane"
PROBED=$(cat "$TMP_ROOT/probe.out")
[ "$PROBED" = "$HARNESSBIN/opencode" ] || {
  echo "skip: a new Herdr pane resolves opencode to '${PROBED:-nothing}' instead of the inert stand-in"
  exit 0
}

as_secondmate() {
  env PATH="$WRAPBIN:$HARNESSBIN:$HERDR_ORIGINAL_PATH" HERDR_ENV=1 HERDR_PANE_ID="$SM_PANE" \
    HERDR_SESSION="$HERDR_LAB_SESSION" HERDR_SOCKET_PATH="$LAB_SOCKET" \
    FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 "$@"
}

# --- the worker is spawned into its own space, then its pane is closed ------

as_secondmate "$ROOT/bin/fm-spawn.sh" "$TASK" "$PROJ" opencode --mode direct-PR --yolo off --backend herdr \
  > "$TMP_ROOT/spawn.out" 2> "$TMP_ROOT/spawn.err" \
  || fail "the second mate's spawn failed"$'\n'"$(cat "$TMP_ROOT/spawn.err")"
FRESH_PANE=$(meta herdr_pane_id)
[ -n "$FRESH_PANE" ] || fail "the spawn recorded no Herdr pane"
wait_agent_idle "$FRESH_PANE" || fail "the stand-in harness never registered on the spawned worker's pane"
FRESH_WS=$(workspace_of_pane "$FRESH_PANE")
case "$(label_of_workspace "$FRESH_WS")" in
  "└ $TASK · p:"*) : ;;
  *) fail "the fresh spawn did not get its own presentation space: '$(label_of_workspace "$FRESH_WS")'" ;;
esac

SM_TABS_BEFORE=$(tab_labels_of_workspace "$SM_WS")
lab pane close "$FRESH_PANE" >/dev/null 2>&1 || fail "could not close the worker's pane"
for _ in $(seq 1 50); do
  [ -n "$(label_of_workspace "$FRESH_WS")" ] || break
  sleep 0.2
done
[ -z "$(label_of_workspace "$FRESH_WS")" ] \
  || fail "Herdr kept the emptied presentation space after its only pane closed"
lab tab focus "$CAP_TAB" >/dev/null 2>&1 || fail "could not refocus the captain's workspace"

# --- the second mate relaunches it from its own pane ------------------------

as_secondmate "$ROOT/bin/fm-control.sh" "$TASK" relaunch --note "relaunch after the pane was closed" \
  > "$TMP_ROOT/relaunch.out" 2> "$TMP_ROOT/relaunch.err" \
  || fail "the relaunch failed"$'\n'"$(cat "$TMP_ROOT/relaunch.out" "$TMP_ROOT/relaunch.err")"
NEW_PANE=$(meta herdr_pane_id)
[ -n "$NEW_PANE" ] && [ "$NEW_PANE" != "$FRESH_PANE" ] || fail "the relaunch did not record a new Herdr pane"
NEW_WS=$(workspace_of_pane "$NEW_PANE")
[ -n "$NEW_WS" ] || fail "could not read the relaunched worker's workspace"
[ "$NEW_WS" != "$SM_WS" ] || fail "the relaunched worker landed in the second mate's own workspace"
case "$(label_of_workspace "$NEW_WS")" in
  "└ $TASK · p:"*) : ;;
  *) fail "the relaunched worker is not in its own presentation space: '$(label_of_workspace "$NEW_WS")'" ;;
esac
[ "$(workspace_offset "$SM_WS" "$NEW_WS")" = 1 ] \
  || fail "the relaunched worker's space should sit immediately after the second mate's workspace"
[ "$(tab_labels_of_workspace "$SM_WS")" = "$SM_TABS_BEFORE" ] \
  || fail "the second mate's own workspace gained or lost tabs"
[ "$(meta herdr_workspace_id)" = "$NEW_WS" ] || fail "the record does not name the relaunched worker's workspace"
[ "$(journal_field version)" = 2 ] && [ "$(journal_field pane_id)" = "$NEW_PANE" ] \
  && [ "$(journal_field parent_workspace_id)" = "$SM_WS" ] \
  || fail "the presentation journal is not bound to the relaunched worker under its parent"$'\n'"$(cat "$SM_HOME/state/$TASK.herdr-presentation" 2>/dev/null)"
[ "$(focused_workspace)" = "$CAP_WS" ] || fail "the relaunch stole focus from the captain's workspace"
pass "real herdr: a second mate's worker whose pane was closed is relaunched into its own presentation space, without stealing focus"
