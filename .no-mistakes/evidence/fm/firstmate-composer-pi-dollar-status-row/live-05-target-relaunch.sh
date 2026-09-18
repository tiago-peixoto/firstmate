#!/usr/bin/env bash
# Stage 5: pi running idle again with the `$0.000 (sub)` status row, then the
# full TARGET fm-control relaunch (checkpoint -> exit -> fm-spawn --relaunch).
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
lab pane run "$PANE_ID" "clear; pi --no-session" >/dev/null 2>&1 || { echo "pane run pi failed"; exit 1; }
for _ in $(seq 1 150); do
  st=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  [ "$st" = idle ] && screen | grep -qE '^\$[0-9]' && break; sleep 0.4
done
sleep 1
echo "before: pi $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}'), status row: $(screen | grep -E '^\$[0-9]' | tail -1 | sed 's/  .*//')"
echo "composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
echo '$ fm-control.sh pidollar relaunch --note "..."    # BASE 07dab42d'
control "$BASE" relaunch --note "live lab relaunch check" ; echo "[exit status $?]"
echo '$ fm-control.sh pidollar relaunch --note "..."    # TARGET 5f987b66'
control "$ROOT" relaunch --note "live lab relaunch check" ; echo "[exit status $?]"
