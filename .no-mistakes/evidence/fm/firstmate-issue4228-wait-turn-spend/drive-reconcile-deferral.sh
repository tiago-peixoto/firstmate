#!/usr/bin/env bash
# Live drive of bin/fm-secondmate-reconcile.sh request/process-requests (the
# exact command the watcher spawns each poll) against a real tmux pane for a
# secondmate that waits on its own open decision. bin/ is copied to a scratch
# dir so fm-send.sh can be wrapped with a call counter; the wrapper execs the
# real script unchanged.
set -u
ROOT=${ROOT:?}
W=$(mktemp -d /tmp/fm4228-rec.XXXXXX); W=$(cd "$W" && pwd -P)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
cp -R "$ROOT/bin" "$W/bin"
mv "$W/bin/fm-send.sh" "$W/bin/fm-send.real.sh"
cat > "$W/bin/fm-send.sh" <<'WRAP'
#!/usr/bin/env bash
printf 'fm-send %s %s %s %s <message>\n' "$1" "$2" "$3" "$4" >> "$FM_SEND_CALLS"
exec "$(dirname "$0")/fm-send.real.sh" "$@"
WRAP
chmod +x "$W/bin/fm-send.sh"
export FM_SEND_CALLS="$W/fm-send-calls.log"; : > "$FM_SEND_CALLS"
H="$W/home"; M="$W/mate"; mkdir -p "$H/state" "$H/data" "$M/state" "$M/data"; chmod 755 "$H/state"
printf 'secondmate-home: mate\n' > "$M/.firstmate-secondmate-home" 2>/dev/null || true
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
R="$W/bin/fm-secondmate-reconcile.sh"
state() {
  echo "  requests queued: $(ls "$H/state/reconcile-notify"/request-*.json 2>/dev/null | wc -l | tr -d ' ')" \
       "| fm-send spawns so far: $(wc -l < "$FM_SEND_CALLS" | tr -d ' ')" \
       "| mate inbox records: $(ls "$H/state/mate.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')" \
       "| cooldown stamp: $([ -e "$H/state/mate.reconcile-nudged" ] && echo present || echo absent)"
}
run() { echo "\$ fm-secondmate-reconcile.sh $*"; "$R" "$@" 2>&1 | grep -v -e '^$' -e '^●' -e '^WARNING: watcher' | sed 's/^/  | /'; echo "  exit=${PIPESTATUS[0]}"; }

echo "== mate opens its own decision"
printf 'working: supervising crew\nneeds-decision [key=pick]: alpha or beta?\n' > "$H/state/mate.status"; sed 's/^/  status: /' "$H/state/mate.status"
echo; echo "== bearings publishes a reconcile request"
run request --snapshot "$W/snap.json"; state
for pass in 1 2 3; do
  echo; echo "== watcher poll $pass runs process-requests"
  run process-requests; state
done
echo; echo "== a direct notify also defers without spawning fm-send"
run notify --snapshot "$W/snap.json"; state
echo; echo "== firstmate answers the decision; next poll delivers the queued ask"
printf 'resolved [key=pick]: answered: alpha\n' >> "$H/state/mate.status"
run process-requests; state
echo "  fm-send calls:"; sed 's/^/    /' "$FM_SEND_CALLS"
echo "  mate pane:"; tmux capture-pane -p -t firstmate:fm-mate | sed '/^$/d; s/^/    > /'
echo; echo "== next poll: queue empty, cooldown now active"
run process-requests; state
tmux kill-server 2>/dev/null; rm -rf "$W"
