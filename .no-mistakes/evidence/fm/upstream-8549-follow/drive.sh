#!/usr/bin/env bash
# Live drive of bin/fm-wake-drain.sh against disposable state/config dirs.
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-replay-drive.XXXXXX")
trap 'rm -rf "$T"' EXIT
DRAIN="$ROOT/bin/fm-wake-drain.sh"
mkdir -p "$T/on" "$T/off"
: > "$T/on/supervision-host-off"; : > "$T/on/result-replay"; : > "$T/off/supervision-host-off"
CFG="$T/on"
new() { S="$T/$1/state"; mkdir -p "$S"; echo; echo "===== SCENARIO: $2 ====="; }
q() { FM_STATE_OVERRIDE="$S" bash -c '. "$1"; fm_wake_append signal "$2" "signal: $2"' _ "$ROOT/bin/fm-wake-lib.sh" "$1"; }
d() { # <label> [stdout-target]
  echo "--- $1: fm-wake-drain.sh"
  FM_CONFIG_OVERRIDE="$CFG" FM_STATE_OVERRIDE="$S" "$DRAIN" > "${2:-$T/out}" 2> "$T/err"; echo "exit=$?"
  [ -n "${2:-}" ] && echo "(stdout sent to $2)" || sed 's/^/stdout| /' "$T/out"
  sed 's/^/stderr| /' "$T/err"
  cp "$T/err" "$T/err.$1"
}
ack() { # <label of drain whose printed command to run>
  local c; c=$(sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*\)$/\1/p' "$T/err.$1")
  echo "--- run printed ack from $1: fm-wake-drain.sh $c"
  # shellcheck disable=SC2086
  FM_CONFIG_OVERRIDE="$CFG" FM_STATE_OVERRIDE="$S" "$DRAIN" $c 2>&1 | sed 's/^/ack| /'; echo "exit=${PIPESTATUS[0]}"
}

new s1 "gate on: interrupted turn (no ack) - result must repeat"
printf 'done: UNIQUE_COMPLETED_RESULT\n' > "$S/result.status"; q result.status
d first; d second; d third
ack third; d after-ack; d after-ack-again

new s1b "gate on: first stdout to /dev/null, no ack - result must still appear"
printf 'done: UNIQUE_COMPLETED_RESULT\n' > "$S/result.status"; q result.status
d first /dev/null; d second

CFG="$T/off"
new s2 "DEFAULT home (no config/result-replay): one-shot presentation unchanged"
printf 'done: UNIQUE_COMPLETED_RESULT\n' > "$S/result.status"; q result.status
d first; d second
echo "receipt file:"; cat -A "$S/.status-presentation-cursor" 2>/dev/null
ack second; d after-ack
CFG="$T/on"

new s3 "gate on: empty queue completion gets an ack command, repeats, then silent"
printf 'done: finished without a queued signal\n' > "$S/quiet.status"
d first; d second; ack second; d after-ack

new s4 "gate on, adversarial: earlier partial ack must not retire row 2's result"
printf 'working: row one\n' > "$S/early.status"; q early.status
d first
printf 'done: row two result\n' > "$S/late.status"; q late.status
d second; ack first; d third; ack third; d fourth

new s5 "gate on: bounded replay - 6 results in one task"
for i in 1 2 3 4 5 6; do printf 'done: result %s\n' $i >> "$S/many.status"; done; q many.status
d first; d second

new s6 "gate on: ordinary note stays one-shot"
printf 'note: captain said use REST\n' > "$S/notes.status"
d first; d second

new s7 "gate on, adversarial: filtered consumer acks a stale generation / wrong generation"
printf 'done: guarded result\n' > "$S/g.status"; q g.status
d first
echo "--- ack with a wrong generation"
FM_CONFIG_OVERRIDE="$CFG" FM_STATE_OVERRIDE="$S" "$DRAIN" --ack-through 1 --recovery-generation bogus-generation 2>&1 | sed 's/^/ack| /'; echo "exit=${PIPESTATUS[0]}"
d second
