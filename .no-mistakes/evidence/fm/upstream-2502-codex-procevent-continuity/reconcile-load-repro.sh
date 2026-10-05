#!/usr/bin/env bash
# Repeats the deterministic test's setup (register a single-shot source, then
# reconcile) under CPU load, and reports each reconcile that exits non-zero.
ROOT=$1; ROUNDS=${2:-30}; LOAD=${3:-0}; CONFIRM=${4:-}
. "$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile-flake)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
[ -z "$CONFIRM" ] || export FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=$CONFIRM
burners=()
for i in $(seq 1 "$LOAD"); do ( while :; do :; done ) & burners+=($!); done
bad=0
for r in $(seq 1 "$ROUNDS"); do
  H="$TMP_ROOT/h$r"; mkdir -p "$H/bin" "$H/state"; git init -q "$H"; : > "$H/AGENTS.md"
  printf '#!/bin/sh\nprintf x >> %s\n' "$TMP_ROOT/log$r" > "$TMP_ROOT/src$r.sh"; chmod +x "$TMP_ROOT/src$r.sh"
  fm_test_track_procevent_home "$H" "$FM_PROCEVENT_CLAIM_ROOT"
  FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" register lavish "shot$r" -- "$TMP_ROOT/src$r.sh" >/dev/null || echo "register fail $r"
  out=$(FM_HOME="$H" "$ROOT/bin/fm-procevent.sh" reconcile 2>&1); rc=$?
  [ $rc -eq 0 ] || { bad=$((bad+1)); echo "round $r rc=$rc: $out"; }
done
kill "${burners[@]}" 2>/dev/null
echo "load=$LOAD busy loops, confirm window=${CONFIRM:-default 3}s: reconcile failures $bad of $ROUNDS"
