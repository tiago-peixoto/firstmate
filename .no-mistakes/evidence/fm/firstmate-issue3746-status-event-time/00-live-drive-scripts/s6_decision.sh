. /tmp/fm-live/common.sh
H=$(mktemp -d /tmp/fm-live/home-s6.XXXXXX)
mkdir -p "$H"/{state,data,projects}
FB="$H/fakebin"; mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t-stamped fm-t-legacy; exit 0 ;;
esac
exit 0
SH
cat > "$FB/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FB"/*
rc=0
LOG="$H/send.log"

hr "two workers open a decision: one stamped by the new brief, one legacy"
write_meta "$H/state/t-stamped.meta" "window=sess:fm-t-stamped" "kind=ship"
write_meta "$H/state/t-legacy.meta" "window=sess:fm-t-legacy" "kind=ship"
NOW=$(date +%s)
printf 'needs-decision [key=api-shape] [at=%s]: choose REST or gRPC\n' "$NOW" > "$H/state/t-stamped.status"
printf 'working [at=%s]: continuing on an unrelated stream\n' "$((NOW + 1))" >> "$H/state/t-stamped.status"
printf 'needs-decision [key=port-choice]: 8080 or 9090\n' > "$H/state/t-legacy.status"
cat "$H"/state/t-stamped.status "$H"/state/t-legacy.status

hr "captain drain before answering"
FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_ROOT_OVERRIDE="$H" "$BIN/fm-wake-drain.sh" 2>/dev/null | sed -n '/OPEN DECISIONS/,/close one/p'

hr "captain answers the stamped decision: bin/fm-send.sh t-stamped --resolve-key api-shape 'go with REST'"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_SEND_LOG="$LOG" FM_SEND_SETTLE=0 \
  "$BIN/fm-send.sh" t-stamped --resolve-key api-shape 'go with REST' 2>&1 | sed 's/^/  /'
echo "  (rc=$?)"

hr "captain answers the legacy decision: bin/fm-send.sh t-legacy --resolve-key port-choice 'use 9090'"
env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$H" FM_HOME="$H" FM_SEND_LOG="$LOG" FM_SEND_SETTLE=0 \
  "$BIN/fm-send.sh" t-legacy --resolve-key port-choice 'use 9090' 2>&1 | sed 's/^/  /'
echo "  (rc=$?)"

hr "status ledgers after the answers"
for f in "$H"/state/t-stamped.status "$H"/state/t-legacy.status; do printf '%s:\n' "$(basename "$f")"; sed 's/^/  /' "$f"; done

hr "the closing lines carry their own emission time"
for id in t-stamped t-legacy; do
  line=$(tail -1 "$H/state/$id.status")
  epoch=$(bash -c '. "$1"; status_line_at_epoch "$2"' _ "$BIN/fm-classify-lib.sh" "$line")
  if [ -n "$epoch" ] && [ "$epoch" -ge "$NOW" ]; then
    printf '  ok   %s close stamped at %s: %s\n' "$id" "$epoch" "$line"
  else
    printf '  FAIL %s close has no emission time: %s\n' "$id" "$line"; rc=1
  fi
done

hr "captain drain after answering"
OUT=$(FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_ROOT_OVERRIDE="$H" "$BIN/fm-wake-drain.sh" 2>/dev/null)
if printf '%s' "$OUT" | grep -q 'OPEN DECISIONS'; then
  echo "  FAIL decisions still open:"; printf '%s\n' "$OUT" | sed -n '/OPEN DECISIONS/,/close one/p'; rc=1
else
  echo "  ok   no OPEN DECISIONS remain"
fi

hr "fleet snapshot agrees the decisions are closed"
FM_HOME="$H" "$BIN/fm-fleet-snapshot.sh" --json | jq -c '[.tasks[]|{id, open:(.hints.open_decisions|length), pending:.hints.pending_decision, last:.paths.status_log.last_event.emitted_at_epoch}]'
[ "$rc" = 0 ] && echo "RESULT S6: PASS" || echo "RESULT S6: FAIL"
exit $rc
