#!/usr/bin/env bash
# tests/fm-status-write.test.sh - validated status writer and decision recovery.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-write)
WRITER="$ROOT/bin/fm-status-write.sh"
. "$ROOT/bin/fm-classify-lib.sh"

f="$TMP_ROOT/task.status"
printf '%s\n' 'blocked [at=1793378273] [key=example]: An implementation decision needs an answer.' > "$f"
printf '%s\n' '1793378273 blocked [key=broken] A malformed later event.' >> "$f"
"$WRITER" "$f" working -- 'test setup' || fail "writer rejected a valid working event"
[ -n "$(status_open_decisions "$f" ship 2>"$TMP_ROOT/format-errors")" ] || fail "a later event erased the existing decision"
grep -q 'malformed status line; repair' "$TMP_ROOT/format-errors" || fail "malformed legacy input was not reported as repairable"
pass "status writer preserves an earlier open decision"

"$WRITER" "$f" blocked --key example -- $'first line\nsecond line' || fail "writer rejected a multiline body"
last=$(tail -n 1 "$f")
case "$last" in *'[key=example]'*'first line second line'*) ;; *) fail "multiline body was not flattened into one event: $last" ;; esac
pass "status writer stamps keyed multiline events"

"$WRITER" "$f" needs-decision --key captain-hold-t-1 --until 2026-12-01 -- 'captain hold t: wait' || fail "writer rejected a dated hold"
last=$(tail -n 1 "$f")
case "$last" in 'needs-decision [key=captain-hold-t-1] [until=2026-12-01] [at='*']: captain hold t: wait') ;; *) fail "dated hold lost its until field: $last" ;; esac
"$WRITER" "$f" note --until 2026-1-1 -- 'bad date' >/dev/null 2>&1 && fail "writer accepted a malformed until date"
pass "status writer carries a validated until date"

undated="$TMP_ROOT/undated.status"
"$WRITER" "$undated" paused -- 'Draft PR pushed. Waiting on CI.' >/dev/null 2>&1 && fail "writer accepted a pause with no until"
[ ! -s "$undated" ] || fail "a refused pause still reached the status log"
FM_CLASSIFY_PAUSED_VERB=awaiting "$WRITER" "$undated" awaiting -- 'Waiting on CI.' >/dev/null 2>&1 && fail "writer accepted a custom-verb pause with no until"
"$WRITER" "$undated" paused -- 'Waiting until 2026-13-40T25:00Z' >/dev/null 2>&1 && fail "writer accepted a pause with an impossible until"
due=$(( $(date +%s) / 60 * 60 + 3600 ))
due_iso=$(date -u -r "$due" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$due" +%Y-%m-%dT%H:%MZ)
"$WRITER" "$undated" paused -- $'Waiting on CI\nuntil '"$due_iso" || fail "writer refused a dated pause"
[ "$(status_paused_until "$(tail -n 1 "$undated")")" = "$due" ] || fail "dated pause is not rechecked at its until: $(tail -n 1 "$undated")"
pass "status writer requires until on a pause and keeps its recheck time"

"$WRITER" "$f" definitely-not-a-verb -- 'invalid' >/dev/null 2>&1 && fail "writer accepted an invalid verb"
pass "status writer rejects invalid verbs"

parallel="$TMP_ROOT/concurrent.status"
for n in $(seq 1 20); do "$WRITER" "$parallel" note -- "message-$n" & done
wait
[ "$(wc -l < "$parallel" | tr -d ' ')" = 20 ] || fail "concurrent appends lost or split events"
[ "$(grep -cE '^note \[at=[0-9]+\]: message-[0-9]+$' "$parallel")" = 20 ] || fail "concurrent appends interleaved event lines"
pass "concurrent status appends remain whole"

legacy="$TMP_ROOT/legacy.status"
printf '%s\n' 'needs-decision: legacy question' 'blocked [at=1793378273]: legacy blocker' > "$legacy"
legacy_open=$(status_open_decisions "$legacy" ship)
[ "$legacy_open" = $'default\tblocked\tlegacy blocker' ] || fail "valid legacy status lines stopped parsing: $legacy_open"
pass "recognized legacy status lines remain readable"

echo "PASS fm-status-write"
