#!/usr/bin/env bash
# usage: drive-report.sh <bin-dir> <lab-home> <history-lines>
# The first repost to mate 'ready' writes a correlated report for the last ready request, mid-tick.
set -u
BIN=$1 LAB=$2 HIST=$3
. "$BIN/fm-marker-lib.sh"
. "$BIN/fm-pending-reply-lib.sh"
export FM_HOME="$LAB" FM_PENDING_REPLY_GRACE_SECS=0 FM_SEND_SETTLE=0
STATE="$LAB/state"; export STATE_DIR="$STATE"
touch "$LAB/config/wait-no-turns"
export SENDS="$LAB/sends"; : > "$SENDS"
gen_history() { local i; for ((i = 0; i < HIST; i++)); do printf 'blocked [key=q%d]: Q%d?\nresolved [key=q%d]: A%d.\n' "$i" "$i" "$i" "$i"; done; }
{ gen_history; printf 'blocked [key=scope]: Choose a scope.\n'; } > "$STATE/waiting.status"
{ gen_history; printf 'working: No decision is open.\n'; } > "$STATE/ready.status"
for t in waiting waiting ready ready ready waiting; do
  c=$(fm_pending_reply_create "$LAB" "$STATE" $t "request for $t")
  fm_pending_reply_mark_delivered "$STATE" "$c"; fm_pending_reply_mark_turn_completed "$STATE" "$c" request
done
LAST=""; for rec in "$STATE/pending-replies"/*; do [ "$(fm_pending_reply_get "$rec" task_id)" = ready ] && LAST=$(fm_pending_reply_get "$rec" corr_id); done
export LAST
echo "tick order:"; for rec in "$STATE/pending-replies"/*; do echo "  $(fm_pending_reply_get "$rec" task_id) $(fm_pending_reply_get "$rec" corr_id)"; done
echo "last ready request (gets a correlated report mid-tick): $LAST"
export FM_PENDING_REPLY_SEND_HOOK='printf "%s\n" "$task_id" >> "$SENDS"; if [ "$task_id" = ready ] && [ ! -e "$SENDS.reported" ]; then : > "$SENDS.reported"; printf "done [corr=%s]: finished the work\n" "$LAST" >> "$STATE_DIR/ready.status"; fi; :'
fm_pending_reply_tick "$STATE"
echo "tick rc=$?"
echo "sends: waiting=$(grep -c '^waiting$' "$SENDS") ready=$(grep -c '^ready$' "$SENDS")"
for rec in "$STATE/pending-replies"/*; do
  echo "  $(fm_pending_reply_get "$rec" task_id) $(fm_pending_reply_get "$rec" corr_id) phase=$(fm_pending_reply_get "$rec" phase) resolved_via=$(fm_pending_reply_get "$rec" resolved_via)"
done
