#!/usr/bin/env bash
# Live drive of issue #4755: real fm-session-start.sh, fm-bearings-snapshot.sh,
# fm-send.sh --resolve-key against a throwaway FM_HOME. tmux/herdr are stubbed
# so no live fleet pane or Herdr session is touched.
set -u
WT=${WT:?}
W=$(mktemp -d /tmp/fm-4755-live.XXXXXX)
home="$W/home"; root="$W/root"; fb="$W/fakebin"
mkdir -p "$home/state" "$home/data" "$home/config" "$fb"
git init -q -b main "$root"; git -C "$root" commit -q --allow-empty -m init
printf 'tmux\n' > "$home/config/backend"
printf 'manual\n' > "$home/config/backlog-backend"
for t in tmux herdr; do printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/$t"; chmod +x "$fb/$t"; done
state="$home/state"
lib="$WT/bin/fm-pending-reply-lib.sh"
start() {  # <session-id>
  env -u FM_PENDING_REPLY_SESSION TMUX= FM_BACKEND=tmux CLAUDE_CODE_SESSION_ID="$1" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fb:$PATH" \
    timeout 120 "$WT/bin/fm-session-start.sh" 2>&1
}
show() { printf '\n===== %s =====\n' "$*"; }
remind_lines() { grep -n 'pending-reply-escalated' || echo '(no pending-reply-escalated line in output)'; }

show "session A start (lock acquired)"
start sess-A | grep -iE 'lock|SESSION START' | head -5
show "lock + sidecar"; cat "$state/.lock" "$state/.lock-session"

show "build one escalated record through the public lib ladder, under session A (token from real lock)"
corr=$(env -u FM_PENDING_REPLY_SESSION CLAUDE_CODE_SESSION_ID=sess-A FM_PENDING_REPLY_SEND_HOOK=true bash -c '
  . "$1"; home=$2; state=$3
  export FM_PENDING_REPLY_NOW=1000
  c=$(fm_pending_reply_create "$home" "$state" mate "finish the quarterly report")
  fm_pending_reply_mark_delivered "$state" "$c"
  fm_pending_reply_mark_turn_completed "$state" "$c" request
  FM_PENDING_REPLY_NOW=2000 fm_pending_reply_send_recovery "$state" "$c" >/dev/null
  FM_PENDING_REPLY_NOW=3000 fm_pending_reply_mark_turn_completed "$state" "$c" recovery
  FM_PENDING_REPLY_NOW=4000 fm_pending_reply_maybe_escalate "$state" "$c"
  printf %s "$c"' _ "$lib" "$home" "$state")
echo "corr=$corr"
grep -E '^(phase|escalated_epoch|surfaced_session|escalation_dismissed_epoch)=' "$state/pending-replies/$corr"
show "parent channel mate.status"; cat "$state/mate.status"
: > "$state/.wake-queue"   # session A consumed its escalation wake
show "unkeyed resolved line lands on the parent channel (must NOT settle)"
printf 'resolved: looked at it\n' | tee -a "$state/mate.status"

show "session A re-runs session start (same session): expect NO reminder"
start sess-A | remind_lines

show "session B start (/clear in same harness process): expect ONE reminder in drain"
start sess-B | remind_lines
grep -E '^surfaced_session=' "$state/pending-replies/$corr"
show "session B start again (same session re-poll): expect NO new reminder"
start sess-B | remind_lines
show "watcher tick in session B (fm_pending_reply_tick): queue count stays"
CLAUDE_CODE_SESSION_ID=sess-B env -u FM_PENDING_REPLY_SESSION bash -c '. "$1"; fm_pending_reply_tick "$2"' _ "$lib" "$state"
echo "queued pending-reply-escalated rows: $(grep -c pending-reply-escalated "$state/.wake-queue" 2>/dev/null || echo 0)"
echo "blocked lines for key: $(grep -Fc "blocked [key=pending-reply-$corr]" "$state/mate.status")  recovery_sent/phase: $(grep -E '^phase=' "$state/pending-replies/$corr")"

show "Bearings snapshot --json decisions_open (record still escalated)"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fb:$PATH" "$WT/bin/fm-bearings-snapshot.sh" --json 2>&1 | jq '.decisions_open' 2>&1 || true
show "Bearings snapshot rendered (text)"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fb:$PATH" "$WT/bin/fm-bearings-snapshot.sh" 2>&1 | head -40

show "session C: operator keyed close of pending-reply-$corr (the line fm-send --resolve-key writes; fm-send itself is refused under NO_MISTAKES_GATE)"
note=$(bash -c '. "$1"; fm_pending_reply_close_note_for_key "$2" mate operator-resolve-key "ack, handled out of band"' _ "$lib" "pending-reply-$corr")
printf 'resolved [key=pending-reply-%s]: %s\n' "$corr" "$note" | tee -a "$state/mate.status"
: > "$state/.wake-queue"
show "session D start after operator close: expect NO reminder"
start sess-D | remind_lines
grep -E '^(phase|escalation_dismissed_epoch)=' "$state/pending-replies/$corr"
show "Bearings decisions_open after operator close: expect no pending-reply row"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$root" PATH="$fb:$PATH" "$WT/bin/fm-bearings-snapshot.sh" --json 2>&1 | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-"))]'
echo "LIVE_HOME=$W"
