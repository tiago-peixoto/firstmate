#!/usr/bin/env bash
# Stage 3: (a) base fm-control exit on the idle dollar-footer pi pane;
# (b) adversarial: a typed draft above the dollar footer must still block
# target exit and survive untouched.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
echo '$ fm-control.sh pidollar exit    # BASE 07dab42d, pi idle, footer $0.000 (sub) ...'
control "$BASE" exit; echo "[exit status $?]"
echo "pi still registered: $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}')"
echo
DRAFT='draft that must survive the exit attempt'
lab pane send-text "$PANE_ID" "$DRAFT" >/dev/null
sleep 1
echo "typed (no Enter): $DRAFT"
echo "target composer_state=$(verdict "$ROOT" "$TARGET")"
echo '$ fm-control.sh pidollar exit    # TARGET 5f987b66, draft in composer'
control "$ROOT" exit; echo "[exit status $?]"
sleep 0.5
echo "draft still on screen: $(screen | grep -c "$DRAFT") row(s); pi: $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}')"
