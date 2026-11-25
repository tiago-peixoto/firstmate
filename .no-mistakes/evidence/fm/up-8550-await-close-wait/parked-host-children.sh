#!/usr/bin/env bash
# Starts the real supervision host in a fixture home, waits until its arm has
# reported, then reads the kernel's own accounting for the parked host over a
# 6-second window: /proc/<host>/stat field 11 (cminflt, page faults of reaped
# children) grows whenever the host starts and reaps a child. Then a real
# status append closes the arm and the host hands the close to main.
# usage: parked-host-children.sh <repo-root> [host-script]
set -u
. "$1/tests/supervision-host-helpers.sh"
[ -z "${2:-}" ] || HOST=$2
echo "host script: $HOST"
home=$(make_home kernel-count attended)
start_host "$home"
wait_until 150 grep -qs '^watcher: started ' "$home/host.out" || fail "arm never reported"
host_pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
cminflt() { local s; s=$(< "/proc/$host_pid/stat"); s=${s##*) }; set -- $s; echo "$9"; }
sleep 2.5
before=$(cminflt); sleep 6; after=$(cminflt)
echo "parked 6s: reaped-child page faults before=$before after=$after delta=$((after - before))"
append_status "$home" 'which export format?' needs-decision
wait_until_deadline 60 host_exited "$home" || fail "close did not reach main"
echo "host exit code after the close: $(cat "$home/host.rc")"
echo "--- host output delivered to main ---"; cat "$home/host.out"
echo "--- ledger ---"; cat "$home/state/.supervision-host.log"
stop_home_processes "$home"
