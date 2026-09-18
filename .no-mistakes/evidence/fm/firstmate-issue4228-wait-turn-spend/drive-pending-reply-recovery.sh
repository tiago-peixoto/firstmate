#!/usr/bin/env bash
# The pending-reply recovery repost (the watcher's fm_pending_reply_tick step)
# driven through the real library and the real fm-send into a REAL tmux pane,
# for a secondmate that missed its report. Adversarial: a relayed captain hold
# open on the same mate must not block the recovery; the mate's own decision must.
set -u
ROOT=${ROOT:?}
W=$(mktemp -d /tmp/fm4228-prr.XXXXXX); W=$(cd "$W" && pwd -P)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0 FM_PENDING_REPLY_GRACE_SECS=0
H="$W/home"; mkdir -p "$H/state" "$H/data"; chmod 755 "$H/state"
printf '%s\n' window=firstmate:fm-hibit kind=secondmate harness=claude backend=tmux "home=$W/mate" > "$H/state/hibit.meta"
tmux new-session -d -s firstmate -n fm-hibit "cat"
. "$ROOT/bin/fm-pending-reply-lib.sh"; . "$ROOT/bin/fm-classify-lib.sh"
export FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT"
S="$H/state"
corr=$(fm_pending_reply_create "$H" "$S" hibit "status of phase 8")
fm_pending_reply_mark_delivered "$S" "$corr"
fm_pending_reply_observe_busy "$S" "$corr" busy
fm_pending_reply_observe_busy "$S" "$corr" idle
look() {
  echo "  record phase: $(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$corr")" phase)" \
       "| inbox records: $(ls "$S/hibit.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
  echo "  mate pane:"; tmux capture-pane -p -t firstmate:fm-hibit | sed '/^$/d; s/^/    > /'
}
try() { if fm_pending_reply_send_recovery "$S" "$corr" >/dev/null 2>&1; then echo "  recovery: sent"; else echo "  recovery: not attempted"; fi; }
echo "== firstmate asked hibit for a report; hibit finished its turn without one (grace 0)"
echo "== hibit has its own decision open AND relays a captain hold for its child"
printf '%s\n' 'needs-decision [key=scope]: narrow or wide?' 'needs-decision [key=captain-hold-t42-1]: captain hold t42: ship alpha or beta?' > "$S/hibit.status"
sed 's/^/  status: /' "$S/hibit.status"; try; look
echo; echo "== watcher tick again while still open"; try; look
echo; echo "== firstmate answers hibit's own decision; the captain hold stays open"
printf 'resolved [key=scope]: answered: narrow\n' >> "$S/hibit.status"
try; look
echo "  recovery message recorded:"; bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$(ls "$S/hibit.inbox"/*.msg | head -1)" | sed 's/^/    /'
tmux kill-server 2>/dev/null; rm -rf "$W"
