#!/usr/bin/env bash
# Live end-to-end driver for PR #4907's intent:
# "stop this home's own --resolve-key answers from each waking the supervisor".
#
# Drives the REAL product executables in a throwaway FM_HOME:
#   bin/fm-watch.sh       the watcher that wakes the supervisor (exits on an
#                         actionable wake, printing its reason)
#   bin/fm-send.sh        the supervisor answering a decision with --resolve-key
#   bin/fm-wake-drain.sh  the captain-facing presentation of that wake
#
# Nothing here reads the implementation source. Every assertion is on observable
# product behaviour: whether the watcher process exits (= the supervisor is
# woken), what the durable wake queue holds, and what the drain prints.
set -u

ROOT=${FM_LIVE_ROOT:?set FM_LIVE_ROOT to the checkout under test}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-4907.XXXXXX")
HOMEDIR="$WORK/home"; STATE="$HOMEDIR/state"; FAKEBIN="$WORK/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$WORK/notangle"
STATUS="$STATE/t1.status"

step=0
say() { printf '\n=== %s\n' "$*"; }
ok()  { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILED=1; }
FAILED=0

# --- stubs: the backend pane transport and the crew-state reader -------------
# These stand in for a real terminal multiplexer and a real no-mistakes run
# probe. Everything under test (watcher triage, ledger, drain) is the real code.
cat > "$FAKEBIN/tmux" <<'SH'
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
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: none · idle worker\n'
exit 0
SH
cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$WORK/wedge-rec" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/fm-crew-state.sh" "$FAKEBIN/sleep" "$WORK/wedge-rec"

export FM_WEDGE_ALARM_EXEC="$WORK/wedge-rec"
export FM_ROOT_OVERRIDE="$WORK/notangle"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
SEND="$ROOT/bin/fm-send.sh"

drain() { FM_STATE_OVERRIDE="$STATE" "$DRAIN" "$@"; }

ack_cycle() {  # drain, then acknowledge whatever it demands
  local err seq gen
  err="$WORK/ack.err"
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" >/dev/null 2>"$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || return 1
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$seq" --recovery-generation "$gen"
}

watch_bg() {  # <stdout-file>
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$1" 2>"$1.err" &
}

wait_for_exit() {  # <pid> <ticks>
  local pid=$1 limit=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 1
}

