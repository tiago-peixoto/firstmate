#!/usr/bin/env bash
# Live: the real fm-watch.sh watcher against a provably-busy crew in a real tmux
# pane. A stamped captain-relevant line must surface, a stamped progress line must
# be absorbed, exactly like the unstamped twin, including under an FM_CAPTAIN_RE
# override and with malformed time tags.
. "$(dirname "$0")/live-common.sh"
trap 'cleanup_tmux; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null' EXIT
H=$(make_home watch)
S="$H/state"
mkdir -p "$H/projects/wt"
tmux new-session -d -s firstmate -n fm-t1 'cat'
write_meta "$S/t1.meta" "window=firstmate:fm-t1" "worktree=$H/projects/wt" "project=alpha" \
  "harness=claude" "kind=ship" "mode=direct-PR"
printf 'working: started\n' > "$S/t1.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$S" t1)
"$ROOT/bin/fm-busy-event.sh" apply "$S" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
printf 'crew-state: %s\n' "$(FM_HOME="$H" FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-crew-state.sh" t1 2>/dev/null)"

watch_case() {  # <expect surfaced|absorbed> <line> [env assignments...]
  local expect=$1 line=$2 out="$WORK/watch.out" i got=absorbed
  shift 2
  rm -f "$S/.last-watcher-beat" "$out"
  env FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$@" "$ROOT/bin/fm-watch.sh" > "$out" 2>"$WORK/watch.err" &
  WPID=$!
  for i in $(seq 1 100); do [ -e "$S/.last-watcher-beat" ] && break; sleep 0.1; done
  sleep 1.5
  printf '%s\n' "$line" >> "$S/t1.status"
  for i in $(seq 1 60); do kill -0 "$WPID" 2>/dev/null || { got=surfaced; break; }; sleep 0.1; done
  if [ "$got" = absorbed ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
  WPID=''
  printf '%-60s %s -> %s  watcher stdout: %s\n' "'$line'" "${*:-(default FM_CAPTAIN_RE)}" "$got" "$(tr '\n' ' ' < "$out")"
  check "$expect: $line ${*}" [ "$got" = "$expect" ]
  FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1 || true
  err=$(FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p')
  if [ -n "$seq" ]; then
    FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-wake-drain.sh" --ack-through "${seq% *}" --recovery-generation "${seq#* }" >/dev/null 2>&1 || true
  fi
}

now=$(date +%s)
say "E1. Default classification: stamped lines behave like their unstamped twins"
watch_case absorbed 'working: done: mentioned in passing'
watch_case absorbed "working [at=$now]: done: mentioned in passing"
watch_case surfaced 'done: PR ready'
watch_case surfaced "done [at=$now]: PR ready"
watch_case surfaced "needs-decision [key=k1] [at=$now]: A or B"

say "E2. FM_CAPTAIN_RE override: time tags (even malformed) never hide an actionable verb"
RE='FM_CAPTAIN_RE=done:|needs-decision:|blocked:|failed:'
watch_case surfaced 'done: audit complete' "$RE"
watch_case surfaced "done [at=$now]: audit complete" "$RE"
watch_case surfaced 'failed [at=17:00]: malformed colon tag' "$RE"
watch_case surfaced 'blocked [at=bad] [at=17:00]: duplicate malformed tags' "$RE"
watch_case absorbed "working [at=$now]: done: mentioned" "$RE"
watch_case absorbed "blocked [at=$now]: waiting" 'FM_CAPTAIN_RE=done:'
printf '\nstored status bytes (never rewritten by classification):\n'; cat "$S/t1.status"
printf '\nFAILS=%s\n' "$FAILS"
