#!/usr/bin/env bash
# Live driver for kunchenguid/firstmate#4096. Runs the REAL bin/fm-supervise-daemon.sh
# as a background process (with its real bin/fm-watch.sh child and real
# bin/fm-wake-drain.sh) in away mode, against a throwaway firstmate home and a
# private tmux socket whose supervisor pane logs every submitted line verbatim.
# It then writes status logs the way crewmates do and records exactly what
# reached the supervisor pane. The decision's backlog row is placed under a real
# captain hold (bin/fm-captain-hold.sh + tasks-axi) before the daemon starts.
#
# Usage: [FM_LIVE_SCAN_SECS=N] live-decision-wake.sh <repo-root> <label> <out-dir>
set -u
REPO=$1 LABEL=$2 OUT=$3
SCAN=${FM_LIVE_SCAN_SECS:-3}
BIN="$REPO/bin"
DAEMON="$BIN/fm-supervise-daemon.sh"
DRAIN="$BIN/fm-wake-drain.sh"
REAL_TMUX=$(command -v tmux)
SOCKET="nd-live-$LABEL-$$"
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-nd-live.XXXXXX")
HOME_DIR="$WORK/home"
STATE_DIR="$HOME_DIR/state"
SHIM="$WORK/shim"
HOLDBIN="$WORK/holdbin"
mkdir -p "$HOME_DIR/data" "$STATE_DIR" "$HOME_DIR/config" "$HOME_DIR/projects" "$SHIM" "$HOLDBIN"
LOG_FILE="$STATE_DIR/submitted.log"; : > "$LOG_FILE"
SUMMARY="$OUT/summary.txt"; : > "$SUMMARY"
DAEMON_PID=

