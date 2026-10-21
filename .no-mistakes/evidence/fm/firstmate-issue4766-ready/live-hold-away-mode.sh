#!/usr/bin/env bash
# Live scenario: a lane held through the real bin/fm-captain-hold.sh while the
# captain is away (real bin/fm-afk-contract.sh record) is never rechecked by the
# real bin/fm-watch.sh, and the bounded recheck returns once the record is
# archived. Disposable FM_HOME, real tmux on a private socket, removed at exit.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-away.XXXXXX")
mkdir -p "$LAB/tmux"; export TMUX_TMPDIR="$LAB/tmux"
REAL_TMUX=$(command -v tmux); SOCK=fm-live-away
rtmux() { "$REAL_TMUX" -L "$SOCK" "$@"; }
rtmux new-session -d -s firstmate -n seed -x 120 -y 40 bash
WPID=
trap '[ -z "$WPID" ] || kill "$WPID" 2>/dev/null; rtmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
FAILS=0
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }
H="$LAB/home"; mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
printf '#!/usr/bin/env bash\nexport TMUX_TMPDIR=%q\nexec %q -L %q "$@"\n' "$LAB/tmux" "$REAL_TMUX" "$SOCK" > "$H/fakebin/tmux"; chmod +x "$H/fakebin/tmux"
printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/alarm-rec"; chmod +x "$H/fakebin/alarm-rec"
ID=t5; W="firstmate:fm-$ID"; KEY=$(printf '%s' "$W" | tr ':/.' '___')
(cd "$H" && tasks-axi add "$ID" "Ship the away sample" --kind ship --repo sample >/dev/null) || bad "tasks-axi add"
mkdir -p "$H/wt-$ID"; rtmux new-window -d -t firstmate -n "fm-$ID" bash
printf 'window=%s\nworktree=%s/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=ship\nmode=ship\nspawn_gen=fixture-%s\n' "$W" "$H" "$ID" "$H" "$ID" > "$H/state/$ID.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$H/state" "$ID"); "$ROOT/bin/fm-busy-event.sh" apply "$H/state" "$ID" idle --gen "$gen" --source claude-hook --event stop >/dev/null
printf 'done: PR https://example.test/pull/5 checks green\n' > "$H/state/$ID.status"
FM_STATE_OVERRIDE="$H/state" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$H/state" "$H/state/$ID.status" || bad "prime baseline"
PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
  "$ROOT/bin/fm-captain-hold.sh" hold "$ID" --reason "merge approval while the captain is away" >/dev/null || bad "hold failed"
touch -m -d "@$(( $(date +%s) - 500 ))" "$H/state/$ID.status"   # hold well past the 240s recheck cadence below
echo "--- status log:"; cat "$H/state/$ID.status"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-afk-contract.sh" enter --words 'back tomorrow' >/dev/null 2>&1 || bad "could not write the away-posture record"
check '[ -f "$H/state/.afk-contract" ]' "away-posture record written by fm-afk-contract.sh enter"
watch_bg() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_WEDGE_ALARM_EXEC="$H/fakebin/alarm-rec" FM_PAUSE_RESURFACE_SECS=240 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$1" 2> "$1.err" & WPID=$!; }
wait_cycles() { local beat="$H/state/.last-watcher-beat" seen=0 last="" now i=0; while [ $i -lt $(( $3 * 10 )) ]; do kill -0 "$1" 2>/dev/null || return 1; now=$(stat -c %Y "$beat" 2>/dev/null || true); if [ -n "$now" ] && [ "$now" != "$last" ]; then last=$now; seen=$((seen+1)); [ $seen -gt "$2" ] && return 0; fi; sleep 0.1; i=$((i+1)); done; return 2; }
wait_exit() { local i=0; while [ $i -lt $(( $2 * 10 )) ]; do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }; sleep 0.1; i=$((i+1)); done; return 1; }
ack_cycle() {  # acknowledge the stopped watcher's episode through the real drain, as firstmate's turn would
  local err="$H/drain.err" seq gen
  FM_ROOT_OVERRIDE="$LAB/noroot" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" PATH="$H/fakebin:$PATH" "$ROOT/bin/fm-wake-drain.sh" > "$H/drain.out" 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || { cat "$err"; return 1; }
  FM_ROOT_OVERRIDE="$LAB/noroot" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" PATH="$H/fakebin:$PATH" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
mkdir -p "$LAB/noroot"
echo "--- phase A: away record present; held lane past the cadence"
watch_bg "$H/a.out"; RC=0; wait_cycles "$WPID" 5 60 || RC=$?
echo "watcher output:"; cat "$H/a.out"; grep -v '^$' "$H/a.out.err" | head -3
check '[ "$RC" = 0 ]' "watcher stayed alive through 5 poll cycles (rc=$RC)"
check '[ ! -s "$H/a.out" ]' "no recheck printed while the away-posture record exists"
check '[ ! -s "$H/state/.wake-queue" ]' "no wake queued while away"
check '[ ! -e "$H/state/.paused-resurfaced-$KEY" ]' "no recheck throttle armed"
echo "triage log:"; grep -F "$W" "$H/state/.watch-triage.log" | tail -3
check 'grep -Fq "never rechecked while the away-posture record exists" "$H/state/.watch-triage.log"' "triage log names the away-posture rule for the held lane"
kill "$WPID" 2>/dev/null; wait_exit "$WPID" 10 || kill -9 "$WPID"; WPID=
ack_cycle || bad "could not acknowledge the phase-A stop through fm-wake-drain.sh"
echo "--- phase B: captain returns (record archived); the bounded recheck comes back"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 || bad "could not archive the away record"
for attempt in 1 2; do
  watch_bg "$H/b.out"; if wait_exit "$WPID" 60; then WPID=; else bad "watcher did not surface the recheck within 60s"; break; fi
  if grep -Fxq "check: rearm-resurface" "$H/b.out"; then
    echo "(attempt $attempt: the successor first announced its re-arm check; acknowledging it as firstmate would)"; cat "$H/b.out"
    ack_cycle || bad "could not acknowledge the re-arm check"
    continue
  fi
  break
done
echo "watcher output:"; cat "$H/b.out"; grep -v '^$' "$H/b.out.err" | head -3
check 'grep -Fq "stale: $W" "$H/b.out"' "the recheck surfaced for $W"
check 'grep -Fqi "captain" "$H/b.out"' "the recheck names the captain, not an external wait"
check '! grep -Fq "possible wedge" "$H/b.out"' "no wedge label on the held lane"
echo; echo "TOTAL FAILS: $FAILS"; exit $FAILS
