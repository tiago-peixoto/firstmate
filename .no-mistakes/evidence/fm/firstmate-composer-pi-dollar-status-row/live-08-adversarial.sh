#!/usr/bin/env bash
# Stage 8: adversarial shapes in the same lab pane (no agent running).
# (a) Pi's stale frame (pair + `$0.000 (sub)` row) above a REAL `$ ` bash prompt
#     at column 0 - a dead shell must never read empty.
# (b) another harness's bare `❯` composer with a `$<digit>` row below it - the
#     exemption must not create a new path to empty.
. /Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1/live-env.sh
lab pane run "$PANE_ID" "PS1='\$ ' bash --norc" >/dev/null 2>&1; sleep 1.5
echo "(a) tail: $(screen | grep -v '^[[:space:]]*$' | tail -3 | sed 's/   .*//' | tr '\n' '|')"
echo "(a) composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
screen > "$EV/08a-live-dead-dollar-shell-screen.txt"
lab pane run "$PANE_ID" "clear; printf '\\342\\235\\257\\n\$5 left in the budget\\n'; exec sleep 600" >/dev/null 2>&1; sleep 1.5
echo "(b) tail: $(screen | grep -v '^[[:space:]]*$' | tail -2 | tr '\n' '|')"
echo "(b) composer_state: base=$(verdict "$BASE" "$TARGET") target=$(verdict "$ROOT" "$TARGET")"
screen > "$EV/08b-live-bare-glyph-dollar-row-screen.txt"
