#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh, bin/fm-crew-state.sh and
# bin/fm-herdr-groups.sh against a disposable FM_HOME. Prints a transcript.
set -u
ROOT=${1:?worktree root}
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-live-hold-mirror)
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"
HOLDLIB="$ROOT/bin/fm-hold-status-lib.sh"
TASKS_AXI_BIN=$(command -v tasks-axi)

say() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@"; }
reader() {  # <fn> <file>: the exact reader the watcher / crew state source
  bash -c '. "$1"; . "$2"; "$3" "$4"' _ "$CLASSIFY" "$HOLDLIB" "$1" "$2"
}
classify_held() { bash -c '. "$1"; status_is_captain_held "$2"' _ "$CLASSIFY" "$1"; }
check() {  # <ok?> <label>
  if [ "$1" -eq 0 ]; then printf 'PASS: %s\n' "$2"; else printf 'FAIL: %s\n' "$2"; FAILS=$((FAILS + 1)); fi
}
FAILS=0

make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}
hold() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}
lane_meta() {  # <home> <id> <kind>
  fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "worktree=$1/projects/missing-$2" \
    "project=$1/projects/sample" "harness=codex" "kind=$3" "mode=$3" "spawn_gen=fixture-$2"
}
add_task() { (cd "$1" && tasks-axi add "$2" "$3" --kind "$4" --repo sample >/dev/null); }

HOME_A=$(make_home lifecycle)
say "Scenario 1: hold on a worker lane declares the hold on state/<id>.status"
add_task "$HOME_A" t1 "Ship the gated sample" ship
lane_meta "$HOME_A" t1 ship
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which API shape\npaused: waiting on upstream release\n' > "$HOME_A/state/t1.status"
show hold "$HOME_A" hold t1 --reason "operator review pending"
show cat "$HOME_A/state/t1.status"
last=$(reader last_status_line "$HOME_A/state/t1.status")
printf 'watcher reader last_status_line -> %s\n' "$last"
classify_held "$last"; check $? "watcher reader sees the lane as captain-held while the hold stands"
printf 'worker reader last_worker_status_line -> %s\n' "$(reader last_worker_status_line "$HOME_A/state/t1.status")"
[ "$(reader last_worker_status_line "$HOME_A/state/t1.status")" = "paused: waiting on upstream release" ]; check $? "worker-state reader still reports the worker's own paused line"
show hold "$HOME_A" hold t1 --reason "operator review pending"
n=$(grep -c '^captain-held ' "$HOME_A/state/t1.status"); printf 'captain-held lines after repeated hold: %s\n' "$n"
[ "$n" = 1 ]; check $? "a repeated hold does not duplicate the declaration"

say "Scenario 2: release retracts the declaration with no worker alive; readers return the worker's own line"
printf 'Proceed as planned.\n' > "$HOME_A/go.txt"
show hold "$HOME_A" answer t1 --decision-file "$HOME_A/go.txt" --release
show cat "$HOME_A/state/t1.status"
grep -qE '^resolved \[key=captain-hold-t1-1\]( \[at=[0-9]+\])?: captain call released by fm-captain-hold$' "$HOME_A/state/t1.status"; check $? "release appended the keyed retraction"
last=$(reader last_status_line "$HOME_A/state/t1.status"); printf 'last_status_line -> %s\n' "$last"
[ "$last" = "paused: waiting on upstream release" ]; check $? "settled pair is read past to the worker's paused line"
wait_line=$(reader status_declared_wait_line "$HOME_A/state/t1.status"); printf 'status_declared_wait_line -> %s\n' "$wait_line"
[ "$wait_line" = "paused: waiting on upstream release" ]; check $? "declared wait is the worker's pause again"
open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$CLASSIFY" "$HOME_A/state/t1.status"); printf 'status_open_decisions -> %s\n' "$open"
case "$open" in api-shape$'\t'*) check 0 "worker's own open decision survives hold and release" ;; *) check 1 "worker's own open decision survives hold and release" ;; esac

say "Scenario 3: re-hold starts key 2; a closing answer retracts it; replay appends nothing"
show hold "$HOME_A" hold t1 --reason "second operator review"
printf 'Ship it as reviewed.\n' > "$HOME_A/ship.txt"
show hold "$HOME_A" answer t1 --decision-file "$HOME_A/ship.txt"
show hold "$HOME_A" answer t1 --decision-file "$HOME_A/ship.txt"
show cat "$HOME_A/state/t1.status"
[ "$(grep -c 'resolved \[key=captain-hold-t1-2\]' "$HOME_A/state/t1.status")" = 1 ]; check $? "closing answer retracted key 2 exactly once across a replay"
last=$(reader last_status_line "$HOME_A/state/t1.status"); printf 'last_status_line -> %s\n' "$last"
[ "$last" = "paused: waiting on upstream release" ]; check $? "lane reads as the worker's pause after close"

