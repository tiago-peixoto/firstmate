#!/usr/bin/env bash
# Stage 4: target fm-control exit on the idle pi pane whose status row starts
# with `$0.000 (sub)`; then idempotent re-exit and the dead-shell verdict.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
echo "before: pi $(herdr agent get "$PANE_ID" --session "$SESSION" | jq -c '.result.agent | {agent, agent_status}'), status row: $(screen | grep -E '^\$[0-9]' | tail -1 | sed 's/  .*//')"
echo "target composer_state=$(verdict "$ROOT" "$TARGET")"
echo '$ fm-control.sh pidollar exit    # TARGET 5f987b66'
control "$ROOT" exit; echo "[exit status $?]"
sleep 1
echo "after: herdr agent get -> $(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -c '.result.agent // .error // .' 2>/dev/null | head -c 200)"
echo "pane process state: $( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")"
echo "recovery-grade agent state: $( . "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_agent_state herdr "$TARGET")"
echo "dead-shell pane composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
echo '$ fm-control.sh pidollar exit    # TARGET again (idempotent)'
control "$ROOT" exit; echo "[exit status $?]"