stop_daemon() {
  [ -n "$DAEMON_PID" ] || return 0
  kill "$DAEMON_PID" 2>/dev/null; wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=
}
cleanup() {
  stop_daemon
  "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

note() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
count_sub() { grep -c -- "$1" "$LOG_FILE" 2>/dev/null; }
count_log() { grep -c -- "$1" "$STATE_DIR/.supervise-daemon.log" 2>/dev/null; }
wait_for_sub() {  # <pattern> <timeout-secs>
  local i=0
  while [ "$i" -lt "$2" ]; do
    grep -q -- "$1" "$LOG_FILE" && return 0
    sleep 1; i=$((i + 1))
  done
  return 1
}
hold_cmd() {
  PATH="$HOLDBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$BIN/fm-captain-hold.sh" "$@"
}

# --- throwaway home with the decision's backlog row under a captain hold -------
cp "$REPO/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n- [ ] decision-task - Ship the release (repo: sample) (kind: ship) (since 2026-01-01)\n\n## Done\n' \
  > "$HOME_DIR/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOLDBIN/$t"; chmod +x "$HOLDBIN/$t"
done

# --- supervisor pane: a deterministic composer that logs each submitted line ---
# (same fixture shape as tests/fm-afk-inject-e2e.test.sh: "❯ " prompt glyph, logs
# hex, text and whether the line carried the operational-input marker.)
LOOP="$SHIM/supervisor-loop.sh"
cat > "$LOOP" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
trap '[ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true' EXIT INT TERM
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"; }
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then _c=injection; else _c=user; fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K%s\n' "$_line"
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 250 -y 60
PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$LOOP' '$LOG_FILE'" Enter
sleep 1

cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"

hold_cmd hold decision-task --reason "needs-decision [key=release]: pick A or B" >/dev/null 2>"$OUT/hold.err"
note "== [$LABEL] captain hold placed on backlog row decision-task: exit $?"
hold_cmd open decision-task >/dev/null 2>&1
note "   hold open before the daemon starts: exit $? (0 = open)"

# --- away mode on, start the real daemon --------------------------------------
date '+%s' > "$STATE_DIR/.afk"
env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID \
  PATH="$SHIM:$PATH" \
  FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SUPERVISOR_TARGET="$PANE" \
  FM_SUPERVISOR_BACKEND=tmux \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_HEARTBEAT_SCAN_SECS="$SCAN" \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" > "$OUT/daemon.out" 2> "$OUT/daemon.err" &
DAEMON_PID=$!
i=0; while [ "$i" -lt 30 ] && [ ! -f "$STATE_DIR/.supervise-daemon.pid" ]; do sleep 0.2; i=$((i + 1)); done
[ -f "$STATE_DIR/.supervise-daemon.pid" ] || { note "daemon did not start"; cat "$OUT/daemon.err"; exit 1; }
note "== [$LABEL] real daemon pid $DAEMON_PID up; afk on; catch-all scan every ${SCAN}s, watcher poll 1s"
sleep 2   # let the startup catch-all scan pass, so the next one is ${SCAN}s away

# --- A: a decision-owned needs-decision wake, then the status stays unchanged ---
note ""
note "== A. crewmate writes a keyed needs-decision; status then stays unchanged for 35s"
printf 'working: setup\nneeds-decision [key=release]: pick A or B\n' > "$STATE_DIR/decision-task.status"
wait_for_sub 'decision-task' 30 || note "  (no submission naming decision-task within 30s)"
sleep 35
note "  queued rows handled as needs-decision:    $(count_log 'needs-decision: .*decision-task.status')"
note "  escalated by the queued row itself:       $(count_log 'escalate: needs-decision: .*decision-task.status')"
note "  supervisor submissions naming the task:   $(count_sub 'decision-task')"
note "  ...tagged (catch-all scan):               $(grep 'decision-task' "$LOG_FILE" | grep -c 'catch-all scan')"
note "  ...labelled 'unknown wake:':              $(grep 'decision-task' "$LOG_FILE" | grep -c 'unknown wake:')"
note "  ...carrying the decision text:            $(count_sub 'needs-decision \[key=release\]: pick A or B')"
A_TOTAL=$(count_sub 'decision-task')

# --- B: the decision changes (status grows) -------------------------------------
note ""
note "== B. crewmate appends a changed decision; then unchanged for 30s"
printf 'needs-decision [key=release]: pick A, C, or D\n' >> "$STATE_DIR/decision-task.status"
wait_for_sub 'pick A, C, or D' 30 || note "  (changed decision not submitted within 30s)"
sleep 30
note "  new submissions naming the task:          $(( $(count_sub 'decision-task') - A_TOTAL ))"
note "  ...carrying the changed decision text:    $(count_sub 'needs-decision \[key=release\]: pick A, C, or D')"
note "  ...labelled 'unknown wake:' (all time):   $(grep 'decision-task' "$LOG_FILE" | grep -c 'unknown wake:')"
note "  escalated by the queued row (all time):   $(count_log 'escalate: needs-decision: .*decision-task.status')"

# --- C: a captain-held transfer is the only new line ----------------------------
note ""
note "== C. a task's only new line is a captain-held [key=...] transfer; watch 30s"
printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$STATE_DIR/held-task.status"
sleep 30
note "  queued rows handled as needs-decision:    $(count_log 'needs-decision: .*held-task.status')"
note "  daemon self-handled those rows:           $(count_log 'self-handle: needs-decision: .*held-task.status')"
note "  supervisor submissions naming held-task:  $(count_sub 'held-task')"

# --- D: ordinary signal wakes ---------------------------------------------------
note ""
note "== D. ordinary signals: a routine working: note, then a done: line"
printf 'working: still going\n' > "$STATE_DIR/routine-task.status"
sleep 12
note "  routine rows handled as signal:           $(count_log 'signal: .*routine-task.status')"
note "  supervisor submissions naming routine:    $(count_sub 'routine-task')"
printf 'done: PR https://example.test/pull/1\n' > "$STATE_DIR/done-task.status"
wait_for_sub 'done-task' 30 || note "  (done not submitted within 30s)"
sleep 25
note "  escalated by the queued signal row:       $(count_log 'escalate: signal: .*done-task.status')"
note "  supervisor submissions naming done-task:  $(count_sub 'done-task')"
note "  ...carrying the done line:                $(count_sub 'done: PR https://example.test/pull/1')"
note "  ...labelled 'unknown wake:':              $(grep 'done-task' "$LOG_FILE" | grep -c 'unknown wake:')"

# --- evidence: pane, submissions, daemon log -------------------------------------
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -J -S -300 -t "$PANE" > "$OUT/supervisor-pane.txt" 2>/dev/null
stop_daemon
cut -f2,3 "$LOG_FILE" > "$OUT/supervisor-submissions.txt"
sed "s#$STATE_DIR/##g" "$STATE_DIR/.supervise-daemon.log" > "$OUT/supervise-daemon.log" 2>/dev/null

# --- E: the decision is not lost: a locked drain and the backlog hold -----------
note ""
note "== E. daemon stopped; a locked fm-wake-drain.sh run over the same state, and the backlog hold"
env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID PATH="$SHIM:$PATH" \
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$DRAIN" > "$OUT/drain.out" 2> "$OUT/drain.err"
note "  drain exit: $?"
note "  OPEN DECISIONS lines naming decision-task: $(grep -A20 '^OPEN DECISIONS' "$OUT/drain.out" | grep -c 'decision-task')"
grep -A20 '^OPEN DECISIONS' "$OUT/drain.out" | grep 'decision-task\|^OPEN DECISIONS' | sed 's/^/    /' | tee -a "$SUMMARY"
hold_cmd open decision-task >/dev/null 2>&1
note "  backlog captain hold on decision-task still open after the run: exit $? (0 = open)"
note ""
note "== supervisor submissions (verbatim text, classification):"
sed "s#$STATE_DIR/##g" "$OUT/supervisor-submissions.txt" | sed 's/^/    /' | tee -a "$SUMMARY"
