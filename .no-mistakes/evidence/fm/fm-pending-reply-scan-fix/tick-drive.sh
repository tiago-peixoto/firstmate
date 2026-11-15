#!/usr/bin/env bash
# Usage: tick-drive.sh <bin-root> <n-requests> <history-lines>
# Drives the watcher's fm_pending_reply_tick on a disposable home.
set -u
root=$1 n=$2 lines=$3
. "$root/bin/fm-pending-reply-lib.sh"
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-prt.XXXXXX"); trap 'rm -rf "$home"' EXIT
mkdir -p "$home/state" "$home/config"
export FM_HOME=$home STATE=$home/state CONFIG=$home/config FM_PENDING_REPLY_NOW=1000
for ((i=0; i<n; i++)); do
  corr=$(fm_pending_reply_create "$home" "$home/state" mate 'Synthetic unanswered request')
  fm_pending_reply_mark_delivered "$home/state" "$corr"
  printf '%s\n' "$corr" >> "$home/ids"
done
awk -v n="$lines" 'BEGIN { for (i=0; i<n; i++) printf "working: unrelated history %0444d\n", i }' > "$home/state/mate.status"
first=$(head -1 "$home/ids"); second=$(sed -n 2p "$home/ids")
# adversarial near-miss tokens for the second request, then a real unterminated reply for the first
printf 'done [corr=%sff]: wrong token\ndone [xcorr=%s]: wrong prefix\n' "$second" "$second" >> "$home/state/mate.status"
printf 'done [corr=%s]: report arrived' "$first" >> "$home/state/mate.status"
wc -lc < "$home/state/mate.status" | awk '{print "status_file lines="$1" bytes="$2}'
TIMEFORMAT='tick_seconds=%3R'
time fm_pending_reply_tick "$home/state"
while IFS= read -r corr; do
  p=$(fm_pending_reply_get "$(fm_pending_reply_path "$home/state" "$corr")" phase)
  [ "$corr" = "$first" ] && tag=first-replied || { [ "$corr" = "$second" ] && tag=second-nearmiss || tag=other; }
  printf '%s %s\n' "$tag" "$p"
done < "$home/ids" | sort | uniq -c
