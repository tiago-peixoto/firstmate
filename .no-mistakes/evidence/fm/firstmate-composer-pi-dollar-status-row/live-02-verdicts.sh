#!/usr/bin/env bash
# Stage 2: the same live idle pi pane, classified by base and by target code.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
echo "herdr agent get: $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}')"
echo "status row: $(screen | grep -E '^\$[0-9]' | tail -1 | sed 's/  */ /g')"
for i in 1 2 3; do
  echo "try $i: base 07dab42d composer_state=$(verdict "$BASE" "$TARGET")  target 5f987b66 composer_state=$(verdict "$ROOT" "$TARGET")"
done
