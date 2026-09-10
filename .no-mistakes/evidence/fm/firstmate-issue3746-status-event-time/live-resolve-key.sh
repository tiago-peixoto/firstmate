#!/usr/bin/env bash
# Live: a crewmate raises a stamped keyed decision; the captain-facing OPEN
# DECISIONS digest lists it; fm-send --resolve-key answers it through a real
# tmux pane; the stamped close record closes it and nothing else.
# FM_GATE_REFUSE_BYPASS=1 is the documented sandbox-fleet escape hatch the repo's
# own test helpers export (bin/fm-gate-refuse-lib.sh): this home and tmux server
# are throwaway, not the user's fleet.
. "$(dirname "$0")/live-common.sh"
trap cleanup_tmux EXIT
H=$(make_home resolve)
tmux new-session -d -s sess -n fm-t1 'cat'
write_meta "$H/state/t1.meta" "window=sess:fm-t1" "kind=ship"
drain() { FM_STATE_OVERRIDE="$H/state" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null; }

say "D1. Worker raises a decision the way its brief now tells it to"
bash -c "echo \"needs-decision [key=api-shape] [at=\$(date +%s)]: pick REST or RPC\" >> '$H/state/t1.status'"
printf 'working [at=%s]: unrelated progress\n' "$(date +%s)" >> "$H/state/t1.status"
cat "$H/state/t1.status"
out=$(drain); printf '%s\n' "$out" | sed -n '/OPEN DECISIONS/,/^$/p'
check "stamped decision is listed as open under its key" grep -qF '[key=api-shape]' <<<"$out"

say "D2. Captain answers through fm-send --resolve-key (real tmux pane)"
printf '$ fm-send.sh t1 --resolve-key api-shape "go with REST"\n'
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key api-shape "go with REST"
echo "rc=$?"
printf 'inbox record: '; cat "$H/state/t1.inbox/001.msg" 2>/dev/null | head -3; echo
printf 'pane shows:\n'; tmux capture-pane -p -t sess:fm-t1 | grep -v '^$' | tail -3
printf 'state/t1.status:\n'; cat "$H/state/t1.status"
close=$(grep "^resolved" "$H/state/t1.status" | tail -1)
check "close record is stamped with its emission time" \
  bash -c '. "$1"; status_line_at_epoch "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$close"
check "close record keeps key=api-shape and answered: go with REST" \
  bash -c '. "$1"; [ "$(status_line_verb "$2")" = resolved ] && [ "$(_fm_decision_key "$2")" = api-shape ] && [ "$(status_line_note "$2")" = "answered: go with REST" ]' \
  _ "$ROOT/bin/fm-classify-lib.sh" "$close"
out=$(drain); printf 'drain after answer:\n%s\n' "$out" | head -20
check "decision no longer listed as open" bash -c '! grep -qF "OPEN DECISIONS" <<<"$1"' _ "$out"

say "D3. Adversarial: a mistyped key still refuses before anything is sent"
lines_before=$(wc -l < "$H/state/t1.status")
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key api-shap "typo" 2>&1 | head -2
check "no status line added by the refused send" [ "$(wc -l < "$H/state/t1.status")" = "$lines_before" ]
check "no second inbox record" [ ! -e "$H/state/t1.inbox/002.msg" ]

say "D4. Adversarial: a stamped working line cannot close a stamped decision"
printf 'needs-decision [key=port] [at=%s]: 8080 or 9090\n' "$(date +%s)" >> "$H/state/t1.status"
printf 'working [key=port] [at=%s]: started on 9090 anyway\n' "$(date +%s)" >> "$H/state/t1.status"
out=$(drain); printf '%s\n' "$out" | sed -n '/OPEN DECISIONS/,/^$/p'
check "keyed decision stays open after a stamped working line" grep -qF '[key=port]' <<<"$out"
printf '\nFAILS=%s\n' "$FAILS"
