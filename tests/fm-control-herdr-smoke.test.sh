#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real agent is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, so registering and not registering an agent on a plain
# shell pane exercises exactly the classification the control plane gates on.
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
printf '# brief\n' > "$HOME_DIR/data/hsmoke/brief.md"

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a stale registration on a shell is agent-free --------------------------
#
# herdr pane report-agent is the same registry hook-authority integrations
# write. After /quit the process is gone and only the shell remains, but
# herdr 0.9.0 can keep the registration (done/idle under
# full_lifecycle_hook_authority) because Pi and OpenCode never call
# pane.release-agent. Registration alone is not live.

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a leftover agent on the task pane"

STATE=
for _ in $(seq 1 20); do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = dead ] && break
  sleep 0.1
done
[ "$STATE" = dead ] || fail "a registered agent whose foreground is only a shell should be dead, got '$STATE'"

OUT=$(run_control hsmoke exit) || fail "exit against a stale herdr registration should confirm the agent is gone: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*|"stopped hsmoke"*) : ;;
  *) fail "a stale registration on a shell should confirm stopped, got: $OUT" ;;
esac
pass "real herdr: a registered agent whose process is gone is agent-free"

# --- a leftover registration on a nested shell is agent-free ----------------
#
# Pooled spawns run `treehouse get`, which leaves the agent inside a nested
# interactive shell. After the agent exits, process-info reports that nested
# zsh as the foreground process group, not the pane shell. Combined with a
# leftover hook-authority registration, the previous classifier read live
# and fm-control exit reported unconfirmed.

herdr pane send-keys "$PANE_ID" enter --session "$SESSION" >/dev/null 2>&1 || true
sleep 0.2
herdr pane run "$PANE_ID" "zsh" --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not start a nested interactive shell in the task pane"

NESTED=0
for _ in $(seq 1 50); do
  info=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null || true)
  shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true)
  pgid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null || true)
  name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null || true)
  if [ -n "$shell_pid" ] && [ -n "$pgid" ] && [ "$shell_pid" != "$pgid" ] && [ "$name" = zsh ]; then
    NESTED=1
    break
  fi
  sleep 0.1
done
if [ "$NESTED" != 1 ]; then
  herdr pane process-info --pane "$PANE_ID" --session "$SESSION" >&2 || true
  fail "the nested zsh never became the foreground process group"
fi

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a leftover agent on the nested-shell pane"

STATE=
for _ in $(seq 1 20); do
  STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
  [ "$STATE" = dead ] && break
  sleep 0.1
done
[ "$STATE" = dead ] || fail "a leftover registration on a nested shell should be dead, got '$STATE'"

OUT=$(run_control hsmoke exit) || fail "exit against a nested-shell leftover registration should confirm the agent is gone: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*|"stopped hsmoke"*) : ;;
  *) fail "a leftover registration on a nested shell should confirm stopped, got: $OUT" ;;
esac
pass "real herdr: a leftover registration on a nested shell is agent-free"

# --- a registered agent with a live payload process -------------------------

command -v python3 >/dev/null 2>&1 || fail "python3 is required to hold a live non-shell foreground process"
herdr pane send-keys "$PANE_ID" enter --session "$SESSION" >/dev/null 2>&1 || true
sleep 0.2
PY_LIVE="$SCRATCH/py-live"
# The payload stays in the foreground and spawns a child shell so a live
# agent that is running a shell command cannot be classified gone.
herdr pane run "$PANE_ID" \
  "python3 -c 'import signal,subprocess,time; signal.signal(signal.SIGINT, signal.SIG_IGN); signal.signal(signal.SIGTERM, signal.SIG_IGN); subprocess.Popen([\"zsh\",\"-c\",\"sleep 3600\"]); open(\"$PY_LIVE\",\"w\").write(\"ok\"); time.sleep(3600)'" \
  --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not start a live payload process in the task pane"

LIVE_PROC=0
for _ in $(seq 1 50); do
  [ -f "$PY_LIVE" ] || { sleep 0.1; continue; }
  info=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null || true)
  shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty' 2>/dev/null || true)
  pgid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_process_group_id // empty' 2>/dev/null || true)
  name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty' 2>/dev/null || true)
  comm=${name##*/}
  comm=${comm#-}
  case "$comm" in
    sh|bash|zsh|dash|ksh|fish|'') sleep 0.1; continue ;;
  esac
  if [ -n "$shell_pid" ] && [ -n "$pgid" ] && [ "$shell_pid" != "$pgid" ]; then
    LIVE_PROC=1
    break
  fi
  sleep 0.1
done
if [ "$LIVE_PROC" != 1 ]; then
  herdr pane process-info --pane "$PANE_ID" --session "$SESSION" >&2 || true
  herdr pane read "$PANE_ID" --source recent --lines 20 --session "$SESSION" >&2 || true
  fail "the payload process never appeared in pane process-info"
fi

herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the payload pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent with a live process as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a live registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# Last, because it deliberately types a harness command into a pane whose
# live process ignores /exit: the control plane must say so rather than
# report a stop it did not achieve.
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent does not stop: $OUT"
fi
case "$OUT" in
  *"did not stop"*) : ;;
  *) fail "the exit failure should say the agent did not stop, got: $OUT" ;;
esac
pass "real herdr: an agent that does not stop fails closed instead of being reported as stopped"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
