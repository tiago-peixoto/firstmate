#!/usr/bin/env bash
# Live drive of bin/fm-watch.sh against real tmux panes on a disposable lab socket.
# Usage: live-lab-drive.sh <worktree> <scenario>
set -u
WT=$1; SCEN=$2
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
SOCK="$LAB/tmux/tmux-$(id -u)/fm-lab"
T() { tmux -L fm-lab "$@"; }
cleanup() { T kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
REPO="$LAB/data/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q
case "$SCEN" in
  idle-*) CMD="bash --norc --noprofile -i" ;;
  *) CMD="bash -c 'while :; do date +%H:%M:%S.%N; sleep 0.25; done'" ;;
esac
T new-session -d -s crew -n fm-parked -x 120 -y 30 "$CMD"
W=crew:fm-parked
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\nworktree=%s\n' "$W" "$REPO" > "$LAB/state/parked.meta"
S="$LAB/state/parked.status"
now=$(date +%s); iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
RES=999
case "$SCEN" in
  idle-first-sight) printf 'paused: waiting on upstream review\n' > "$S" ;;
  churn-cadence-due) printf 'paused: waiting on upstream review\n' > "$S"; touch -d "@$((now-200))" "$S"; RES=60 ;;
  churn-inside-cadence) printf 'paused: waiting on upstream review\n' > "$S"; touch -d "@$((now-100))" "$S" ;;
  churn-until-elapsed) printf 'paused: rate limit until %s\n' "$(iso $((now-30)))" > "$S"; touch -d "@$((now-100))" "$S" ;;
  churn-captain-held-due) printf 'captain-held [key=route]: awaiting the captain on the routing call\n' > "$S"; touch -d "@$((now-200))" "$S"; RES=60 ;;
  churn-ceiling-optin) touch "$LAB/config/pause-ceiling"; printf 'paused: waiting on upstream review\n' > "$S"; touch -d "@$((now-200))" "$S"; export FM_PAUSE_UNDATED_MAX_SECS=100 ;;
  idle-until-elapsed) printf 'paused: rate limit until %s\n' "$(iso $((now-30)))" > "$S"; touch -d "@$((now-100))" "$S" ;;
  idle-ceiling-optin) touch "$LAB/config/pause-ceiling"; printf 'paused: waiting on upstream review\n' > "$S"; touch -d "@$((now-200))" "$S"; export FM_PAUSE_UNDATED_MAX_SECS=100 ;;
  churn-ceiling-off) printf 'paused: waiting on upstream review\n' > "$S"; touch -d "@$((now-200))" "$S"; export FM_PAUSE_UNDATED_MAX_SECS=100 ;;
esac
run_watch() {  # <seconds>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMUX="$SOCK,0,0" FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_PAUSE_RESURFACE_SECS=$RES timeout "$1" bin/fm-watch.sh > "$LAB/watch.out" 2>&1
  echo "watcher exit=$? (124 = still polling at timeout, i.e. no wake)"
}
ack() {
  local err="$LAB/drain.err" seq gen
  FM_HOME="$LAB" bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$err"
  echo "--- drained wake as firstmate sees it:"; grep -v "^$" "$LAB/drain.out" | head -12 | sed "s/^/    /"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_HOME="$LAB" bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
show_queue() { echo "--- wake queue rows (type, window, text):"; awk -F"\t" "{\$1=\$2=\"\"; print \"  row:\" \$0}" "$LAB/state/.wake-queue" 2>/dev/null | tail -n +"${1:-1}"; }
echo "=== scenario: $SCEN (FM_PAUSE_RESURFACE_SECS=$RES)"
echo "status line: $(cat "$S")   status age: $(( $(date +%s) - $(stat -c %Y "$S") ))s"
[ -e "$LAB/config/pause-ceiling" ] && echo "config/pause-ceiling: present (FM_PAUSE_UNDATED_MAX_SECS=$FM_PAUSE_UNDATED_MAX_SECS)"
echo "pane sample: $(T capture-pane -p -t "$W" | grep -v '^$' | tail -1)"
echo "real crew state: $(FM_HOME="$LAB" TMUX="$SOCK,0,0" bin/fm-crew-state.sh parked 2>&1 | head -1)"
echo "## round 0: watcher sees the fresh status line (signal path)"
run_watch 20; show_queue
ack
n0=$(wc -l < "$LAB/state/.wake-queue" 2>/dev/null || echo 0)
echo "## round 1: status signal acked, watcher polls the real pane (FM_POLL=1, up to 25s)"
run_watch 25; show_queue $((n0+1))
n1=$(wc -l < "$LAB/state/.wake-queue" 2>/dev/null || echo 0)
ls "$LAB/state" | grep -E '^\.(paused|stale)' | sed 's/^/  marker: /'
[ -e "$LAB/state/.paused-overdue-parked" ] && echo "  overdue record present"
grep -h 'paused-overdue' "$S" | sed 's/^/  status log: /'
if [ "$n1" -gt "$n0" ]; then
  ack
  echo "## round 2: after ack, same declaration, up to 15s more polling"
  run_watch 15; show_queue $((n1+1))
fi
echo "=== end $SCEN"
