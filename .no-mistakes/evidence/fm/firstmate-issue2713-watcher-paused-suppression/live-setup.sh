#!/usr/bin/env bash
# usage: live-setup.sh <repo-root> <label> <evidence-dir> <duration>
# Builds a disposable lab home + private tmux server, starts five crew panes and the driver.
set -u
ROOT=$1; LABEL=$2; EV=$3; DUR=$4
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/work"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
CLEAN="env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE"
$CLEAN TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s crew -n fm-dead -x 120 -y 30 -c "$LAB/work" bash --norc
T new-window -d -t crew -n fm-unknown -c "$LAB/work" "sleep 100000"
T new-window -d -t crew -n fm-alive -c "$LAB/work" claude
T new-window -d -t crew -n fm-held -c "$LAB/work" bash --norc
T new-window -d -t crew -n fm-until -c "$LAB/work" bash --norc
mk() {  # <id> <status-line>
  printf 'window=crew:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$1" > "$LAB/state/$1.meta"
  printf '%s\n' "$2" > "$LAB/state/$1.status"
}
mk dead    'paused: waiting on the upstream release'
mk unknown 'paused: waiting on the upstream release'
mk alive   'paused: waiting on the upstream release'
mk held    'captain-held [key=route]: tracked by held-decision-route'
mk until   'paused: rate limit until 2027-10-06T00:00:00Z'
sleep 8   # let claude draw its first screen
T new-session -d -s primary -x 160 -y 40 -c "$ROOT" \
  -e FM_HOME="$LAB" -e FM_POLL=2 -e FM_SIGNAL_GRACE=1 -e FM_CHECK_INTERVAL=999999 -e FM_HEARTBEAT=999999 \
  -e FM_SECONDMATE_LIVENESS_SECS=99999999 -e FM_PAUSE_RESURFACE_SECS=45 -e FM_STALE_ESCALATE_SECS=10 \
  "$CLEAN $EV/live-driver.sh $ROOT $LAB $EV/timeline-$LABEL.txt $DUR"
echo "$LAB"