wait_poll_cycle() {  # <pid>; 0 = alive through a whole poll cycle
  local pid=$1 limit=300 beat first now i=0
  beat="$STATE/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(stat -c %Y "$beat" 2>/dev/null); [ -n "$first" ] && break
    sleep 0.1; i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(stat -c %Y "$beat" 2>/dev/null)
    [ -n "$now" ] && [ "$now" != "$first" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

send() {  # <resolve-key> <answer>
  # FM_GATE_REFUSE_BYPASS=1 is the harness seam fm-gate-refuse-lib.sh documents
  # for driving real fleet commands from a test context; without it fm-send
  # refuses because this validation runs inside a no-mistakes gate worktree.
  env -u NO_MISTAKES_GATE PATH="$FAKEBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 \
    FM_ROOT_OVERRIDE="$HOMEDIR" FM_HOME="$HOMEDIR" \
    FM_SEND_LOG="$WORK/send.log" FM_SEND_SETTLE=0 \
    "$SEND" t1 --resolve-key "$1" "$2"
}

# ---------------------------------------------------------------------------
printf 'checkout under test: %s (%s)\n' "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')"
printf 'throwaway FM_HOME:   %s\n' "$HOMEDIR"

say "setup: a ship worker opens two captain decisions on task t1"
{
  printf 'window=sess:fm-t1\n'
  printf 'kind=ship\n'
} > "$STATE/t1.meta"
{
  printf 'needs-decision [key=budget]: approve the $400 spend?\n'
  printf 'needs-decision [key=vendor]: vendor A or vendor B?\n'
} > "$STATUS"
cat "$STATUS"

say "scenario 1: the worker's two decisions wake the supervisor once"
watch_bg "$WORK/watch1.out"; W1=$!
if wait_for_exit "$W1" 150; then
  if grep -qF "signal: $STATUS" "$WORK/watch1.out"; then
    ok "watcher exited and woke the supervisor: $(cat "$WORK/watch1.out")"
  else
    bad "watcher exited without naming the status signal: $(cat "$WORK/watch1.out")"
  fi
else
  bad "the worker's decisions never woke the supervisor"
fi

say "scenario 2: the supervisor sees both decisions and acknowledges the wake"
drain > "$WORK/drain1.out" 2>"$WORK/drain1.err" || true
cat "$WORK/drain1.out"
grep -qF '[key=budget]' "$WORK/drain1.out" && grep -qF '[key=vendor]' "$WORK/drain1.out" \
  && ok "both open decisions presented to the captain" \
  || bad "the drain did not present both open decisions"
ack_cycle && ok "wake acknowledged; queue is $( [ -s "$STATE/.wake-queue" ] && echo 'NOT empty' || echo empty)" \
  || bad "could not acknowledge the wake"

say "scenario 3: the supervisor answers BOTH decisions with two --resolve-key sends"
send budget "approved, go ahead" && ok "first answer sent (key=budget)" || bad "first --resolve-key send failed"
send vendor "go with vendor B"  && ok "second answer sent (key=vendor)" || bad "second --resolve-key send failed"
printf -- '--- status log after both answers ---\n'; cat "$STATUS"

say "scenario 4 (the fix): neither of this home's own answers wakes the supervisor again"
: > "$WORK/watch2.out"
watch_bg "$WORK/watch2.out"; W2=$!
if wait_poll_cycle "$W2"; then
  if [ -s "$WORK/watch2.out" ]; then
    bad "the home's own answers re-woke the supervisor: $(cat "$WORK/watch2.out")"
  elif [ -s "$STATE/.wake-queue" ]; then
    bad "the home's own answers queued a durable wake: $(cat "$STATE/.wake-queue")"
  else
    ok "watcher stayed asleep through a full poll cycle: no wake reason, empty wake queue"
  fi
else
  bad "the watcher EXITED on this home's own --resolve-key answers: $(cat "$WORK/watch2.out")"
fi

say "scenario 5 (adversarial): a later worker line on the same task still wakes"
printf 'blocked: need staging credentials to continue\n' >> "$STATUS"
if wait_for_exit "$W2" 150; then
  grep -qF "signal: $STATUS" "$WORK/watch2.out" \
    && ok "the worker's blocked: line woke the supervisor: $(cat "$WORK/watch2.out")" \
    || bad "the worker's blocked: line did not name the status signal: $(cat "$WORK/watch2.out")"
else
  bad "a worker line after two owned answers was SWALLOWED"
fi
reap "$W2" 2>/dev/null || true

say "scenario 6 (guard): the answers are still shown to the captain, not hidden"
drain > "$WORK/drain2.out" 2>"$WORK/drain2.err" || true
cat "$WORK/drain2.out"
if grep -qF 'resolved [key=budget]: answered: approved, go ahead' "$WORK/drain2.out" \
  && grep -qF 'resolved [key=vendor]: answered: go with vendor B' "$WORK/drain2.out"; then
  ok "both owned closes still printed on the captain-facing surface"
else
  bad "the ledger hid this home's own closes from the captain-facing surface"
fi
grep -qF 'blocked: need staging credentials' "$WORK/drain2.out" \
  && ok "the worker's blocker is presented too" || bad "the worker's blocker was not presented"

say "scenario 7 (adversarial): a real fm-teardown.sh leaves no orphaned ledger state"
# Stand up the fixtures the real teardown executable needs (a project clone with
# an origin, a task worktree with nothing unlanded, and the backend/PR probes it
# shells out to), then run bin/fm-teardown.sh itself on a task whose status log
# carries this home's own --resolve-key closes, i.e. a live ledger.
TD="$WORK/td"; TDSTATE="$TD/state"; TDBIN="$TD/fakebin"
mkdir -p "$TDSTATE" "$TD/config" "$TD/data" "$TDBIN"
for stub in treehouse tmux; do printf '#!/usr/bin/env bash\nexit 0\n' > "$TDBIN/$stub"; done
cat > "$TDBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2; exit 1 ;;
esac
exit 0
SH
cp "$TDBIN/gh-axi" "$TDBIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TDBIN/no-mistakes"
chmod +x "$TDBIN"/*
git init -q --bare "$TD/origin.git"
git -C "$TD/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$TD/origin.git" "$TD/_seed" 2>/dev/null
git -C "$TD/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m baseline
git -C "$TD/_seed" push -q origin main
rm -rf "$TD/_seed"
git clone -q "$TD/origin.git" "$TD/project"
git -C "$TD/project" remote set-head origin main 2>/dev/null || true
git -C "$TD/project" worktree add -q -b fm/task-x1 "$TD/wt" main
touch "$TDSTATE/.last-watcher-beat"
{
  printf 'window=firstmate:fm-task-x1\n'
  printf 'endpoint_task_id=task-x1\n'
  printf 'worktree=%s\n' "$TD/wt"
  printf 'project=%s\n' "$TD/project"
  printf 'kind=ship\nmode=local-only\nspawn_gen=live-4907\n'
} > "$TDSTATE/task-x1.meta"
printf 'needs-decision [key=budget]: approve the spend?\n' > "$TDSTATE/task-x1.status"
env -u NO_MISTAKES_GATE PATH="$TDBIN:$PATH" FM_GATE_REFUSE_BYPASS=1 \
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$TDSTATE" FM_HOME="$TD" \
  FM_SEND_LOG="$WORK/send2.log" FM_SEND_SETTLE=0 \
  "$SEND" task-x1 --resolve-key budget "approved" >/dev/null 2>&1 || true
if [ -s "$TDSTATE/.task-x1.home-appends" ]; then
  ok "precondition: the answered task carries a live home-appends ledger"
  ls -a "$TDSTATE" | grep -F home-appends
else
  bad "precondition: no ledger was written, so teardown has nothing to retire"
fi
mkdir -p "$TDSTATE/.task-x1.home-appends.lock"
printf '%s\n' 2147483646 > "$TDSTATE/.task-x1.home-appends.lock/pid"
env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$TDSTATE" FM_DATA_OVERRIDE="$TD/data" FM_CONFIG_OVERRIDE="$TD/config" \
  PATH="$TDBIN:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 > "$WORK/td.out" 2> "$WORK/td.err"
TDRC=$?
printf 'fm-teardown.sh exit=%s\n' "$TDRC"
tail -n 5 "$WORK/td.out" "$WORK/td.err"
if [ "$TDRC" -ne 0 ]; then
  bad "the real teardown refused, so the ledger-retirement path was not exercised"
elif ls -a "$TDSTATE" | grep -qF 'home-appends'; then
  bad "teardown left ledger state behind: $(ls -a "$TDSTATE" | grep -F home-appends)"
else
  ok "real fm-teardown.sh removed the per-task ledger and its stale lock"
  printf 'remaining task-x1 state: %s\n' "$(ls -a "$TDSTATE" | grep -F task-x1 || echo none)"
fi

printf '\n===========================\n'
if [ "$FAILED" -eq 0 ]; then printf 'RESULT: all live scenarios passed\n'; else printf 'RESULT: at least one live scenario FAILED\n'; fi
printf 'artifacts under %s\n' "$WORK"
exit "$FAILED"
