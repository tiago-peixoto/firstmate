. /tmp/fm-live/common.sh
H=$(mktemp -d /tmp/fm-live/home-s1.XXXXXX)
mkdir -p "$H"/{state,data,projects}
FB=$(make_fakebin "$H")
export PATH="$FB:$PATH"

hr "captain scaffolds a no-mistakes ship task brief (real bin/fm-brief.sh)"
FM_HOME="$H" "$BIN/fm-brief.sh" ship-alpha firstmate --mode no-mistakes
BRIEF="$H/data/ship-alpha/brief.md"

hr "the status-report interface the brief hands the worker"
grep -n 'echo "{state}' "$BRIEF"
grep -n 'append .done \[at=' "$BRIEF"

write_meta "$H/state/ship-alpha.meta" \
  "window=firstmate:fm-ship-alpha" "worktree=$H/projects/alpha" "project=firstmate" \
  "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"

hr "worker runs the brief's rule-4 append verbatim (shell evaluates the stamp now)"
APPEND=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$BRIEF")
APPEND=${APPEND//\{state\}/working}
APPEND=${APPEND//\{one short line\}/fix implemented, validating}
printf '$ %s\n' "$APPEND"
bash -c "$APPEND" || echo "APPEND FAILED"

hr "worker reaches CI green and follows the Definition of done ready signal"
BEFORE=$(date +%s)
READY=$(grep -o 'done \[at=\$(date +%s)\]: PR {url} checks green' "$BRIEF")
READY=${READY//\{url\}/https://github.com/kunchenguid/firstmate/pull/3746}
printf '$ echo "%s" >> %s\n' "$READY" "$H/state/ship-alpha.status"
eval "printf '%s\n' \"$READY\"" >> "$H/state/ship-alpha.status"
AFTER=$(date +%s)

hr "state/ship-alpha.status as written by the worker"
cat "$H/state/ship-alpha.status"

hr "captain reads the fleet snapshot (real bin/fm-fleet-snapshot.sh --json)"
OUT=$(FM_HOME="$H" "$BIN/fm-fleet-snapshot.sh" --json)
printf '%s' "$OUT" | jq '.tasks[]|select(.id=="ship-alpha")|.paths.status_log'

EPOCH=$(printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="ship-alpha")|.paths.status_log.last_event.emitted_at_epoch')
AGE=$(printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="ship-alpha")|.paths.status_log.last_event.age_seconds')
echo "worker appended between $BEFORE and $AFTER; snapshot emitted_at_epoch=$EPOCH age_seconds=$AGE"
if [ "$EPOCH" = null ] || [ "$EPOCH" -lt "$BEFORE" ] || [ "$EPOCH" -gt "$AFTER" ]; then
  echo "RESULT S1: FAIL - emission time is not the append time"; exit 1
fi
[ "$AGE" = null ] && { echo "RESULT S1: FAIL - age unknown for a stamped event"; exit 1; }

hr "same snapshot 90 seconds later (FM_SNAPSHOT_NOW_EPOCH) ages the same event"
FM_HOME="$H" FM_SNAPSHOT_NOW_EPOCH=$((EPOCH + 90)) "$BIN/fm-fleet-snapshot.sh" --json \
  | jq '.tasks[]|select(.id=="ship-alpha")|.paths.status_log.last_event|{emitted_at_epoch,age_seconds,raw}'

hr "the PR URL the captain copies is still readable from the stamped ready line"
printf '%s' "$OUT" | jq -r '.tasks[]|select(.id=="ship-alpha")|{pr:.pr.url, state:.current_state.state, note:.paths.status_log.last_event.note}'
echo "RESULT S1: PASS"
echo "HOME=$H"
