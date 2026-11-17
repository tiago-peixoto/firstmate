#!/usr/bin/env bash
# measure.sh <tree> <label> <window-seconds> <outdir>
# Starts the real fm-supervision-host.sh park under strace -f and counts the
# processes the parked host creates (arm subtree excluded) in a fixed window.
TREE=$1 LABEL=$2 WINDOW=$3 OUT=$4
. "$TREE/tests/supervision-host-helpers.sh"
home=$(make_home measure attended)
TRACE="$OUT/$LABEL.strace"
FM_HOME="$home" FM_CREW_STATE_BIN="$home/fakebin/fm-crew-state.sh" PATH="$home/fakebin:$PATH" \
  MIRROR_ROOT="$MIRROR_ROOT" strace -f -qq -ttt -e trace=clone,clone3,fork,vfork,execve -o "$TRACE" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "$$" >> "$FM_HOME/claude-pids"
    rm -f "$FM_HOME/host.rc"
    for seed in "$FM_HOME"/mirror-seed.*; do
      [ -f "$seed" ] || continue
      FM_ROOT_OVERRIDE="$MIRROR_ROOT" "$MIRROR_ROOT/bin/fm-host-mirror.sh" hook claude < "$seed"
    done
    "$0" park "$@" > "$FM_HOME/host.out" 2>&1
    printf "%s\n" "$?" > "$FM_HOME/host.rc"
  ' "$HOST" 2>> "$home/claude.err" &
wait_until 300 grep -qs '^watcher: started ' "$home/host.out" || { echo "$LABEL: arm never reported"; cat "$home/host.out" "$home/claude.err"; exit 1; }
sleep 4
cp "$home/state/.supervision-host" "$OUT/$LABEL.record"
t0=$(date +%s.%N); sleep "$WINDOW"; t1=$(date +%s.%N)
append_status "$home" 'which export format?' needs-decision
wait_until_deadline 90 host_exited "$home" || echo "$LABEL: host did not exit"
cp "$home/host.out" "$OUT/$LABEL.host.out"; cp "$home/host.rc" "$OUT/$LABEL.host.rc"
stop_home_processes "$home"
wait
python3 -I - "$TRACE" "$OUT/$LABEL.record" "$t0" "$t1" "$LABEL" <<'PY'
import re,sys,collections
trace,record,t0,t1,label=sys.argv[1:]; t0=float(t0); t1=float(t1)
host=None; arms=set()
for l in open(record):
    f=l.rstrip('\n').split('\t')
    if f[0]=='host': host=f[1]
    if f[0]=='arm': arms.add(f[1])
parent={}; born={}; exe={}
for l in open(trace):
    m=re.match(r'(\d+) +(\d+\.\d+) (.*)',l)
    if not m: continue
    pid,ts,rest=m.group(1),float(m.group(2)),m.group(3)
    c=re.search(r'(?:clone3?|fork|vfork).*\) = (\d+)$',rest)
    if c: parent[c.group(1)]=pid; born[c.group(1)]=ts; continue
    e=re.match(r'execve\("([^"]+)", \[([^\]]*)\]',rest)
    if e and rest.rstrip().endswith('= 0'): exe.setdefault(pid,[]).append(e.group(1).rsplit('/',1)[-1]+' '+' '.join(a.strip('"') for a in e.group(2).split(', ')[1:3]))
def from_host(p):
    while p in parent:
        p=parent[p]
        if p in arms: return False
        if p==host: return True
    return False
n=0; kinds=collections.Counter()
for p,ts in born.items():
    if t0<=ts<=t1 and p not in arms and from_host(p):
        n+=1; kinds[(exe.get(p) or ['(subshell, no exec)'])[-1]]+=1
w=t1-t0
print(f"{label}: host pid {host}, window {w:.1f}s, processes started by the parked host: {n} -> {n*3600/w:.0f} per hour")
for k,v in kinds.most_common(): print(f"    {v:5d}  {k}")
PY
