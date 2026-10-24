#!/usr/bin/env bash
# Dead-pane boundary: the fake tmux reports pane_current_command=zsh, which the
# backend classifies as a dead bare shell. Unread record -> direct escalation
# naming the exited agent. Read record -> no unread-instruction wake.
set -u
. "$1"
trap 'rm -rf "$TMP_ROOT"' EXIT
dead_check() {
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" FM_FAKE_TMUX_AGENT=zsh \
    env -u FM_TASK_INBOX_GRACE_SECS -u FM_TASK_INBOX_BUSY_MAX -u FM_TASK_INBOX_RING_MAX \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$1/check.out" 2>&1
}
for variant in unread read; do
  d=$(busy_case "dead-$variant"); : > "$d/send.log"
  [ "$variant" = read ] && "$ROOT/bin/fm-task-inbox-read.sh" "$d/state/t1.inbox/001.msg"
  dead_check "$d"
  printf '%-7s record: wake-queue lines=%s typed=%s\n' "$variant" "$( [ -s "$d/state/.wake-queue" ] && wc -l < "$d/state/.wake-queue" || echo 0)" "$( [ -s "$d/send.log" ] && echo yes || echo no)"
  [ -s "$d/state/.wake-queue" ] && sed 's/^/    /' "$d/state/.wake-queue"
done
