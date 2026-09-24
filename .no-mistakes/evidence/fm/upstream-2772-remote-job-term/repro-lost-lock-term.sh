#!/usr/bin/env bash
# Usage: repro-lost-lock-term.sh <worker-source-dir-with-bin/> <label>
# Starts a real remote-job worker, removes its ownership lock (lost ownership),
# sends TERM, and reports whether the worker exits. Then, in a second run, lets a
# replacement own the lock with a quarantine and checks the ousted worker's TERM
# leaves it untouched.
set -u
SRC=$1; LABEL=$2
T=$(mktemp -d); trap 'kill -KILL $W $R 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/root/bin" "$T/home"; chmod 700 "$T/home"
cp "$SRC/bin/fm-remote-job-lib.sh" "$SRC/bin/fm-remote-job-worker.sh" "$SRC/bin/fm-remote-delta-read.sh" "$T/root/bin/"
printf "fixture\n" > "$T/root/AGENTS.md"; git -C "$T/root" init -q; git -C "$T/root" add -A; git -C "$T/root" -c user.name=t -c user.email=t@t commit -qm init
start() { HOME="$T/home" FM_ROOT_OVERRIDE="$T/root" FM_REMOTE_JOB_STATE_ROOT="$1" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$T/root/bin/fm-remote-job-worker.sh" --serve >"$1.out" 2>"$1.err" & }
waitfile() { for _ in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
echo "== [$LABEL] scenario A: lock removed, then TERM"
S="$T/a"; start "$S"; W=$!
waitfile "$S/worker.ready" && echo "worker $W ready; lock owner pid=$(cat $S/worker.lock/pid)"
rm -rf -- "$S/worker.lock"; echo "removed worker.lock (ownership lost)"
sleep 0.5; kill -TERM $W; echo "sent TERM to $W"
for _ in $(seq 1 60); do kill -0 $W 2>/dev/null || break; sleep 0.05; done
if kill -0 $W 2>/dev/null; then echo "RESULT A: worker $W STILL ALIVE 3s after TERM (TERM swallowed)"; kill -KILL $W; else wait $W; echo "RESULT A: worker exited rc=$? after TERM"; fi
echo "stderr: $(cat $S.err)"
echo "== [$LABEL] scenario B: replacement owns lock + quarantine, ousted worker gets TERM"
S="$T/b"; start "$S"; W=$!
waitfile "$S/worker.ready"
kill -STOP $W; rm -rf -- "$S/worker.lock"; start "$S"; R=$!
for _ in $(seq 1 300); do [ "$(cat $S/worker.lock/pid 2>/dev/null)" = "$R" ] && break; sleep 0.05; done
echo "old=$W replacement=$R lock pid=$(cat $S/worker.lock/pid)"
printf 'replacement guard\n' > "$S/worker.lock/quarantine"; I0=$(stat -c %i "$S/worker.lock/quarantine")
kill -TERM $W; kill -CONT $W
for _ in $(seq 1 60); do kill -0 $W 2>/dev/null || break; sleep 0.05; done
if kill -0 $W 2>/dev/null; then echo "RESULT B: old worker STILL ALIVE after TERM"; kill -KILL $W; else wait $W; echo "RESULT B: old worker exited rc=$?"; fi
echo "replacement alive: $(kill -0 $R 2>/dev/null && echo yes || echo no); lock pid=$(cat $S/worker.lock/pid 2>/dev/null)"
if [ -f "$S/worker.lock/quarantine" ]; then echo "quarantine content='$(cat $S/worker.lock/quarantine)' inode same: $([ "$(stat -c %i $S/worker.lock/quarantine)" = "$I0" ] && echo yes || echo no)"; else echo "quarantine: REMOVED"; fi
kill -TERM $R; for _ in $(seq 1 60); do kill -0 $R 2>/dev/null || break; sleep 0.05; done; wait $R 2>/dev/null
