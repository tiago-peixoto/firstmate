#!/usr/bin/env bash
# usage: drive.sh <bin-dir> <lab-home> <waiting-requests> <ready-requests> <history-lines>
set -u
BIN=$1 LAB=$2 NW=$3 NR=$4 HIST=$5 MODE=${6:-steady} DELAY=${7:-0}
. "$BIN/fm-marker-lib.sh"
. "$BIN/fm-pending-reply-lib.sh"
export FM_HOME="$LAB" FM_PENDING_REPLY_GRACE_SECS=0 FM_SEND_SETTLE=0
STATE="$LAB/state"
touch "$LAB/config/wait-no-turns"
export SENDS="$LAB/sends"; : > "$SENDS"
export FM_PENDING_REPLY_SEND_HOOK='printf "%s %s\n" "$task_id" "$(perl -MTime::HiRes=time -e "printf q(%.3f), time")" >> "$SENDS"; :'
gen_history() {
  local i
  for ((i = 0; i < HIST; i++)); do
    printf 'blocked [key=q%d]: Question %d?\n' "$i" "$i"
    printf 'resolved [key=q%d]: Answer %d.\n' "$i" "$i"
  done
}
{ gen_history; printf 'blocked [key=scope]: Choose a scope.\n'; } > "$STATE/waiting.status"
{ gen_history; printf 'working: No decision is open.\n'; } > "$STATE/ready.status"
for ((i = 0; i < NW; i++)); do
  c=$(fm_pending_reply_create "$LAB" "$STATE" waiting "request $i for waiting")
  fm_pending_reply_mark_delivered "$STATE" "$c"; fm_pending_reply_mark_turn_completed "$STATE" "$c" request
done
for ((i = 0; i < NR; i++)); do
  c=$(fm_pending_reply_create "$LAB" "$STATE" ready "request $i for ready")
  fm_pending_reply_mark_delivered "$STATE" "$c"; fm_pending_reply_mark_turn_completed "$STATE" "$c" request
done
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
fold0=$t0
status_own_open_decisions "$STATE/waiting.status" > /dev/null
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "one_fold_secs=$(echo "$t1 - $t0" | bc)"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
if [ "$MODE" = midtick ]; then
  ( sleep "$DELAY"; printf 'resolved [key=scope]: The scope is narrow.\n' >> "$STATE/waiting.status"; echo "answered_at=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')" ) &
fi
echo "tick_start=$t0"
fm_pending_reply_tick "$STATE"
wait
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
echo "tick_secs=$(echo "$t1 - $t0" | bc)"
echo "sends_waiting=$(grep -c '^waiting ' "$SENDS") sends_ready=$(grep -c '^ready ' "$SENDS")"
echo "first_waiting_send_at=$(grep '^waiting ' "$SENDS" | head -1 | cut -d' ' -f2)"
for rec in "$STATE/pending-replies"/*; do
  printf '%s %s\n' "$(fm_pending_reply_get "$rec" task_id)" "$(fm_pending_reply_get "$rec" phase)"
done | sort | uniq -c
if [ "$MODE" = between ]; then
  printf 'resolved [key=scope]: The scope is narrow.\n' >> "$STATE/waiting.status"
  echo "--- answered between ticks; second tick"
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  fm_pending_reply_tick "$STATE"
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  echo "tick2_secs=$(echo "$t1 - $t0" | bc)"
  echo "sends_waiting=$(grep -c '^waiting ' "$SENDS") sends_ready=$(grep -c '^ready ' "$SENDS")"
  for rec in "$STATE/pending-replies"/*; do
    printf '%s %s\n' "$(fm_pending_reply_get "$rec" task_id)" "$(fm_pending_reply_get "$rec" phase)"
  done | sort | uniq -c
fi
