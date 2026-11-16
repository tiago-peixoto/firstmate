#!/usr/bin/env bash
# Real core terminals and Firstmate routing, without a model or user app.
set -eu
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"
# shellcheck source=tests/fixtures.sh
. "$ROOT/tests/fixtures.sh"
# shellcheck source=tests/hc-test-safety.sh
. "$ROOT/tests/hc-test-safety.sh"

HC_BIN=${FM_HC_BIN:-$(command -v herdr-core || command -v hc || true)}
[ -x "$HC_BIN" ] || { echo 'skip: hc not found'; exit 0; }
for tool in jq python3 treehouse; do
  command -v "$tool" >/dev/null || { echo "skip: $tool not found"; exit 0; }
done
export FM_HC_BIN=$HC_BIN
printf 'CLI: %s (%s)\n' "$("$HC_BIN" --version)" "$HC_BIN"
TMP_ROOT=$(fm_test_tmproot fm-secondmate-hc-smoke)
HC_TEST_SES=$("$ROOT/bin/fm-hc-lab.sh" name secondmate)
HC_TEST_SOCK=$("$ROOT/bin/fm-hc-lab.sh" socket "$HC_TEST_SES")
HC_LAB_DIR=$(hc_test_lab_dir)/$HC_TEST_SES
WT=
cleanup_lab() {
  local rc=$?
  trap - EXIT
  if ! hc_test_safe_teardown "$ROOT" "$HC_TEST_SES"; then
    echo "not ok - lab cleanup failed; preserved $HC_LAB_DIR" >&2
    exit 1
  fi
  if [ -z "$WT" ] && [ -f "${CHILD:-}/state/shell-worker.meta" ]; then
    WT=$(sed -n 's/^worktree=//p' "$CHILD/state/shell-worker.meta")
  fi
  if [ -n "$WT" ]; then
    treehouse return --force "$WT" >/dev/null 2>&1 || rc=1
  fi
  [ "$rc" -ne 0 ] || pass 'lab teardown: core stopped, processes removed, real fleet tripwire unchanged'
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_lab EXIT
# Keep the tripwire pointed at real state while preventing login-shell dotfiles.
export XDG_STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
export HOME="$TMP_ROOT/user" SHELL=/bin/bash FM_HC_SOCKET=$HC_TEST_SOCK
mkdir -p "$HOME"
unset HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE HC_SOCKET HERDR_APP_HOME FM_BACKEND
"$ROOT/bin/fm-hc-lab.sh" provision "$HC_TEST_SES"
hc_test_refuse_if_unsafe "$HC_TEST_SES" || fail 'unsafe lab session'
export HC_SESSION=$HC_TEST_SES XDG_STATE_HOME="$HC_LAB_DIR/env/xdg-state"
export XDG_CONFIG_HOME="$HC_LAB_DIR/env/xdg-config" XDG_DATA_HOME="$HC_LAB_DIR/env/xdg-data"
export FM_SKIP_SECONDMATE_SYNC=1 FM_SPAWN_NO_GUARD=1
PRIMARY="$TMP_ROOT/parent"
CHILD="$TMP_ROOT/child"
PROJ="$TMP_ROOT/project"
fm_test_spawn_home "$PRIMARY"
fm_test_spawn_home "$CHILD"
seed_secondmate_home_marker "$CHILD" captain
cp -R "$ROOT/bin/." "$CHILD/bin/"
fm_git_init_commit "$CHILD"
fm_git_init_commit "$PROJ"
git clone -q --bare "$PROJ" "$TMP_ROOT/origin.git"
git -C "$PROJ" remote add origin "$TMP_ROOT/origin.git"
scaffold_secondmate_charter "$PRIMARY" captain 'Supervise the shell worker' --no-projects
printf 'Supervise the shell worker\n' > "$CHILD/data/charter.md"
printf -- '- captain - shell fleet (home: %s; scope: smoke; projects: ; added 2026-11-15)\n' "$CHILD" > "$PRIMARY/data/secondmates.md"
fm_test_spawn_brief "$CHILD" shell-worker 'Run the isolated shell workload'

cat > "$TMP_ROOT/captain.sh" <<'INNER'
#!/bin/bash
set -eu
receipt=$1
printf '%s\n' "home=$FM_HOME" "backend=$FM_BACKEND" "session=$HC_SESSION" "terminal=$HC_TERMINAL_ID" > "$receipt"
export PS1='❯ '
exec /bin/bash --noprofile --norc -i
INNER
cat > "$TMP_ROOT/worker.sh" <<'INNER'
#!/bin/bash
set -eu
printf 'WORKER_%s\n' EXECUTED
printf '%s\n' "session=$HC_SESSION" "terminal=$HC_TERMINAL_ID" > "$1"
export PS1='❯ '
exec /bin/bash --noprofile --norc -i
INNER
cat > "$TMP_ROOT/dispatch.sh" <<'INNER'
#!/bin/bash
set -eu
project=$1
workload=$2
receipt=$3
# No runtime or session override: this process inherits the secondmate's launch.
"$FM_HOME/bin/fm-spawn.sh" shell-worker "$project" "/bin/bash '$workload' '$receipt'" --mode no-mistakes --yolo off
printf 'CAPTAIN_%s\n' DISPATCHED
printf 'done\n' > "$4"
INNER

wait_file() {
  local file=$1 attempt
  for ((attempt=0; attempt<100; attempt++)); do
    [ -s "$file" ] && return 0
    sleep 0.2
  done
  if [ -n "${CAPTAIN_TERM:-}" ]; then
    "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read --lines 100 "$CAPTAIN_TERM" >&2 || true
  fi
  fail "timed out waiting for $file"
}
parent() { FM_HOME="$PRIMARY" "$ROOT/bin/$1" "${@:2}"; }
FM_HOME="$PRIMARY" FM_BACKEND=hc FM_HC_SPACE=parent-custom \
  "$ROOT/bin/fm-spawn.sh" captain "$CHILD" "/bin/bash '$TMP_ROOT/captain.sh' '$TMP_ROOT/captain.env'" --secondmate
wait_file "$TMP_ROOT/captain.env"
cat "$TMP_ROOT/captain.env"
grep -Fx "home=$CHILD" "$TMP_ROOT/captain.env" || fail 'secondmate did not inherit child home'
grep -Fx 'backend=hc' "$TMP_ROOT/captain.env" || fail 'secondmate did not inherit runtime'
grep -Fx "session=$HC_TEST_SES" "$TMP_ROOT/captain.env" || fail 'secondmate did not inherit session'
CAPTAIN_TERM=$(sed -n 's/^hc_terminal=//p' "$PRIMARY/state/captain.meta")
for ((attempt=0; attempt<100; attempt++)); do
  screen=$("$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" read --lines 0 "$CAPTAIN_TERM")
  case "$screen" in *'❯'*) break ;; esac
  sleep 0.2
