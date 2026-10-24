#!/usr/bin/env bash
# Manual live drive of the issue scenario: the real fm-watch.sh inbox_steer_check
# against a pane whose capture says the worker is busy, at the library's DEFAULT
# busy budget and grace (no FM_TASK_INBOX_* overrides). Each check is a fresh
# watcher process, as across restarts. Fixture functions come from the test file.
set -u
. "$1"   # fixture prelude from tests/fm-task-inbox.test.sh (helpers only)
trap 'rm -rf "$TMP_ROOT"' EXIT
check() {  # <case-dir>  -> one watcher poll, default thresholds
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_SEND_LOG="$1/send.log" \
    FM_FAKE_TMUX_CAPTURE="$1/busy.capture" FM_BUSY_REGEX=BUSYTOKEN \
    env -u FM_TASK_INBOX_GRACE_SECS -u FM_TASK_INBOX_BUSY_MAX -u FM_TASK_INBOX_RING_MAX \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" > "$1/check.out" 2>&1
}
show() {  # <case-dir> <label>
  local d=$1
  printf '%-34s busy-state=%-14s wake-queue=%s typed=%s record-in-root=%s\n' "$2" \
    "$( [ -e "$d/state/t1.inbox/.busy-state" ] && tr '\t' , < "$d/state/t1.inbox/.busy-state" | tr -d '\n' || echo none)" \
    "$( [ -s "$d/state/.wake-queue" ] && wc -l < "$d/state/.wake-queue" || echo 0)" \
    "$( [ -s "$d/send.log" ] && echo yes || echo no)" \
    "$(ls "$d/state/t1.inbox"/*.msg 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
}
echo "defaults in effect: grace=$(FM_STATE_OVERRIDE=/tmp bash -c '. "$1"; fm_task_inbox_grace_secs' _ "$ROOT/bin/fm-task-inbox-lib.sh") busy_max=$(FM_STATE_OVERRIDE=/tmp bash -c '. "$1"; fm_task_inbox_busy_max' _ "$ROOT/bin/fm-task-inbox-lib.sh")"
echo; echo "### A. never-read steer on a continuously busy worker (the alarm must still fire)"
A=$(busy_case default-unread); : > "$A/send.log"
show "$A" "after steer (aged past grace)"
check "$A"; show "$A" "poll 1 (busy)"
check "$A"; show "$A" "poll 2 (busy)"
echo "wake queued:"; sed 's/^/    /' "$A/state/.wake-queue"
check "$A"; show "$A" "poll 3 (busy)"

echo; echo "### B. worker reads the long-running steer right away, then stays busy for many polls"
B=$(busy_case default-read); : > "$B/send.log"
check "$B"; show "$B" "poll 1 (busy, unread)"
echo "worker reads: $(FM_STATE_OVERRIDE="$B/state" bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$B/state/t1.inbox/001.msg")"
"$ROOT/bin/fm-task-inbox-read.sh" "$B/state/t1.inbox/001.msg" && echo "receipt recorded: $(ls "$B/state/t1.inbox/.read")"
for i in 2 3 4 5 6; do check "$B"; show "$B" "poll $i (busy, read)"; done
echo "idle pane after the read (would the ladder ring the doorbell again?)"
PATH="$B/fakebin:$PATH" FM_STATE_OVERRIDE="$B/state" FM_SEND_LOG="$B/send.log" FM_FAKE_TMUX_CAPTURE="$(idle_capture "$B")" FM_BUSY_REGEX=BUSYTOKEN \
  env -u FM_TASK_INBOX_GRACE_SECS -u FM_TASK_INBOX_BUSY_MAX bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$WATCH" >/dev/null 2>&1
show "$B" "poll 7 (idle, read)"
echo; echo "### C. a never-read successor arrives while the read one is still being worked"
nxt=$(inbox_lib "$B/state" fm_task_inbox_write "$B/state" t1 "second instruction, never read"); age_path "$nxt"
check "$B"; show "$B" "poll 8 (busy)"
check "$B"; show "$B" "poll 9 (busy)"
echo "wake queued:"; sed 's/^/    /' "$B/state/.wake-queue"
echo; echo "### D. adversarial: delete the receipt (fake a read that never happened) - alarm must come back"
rm -f "$B/state/.wake-queue" "$B/state/t1.inbox/002.msg"
rm -rf "$B/state/t1.inbox/.read"
check "$B"; show "$B" "poll 10 (busy, receipt gone)"
check "$B"; show "$B" "poll 11 (busy, receipt gone)"
echo "wake queued:"; sed 's/^/    /' "$B/state/.wake-queue"
