#!/usr/bin/env bash
# Stage 6: the relaunched pi (same endpoint) settles idle; TARGET exit stops it.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
echo "relaunched: pi $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}'), agent state $( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_agent_state herdr "$TARGET")"
for _ in $(seq 1 300); do
  st=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac; sleep 0.5
done
sleep 2
echo "settled: agent_status=$st, status row: $(screen | grep -E '(^\$[0-9]|%/[0-9]+k)' | tail -1 | sed 's/   .*//')"
echo "composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
screen > "$EV/06-live-relaunched-idle-screen.txt"; screen ansi > "$EV/06-live-relaunched-idle-screen.ansi"
echo '$ fm-control.sh pidollar exit    # TARGET 5f987b66, relaunched pi'
control "$ROOT" exit; echo "[exit status $?]"
echo "recovery-grade agent state: $( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_agent_state herdr "$TARGET")"
