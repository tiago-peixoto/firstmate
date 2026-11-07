#!/usr/bin/env bash
# drive.sh <repo-root> <lab-home> <records-per-task>
set -u
ROOT=$1 LAB=$2 K=$3
export FM_PENDING_REPLY_GRACE_SECS=0 FM_HOME=$LAB FM_CONFIG_OVERRIDE="$LAB/config" FM_PENDING_REPLY_NOW=2500
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
state="$LAB/state"; sends="$LAB/sends"; folds="$LAB/folds"; : > "$sends"; : > "$folds"
export sends
export FM_PENDING_REPLY_SEND_HOOK='printf "sent\\n" >> "$sends"'
touch "$LAB/config/wait-no-turns"
# A long-lived mate status log with many closed decisions and one open blocker.
{ for i in $(seq 1 400); do printf 'blocked [key=q%d]: Question %d?\n' $i $i; printf 'resolved [key=q%d]: Answer %d.\n' $i $i; done
  printf 'blocked [key=scope]: Choose a scope.\n'; } > "$state/waiting.status"
printf 'working: No decision is open.\n' > "$state/ready.status"
for n in $(seq 1 "$K"); do for task in waiting ready; do
  corr=$(fm_pending_reply_create "$LAB" "$state" "$task" "request $n for $task")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
done; done
orig=$(declare -f status_own_open_decisions); eval "${orig/status_own_open_decisions/real_decisions}"
status_own_open_decisions() { printf 'fold\n' >> "$folds"; real_decisions "$@"; }
phases() { for r in "$state/pending-replies"/*; do printf '%s=%s\n' "$(fm_pending_reply_get "$r" task_id)" "$(fm_pending_reply_get "$r" phase)"; done | sort | uniq -c; }
s=$(date +%s.%N); fm_pending_reply_tick "$state"; e=$(date +%s.%N)
echo "tick1: folds=$(wc -l < "$folds") sends=$(wc -l < "$sends") seconds=$(echo "$e - $s" | bc)"; phases
echo "-- captain answers the open blocker between ticks"
printf 'resolved [key=scope]: The scope is narrow.\n' >> "$state/waiting.status"
: > "$folds"; fm_pending_reply_tick "$state"
echo "tick2: folds=$(wc -l < "$folds") sends_total=$(wc -l < "$sends")"; phases
