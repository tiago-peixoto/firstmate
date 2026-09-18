#!/usr/bin/env bash
# Run the real bin/fm-watch.sh for several polls over a home whose secondmate
# waits on its own decision while a reconcile request is queued. Checks the
# watcher's triage log and that no fm-send is spawned for the waiting mate.
set -u
ROOT=${ROOT:?}; SECS=${SECS:-10}
W=$(mktemp -d /tmp/fm4228-watch.XXXXXX); W=$(cd "$W" && pwd -P)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
cp -R "$ROOT/bin" "$W/bin"; mv "$W/bin/fm-send.sh" "$W/bin/fm-send.real.sh"
cat > "$W/bin/fm-send.sh" <<'WRAP'
#!/usr/bin/env bash
printf 'fm-send %s %s\n' "$1" "$2" >> "$FM_SEND_CALLS"
exec "$(dirname "$0")/fm-send.real.sh" "$@"
WRAP
chmod +x "$W/bin/fm-send.sh"
export FM_SEND_CALLS="$W/fm-send-calls.log"; : > "$FM_SEND_CALLS"
H="$W/home"; M="$W/mate"; mkdir -p "$H/state" "$H/data" "$M/state" "$M/data"; chmod 755 "$H/state"
printf -- '- mate - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-08-26)\n' "$M" > "$H/data/secondmates.md"
printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nspawn_gen=spawn-mate\nhome=%s\nworktree=%s\n' "$M" "$M" > "$H/state/mate.meta"
tmux new-session -d -s firstmate -n fm-mate "cat"
export FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$H/state"
jq -n '{schema:"fm-fleet-snapshot.v1", generated:"2026-09-18T00:00:00Z",
  secondmate_current:{records:[{id:"mate", home:"/tmp/mate", spawn_gen:"spawn-mate",
  current:{state:"captain_decision", reason:null},
  invalidity:{kind:"orphan_in_flight",ids:["ghost"]},
  reconcile_inventory:{kind:"orphan_in_flight",ids:["ghost"]},
  provenance:{selected:"structured-home", trust:"partial-structured"}}]}}' > "$W/snap.json"
printf 'working: supervising crew\nneeds-decision [key=pick]: alpha or beta?\n' > "$H/state/mate.status"
"$W/bin/fm-secondmate-reconcile.sh" request --snapshot "$W/snap.json" >/dev/null
echo "== queued request, mate status:"; sed 's/^/  /' "$H/state/mate.status"
run_watcher() {  # <secs>
  local SECS=$1
# Firstmate re-arms the watcher after every wake it reports, so relaunch it
  # whenever it exits, for SECS seconds in total, as the real supervisor would.
  end=$(( $(date +%s) + SECS )); launches=0; : > "$W/watch.out"
  while [ "$(date +%s)" -lt "$end" ]; do
    launches=$((launches + 1))
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      "$W/bin/fm-watch.sh" >> "$W/watch.out" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$end" ]; do sleep 0.2; done
    if kill -0 "$pid" 2>/dev/null; then pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; fi
    wait "$pid" 2>/dev/null
  done
  alive="relaunched $launches time(s)"
  sleep 2  # let a last detached process-requests finish
  
}
report() {  # <label>
  local alive="relaunched $launches time(s)"
echo "== $1: after ${SECS}s of the real watcher at FM_POLL=1 (watcher $alive)"
  echo "  watcher beats: $([ -e "$H/state/.last-watcher-beat" ] && echo yes || echo no)"
  echo "  requests still queued: $(ls "$H/state/reconcile-notify"/request-*.json 2>/dev/null | wc -l | tr -d ' ')"
  echo "  fm-send spawns: $(wc -l < "$FM_SEND_CALLS" | tr -d ' ')"
  echo "  mate inbox records: $(ls "$H/state/mate.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
  echo "  triage log lines mentioning reconcile: $(cat "$H/state/.watch-triage.log" 2>/dev/null | grep -c reconcile)"
  echo "  triage log:"; sed 's/^/    /' "$H/state/.watch-triage.log" 2>/dev/null || echo "    (absent)"
  echo "  watcher stdout:"; sed 's/^/    /' "$W/watch.out" | head -20
  echo "  mate pane:"; tmux capture-pane -p -t firstmate:fm-mate | sed '/^$/d; s/^/    > /'
  
}
run_watcher "$SECS"; report "PHASE 1 (decision open)"
echo; echo "== firstmate answers the decision"
printf 'resolved [key=pick]: answered: alpha\n' >> "$H/state/mate.status"; sed 's/^/  /' "$H/state/mate.status"
: > "$W/watch.out"; SECS=6; run_watcher "$SECS"; report "PHASE 2 (decision answered)"
tmux kill-server 2>/dev/null; rm -rf "$W"
