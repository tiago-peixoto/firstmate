#!/usr/bin/env bash
# Run from the gate worktree: bash <this-script> <evidence-directory>
set -eu
ROOT=$PWD
EVIDENCE=$1
FIXTURE=$(mktemp -d "$ROOT/.test-tmp-event-time/evidence.XXXXXX")
trap 'rm -rf "$FIXTURE"' EXIT
export TMPDIR="$ROOT/.test-tmp-event-time"
PARENT=$FIXTURE/parent
MATE=$FIXTURE/mate
mkdir -p "$PARENT/state" "$PARENT/data" "$MATE/state"
printf 'timed-secondmate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"
for id in timed-secondmate legacy-secondmate historical-secondmate malformed-secondmate; do
  printf 'kind=secondmate\nmode=secondmate\nharness=codex\nbackend=tmux\nwindow=\nhome=%s\n' "$FIXTURE/unavailable-$id" > "$PARENT/state/$id.meta"
done
. "$ROOT/bin/fm-classify-lib.sh"
before=$(date +%s)
printf '$ FM_HOME=<mate> bin/fm-secondmate-report.sh done 0123456789abcdef "build verified"\n'
FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" done 0123456789abcdef 'build verified'
after=$(date +%s)
line=$(cat "$PARENT/state/timed-secondmate.status")
epoch=$(status_line_at_epoch "$line")
[ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ]
printf '%s\n' "$line"
printf 'done: legacy report\n' > "$PARENT/state/legacy-secondmate.status"
printf 'done [at=1700000000]: historical report\n' > "$PARENT/state/historical-secondmate.status"
printf 'done [at=bad]: malformed time, preserved event\n' > "$PARENT/state/malformed-secondmate.status"
snapshot_epoch=$((epoch + 120))
for phase in old-mtime future-mtime; do
  if [ "$phase" = old-mtime ]; then mtime=1577836800; else mtime=$((snapshot_epoch + 86400)); fi
  python3 - "$PARENT/state" "$mtime" <<'PY'
import os, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('*.status'):
    os.utime(path, (int(sys.argv[2]), int(sys.argv[2])))
PY
  printf '\n$ FM_HOME=<parent> FM_SNAPSHOT_NOW_EPOCH=%s bin/fm-fleet-snapshot.sh --json\n' "$snapshot_epoch"
  printf 'All status files have mtime=%s (%s). Output projected to event-time fields:\n' "$mtime" "$phase"
  FM_HOME="$PARENT" FM_SNAPSHOT_NOW_EPOCH="$snapshot_epoch" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$EVIDENCE/snapshot-$phase.json"
  jq '{tasks: [.tasks[] | {id, last_event: .paths.status_log.last_event}], secondmates: [.secondmate_current.records[] | {id, current: .current.state, parent_event: {emitted_at_epoch: .parent_event.emitted_at_epoch, age_seconds: .parent_event.age_seconds}}]}' "$EVIDENCE/snapshot-$phase.json"
  jq -e --argjson epoch "$epoch" --argjson now "$snapshot_epoch" '
    all(.tasks[];
      .paths.status_log.last_event as $e |
      if .id == "timed-secondmate" then $e.emitted_at_epoch == $epoch and $e.age_seconds == 120
      elif .id == "historical-secondmate" then $e.emitted_at_epoch == 1700000000 and $e.age_seconds == ($now - 1700000000)
      else $e.emitted_at_epoch == null and $e.age_seconds == null end)
    and all(.secondmate_current.records[];
      if .id == "timed-secondmate" then .parent_event.emitted_at_epoch == $epoch and .parent_event.age_seconds == 120
      elif .id == "historical-secondmate" then .parent_event.emitted_at_epoch == 1700000000 and .parent_event.age_seconds == ($now - 1700000000)
      else .parent_event.emitted_at_epoch == null and .parent_event.age_seconds == null end)
  ' "$EVIDENCE/snapshot-$phase.json" >/dev/null
done
cmp <(jq '[.tasks[].paths.status_log.last_event]' "$EVIDENCE/snapshot-old-mtime.json") \
    <(jq '[.tasks[].paths.status_log.last_event]' "$EVIDENCE/snapshot-future-mtime.json")
printf '\nEvent fields are identical after changing file mtime from 2020 to the future.\n'
. "$ROOT/bin/fm-parent-channel-lib.sh"
for id in historical-secondmate legacy-secondmate; do
  line=$(cat "$PARENT/state/$id.status")
  fm_parent_channel_append_once "$FIXTURE/relay.status" "$line" relay
  fm_parent_channel_append_once "$FIXTURE/relay.status" "$line" relay
done
[ "$(wc -l < "$FIXTURE/relay.status")" -eq 2 ]
printf '\nParent relay output after publishing each source event twice:\n'
cat "$FIXTURE/relay.status"
cp "$FIXTURE/relay.status" "$EVIDENCE/relayed-events.status"
for id in timed-secondmate legacy-secondmate historical-secondmate malformed-secondmate; do
  printf '%s: ' "$id"
  cat "$PARENT/state/$id.status"
done > "$EVIDENCE/emitted-events.txt"
printf '\nCaptain relevance with FM_CAPTAIN_RE=done:|needs-decision:|blocked:|failed:\n'
export FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:'
missed=0
for line in 'done: build verified' 'done [at=1700000000]: build verified' \
  'done [at=]: build verified' 'done [at=bad]: build verified' \
  'done [at=$(date +%s)]: build verified' 'done [at=1] [at=2]: build verified'; do
  printf '%s\n' "$line" > "$FIXTURE/task.status"
  selected=$(status_span_first_actionable "$FIXTURE/task.status" 0) || selected=''
  printf 'stored: %s\nselected notification: %s\n' "$line" "${selected:-<none>}"
  [ "$(cat "$FIXTURE/task.status")" = "$line" ]
  [ "$selected" = "$line" ] || missed=$((missed + 1))
done
printf '\nMissed terminal notifications: %s\n' "$missed"
[ "$missed" -eq 0 ]
