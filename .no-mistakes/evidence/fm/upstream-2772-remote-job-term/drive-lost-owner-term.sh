#!/usr/bin/env bash
# Manual driver: runs the real fm-remote-job-worker.sh --serve and sends TERM
# after it loses ownership. Usage: drive-lost-owner-term.sh <worker-src-dir> <label>
set -u
SRC=$1 LABEL=$2
T=$(mktemp -d /tmp/fm-lost-owner.XXXXXX)
R=$T/root; mkdir -p $R/bin $T/home; chmod 700 $T/home
cp "$SRC/fm-remote-job-lib.sh" "$SRC/fm-remote-job-worker.sh" "$SRC/fm-remote-delta-read.sh" $R/bin/
printf 'fixture\n' > $R/AGENTS.md
PIDS=()
cleanup(){ for p in "${PIDS[@]}"; do pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT
git -C $R init -q -b main; git -C $R -c user.email=t@e -c user.name=t add .; git -C $R -c user.email=t@e -c user.name=t commit -qm fixture
start_worker(){ HOME=$T/home FM_ROOT_OVERRIDE=$R FM_REMOTE_JOB_STATE_ROOT=$1 FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux $R/bin/fm-remote-job-worker.sh --serve >$1.out 2>$1.err & }
waitfor(){ for _ in $(seq 1 200); do eval "$1" && return 0; sleep 0.05; done; return 1; }
alive(){ kill -0 $1 2>/dev/null && echo ALIVE || echo EXITED; }
echo "=== [$LABEL] Scenario A: lock directory removed, then TERM ==="
S=$T/a; start_worker $S; W=$!; PIDS+=($W)
waitfor "[ -f $S/worker.ready ]"; echo "worker pid=$W ready; lock pid=$(cat $S/worker.lock/pid)"
kill -STOP $W; rm -rf $S/worker.lock; kill -CONT $W; echo "removed worker.lock (ownership lost)"
sleep 1; echo "before TERM: worker $(alive $W)"
kill -TERM $W; sleep 3; echo "3s after TERM: worker $(alive $W)"
echo "lock dir after TERM: $([ -e $S/worker.lock ] && echo present || echo absent)"
echo
echo "=== [$LABEL] Scenario B: replacement owns lock and has a quarantine, then TERM old worker ==="
S=$T/b; start_worker $S; OLD=$!; PIDS+=($OLD)
waitfor "[ -f $S/worker.ready ]"; echo "old worker pid=$OLD ready"
kill -STOP $OLD; rm -rf $S/worker.lock
start_worker $S; NEW=$!; PIDS+=($NEW)
waitfor "[ \"\$(cat $S/worker.lock/pid 2>/dev/null)\" = $NEW ]"; echo "replacement pid=$NEW owns lock (pid file=$(cat $S/worker.lock/pid))"
printf 'replacement guard\n' > $S/worker.lock/quarantine; INO=$(stat -c %i $S/worker.lock/quarantine)
echo "replacement quarantine written, inode=$INO"
kill -TERM $OLD; kill -CONT $OLD; sleep 3
echo "old worker: $(alive $OLD); replacement: $(alive $NEW)"
echo "lock pid now: $(cat $S/worker.lock/pid 2>/dev/null || echo MISSING)"
if [ -f $S/worker.lock/quarantine ]; then echo "quarantine: '$(cat $S/worker.lock/quarantine)' inode=$(stat -c %i $S/worker.lock/quarantine) (orig $INO)"; else echo "quarantine: REMOVED"; fi
echo "old worker stderr: $(cat $S.err 2>/dev/null | tail -2)"
