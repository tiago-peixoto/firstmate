#!/usr/bin/env bash
# Stage 8c: Pi-shaped frame (separator pair + `$0.000 (sub)` row) drawn directly
# above a REAL bash `$ ` prompt at column 0, cursor parked on the prompt.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
lab pane send-keys "$PANE_ID" ctrl+c >/dev/null 2>&1; sleep 0.5
lab pane run "$PANE_ID" "clear; printf 'transcript\\n%s\\n\\n%s\\n\$0.000 (sub) 0.0%%/272k (auto)\\n' '────────────────────────' '────────────────────────'; PS1='\$ ' bash --norc" >/dev/null 2>&1; sleep 1.5
echo "(c) tail: $(screen | grep -v '^[[:space:]]*$' | tail -5 | tr '\n' '|')"
echo "(c) identity: $(herdr agent get "$PANE_ID" --session "$SESSION" 2>&1 | jq -c '.result.agent // .error.code // .' 2>/dev/null)"
echo "(c) composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
screen > "$EV/08c-live-pi-frame-over-dollar-shell-screen.txt"
