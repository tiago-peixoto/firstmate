#!/usr/bin/env bash
# Adversarial live check on the boundary this change introduces: a per-task
# ledger with its own lock, written by a read-merge-write inside every
# self-announced append. Several real fm-send --resolve-key processes answer the
# same task at the same moment (a firstmate answering while another actor closes
# a decision on the same log). The product must still close every decision
# exactly once, keep the ledger well formed, and present every close.
set -u
ROOT=${FM_LIVE_ROOT:?set FM_LIVE_ROOT}
N=${FM_CONC_N:-8}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-conc.XXXXXX")
HOMEDIR="$WORK/home"; STATE="$HOMEDIR/state"; FAKEBIN="$WORK/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$WORK/notangle"
STATUS="$STATE/t1.status"
FAILED=0
ok(){ printf 'PASS  %s\n' "$*"; }; bad(){ printf 'FAIL  %s\n' "$*"; FAILED=1; }
say(){ printf '\n=== %s\n' "$*"; }

cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/wedge-rec"
chmod +x "$FAKEBIN/tmux" "$WORK/wedge-rec"
export FM_WEDGE_ALARM_EXEC="$WORK/wedge-rec" FM_ROOT_OVERRIDE="$WORK/notangle"

printf 'window=sess:fm-t1\nkind=ship\n' > "$STATE/t1.meta"
: > "$STATUS"
for i in $(seq 1 "$N"); do printf 'needs-decision [key=k%s]: choose option %s\n' "$i" "$i" >> "$STATUS"; done
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATUS" >/dev/null

say "$N real fm-send --resolve-key processes answer the same task simultaneously"
for i in $(seq 1 "$N"); do
  env -u NO_MISTAKES_GATE PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    FM_ROOT_OVERRIDE="$HOMEDIR" FM_HOME="$HOMEDIR" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" t1 --resolve-key "k$i" "answer $i" > "$WORK/send-$i.out" 2>&1 &
done
wait

say "every send either closed its key exactly once or refused loudly"
# fm-send serializes final delivery validation on the task's metadata lock, so
# under a burst some sends refuse outright. That is fail-closed and pre-existing
# (it reproduces identically on the base commit): the decision stays open and the
# operator is told. What must never happen is a silent loss - a send that
# reported success without closing - or a duplicated close.
bad_outcome=0; landed=0; refused=0
for i in $(seq 1 "$N"); do
  c=$(grep -cF "resolved [key=k$i]: answered: answer $i" "$STATUS" || true)
  if [ "$c" -eq 1 ]; then
    landed=$((landed + 1))
  elif [ "$c" -eq 0 ] && grep -q '^error: ' "$WORK/send-$i.out"; then
    refused=$((refused + 1))
    printf '  key k%s: send refused loudly -> %s\n' "$i" "$(grep -m1 '^error: ' "$WORK/send-$i.out")"
  else
    bad_outcome=1
    printf '  key k%s appears %s times; that send reported:\n' "$i" "$c"
    sed 's/^/    | /' "$WORK/send-$i.out"
  fi
done
printf '  %s closed, %s refused, out of %s concurrent answers\n' "$landed" "$refused" "$N"
[ "$bad_outcome" -eq 0 ] && [ "$landed" -gt 0 ] \
  && ok "no close was silently lost or duplicated" \
  || bad "a send reported success without closing, or closed twice"
badline=$(grep -cvE '^(needs-decision|resolved) \[key=k[0-9]+\]: ' "$STATUS" || true)
[ "$badline" -eq 0 ] && ok "no torn or interleaved line in the status log" \
  || { bad "the status log has $badline malformed lines"; cat "$STATUS"; }

say "the ledger is well formed: ascending, non-overlapping, byte-accurate ranges"
LEDGER="$STATE/.t1.home-appends"
printf -- '--- %s ---\n' "$LEDGER"; cat "$LEDGER"
ranges=$(FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; status_home_appends_ranges "$2"' \
  _ "$ROOT/bin/fm-classify-lib.sh" "$STATUS")
printf -- '--- ranges as the product reads them ---\n%s\n' "$ranges"
prev_end=-1; sane=1
while IFS=$'\t' read -r s e; do
  [ -n "$s" ] || continue
  { [ "$s" -ge "$prev_end" ] && [ "$e" -gt "$s" ]; } || sane=0
  prev_end=$e
done <<< "$ranges"
[ "$sane" -eq 1 ] && ok "ranges are ascending and non-overlapping" || bad "the ledger holds overlapping or inverted ranges"
size=$(LC_ALL=C wc -c < "$STATUS" | tr -d '[:space:]')
[ "$prev_end" -le "$size" ] && ok "no range runs past the log's $size bytes" \
  || bad "a range ends at $prev_end, past the $size-byte log"

say "the captain still sees every close, and no decision is left open"
# A drain only annotates a status file that a wake row names, so queue the row a
# real watcher would have queued for the worker's later line.
printf 'working: carrying on with the answers\n' >> "$STATUS"
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_append signal t1.status "signal: $2"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$STATUS" >/dev/null
out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null || true)
printf '%s\n' "$out"
shown=0
for i in $(seq 1 "$N"); do
  grep -qF "resolved [key=k$i]: answered: answer $i" "$STATUS" || continue
  printf '%s' "$out" | grep -qF "resolved [key=k$i]: answered: answer $i" || {
    shown=1; printf '  k%s was closed in the log but not presented\n' "$i"; }
done
[ "$shown" -eq 0 ] && ok "every landed close is presented on the captain-facing surface" \
  || bad "at least one landed close was hidden from the captain"
still_open=$(printf '%s' "$out" | grep -cE '^t1 \[key=k[0-9]+\] needs-decision' || true)
[ "$still_open" -eq "$refused" ] \
  && ok "exactly the $refused refused answers are still listed as open decisions" \
  || bad "$still_open decisions are open but $refused sends refused"

printf '\n===========================\n'
[ "$FAILED" -eq 0 ] && printf 'RESULT: all live scenarios passed\n' || printf 'RESULT: at least one live scenario FAILED\n'
exit "$FAILED"