say "Scenario 4 (adversarial): multi-line reason with a forged 'blocked:' second line folds to one status line"
add_task "$HOME_A" t2 "Scout the multiline sample" scout
lane_meta "$HOME_A" t2 scout
printf 'done: PR ready\n' > "$HOME_A/state/t2.status"
show hold "$HOME_A" hold t2 --reason $'Pick the API shape\r\nblocked: on vendor reply'
show cat -A "$HOME_A/state/t2.status"
[ "$(wc -l < "$HOME_A/state/t2.status")" -eq 2 ]; check $? "hold wrote exactly one status line"
printf 'last_worker_status_line -> %s\n' "$(reader last_worker_status_line "$HOME_A/state/t2.status")"
[ "$(reader last_worker_status_line "$HOME_A/state/t2.status")" = "done: PR ready" ]; check $? "the forged blocked: text never became a worker event"
cur=$(bash -c '. "$1"; . "$2"; status_current_line "$3" scout' _ "$CLASSIFY" "$HOLDLIB" "$HOME_A/state/t2.status"); printf 'status_current_line -> %s\n' "$cur"
[ "$cur" = "done: PR ready" ]; check $? "crew-state current line stays done under the standing hold"

say "Scenario 5 (boundary): a decision-only hold (no lane) mints no status log"
show hold "$HOME_A" hold plain-call --title "Pick a sample flavor" --reason "flavor choice pending"
ls "$HOME_A/state/" | grep plain-call || echo "(no state file for plain-call)"
[ ! -e "$HOME_A/state/plain-call.status" ]; check $? "no status log created for a lane-less hold"

say "Scenario 6: an answered decision under a standing hold stays closed (crew-state current line)"
add_task "$HOME_A" t3 "Scout the answered sample" scout
lane_meta "$HOME_A" t3 scout
printf 'needs-decision [key=q]: pick\nresolved [key=q]: use a\n' > "$HOME_A/state/t3.status"
show hold "$HOME_A" hold t3 --reason "captain review"
show cat "$HOME_A/state/t3.status"
cur=$(bash -c '. "$1"; . "$2"; status_current_line "$3" scout' _ "$CLASSIFY" "$HOLDLIB" "$HOME_A/state/t3.status"); printf 'status_current_line -> %s\n' "$cur"
case "$cur" in needs-decision*) check 1 "answered decision not revived by the standing mirror" ;; *) check 0 "answered decision not revived by the standing mirror" ;; esac

say "Scenario 7: reconcile close retracts a held lane's declaration"
add_task "$HOME_A" t4 "Scout the reconciled sample" scout
lane_meta "$HOME_A" t4 scout
printf 'paused: waiting on the sample upstream\n' > "$HOME_A/state/t4.status"
show hold "$HOME_A" hold t4 --reason "upstream choice pending"
hold "$HOME_A" bind board-src >/dev/null && printf 't4\n' | hold "$HOME_A" reconcile-requests --source-id board-src --source "captured board result" >/dev/null
printf 'The premise dissolved: upstream already ships it.\n' > "$HOME_A/evidence.txt"
show hold "$HOME_A" reconcile close t4 --evidence-file "$HOME_A/evidence.txt"
show cat "$HOME_A/state/t4.status"
grep -qE '^resolved \[key=captain-hold-t4-1\]( \[at=[0-9]+\])?: captain call reconciled by fm-captain-hold$' "$HOME_A/state/t4.status"; check $? "reconcile close retracted the declaration"
[ "$(reader last_status_line "$HOME_A/state/t4.status")" = "paused: waiting on the sample upstream" ]; check $? "lane reads as its own pause after reconcile close"

say "Scenario 8: divergence guard stays silent over the mirror's own keys"
out=$(hold "$HOME_A" diverged); rc=$?; printf 'diverged rc=%s out=[%s]\n' "$rc" "$out"
[ "$rc" = 0 ] && [ -z "$out" ]; check $? "no false divergence signal"

