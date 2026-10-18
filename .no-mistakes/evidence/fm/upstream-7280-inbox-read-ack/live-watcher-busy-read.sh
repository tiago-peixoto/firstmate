#!/usr/bin/env bash
# Live driver: real tmux pane (private fm-lab socket) kept busy, real fm-watch.sh inbox_steer_check,
# real fm-task-inbox-read.sh. Usage: live-watcher-busy-read.sh <worktree>
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
mkdir -p "$LAB/tmux" "$LAB/state" "$LAB/config"
export TMUX_TMPDIR="$LAB/tmux"
T() { tmux -L fm-lab "$@"; }
T new-session -d -s sess -n fm-t1 "while :; do echo 'BUSYTOKEN working on long steer'; sleep 1; done"
SOCK=$(T display-message -p '#{socket_path}')
export TMUX="$SOCK,0,0"
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_write_meta "$LAB/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok" 2>/dev/null || \
  printf 'window=sess:fm-t1\nkind=ship\nharness=grok\n' > "$LAB/state/t1.meta"
check() {
  env -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_GRACE_SECS=0 \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$ROOT/bin/fm-watch.sh" >>"$LAB/check.out" 2>&1
  printf '  check %s: wake-queue=[%s] busy-state=[%s]\n' "$1" "$(cat "$LAB/state/.wake-queue" 2>/dev/null | tr '\n' ' ')" "$(cat "$LAB/state/t1.inbox/.busy-state" 2>/dev/null | tr '\t\n' ': ')"
}
echo "pane tail: $(T capture-pane -p -t sess:fm-t1 | grep . | tail -1)"
echo "== Scenario A: busy worker reads a long-running steer"
REC=$(FM_STATE_OVERRIDE="$LAB/state" fm_task_inbox_write "$LAB/state" t1 "long-running steer: refactor the module")
touch -d '-10 minutes' "$REC"; echo "steer: $REC"
check 1
echo "  worker reads: $(fm_task_inbox_body "$REC" 2>/dev/null || cat "$REC" | tail -1)"
"$ROOT/bin/fm-task-inbox-read.sh" "$REC"; echo "  fm-task-inbox-read.sh rc=$? receipt: $(ls "$LAB/state/t1.inbox/.read/")"
for i in 2 3 4 5; do check $i; done
[ -s "$LAB/state/.wake-queue" ] && echo "RESULT A: FAIL (escalated)" || echo "RESULT A: PASS (no stuck-busy escalation after 5 busy checks; msg still pending: $(ls "$LAB/state/t1.inbox/"*.msg))"
echo "== Scenario B: never-read message on the same busy worker"
REC2=$(FM_STATE_OVERRIDE="$LAB/state" fm_task_inbox_write "$LAB/state" t1 "second steer never read")
touch -d '-10 minutes' "$REC2"; echo "steer: $REC2"
check 6; check 7
grep -q "stuck-busy" "$LAB/state/.wake-queue" 2>/dev/null && echo "RESULT B: PASS (escalated): $(cat "$LAB/state/.wake-queue")" || echo "RESULT B: FAIL (no escalation)"
echo "== Scenario C (baseline guard): never-read only, no receipt, default budget"
rm -rf "$LAB/state/t1.inbox" "$LAB/state/.wake-queue"
REC3=$(FM_STATE_OVERRIDE="$LAB/state" fm_task_inbox_write "$LAB/state" t1 "unread steer")
touch -d '-10 minutes' "$REC3"
check 1; check 2
grep -q "stuck-busy" "$LAB/state/.wake-queue" 2>/dev/null && echo "RESULT C: PASS (unread escalates at FM_TASK_INBOX_BUSY_MAX default 2)" || echo "RESULT C: FAIL"
echo "== pane never typed into (no doorbell text in pane):"
T capture-pane -p -t sess:fm-t1 -S -200 | grep -c 'Firstmate instruction waiting' || true
echo "watcher stderr/stdout:"; cat "$LAB/check.out"
T kill-server; rm -rf "$LAB"; echo "lab removed"
