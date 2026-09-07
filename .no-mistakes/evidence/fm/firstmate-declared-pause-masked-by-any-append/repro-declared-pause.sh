#!/usr/bin/env bash
# repro-declared-pause.sh <tree> <label> [masked|undeclared|bounded]
#
# Drives the REAL bin/fm-crew-state.sh, bin/fm-watch.sh and bin/fm-wake-drain.sh
# of a whole firstmate tree over the reported live sequence:
#
#   state/<id>.status:
#     paused: waiting on the upstream maintainer to review PR 3753
#     working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,failed   <- foreign append
#
# ...with the crew's pane idle and unchanged for 500s, past the watcher's
# possible-wedge threshold. Only `no-mistakes` (no active run) and `tmux` (an
# idle pane) are faked; every decision shown below is the product's own.
#
# Scenarios:
#   masked      the sequence above (default)
#   undeclared  byte-for-byte the same log with the `paused:` line removed -
#               the disconfirming case: it must still escalate
#   bounded     the masked sequence, aged past FM_PAUSE_RESURFACE_SECS - the
#               declared wait must come back for a recheck, not go silent
set -u
TREE=$1; LABEL=$2; SCENARIO=${3:-masked}
ID=attest-upstream-pr3753
WINDOW=fm:fm-$ID
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-declared-pause-XXXXXX")
trap 'rm -rf "$CASE"' EXIT
mkdir -p "$CASE/state" "$CASE/fakebin" "$CASE/wt"

cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  display-message)
    case "$*" in
      *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;;
      *) printf '%%1\n'; exit 0 ;;
    esac ;;
esac
exit 1
SH
cat > "$CASE/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
# No active pipeline run: the crew's run has ended and it is waiting on a human.
case "${1:-}" in
  axi) shift; case "${1:-}" in status|logs) printf '\n' ;; esac ;;
  runs) printf '\n' ;;
esac
exit 0
SH
chmod +x "$CASE/fakebin/tmux" "$CASE/fakebin/no-mistakes"

git -C "$CASE/wt" init -q
git -C "$CASE/wt" -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
git -C "$CASE/wt" checkout -q -b "fm/$ID"

PANE='waiting on upstream review, nothing to do'
printf '%s' "$PANE" > "$CASE/pane.txt"
printf 'window=%s\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' \
  "$WINDOW" "$CASE/wt" > "$CASE/state/$ID.meta"
STATUSF="$CASE/state/$ID.status"
: > "$STATUSF"
[ "$SCENARIO" = undeclared ] || \
  printf 'paused: waiting on the upstream maintainer to review PR 3753\n' >> "$STATUSF"
printf 'working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,failed\n' >> "$STATUSF"

gen=$("$TREE/bin/fm-busy-event.sh" arm "$CASE/state" "$ID")
"$TREE/bin/fm-busy-event.sh" apply "$CASE/state" "$ID" idle --gen "$gen" \
  --source claude-hook --event stop

export PATH="$CASE/fakebin:$PATH"
export FM_STATE_OVERRIDE="$CASE/state"
export FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$CASE/pane.txt"
export FM_FAKE_TMUX_CURRENT_COMMAND=zsh
export FM_CREW_STATE_BIN="$TREE/bin/fm-crew-state.sh"

backdate() { local b; b=$(( $(date +%s) - $2 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$b" '+%Y%m%d%H%M.%S')" "$1"
  else touch -m -d "@$b" "$1"; fi; }

# One watcher re-arm. Prints what firstmate is woken with, or that it was not.
run_watcher() {  # <resurface-secs>
  local out="$CASE/watch.out" pid i=0
  : > "$out"
  FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS="$1" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$TREE/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while [ "$i" -lt 100 ]; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo "    watcher still running after 10s: NO WAKE - the crew was left alone"
  else
    echo "    watcher EXITED to wake firstmate. Its wake reason:"
    sed 's/^/      /' "$out"
  fi
}

drain() {
  local d="$CASE/drain.out"
  "$TREE/bin/fm-wake-drain.sh" > "$d" 2>/dev/null || true
  if [ -s "$d" ]; then sed 's/^/      /' "$d"; else echo "      (empty: nothing queued)"; fi
}

markers() {
  if [ -e "$CASE/state/.paused-$KEY" ]
  then echo "    .paused-<win>            present  -> bounded external-wait cadence"
  else echo "    .paused-<win>            absent   -> no bounded cadence"; fi
  if [ -e "$CASE/state/.wedge-escalations-$KEY" ]
  then echo "    .wedge-escalations-<win> $(cat "$CASE/state/.wedge-escalations-$KEY")        -> possible-wedge ladder climbing"
  else echo "    .wedge-escalations-<win> absent   -> possible-wedge ladder not climbing"; fi
}

echo "=============================================================================="
echo "$LABEL   [scenario: $SCENARIO]"
echo "=============================================================================="
echo "\$ cat state/$ID.status"
sed 's/^/    /' "$STATUSF"
echo
echo "--- 1. authoritative crew state, the reader every pause gate consults -------"
echo "\$ bin/fm-crew-state.sh $ID"
printf '    '; "$TREE/bin/fm-crew-state.sh" "$ID"
echo
echo "--- 2. the supervisor's absorb decision for that crew -----------------------"
echo "\$ crew_absorb_class $ID   (paused/working = absorb, none = possible-wedge ladder)"
# shellcheck disable=SC1090
. "$TREE/bin/fm-classify-lib.sh"
printf '    '; crew_absorb_class "$ID"; echo
echo

# Prime the watcher's bookkeeping: the status log is already reported, and the
# pane hash has been unchanged for 500s - past the 240s wedge threshold below.
# shellcheck disable=SC1090
. "$TREE/bin/fm-wake-lib.sh"
fm_wake_status_reported_commit "$CASE/state" "$STATUSF" "$(fm_wake_signal_sig "$STATUSF")"
if command -v md5 >/dev/null 2>&1; then H=$(printf '%s' "$PANE" | md5 -q)
else H=$(printf '%s' "$PANE" | md5sum | cut -d' ' -f1); fi
printf '%s' "$H" > "$CASE/state/.hash-$KEY"
printf '1\n' > "$CASE/state/.count-$KEY"
printf '%s' "$H" > "$CASE/state/.stale-$KEY"
echo $(( $(date +%s) - 500 )) > "$CASE/state/.stale-since-$KEY"

echo "--- 3. the watcher itself, one re-arm over that idle pane -------------------"
echo "\$ bin/fm-watch.sh   (exits only to wake firstmate; a wake costs a supervision turn)"
run_watcher 999
echo
echo "\$ bin/fm-wake-drain.sh   (what firstmate is handed)"
drain
echo
echo "--- 4. pause bookkeeping written for this crew ------------------------------"
markers
echo

if [ "$SCENARIO" = bounded ]; then
  echo "--- 5. the same crew, now past FM_PAUSE_RESURFACE_SECS ----------------------"
  echo "    (the declared wait is aged 500s and the recheck cadence set to 240s)"
  for m in "$CASE/state/.paused-since-$KEY" "$STATUSF"; do [ -e "$m" ] && backdate "$m" 500; done
  fm_wake_status_reported_commit "$CASE/state" "$STATUSF" "$(fm_wake_signal_sig "$STATUSF")"
  printf '%s (token 2)' "$PANE" > "$CASE/pane.txt"
  echo "\$ bin/fm-watch.sh"
  run_watcher 240
  echo
  echo "\$ bin/fm-wake-drain.sh"
  drain
  echo
fi
