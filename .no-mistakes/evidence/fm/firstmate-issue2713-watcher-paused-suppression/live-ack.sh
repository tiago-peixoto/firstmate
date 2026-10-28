#!/usr/bin/env bash
# Acknowledge the queued wake the way the primary does after reading it.
set -u
ROOT=$1; LAB=$2
err=$(FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
gen=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p')
[ -n "$seq" ] && [ -n "$gen" ] || { echo "ack: nothing to acknowledge ($err)"; exit 1; }
FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null && echo "ack: acknowledged through sequence $seq"
