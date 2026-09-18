#!/usr/bin/env bash
# Live drive of issue 3746 (optional [at=<epoch>] emission stamp on new status
# records) against the real firstmate bin/ scripts in an isolated FM home.
# Usage: drive-status-event-time.sh <firstmate-checkout>
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3746-live.XXXXXX")
trap 'rm -rf "$W"' EXIT
H=$W/home
FB=$W/fakebin
mkdir -p "$H/state" "$H/data" "$H/projects/alpha" "$H/config" "$FB" "$H/mate"
# Fake tmux/no-mistakes so the snapshot never reads the operator's real tmux.
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
printf '#!/usr/bin/env bash\ncase "${1:-}" in display-message) printf "codex\\n";; esac\nexit 0\n' > "$FB/tmux"
chmod +x "$FB/no-mistakes" "$FB/tmux"
export PATH="$FB:$PATH"
: > "$H/data/backlog.md"
FAILS=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi; }
at_of() { bash -c '. "$1/bin/fm-classify-lib.sh"; status_line_at_epoch "$2"' _ "$ROOT" "$1"; }

meta() {  # <id> <kind>
  printf '%s\n' "window=firstmate:fm-$1" "worktree=$H/projects/alpha" "project=alpha" \
    "harness=codex" "kind=$2" "mode=$2" "yolo=off" > "$H/state/$1.meta"
}

echo "=== S1: secondmate reports an outcome through the real report helper ==="
meta mate secondmate
printf '%s\n' "home=$H/mate" >> "$H/state/mate.meta"
printf 'mate\n' > "$H/mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$H/mate/.fm-secondmate-parent"
before=$(date +%s)
echo "\$ FM_HOME=mate bin/fm-secondmate-report.sh done 0123456789abcdef 'audit complete'"
FM_HOME=$H/mate "$ROOT/bin/fm-secondmate-report.sh" done 0123456789abcdef 'audit complete'
after=$(date +%s)
line=$(tail -1 "$H/state/mate.status")
echo "parent state/mate.status -> $line"
epoch=$(at_of "$line")
check "report line carries [at=<epoch>] within [$before,$after] (got ${epoch:-none})" \
  '[ -n "$epoch" ] && [ "$epoch" -ge "$before" ] && [ "$epoch" -le "$after" ]'
verb=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_line_verb "$2"' _ "$ROOT" "$line")
note=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_line_note "$2"' _ "$ROOT" "$line")
check "classifier still reads verb=done (got $verb) and note unchanged (got '$note')" \
  '[ "$verb" = done ] && [ "$note" = "audit complete (via-helper)" ]'