say "Scenario 9: real crew-state helper keeps a delivered scout 'done' while held and after release"
eval "$(sed -n '/^make_fakebin()/,/^}$/p' "$ROOT/tests/fm-crew-state.test.sh")"
NM_HOME="$TMP_ROOT/nm-unused"; export NM_HOME
export FM_FAKE_AXI_STATUS="" FM_FAKE_RUNS_LIST="" FM_FAKE_TMUX_BUSY=""
HOME_C=$(make_home crew)
mkdir -p "$HOME_C/wt"
make_fakebin "$HOME_C" >/dev/null
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$HOME_C/state" task)
"$ROOT/bin/fm-busy-event.sh" apply "$HOME_C/state" task idle --gen "$gen" --source claude-hook --event stop
fm_write_meta "$HOME_C/state/task.meta" "window=fm:fm-task" "worktree=$HOME_C/wt" "kind=scout" "harness=claude"
add_task "$HOME_C" task "Scout the crew sample" scout
printf 'done: report ready\n' > "$HOME_C/state/task.status"
crew() { PATH="$HOME_C/fakebin:$PATH" FM_STATE_OVERRIDE="$HOME_C/state" "$ROOT/bin/fm-crew-state.sh" task; }
printf -- '--- before hold\n'; out0=$(crew); printf '%s\n' "$out0"
show hold "$HOME_C" hold task --reason "captain review pending"
printf -- '--- while held\n'; out1=$(crew); printf '%s\n' "$out1"
printf '%s\n' "$out1" | grep -q '^state: done'; check $? "fm-crew-state.sh reports done while the hold stands"
printf 'Release.\n' > "$HOME_C/go.txt"
show hold "$HOME_C" answer task --decision-file "$HOME_C/go.txt" --release
printf -- '--- after release\n'; out2=$(crew); printf '%s\n' "$out2"
printf '%s\n' "$out2" | grep -q '^state: done'; check $? "fm-crew-state.sh reports done after release"
show cat "$HOME_C/state/task.status"

say "Scenario 10: Herdr groups view labels a held and a released delivered task 'done' (real hold command, real groups view, scripted herdr CLI)"
HOME_H=$(make_home herdr)
printf 'on\n' > "$HOME_H/config/herdr-project-groups"
FAKE_DIR="$HOME_H/fake"; mkdir -p "$FAKE_DIR"
printf '{"result":{"workspaces":[]}}\n' > "$FAKE_DIR/workspaces.json"
printf '{"result":{"panes":[]}}\n' > "$FAKE_DIR/panes.json"
cat > "$HOME_H/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "status --json") printf '{"client":{"version":"0.9.3","protocol":22},"server":{"running":true}}\n' ;;
  "workspace list") cat "$FAKE_DIR/workspaces.json" ;;
  "pane list") cat "$FAKE_DIR/panes.json" ;;
  "session list") printf '{"sessions":[{"name":"s1","running":true,"socket_path":"/tmp/fm-live-groups-s1.sock"}]}\n' ;;
  "pane report-metadata"|"workspace report-metadata") ;;
  *) exit 1 ;;
esac
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME_H/fakebin/agent-view"
chmod +x "$HOME_H/fakebin/herdr" "$HOME_H/fakebin/agent-view"
herdr_task() {  # <id> <workspace> <status>
  printf 'window=s1:%s:p2\nproject=/p/api-server\nkind=ship\nbackend=herdr\nherdr_session=s1\nherdr_workspace_id=%s\nherdr_tab_id=%s:t2\nherdr_pane_id=%s:p2\n' \
    "$2" "$2" "$2" "$2" > "$HOME_H/state/$1.meta"
  printf '%s\n' "$3" > "$HOME_H/state/$1.status"
  add_task "$HOME_H" "$1" "Ship $1" ship
}
herdr_task api-standing w2 'done: PR ready, checks green'
herdr_task api-settled w3 'done: PR ready, checks green'
herdr_task api-control w4 'done: PR ready, checks green'
show hold "$HOME_H" hold api-standing --reason "merge approval"
show hold "$HOME_H" hold api-settled --reason "merge approval"
printf 'Released.\n' > "$HOME_H/go.txt"
show hold "$HOME_H" answer api-settled --decision-file "$HOME_H/go.txt" --release
show cat "$HOME_H/state/api-standing.status" "$HOME_H/state/api-settled.status"
groups_out=$(env FM_ROOT_OVERRIDE='' FM_HOME="$HOME_H" FM_STATE_OVERRIDE="$HOME_H/state" FM_CONFIG_OVERRIDE="$HOME_H/config" \
  PATH="$HOME_H/fakebin:$PATH" FAKE_DIR="$FAKE_DIR" FM_HERDR_GROUPS_AGENT_VIEW="$HOME_H/fakebin/agent-view" \
  "$ROOT/bin/fm-herdr-groups.sh" plan 2>&1); rc=$?
printf '$ fm-herdr-groups.sh plan (rc=%s)\n%s\n' "$rc" "$groups_out"
printf '%s\n' "$groups_out" | grep -q $'^api-standing\tapi-server\tdone\t'; check $? "standing hold mirror: groups view labels the task done"
printf '%s\n' "$groups_out" | grep -q $'^api-settled\tapi-server\tdone\t'; check $? "settled hold mirror: groups view labels the task done (not running)"
printf '%s\n' "$groups_out" | grep -q $'^api-control\tapi-server\tdone\t'; check $? "control task with no hold labels done"

printf '\n=== RESULT: %s failing check(s); fixture root %s\n' "$FAILS" "$TMP_ROOT"
rm -rf "$TMP_ROOT"
exit "$FAILS"
