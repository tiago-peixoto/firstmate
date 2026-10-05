#!/usr/bin/env bash
# Drives one marked request through a missed turn, one recovery, and a second
# missed turn, using the real library calls the watcher tick makes.
# Usage: escalate.sh <worktree> <lab-home> <summary>   -> prints corr id
set -u
ROOT=$1; home=$2; summary=$3; state="$home/state"
export FM_HOME="$home" FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_SEND_HOOK=true
. "$ROOT/bin/fm-marker-lib.sh"; . "$ROOT/bin/fm-pending-reply-lib.sh"
corr=$(fm_pending_reply_create "$home" "$state" mate "$summary")
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_mark_turn_completed "$state" "$corr" request
fm_pending_reply_send_recovery "$state" "$corr" >&2 || { echo recovery-failed >&2; exit 1; }
fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
fm_pending_reply_maybe_escalate "$state" "$corr" >&2 || { echo escalate-failed >&2; exit 1; }
printf '%s\n' "$corr"
