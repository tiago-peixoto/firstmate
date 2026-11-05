#!/usr/bin/env bash
# Times each checkpoint phase of the watcher movement scenario, reusing the
# behavior test's own fixture helpers (fake forge, quiet checkpoint clock).
set -u
ROOT={run-worktree}
W=$(mktemp -d /tmp/fm-watcher-timing.XXXXXX)
sed -e "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. $ROOT/tests/lib.sh|" \
    -e 's/^for test_name in .*; do$/for test_name in; do/' "$ROOT/tests/fm-contributions.test.sh" > "$W/helpers.sh"
. "$W/helpers.sh"
rm -rf "$W"
phase() { # label seconds [env...]
  local label=$1 secs=$2; shift 2; local t0 t1 rc=0
  t0=$(date +%s.%N)
  with_home "$home" env "$@" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$secs" > "$home/$label.out" 2> "$home/$label.err" || rc=$?
  t1=$(date +%s.%N)
  printf '\n## %s (--seconds %s): rc=%s elapsed=%.1fs wakes=%s\n' "$label" "$secs" "$rc" "$(echo "$t1 - $t0" | bc)" "$(queued_wakes "$home")"
  printf -- '--- stdout\n'; cat "$home/$label.out"; printf -- '--- stderr\n'; cat "$home/$label.err"
}
home=$(new_home watcher-timing); forge_home "$home"; quiet_checkpoint_clock "$home"
with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null || fail 'register failed'
printf 'registered checks: %s\n' "$(ls "$home/state/" | grep '\.check\.sh$' | tr '\n' ' ')"
phase quiet 60 PATH="$home/quietbin:$home/fakebin:$PATH"
printf '\n$ forge: head -> %s\n' "$HEAD_B"; printf '%s\n' "$HEAD_B" > "$home/forge/head"
phase movement 30 FM_WATCH_HANDLING_SUCCESSOR=1
printf '\n$ fm-contributions.sh pending\n'; with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -c '.[] | {type,body}'
phase repeat 2 FM_WATCH_HANDLING_SUCCESSOR=1
