#!/usr/bin/env bash
# One real watcher inbox check in a fresh process against the lab home over
# the private fm-lab tmux socket. Usage: lab-check.sh <lab> <label>
set -u
LAB=$1; label=$2
ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5GRRMHRYG31NEF21A4KBD99
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
TMUX="$SOCK,0,0" FM_HOME="$LAB" FM_TASK_INBOX_GRACE_SECS=0 \
  bash -c '. "$1" && inbox_steer_check primary:fm-t1 t1' _ "$ROOT/bin/fm-watch.sh" > "$LAB/check.out" 2>&1
rc=$?
inbox="$LAB/state/t1.inbox"
printf '[%s] check rc=%s | inbox root: %s | .read: %s | .busy-state: %s | wake-queue lines: %s\n' \
  "$label" "$rc" \
  "$(cd "$inbox" 2>/dev/null && ls *.msg 2>/dev/null | tr '\n' ' ')" \
  "$(ls "$inbox/.read" 2>/dev/null | tr '\n' ' ')" \
  "$(cat "$inbox/.busy-state" 2>/dev/null | tr '\t' ':' || true)" \
  "$(wc -l < "$LAB/state/.wake-queue" 2>/dev/null || echo 0)"
[ ! -s "$LAB/check.out" ] || sed 's/^/    check stderr: /' "$LAB/check.out"