done
[ "$attempt" -lt 100 ] || fail 'secondmate shell prompt never became ready'
# Shell workloads use the backend's ownership-checked send, without model readiness.
# shellcheck disable=SC2016 # The child shell resolves the recorded endpoint.
FM_HOME="$PRIMARY" bash -c '
  . "$1/bin/fm-backend.sh"
  target=$(fm_backend_resolve_selector captain "$FM_HOME/state")
  backend=$(fm_backend_of_selector captain "$target" "$FM_HOME/state")
  label=$(fm_backend_expected_label_of_selector captain "$FM_HOME/state")
  fm_backend_source "$backend"
  fm_backend_hc_send_text_line "$target" "$2" "$label"
' _ "$ROOT" "/bin/bash '$TMP_ROOT/dispatch.sh' '$PROJ' '$TMP_ROOT/worker.sh' '$TMP_ROOT/worker.env' '$TMP_ROOT/dispatch.done'"
wait_file "$TMP_ROOT/dispatch.done"
wait_file "$TMP_ROOT/worker.env"
META="$CHILD/state/shell-worker.meta"
WT=$(sed -n 's/^worktree=//p' "$META")
WORKER_TERM=$(sed -n 's/^hc_terminal=//p' "$META")
grep -Fx 'backend=hc' "$META" || fail 'worker runtime differs'
grep -Fx "hc_session=$HC_TEST_SES" "$META" || fail 'worker session differs'
grep -Fx "session=$HC_TEST_SES" "$TMP_ROOT/worker.env" || fail 'worker command ran in another session'
grep -Fx "terminal=$WORKER_TERM" "$TMP_ROOT/worker.env" || fail 'worker command ran in another terminal'
# shellcheck source=bin/fm-backend-hometag-lib.sh
. "$ROOT/bin/fm-backend-hometag-lib.sh"
PARENT_TAG=$(FM_HOME="$PRIMARY" FM_ROOT="$ROOT" fm_backend_hometag)
CHILD_TAG=$(FM_HOME="$CHILD" FM_ROOT="$CHILD" fm_backend_hometag)
for terminal in "$CAPTAIN_TERM" "$WORKER_TERM"; do
  "$ROOT/bin/fm-hc-lab.sh" run "$HC_TEST_SES" get "$terminal" --json > "$TMP_ROOT/$terminal.json"
done
jq -e --arg owner "$PARENT_TAG" --arg space "fm-$CHILD_TAG" '.labels["firstmate.home"] == $owner and .labels["firstmate.task"] == "fm-captain" and .labels["herdr.space"] == $space' "$TMP_ROOT/$CAPTAIN_TERM.json" >/dev/null || fail 'secondmate labels differ'
jq -e --arg owner "$CHILD_TAG" --arg space "fm-$CHILD_TAG" '.labels["firstmate.home"] == $owner and .labels["firstmate.task"] == "fm-shell-worker" and .labels["herdr.space"] == $space' "$TMP_ROOT/$WORKER_TERM.json" >/dev/null || fail 'worker labels differ'
parent fm-peek.sh captain 100 > "$TMP_ROOT/captain.peek"
FM_HOME="$CHILD" "$CHILD/bin/fm-peek.sh" shell-worker 100 > "$TMP_ROOT/worker.peek"
assert_grep CAPTAIN_DISPATCHED "$TMP_ROOT/captain.peek" 'parent peek missed executed dispatch'
assert_grep WORKER_EXECUTED "$TMP_ROOT/worker.peek" 'child peek missed executed workload'
printf 'lab=%s secondmate=%s worker=%s space=fm-%s\n' "$HC_TEST_SES" "$CAPTAIN_TERM" "$WORKER_TERM" "$CHILD_TAG"
pass 'real hc: inherited child runtime/session, shared child space, separate ownership, parent send/peek and worker execution'
echo FM_TEST_COMPLETE
