. /tmp/fm-live/common.sh
nap() { perl -e 'select(undef,undef,undef,$ARGV[0])' "$1"; }
ROOTDIR=$(mktemp -d /tmp/fm-live/watch.XXXXXX)
rc=0
# Every case below gives the watcher POSITIVE evidence the crew is still working,
# so a status line only wakes the captain when the classifier judges it
# captain-relevant - the exact decision the emission-time tag must not change.
WORKING='state: working · source: run-step · validating (running)'

run_case() { # <name> <status-line> <captain-re> <expect surface|absorb>
  local name=$1 line=$2 re=$3 expect=$4 dir state fb pid i=0 exited=0
  dir="$ROOTDIR/$name"; state="$dir/state"; mkdir -p "$state" "$dir/data"
  fb=$(make_fakebin "$dir")
  write_meta "$state/task.meta" "window=sess:fm-task" "kind=ship" "mode=no-mistakes"
  printf '%s\n' "$line" > "$state/task.status"
  hr "$name"
  printf 'FM_CAPTAIN_RE   : %s\n' "${re:-<default vocabulary>}"
  printf 'crew evidence   : %s\n' "$WORKING"
  printf 'status event    : %s\n' "$line"
  printf 'expectation     : %s\n' "$expect"
  if [ -n "$re" ]; then set -- FM_CAPTAIN_RE="$re"; else set --; fi
  env PATH="$fb:$PATH" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" \
    FM_CREW_STATE_BIN="$fb/fm-crew-state.sh" "FM_FAKE_CREW_STATE=$WORKING" \
    "$@" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$BIN/fm-watch.sh" > "$dir/watch.out" 2>"$dir/watch.err" &
  pid=$!
  while [ "$i" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || { exited=1; break; }
    nap 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  printf 'watcher exited  : %s (after %ss)\n' "$exited" "$(echo "$i" | awk '{printf "%.1f", $1/10}')"
  printf 'watcher stdout  : %s\n' "$(cat "$dir/watch.out")"
  printf 'wake queue      : %s\n' "$(cat "$state/.wake-queue" 2>/dev/null || echo '<empty>')"
  if [ "$expect" = surface ]; then
    if [ "$exited" = 1 ] && [ -s "$state/.wake-queue" ]; then
      echo "  ok   the captain was woken for this event"
      printf 'captain digest  :\n'
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$dir" "$BIN/fm-wake-drain.sh" 2>/dev/null \
        | sed -n '1,6p' | sed 's/^/    /'
    else
      echo "  FAIL the event never reached the captain"; rc=1
    fi
  else
    if [ "$exited" = 0 ] && [ ! -s "$state/.wake-queue" ]; then
      echo "  ok   absorbed: no wake, no queue entry"
    else
      echo "  FAIL a non-captain-relevant event woke the captain"; rc=1
    fi
  fi
  printf 'stored bytes    : %s\n' "$(cat "$state/task.status")"
}

NOW=$(date +%s)
run_case stamped-blocked-custom-vocabulary "blocked [at=$NOW]: pipeline daemon socket refused" \
  'done:|needs-decision:|blocked:|failed:' surface
run_case stamped-blocked-outside-custom-vocabulary "blocked [at=$NOW]: pipeline daemon socket refused" \
  'done:' absorb
run_case stamped-working-is-not-actionable "working [at=$NOW]: rebased onto merged #76" \
  '' absorb
run_case malformed-stamp-default-vocabulary 'needs-decision [at=17:00]: choose REST or gRPC' \
  '' surface
[ "$rc" = 0 ] && echo "RESULT S4/S5: PASS" || echo "RESULT S4/S5: FAIL"
exit $rc
