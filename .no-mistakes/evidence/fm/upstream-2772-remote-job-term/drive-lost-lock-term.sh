#!/usr/bin/env bash
# Usage: drive-lost-lock-term.sh <git-rev> <worktree>
# Live repro of #2772 against a real fm-remote-job-worker.sh --serve at <git-rev>:
# start worker, wait for heartbeat, remove worker.lock, confirm heartbeats continue,
# send TERM, and report whether the process survives and keeps heartbeating.
set -u
REV=$1; WT=$2
T=$(mktemp -d /tmp/fm-2772-live.XXXXXX)
R="$T/root"; H="$T/home"; S="$T/state"
mkdir -p "$R/bin" "$H"; chmod 700 "$H"
for f in fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh; do
  git -C "$WT" show "$REV:bin/$f" > "$R/bin/$f"
done
chmod +x "$R/bin"/*.sh; printf 'fixture\n' > "$R/AGENTS.md"
git -C "$R" init -q -b main; git -C "$R" -c user.email=t@e -c user.name=t add .; git -C "$R" -c user.email=t@e -c user.name=t commit -qm fx
ino() { stat -c %i "$1" 2>/dev/null; }
HOME="$H" FM_ROOT_OVERRIDE="$R" FM_REMOTE_JOB_STATE_ROOT="$S" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$R/bin/fm-remote-job-worker.sh" --serve > "$T/out" 2> "$T/err" &
P=$!
for _ in $(seq 1 300); do [ -f "$S/worker.ready" ] && break; sleep 0.05; done
echo "rev=$REV worker pid=$P ready=$( [ -f "$S/worker.ready" ] && echo yes || echo no) lock=$(ls -d "$S/worker.lock" 2>/dev/null || echo none)"
kill -STOP $P; rm -rf -- "$S/worker.lock"; kill -CONT $P
echo "removed worker.lock while worker stopped; lock now: $(ls -d "$S/worker.lock" 2>/dev/null || echo absent)"
b=$(ino "$S/worker.ready"); for _ in $(seq 1 100); do a=$(ino "$S/worker.ready"); [ -n "$a" ] && [ "$a" != "$b" ] && break; sleep 0.05; done
echo "heartbeat inode before=$b after=$a (unowned worker still heartbeating)"
echo "sending TERM to $P"; kill -TERM $P
for _ in $(seq 1 100); do kill -0 $P 2>/dev/null || break; sleep 0.05; done
if kill -0 $P 2>/dev/null; then
  s1=$(ino "$S/worker.ready"); sleep 1.5; s2=$(ino "$S/worker.ready")
  echo "RESULT: worker SURVIVED TERM (state=$(ps -o state= -p $P)); heartbeat inode $s1 -> $s2"
  kill -KILL $P; wait $P 2>/dev/null; rc=survived
else
  wait $P; rc=$?
  s1=$(ino "$S/worker.ready"); sleep 1.5; s2=$(ino "$S/worker.ready")
  echo "RESULT: worker EXITED on TERM with status $rc; heartbeat inode $s1 -> $s2 (unchanged=$([ "$s1" = "$s2" ] && echo yes || echo no)); lock=$(ls -d "$S/worker.lock" 2>/dev/null || echo absent)"
fi
echo "worker stderr:"; sed 's/^/  /' "$T/err"
pkill -KILL -f "$R/bin/fm-remote-job-worker.sh" 2>/dev/null
rm -rf "$T"
