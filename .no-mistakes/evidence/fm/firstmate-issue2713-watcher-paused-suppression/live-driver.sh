#!/usr/bin/env bash
# Live driver: re-arms the real bin/fm-watch.sh in a lab home, as a primary does,
# and records every wake with its elapsed time. Runs inside a lab tmux pane so the
# watcher inherits $TMUX for the private fm-lab socket.
# usage: live-driver.sh <repo-root> <lab-home> <timeline-out> <duration-secs>
set -u
ROOT=$1; LAB=$2; OUT=$3; DUR=$4
STATE="$LAB/state"
start=$(date +%s)
el() { echo $(( $(date +%s) - start )); }
log() { printf 't+%03ss %s\n' "$(el)" "$*" >> "$OUT"; }
log "driver start root=$ROOT cadence=${FM_PAUSE_RESURFACE_SECS}s poll=${FM_POLL}s"
while [ "$(el)" -lt "$DUR" ]; do
  left=$(( DUR - $(el) ))
  wout=$(timeout "$left" "$ROOT/bin/fm-watch.sh" 2>&1); rc=$?
  [ "$rc" -eq 124 ] && { log "watcher still blocking at end of window (no wake)"; break; }
  while IFS= read -r l; do [ -z "$l" ] || log "WAKE rc=$rc: $l"; done <<EOF
$wout
EOF
  err="$STATE/.drv-drain.err"
  "$ROOT/bin/fm-wake-drain.sh" > "$STATE/.drv-drain.out" 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err" | tail -1)
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err" | tail -1)
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  else
    log "drain gave no ack token: $(head -3 "$err" | tr '\n' ' ')"; sleep 1
  fi
done
log "driver end"
touch "$OUT.done"
