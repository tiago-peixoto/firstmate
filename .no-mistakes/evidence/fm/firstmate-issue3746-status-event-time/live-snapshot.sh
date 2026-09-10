#!/usr/bin/env bash
# Live: brief scaffold append -> snapshot event time/age; legacy, malformed,
# duplicate, and future tags stay unknown-age; file mtime is never used.
. "$(dirname "$0")/live-common.sh"
trap cleanup_tmux EXIT
H=$(make_home snap)
mkdir -p "$H/projects/alpha-wt"
tmux new-session -d -s firstmate -n fm-ship-task 'cat'
write_meta "$H/state/ship-task.meta" "window=firstmate:fm-ship-task" \
  "worktree=$H/projects/alpha-wt" "project=alpha" "harness=claude" "kind=ship" "mode=direct-PR"

say "A. A crewmate follows the generated brief's status-append instruction"
run env FM_HOME="$H" "$ROOT/bin/fm-brief.sh" ship-task alpha --mode direct-PR >/dev/null
grep -F 'echo "{state}' "$H/data/ship-task/brief.md" | head -1
append=$(sed -n '/`echo "{state}/s/.*`\(echo .*\)`.*/\1/p' "$H/data/ship-task/brief.md" | head -1)
append=${append//\{state\}/done}
append=${append//\{one short line\}/PR ready for review}
printf '$ %s   # as the crewmate would run it\n' "$append"
before=$(date +%s); bash -c "$append"; after=$(date +%s)
printf 'state/ship-task.status now:\n'; cat "$H/state/ship-task.status"
ev=$(snapshot_event "$H" ship-task); printf 'snapshot last_event: %s\n' "$ev"
epoch=$(printf '%s' "$ev" | jq -r .emitted_at_epoch)
check "stamp is the append time" between "$epoch" "$before" "$after"
check "verb and note unchanged by the stamp" \
  jq -e '.state == "done" and .note == "PR ready for review"' <<<"$ev"
check "age derived from emission time (0..5s)" \
  jq -e '.age_seconds >= 0 and .age_seconds <= 5' <<<"$ev"

say "B. Unknown time stays unknown regardless of file mtime"
now=$(date +%s)
for line in 'done: legacy line with no time' \
  'done [at=bad]: malformed time' 'done [at=17:00]: malformed with colon' \
  'done [at=1] [at=2]: duplicate time fields' "done [at=$((now + 86400))]: future time" \
  "done [at=$((now - 3600))]: emitted an hour ago"; do
  printf '%s\n' "$line" > "$H/state/ship-task.status"
  for stamp in 202001010000 now; do
    if [ "$stamp" = now ]; then touch "$H/state/ship-task.status"; else touch -t "$stamp" "$H/state/ship-task.status"; fi
    ev=$(snapshot_event "$H" ship-task)
    printf 'line=%-50s mtime=%-12s -> emitted_at_epoch=%s age_seconds=%s\n' "'$line'" "$stamp" \
      "$(jq -r .emitted_at_epoch <<<"$ev")" "$(jq -r .age_seconds <<<"$ev")"
    case "$line" in
      *legacy*|*malformed*|*duplicate*)
        check "unknown time -> null epoch and null age (mtime $stamp)" \
          jq -e '.emitted_at_epoch == null and .age_seconds == null' <<<"$ev" ;;
      *future*)
        check "future time kept, age unknown (mtime $stamp)" \
          jq -e --argjson e "$((now + 86400))" '.emitted_at_epoch == $e and .age_seconds == null' <<<"$ev" ;;
      *hour*)
        check "age is from emission time, not mtime (mtime $stamp)" \
          jq -e --argjson e "$((now - 3600))" '.emitted_at_epoch == $e and .age_seconds >= 3600 and .age_seconds <= 3700' <<<"$ev" ;;
    esac
  done
done
printf '\nFAILS=%s\n' "$FAILS"
