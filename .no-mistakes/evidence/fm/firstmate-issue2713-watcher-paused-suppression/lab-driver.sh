# Lab driver for live fm-watch.sh rounds. Source with LAB and ROOT set.
STATE="$LAB/state"; EV=/home/firstmate/.no-mistakes/evidence/01M64TN9WMHV1SRRVBB5ZYMKDW
T() { TMUX_TMPDIR="$LAB/tmux" tmux "$@"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$EV/live-transcript.log"; }
beat_mtime() { stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null || true; }
# watch_round <exit|absorb> <cycles> [VAR=val ...] : run one watcher round.
# exit: expect the watcher to surface a wake and exit (prints its stdout).
# absorb: expect it to survive <cycles> whole poll cycles, then TERM it.
watch_round() {
  local mode=$1 cycles=$2; shift 2
  local out="$LAB/watch.out" pid i first now seen=0
  : > "$out"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_CREW_STATE_NO_FORGE=1 \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$ROOT/bin/fm-watch.sh" > "$out" 2> "$LAB/watch.err" &
  pid=$!
  if [ "$mode" = exit ]; then
    i=0; while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; wait "$pid" 2>/dev/null; log "watch_round exit: watcher did NOT exit in 15s; stdout=[$(cat "$out")]"; return 1; fi
    wait "$pid"; log "watch_round exit: watcher exited; stdout=[$(cat "$out")]"; return 0
  fi
  rm -f "$STATE/.last-watcher-beat"
  while [ "$seen" -lt "$cycles" ]; do
    i=0; first=$(beat_mtime)
    while [ "$i" -lt 300 ]; do
      kill -0 "$pid" 2>/dev/null || { wait "$pid"; log "watch_round absorb: watcher EXITED early after $seen cycles; stdout=[$(cat "$out")]"; return 1; }
      now=$(beat_mtime); if [ -n "$now" ] && [ "$now" != "$first" ]; then break; fi
      sleep 0.1; i=$((i+1))
    done
    [ "$i" -lt 300 ] || { kill "$pid"; wait "$pid" 2>/dev/null; log "watch_round absorb: no poll beat in 30s"; return 1; }
    seen=$((seen+1))
  done
  kill "$pid"; wait "$pid" 2>/dev/null
  log "watch_round absorb: watcher survived $seen poll cycles silently; stdout=[$(cat "$out")]"
  return 0
}
ack() {
  local err="$LAB/drain.err" seq gen
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$err" || true
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  log "drain output: $(cat "$LAB/drain.out" | tr '\n' '|')"
  [ -n "$seq" ] && [ -n "$gen" ] || { log "ack: nothing to ack"; return 1; }
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && log "acked through $seq"
}
dump() {
  local key=$1
  log "wake-queue stale rows: $(awk -F '\t' '$3=="stale"{print "#"$2" "$5}' "$STATE/.wake-queue" 2>/dev/null | tr '\n' '|')"
  log "markers: $(cd "$STATE" && ls -a | grep -E "^\.(stale|stale-since|paused|paused-rechecked|paused-resurfaced|count|hash|wedge)[^ ]*-$key$" | tr '\n' ' ') paused-resurfaced=[$(cat "$STATE/.paused-resurfaced-$key" 2>/dev/null)]"
}
reset_task() {  # <task> <key>
  rm -f "$STATE"/.*-"$2" "$STATE/.seen-$1_status" "$STATE/$1.status" "$STATE/.last-watcher-beat"
}
# warm_to_count <key> <n> [VAR=val...]: run the watcher until its own bookkeeping
# records <n> consecutive same-hash polls for <key>, then stop it at once.
warm_to_count() {
  local key=$1 n=$2 pid i=0; shift 2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_CREW_STATE_NO_FORGE=1 \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 "$@" "$ROOT/bin/fm-watch.sh" > "$LAB/warm.out" 2>&1 &
  pid=$!
  while [ "$i" -lt 400 ]; do
    kill -0 "$pid" 2>/dev/null || { log "warm_to_count: watcher exited early: $(cat "$LAB/warm.out")"; return 1; }
    [ "$(cat "$STATE/.count-$key" 2>/dev/null)" = "$n" ] && break
    sleep 0.05; i=$((i+1))
  done
  kill "$pid"; wait "$pid" 2>/dev/null
  log "warm_to_count: watcher-written hash=[$(cat "$STATE/.hash-$key")] count=[$(cat "$STATE/.count-$key")] stale-suppressor? $([ -e "$STATE/.stale-$key" ] && echo yes || echo no)"
}
