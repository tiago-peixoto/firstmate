#!/usr/bin/env bash
# Live: real Pi in a guarded Herdr lab; read composer_state with base vs target libs.
set -u
ROOT=$1; BASE=$2; H=$ROOT/bin/fm-herdr-lab.sh
S=$("$H" name pi-dollar); echo "session=$S"
trap '"$H" teardown "$S"; echo teardown-rc=$?' EXIT
"$H" provision "$S" >/dev/null || exit 1
lab() { "$H" run "$S" "$@"; }
WS=$(lab workspace create --cwd "$ROOT" --label pi-lab --no-focus)
PANE=$(lab pane list | jq -r '.result.panes[0].pane_id'); echo "pane=$PANE"
lab agent start pi --kind pi --pane "$PANE" --timeout 60000 >/dev/null || echo "agent start rc=$?"
sleep 4
state() { # <root> -> composer_state via production herdr adapter
  HERDR_SESSION="$S" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$1"' "$1" "$S:$PANE"
}
show() { echo "--- pane (last 6 rows) ---"; lab pane read "$PANE" --lines 40 | jq -r '.result.read.text // .result.text // .' | grep -v '^\s*$' | tail -6; echo "--- agent ---"; lab agent get "$PANE" | jq -c '.result.agent|{agent,agent_status}'; }
echo "=== 1. idle Pi pane ==="; show
echo "BASE   composer_state: $(state "$BASE")"
echo "TARGET composer_state: $(state "$ROOT")"
echo "=== 2. text typed into the Pi composer ==="
lab pane send-text "$PANE" 'fix the flaky test' >/dev/null; sleep 1.5; show
echo "TARGET composer_state: $(state "$ROOT")"
echo "=== 3. the cost string itself typed into the composer ==="
lab pane send-keys "$PANE" ctrl+u >/dev/null 2>&1 || lab pane send-keys "$PANE" C-u >/dev/null; sleep 0.5
lab pane send-text "$PANE" '$0.000 (sub) 5.4%/272k (auto)' >/dev/null; sleep 1.5; show
echo "TARGET composer_state: $(state "$ROOT")"
