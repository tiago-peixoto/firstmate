#!/usr/bin/env bash
# Live drive: the captain answers an open decision with the real fm-send.sh
# against a real tmux endpoint on an isolated tmux socket directory. The
# resolved close line fm-send appends must carry a fresh [at=<epoch>] stamp and
# still close the keyed decision; the worker's own decision line stays legacy.
# Usage: drive-fm-send-resolve.sh <firstmate-checkout>
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3746-send.XXXXXX")
export TMUX_TMPDIR=$W/tmux; mkdir -p "$TMUX_TMPDIR"; unset TMUX
H=$W/home; mkdir -p "$H/state" "$H/data"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT
tmux new-session -d -s sess -n fm-t1 'bash --norc --noprofile' || { echo "cannot start isolated tmux"; exit 1; }
printf '%s\n' "window=sess:fm-t1" "kind=ship" "harness=codex" > "$H/state/t1.meta"
printf '%s\n' 'needs-decision [key=api-shape]: pick REST or RPC' 'working: kept busy on an unrelated stream' > "$H/state/t1.status"
echo "--- state/t1.status before answer (legacy worker lines, no stamps) ---"; cat "$H/state/t1.status"
echo "--- open decisions before:"; bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$H/state/t1.status"; echo
before=$(date +%s)
echo "\$ fm-send.sh t1 --resolve-key api-shape 'go with REST'"
# Sandboxed fleet: use the documented test-harness bypass (bin/fm-gate-refuse-lib.sh).
FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE=$H FM_HOME=$H FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" t1 --resolve-key api-shape "go with REST"
rc=$?; after=$(date +%s)
echo "fm-send exit=$rc"
echo "--- state/t1.status after answer ---"; cat "$H/state/t1.status"
close=$(tail -1 "$H/state/t1.status")
epoch=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_line_at_epoch "$2"' _ "$ROOT" "$close")
open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$H/state/t1.status")
first=$(head -1 "$H/state/t1.status")
fails=0
[ "$rc" -eq 0 ] && echo "PASS: fm-send delivered" || { echo "FAIL: fm-send exit $rc"; fails=1; }
if [ -n "$epoch" ] && [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ]; then echo "PASS: close line stamped at answer time ($epoch in [$before,$after])"; else echo "FAIL: close line stamp '${epoch:-none}'"; fails=1; fi
[ -z "$open" ] && echo "PASS: stamped resolved line closed key api-shape" || { echo "FAIL: still open: $open"; fails=1; }
[ "$first" = 'needs-decision [key=api-shape]: pick REST or RPC' ] && echo "PASS: worker's legacy decision line not restamped" || { echo "FAIL: legacy line rewritten: $first"; fails=1; }
ls "$H/state/t1.inbox/" 2>/dev/null | sed 's/^/inbox record: /'
exit "$fails"
