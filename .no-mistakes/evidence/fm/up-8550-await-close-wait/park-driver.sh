#!/usr/bin/env bash
# Independent park driver: starts the real bin/fm-supervision-host.sh from <root>
# in a disposable fixture home, then measures, from the kernel's /proc counters
# (not from command shims), whether the parked host reaps any child in a
# 6-second window after its arm reported. Then closes the arm and prints the
# host's exit code and output.
# usage: park-driver.sh <root> <label> [break-mkfifo]
set -u
ROOT_ARG=$1; LABEL=$2; BREAK=${3:-}
. "$ROOT_ARG/tests/supervision-host-helpers.sh"
drive() {
  local home host a b kids t0 t1
  home=$(make_home "drv-$LABEL" attended)
  if [ -n "$BREAK" ]; then printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/mkfifo"; chmod +x "$home/fakebin/mkfifo"; fi
  start_host "$home"
  wait_until 150 grep -qs '^watcher: started ' "$home/host.out" || fail "$LABEL: arm never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  sleep 2.5
  # /proc/<pid>/stat field 11 = cminflt: minor faults of children the process
  # has waited for. It rises whenever the host reaps any child process.
  a=$(awk '{ sub(/^.*\) /, ""); print $9 }' "/proc/$host/stat")
  kids=0; t0=$(date +%s.%N)
  for _ in $(seq 60); do
    [ -z "$(cat "/proc/$host/task/$host/children" 2>/dev/null | tr ' ' '\n' | while read -r c; do [ -n "$c" ] && [ "$(cat /proc/$c/comm 2>/dev/null)" = sleep ] && echo "$c"; done)" ] || kids=$((kids + 1))
    sleep 0.1
  done
  t1=$(date +%s.%N)
  b=$(awk '{ sub(/^.*\) /, ""); print $9 }' "/proc/$host/stat")
  printf '%s: bash=%s window=%.1fs reaped-child-minor-faults before=%s after=%s delta=%s samples-with-live-sleep-child=%s/60 host-open-fifo=%s\n' \
    "$LABEL" "$(bash -c 'echo $BASH_VERSION')" "$(echo "$t1 - $t0" | bc)" "$a" "$b" "$((b - a))" "$kids" \
    "$(ls -l "/proc/$host/fd" 2>/dev/null | grep -c 'fm-supervision-host-probe')"
  t0=$(date +%s.%N)
  append_status "$home" 'which export format?' needs-decision
  wait_until_deadline 60 host_exited "$home" || fail "$LABEL: close did not reach main"
  t1=$(date +%s.%N)
  printf '%s: close delivered in %.1fs host-exit-code=%s\n' "$LABEL" "$(echo "$t1 - $t0" | bc)" "$(cat "$home/host.rc")"
  printf '%s: host output:\n' "$LABEL"; sed "s|$home|<home>|g; s/^/    /" "$home/host.out"
  printf '%s: ledger:\n' "$LABEL"; cut -f3- "$home/state/.supervision-host.log" | sed 's/^/    /'
  printf '%s: leftover probe dirs: %s\n' "$LABEL" "$(ls -d "${TMPDIR:-/tmp}"/fm-supervision-host-probe.* 2>/dev/null | wc -l)"
  stop_home_processes "$home"
  pass "$LABEL driven"
}
fm_test_run drive
