#!/usr/bin/env bash
# Live drive of issue #4755 against the real scripts in a scratch FM_HOME.
set -u
WT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M3AVNSXBTZ3D5VCRE73DJAE2
S=$1
export FM_HOME=$S FM_ROOT_OVERRIDE=$S
STATE=$S/state
FB=$S/fakebin; mkdir -p $FB
cat > $FB/tmux <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
esac
exit 0
SH
chmod +x $FB/tmux
export PATH="$FB:$PATH" FM_SEND_SETTLE=0 FM_PENDING_REPLY_SEND_HOOK=true
. $WT/bin/fm-pending-reply-lib.sh
. $WT/bin/fm-meta-lib.sh 2>/dev/null || true
printf 'window=sess:fm-mate\nkind=ship\n' > $STATE/mate.meta
: > $STATE/mate.status
sec() { printf '\n===== %s =====\n' "$*"; }
esc() {  # summary -> corr
  local c
  c=$(fm_pending_reply_create "$S" "$STATE" mate "$1")
  fm_pending_reply_mark_delivered "$STATE" "$c"
  fm_pending_reply_mark_turn_completed "$STATE" "$c" request
  FM_PENDING_REPLY_NOW=2000 fm_pending_reply_send_recovery "$STATE" "$c" >/dev/null
  FM_PENDING_REPLY_NOW=3000 fm_pending_reply_mark_turn_completed "$STATE" "$c" recovery
  FM_PENDING_REPLY_NOW=4000 fm_pending_reply_maybe_escalate "$STATE" "$c"
  printf '%s' "$c"
}
start() { env -u FM_PENDING_REPLY_SESSION CLAUDE_CODE_SESSION_ID="$1" $WT/bin/fm-session-start.sh 2>&1 | sed -n '/^WAKE QUEUE/,/^SUPERVISION OPERATING/p' | sed '$d'; }
bear() { $WT/bin/fm-bearings-snapshot.sh --json 2>/dev/null | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply"))]'; }
count() { local n; n=$(grep -c $'\tcheck\tpending-reply-escalated\t' $STATE/.wake-queue 2>/dev/null); echo "${n:-0}"; }

export FM_PENDING_REPLY_NOW=1000
sec "SESSION 1 ($CLAUDE_CODE_SESSION_ID): escalate A (to be operator-closed) and B (left open)"
A=$(esc "request A to be closed by operator"); B=$(esc "request B left open")
echo "A=$A B=$B"
echo "session token: $(fm_pending_reply_session_token $STATE)"
echo "A surfaced_session=$(fm_pending_reply_get $(fm_pending_reply_path $STATE $A) surfaced_session)"
echo "parent channel mate.status:"; cat $STATE/mate.status
: > $STATE/.wake-queue
sec "SESSION 1: watcher ticks twice in the escalating session"
fm_pending_reply_tick $STATE; fm_pending_reply_tick $STATE
echo "reminder rows queued: $(count)  (expect 0: escalation wake was this session's surface)"
sec "SESSION 1: bearings decisions_open (pending-reply rows)"
bear
sec "Operator: fm-send mate --resolve-key pending-reply-$A; plus an unkeyed resolved line"
FM_GATE_REFUSE_BYPASS=1 FM_HOME=$S $WT/bin/fm-send.sh mate --resolve-key "pending-reply-$A" "ack, handled out of band" >/dev/null 2>&1; echo "fm-send rc=$?"
printf 'resolved: looked at it\n' >> $STATE/mate.status
tail -2 $STATE/mate.status
echo "A phase=$(fm_pending_reply_get $(fm_pending_reply_path $STATE $A) phase) (operator close is not the mate's reply)"
sec "SESSION 2: /clear in the same harness -> fm-session-start.sh with a new session id"
start 22222222-2222-2222-2222-222222222222
echo "A dismissed_epoch=$(fm_pending_reply_get $(fm_pending_reply_path $STATE $A) escalation_dismissed_epoch)"
sec "SESSION 2: watcher polls three more ticks"
fm_pending_reply_tick $STATE; fm_pending_reply_tick $STATE; fm_pending_reply_tick $STATE
echo "reminder rows queued: $(count) (expect 1, not re-appended)"
echo "blocked lines for B on parent channel: $(grep -Fc "blocked [key=pending-reply-$B]" $STATE/mate.status) (expect 1: no second injection)"
echo "recovery attempts on B: $(fm_pending_reply_get $(fm_pending_reply_path $STATE $B) recovery_attempts)"
sec "SESSION 2: bearings decisions_open"
bear
sec "SESSION 2: acknowledge the reminder; re-running session start in the SAME session"
: > $STATE/.wake-queue
start 22222222-2222-2222-2222-222222222222
sec "SESSION 3: new session id, still unresolved -> reminded again once"
start 33333333-3333-3333-3333-333333333333
: > $STATE/.wake-queue
sec "Mate replies with corr=$B"
printf 'done [corr=%s]: B is finished\n' "$B" >> $STATE/mate.status
fm_pending_reply_tick $STATE
echo "B phase=$(fm_pending_reply_get $(fm_pending_reply_path $STATE $B) phase)"
: > $STATE/.wake-queue
sec "SESSION 4: resolved -> no reminder, no bearings row"
start 44444444-4444-4444-4444-444444444444
bear