echo
echo "=== S2: brief scaffold stamps at worker append time, not scaffold time ==="
FM_HOME=$H "$ROOT/bin/fm-brief.sh" briefed alpha --mode no-mistakes >/dev/null
# shellcheck disable=SC2016
cmd=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$H/data/briefed/brief.md" | head -1)
echo "brief rule 4 command: $cmd"
dod=$(grep -o 'append `done \[at=[^`]*`' "$H/data/briefed/brief.md" | head -1)
echo "brief definition-of-done: $dod"
gen_time=$(date +%s)
sleep 2
cmd=${cmd//\{state\}/done}; cmd=${cmd//\{one short line\}/validation passed}
run_time=$(date +%s)
echo "\$ $cmd"
(cd "$H" && bash -c "$cmd")
line=$(tail -1 "$H/state/briefed.status")
echo "state/briefed.status -> $line"
epoch=$(at_of "$line")
check "worker-appended stamp is execution time ($run_time), not scaffold time ($gen_time); got ${epoch:-none}" \
  '[ -n "$epoch" ] && [ "$epoch" -ge "$run_time" ]'

echo
echo "=== S3: fleet snapshot exposes emission time and age; legacy/malformed stay unknown ==="
NOW=1788576100
for spec in 'stamped|done [at=1788576000]: PR https://example.test/o/r/pull/7 checks green' \
  'legacy|done: PR https://example.test/o/r/pull/8' \
  'malformed|done [at=17:00]: shipped' \
  'empty|done [at=]: shipped' \
  'dup|done [at=1788576000] [at=1788576050]: shipped' \
  'future|working [at=1788576200]: clock skew' \
  'prose|done: mentions [at=1788576000] in prose'; do
  id=${spec%%|*}; meta "$id" ship
  printf '%s\n' "${spec#*|}" > "$H/state/$id.status"
  # A fresh-looking file must never stand in for event time.
  touch "$H/state/$id.status"
done
out=$(FM_HOME=$H FM_SNAPSHOT_NOW_EPOCH=$NOW "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>"$W/snap.err") \
  || { echo "snapshot failed:"; cat "$W/snap.err"; }
printf '%s' "$out" > "$W/snapshot.json"
echo "\$ FM_HOME=home FM_SNAPSHOT_NOW_EPOCH=$NOW bin/fm-fleet-snapshot.sh --json | jq '.tasks[] | {id, last_event}'"
jq -c '.tasks[] | select(.id != "mate" and .id != "briefed") | {id, last_event: .paths.status_log.last_event}' "$W/snapshot.json"
ev() { jq -c --arg id "$1" '.tasks[] | select(.id == $id) | .paths.status_log.last_event | [.emitted_at_epoch, .age_seconds]' "$W/snapshot.json"; }
check "stamped: epoch 1788576000, age 100 ($(ev stamped))" '[ "$(ev stamped)" = "[1788576000,100]" ]'
check "future: epoch retained, age unknown ($(ev future))" '[ "$(ev future)" = "[1788576200,null]" ]'
for id in legacy malformed empty dup prose; do
  check "$id: emission time and age both null, not file mtime ($(ev "$id"))" '[ "$(ev "$id")" = "[null,null]" ]'
done
check "malformed stamp keeps its verb (state=$(jq -r '.tasks[]|select(.id=="malformed")|.paths.status_log.last_event.state' "$W/snapshot.json"))" \
  '[ "$(jq -r ".tasks[]|select(.id==\"malformed\")|.paths.status_log.last_event.state" "$W/snapshot.json")" = done ]'

echo
echo "=== S4: event time never decides decision closure ==="
# A secondmate record: the snapshot never lifecycle-clears its keyed decisions,
# so hints.open_decisions shows the status fold itself.
meta decide secondmate
mkdir -p "$H/decide-home"; printf '%s\n' "home=$H/decide-home" >> "$H/state/decide.meta"
printf '%s\n' 'needs-decision [key=api-shape] [at=1788576000]: choose REST or gRPC' \
  'working [at=1788576050]: exploring both' > "$H/state/decide.status"
open1=$(FM_HOME=$H FM_SNAPSHOT_NOW_EPOCH=$NOW "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[]|select(.id=="decide")|.hints.open_decisions')
echo "after stamped needs-decision + later working: open_decisions=$open1"
check "stamped decision stays open after a later working event" 'printf "%s" "$open1" | grep -q api-shape'
printf '%s\n' 'resolved [key=api-shape] [at=1788575000]: answered: use REST' >> "$H/state/decide.status"
open2=$(FM_HOME=$H FM_SNAPSHOT_NOW_EPOCH=$NOW "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[]|select(.id=="decide")|.hints.open_decisions')
echo "after resolved line whose [at=] is EARLIER than the decision: open_decisions=$open2"
check "keyed resolved closes the decision by log order even with an older stamp" '[ "$open2" = "[]" ]'

echo
echo "=== S5: parent-channel retry is deduplicated, never restamped ==="
bash -c '
  . "$1/bin/fm-parent-channel-lib.sh"
  f=$2/state/retry.status
  printf "%s\n" "$(status_stamp_line "done [corr=0123456789abcdef]: shipped")" > "$f"
  first=$(cat "$f"); sleep 1
  fm_parent_channel_append_once "$f" "done [corr=0123456789abcdef]: shipped"
  fm_parent_channel_append_once "$f" "$(status_stamp_line "done [corr=0123456789abcdef]: shipped")"
  printf "%s\n" "$first" > "$2/first"
' _ "$ROOT" "$H"
echo "state/retry.status after two retries:"; cat "$H/state/retry.status"
check "retries left exactly the original stamped line" \
  '[ "$(wc -l < "$H/state/retry.status" | tr -d " ")" = 1 ] && [ "$(cat "$H/state/retry.status")" = "$(cat "$H/first")" ]'

echo
[ "$FAILS" -eq 0 ] && echo "RESULT: all live checks passed" || echo "RESULT: $FAILS live checks FAILED"
exit "$FAILS"
