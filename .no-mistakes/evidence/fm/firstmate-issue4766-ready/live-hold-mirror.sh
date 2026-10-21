#!/usr/bin/env bash
# Live scenario driver for the captain-hold status-log mirror. Real
# bin/fm-captain-hold.sh, bin/fm-crew-state.sh, bin/fm-watch.sh and
# bin/fm-wake-drain.sh run against a disposable FM_HOME with a real tmux server
# on a private socket. Nothing touches the operator's homes or the default tmux
# server; every path is under a mktemp root removed at exit.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-hold.XXXXXX")
mkdir -p "$LAB/tmux" "$LAB/noroot"
export TMUX_TMPDIR="$LAB/tmux"
REAL_TMUX=$(command -v tmux)
SOCK=fm-live-hold
rtmux() { "$REAL_TMUX" -L "$SOCK" "$@"; }
rtmux new-session -d -s firstmate -n seed -x 120 -y 40 bash
WATCH_PIDS=
trap 'for p in $WATCH_PIDS; do kill "$p" 2>/dev/null; done; rtmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
FAILS=0
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }
unstamp(){ sed -E 's/ \[at=[0-9]+\]//' <<< "$1"; }

make_home() {
  local home="$LAB/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  local t
  for t in treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"
  done
  printf '#!/usr/bin/env bash\nexport TMUX_TMPDIR=%q\nexec %q -L %q "$@"\n' "$LAB/tmux" "$REAL_TMUX" "$SOCK" > "$home/fakebin/tmux"
  chmod +x "$home/fakebin/tmux"
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "${1:-}" "${2:-}" >> %q\nexit 0\n' "$home/alarms.log" > "$home/fakebin/alarm-rec"
  chmod +x "$home/fakebin/alarm-rec"
  printf '%s\n' "$home"
}
hold() {  # <home> args...
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}
reader() {  # <fn> <status-file> [kind]
  bash -c '. "$1"; . "$2"; "$3" "$4" ${5:+"$5"}' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$@"
}
wakelib() {  # <home> <fn> <status-file>
  FM_STATE_OVERRIDE="$1/state" bash -c '. "$1"; "$2" "$3" "$4"' _ "$ROOT/bin/fm-wake-lib.sh" "$2" "$1/state" "$3"
}
crew_state() { PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-crew-state.sh" "$2"; }
meta() {  # <home> <id> <kind>  (worktree exists; real idle pane; idle busy record armed like a live crew)
  mkdir -p "$1/wt-$2"
  rtmux new-window -d -t firstmate -n "fm-$2" bash
  printf 'window=firstmate:fm-%s\nworktree=%s/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=%s\nmode=%s\nspawn_gen=fixture-%s\n' \
    "$2" "$1" "$2" "$1" "$3" "$3" "$2" > "$1/state/$2.meta"
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}

echo "################ Scenario 1: hold mirrors onto the status log; worker state preserved"
H=$(make_home lane); ID=t1
(cd "$H" && tasks-axi add "$ID" "Ship the sample" --kind ship --repo sample >/dev/null) || bad "tasks-axi add"
meta "$H" "$ID" ship
printf 'working: implementing\ndone: PR ready https://example.test/pr/1 checks green\n' > "$H/state/$ID.status"
wakelib "$H" fm_wake_status_mark_current "$H/state/$ID.status" || bad "could not prime the announced baseline"
echo "--- before hold: crew-state"; crew_state "$H" "$ID" | sed -n '1,2p'
hold "$H" hold "$ID" --reason $'Pick the API shape\nblocked: on vendor reply' >/dev/null || bad "hold command failed"
echo "--- status log after hold:"; cat "$H/state/$ID.status"
check '[ "$(grep -c "^captain-held \[key=captain-hold-$ID-1\]" "$H/state/$ID.status")" = 1 ]' "exactly one captain-held line with key captain-hold-$ID-1"
check '! grep -q "^blocked:" "$H/state/$ID.status"' "two-line reason folded: no stray blocked: line"
check '[ "$(wc -l < "$H/state/$ID.status")" = 3 ]' "hold appended exactly one physical line"
check 'wakelib "$H" fm_wake_signal_seen_current "$H/state/$ID.status"' "hold declaration was self-announced (does not re-wake the recording home)"
L=$(reader last_status_line "$H/state/$ID.status");        echo "last_status_line        = $L"
check 'case "$L" in captain-held*) true;; *) false;; esac' "last_status_line (watcher/daemon view) sees the standing hold raw"
L=$(reader last_worker_status_line "$H/state/$ID.status"); echo "last_worker_status_line = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "last_worker_status_line keeps the worker's done line"
L=$(reader status_current_line "$H/state/$ID.status" ship); echo "status_current_line     = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "status_current_line keeps the worker's done line under the hold"
O=$(reader status_open_decisions "$H/state/$ID.status"); echo "status_open_decisions   = [$O]"
check '[ -z "$O" ]' "hold opens no worker decision"
echo "--- crew-state while held:"; CS=$(crew_state "$H" "$ID"); printf '%s\n' "$CS" | sed -n '1,2p'
check 'printf "%s\n" "$CS" | grep -q "^state: done"' "fm-crew-state reports done while held"
echo "--- idempotent re-hold"
hold "$H" hold "$ID" --reason $'Pick the API shape\nblocked: on vendor reply' >/dev/null || bad "idempotent hold failed"
check '[ "$(grep -c "^captain-held " "$H/state/$ID.status")" = 1 ]' "repeated hold does not duplicate the mirror"

echo "################ Scenario 2: release and close retract the mirror; readers return the worker's line"
printf 'Use shape A.\n' > "$H/answer.txt"
hold "$H" answer "$ID" --decision-file "$H/answer.txt" --release >/dev/null || bad "answer --release failed"
echo "--- status log after release:"; cat "$H/state/$ID.status"
check 'grep -Eq "^resolved \[key=captain-hold-$ID-1\]( \[at=[0-9]+\])?: captain call released by fm-captain-hold$" "$H/state/$ID.status"' "release appended the keyed retraction"
check 'wakelib "$H" fm_wake_signal_seen_current "$H/state/$ID.status"' "release retraction was self-announced"
L=$(reader last_status_line "$H/state/$ID.status"); echo "last_status_line        = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "settled mirror pair reads through to the worker's done line"
L=$(reader status_current_line "$H/state/$ID.status" ship); echo "status_current_line     = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "status_current_line after release is the done line"
CS=$(crew_state "$H" "$ID"); printf '%s\n' "$CS" | sed -n '1,2p'
check 'printf "%s\n" "$CS" | grep -q "^state: done"' "fm-crew-state reports done after release"
echo "--- re-hold starts lifecycle 2, close answer retracts it, replay appends nothing"
hold "$H" hold "$ID" --reason "second review" >/dev/null || bad "re-hold failed"
check 'grep -q "^captain-held \[key=captain-hold-$ID-2\]" "$H/state/$ID.status"' "re-hold declares key captain-hold-$ID-2"
printf 'Ship it.\n' > "$H/close.txt"
hold "$H" answer "$ID" --decision-file "$H/close.txt" >/dev/null || bad "closing answer failed"
check 'grep -Eq "^resolved \[key=captain-hold-$ID-2\]( \[at=[0-9]+\])?: captain call answered by fm-captain-hold$" "$H/state/$ID.status"' "close appended the keyed retraction for lifecycle 2"
hold "$H" answer "$ID" --decision-file "$H/close.txt" >/dev/null || bad "replayed closing answer failed"
check '[ "$(grep -c "^resolved \[key=captain-hold-$ID-2\]" "$H/state/$ID.status")" = 1 ]' "replayed settlement appended no second retraction"
L=$(reader last_status_line "$H/state/$ID.status"); echo "last_status_line        = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "after close the lane still reads its done line"
echo "--- final status log:"; cat "$H/state/$ID.status"
echo "--- backlog after close:"; sed -n '1,12p' "$H/data/backlog.md"
check 'grep -q "^- \[x\] $ID " "$H/data/backlog.md"' "closing answer moved the task to Done in the backlog"

echo "################ Scenario 3 (adversarial): hold after an answered worker decision does not revive it"
H2=$(make_home revive); ID2=t2
(cd "$H2" && tasks-axi add "$ID2" "Scout the thing" --kind scout --repo sample >/dev/null) || bad "tasks-axi add t2"
meta "$H2" "$ID2" scout
printf 'needs-decision [key=q]: pick\nresolved [key=q]: use a\n' > "$H2/state/$ID2.status"
echo "--- crew-state before hold:"; CSB=$(crew_state "$H2" "$ID2"); printf '%s\n' "$CSB" | sed -n '1,2p'
hold "$H2" hold "$ID2" --reason "captain review" >/dev/null || bad "hold t2 failed"
cat "$H2/state/$ID2.status"
L=$(reader status_current_line "$H2/state/$ID2.status" scout); echo "status_current_line = $L"
check 'case "$L" in needs-decision*|resolved*) false;; *) true;; esac' "answered needs-decision is not revived by the hold (current line is the mirror, not the answered question)"
O=$(reader status_open_decisions "$H2/state/$ID2.status"); echo "status_open_decisions = [$O]"
check '[ -z "$O" ]' "no decision is open under the hold"
echo "--- crew-state while held:"; CSA=$(crew_state "$H2" "$ID2"); printf '%s\n' "$CSA" | sed -n '1,2p'
check '[ "$(printf "%s\n" "$CSB" | head -1 | cut -d" " -f1-2)" = "$(printf "%s\n" "$CSA" | head -1 | cut -d" " -f1-2)" ]' "fm-crew-state state word unchanged by the hold (before: $(printf "%s" "$CSB" | head -1 | cut -d" " -f1-2) / held: $(printf "%s" "$CSA" | head -1 | cut -d" " -f1-2))"
printf 'blocked: daemon socket refused\nresolved [key=default]: restarted\n' > "$H2/state/$ID2.status"
hold "$H2" answer "$ID2" --decision-file "$H/answer.txt" --release >/dev/null || bad "release t2 failed"
hold "$H2" hold "$ID2" --reason "captain review again" >/dev/null || bad "re-hold t2 failed"
cat "$H2/state/$ID2.status"
L=$(reader status_current_line "$H2/state/$ID2.status" scout); echo "keyless: status_current_line = $L"
check 'case "$L" in blocked*|resolved*) false;; *) true;; esac' "answered keyless blocked is not revived by the hold"
CSA=$(crew_state "$H2" "$ID2"); printf '%s\n' "$CSA" | sed -n '1,1p'
check '! printf "%s\n" "$CSA" | grep -q "^state: blocked"' "fm-crew-state does not report the answered blocked under the re-hold"

echo "################ Scenario 4: failed lane stays failed under a standing hold"
H3=$(make_home failed); ID3=t3
(cd "$H3" && tasks-axi add "$ID3" "Ship failing" --kind ship --repo sample >/dev/null) || bad "tasks-axi add t3"
meta "$H3" "$ID3" ship
printf 'working: start\nfailed: build broke\n' > "$H3/state/$ID3.status"
hold "$H3" hold "$ID3" --reason "retry or drop?" >/dev/null || bad "hold t3 failed"
cat "$H3/state/$ID3.status"
L=$(reader last_worker_status_line "$H3/state/$ID3.status"); echo "last_worker_status_line = $L"
check '[ "$L" = "failed: build broke" ]' "worker failure visible under the standing hold"
CS=$(crew_state "$H3" "$ID3"); printf '%s\n' "$CS" | sed -n '1,1p'
check 'printf "%s\n" "$CS" | grep -q "^state: failed"' "fm-crew-state reports failed while held"

echo "################ Scenario 5 (boundary): a decision-only hold mints no status log"
hold "$H3" hold plain-call --title "Pick a flavor" --reason "flavor choice" >/dev/null || bad "decision-only hold failed"
check '[ ! -e "$H3/state/plain-call.status" ]' "no status log created for a lane-less hold"
echo "--- divergence guard over the mirrored home:"; D=$(hold "$H" diverged 2>&1); RC=$?; printf '%s\n' "$D"
check '[ "$RC" = 0 ] && [ -z "$D" ]' "diverged reports nothing for the hold lifecycle's own keyed pair"

echo "################ Scenario 6 (live watcher): hold and release never re-surface a delivered lane"
H4=$(make_home watch); ID4=t4
(cd "$H4" && tasks-axi add "$ID4" "Ship the watched sample" --kind ship --repo sample >/dev/null) || bad "tasks-axi add t4"
meta "$H4" "$ID4" ship
W="firstmate:fm-$ID4"; KEY=$(printf '%s' "$W" | tr ':/.' '___')
printf 'done: PR https://example.test/pull/4 checks green\n' > "$H4/state/$ID4.status"
wakelib "$H4" fm_wake_status_mark_current "$H4/state/$ID4.status" || bad "could not prime t4 baseline"
watch_bg() {  # <out> [extra env...]
  local out=$1; shift
  PATH="$H4/fakebin:$PATH" FM_HOME="$H4" FM_STATE_OVERRIDE="$H4/state" FM_WEDGE_ALARM_EXEC="$H4/fakebin/alarm-rec" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    env "$@" "$ROOT/bin/fm-watch.sh" > "$out" 2> "$out.err" &
  WPID=$!; WATCH_PIDS="$WATCH_PIDS $WPID"
}
wait_exit() {  # <pid> <secs>
  local i=0; while [ $i -lt $(( $2 * 10 )) ]; do kill -0 "$1" 2>/dev/null || { wait "$1" 2>/dev/null; return 0; }; sleep 0.1; i=$((i+1)); done; return 1
}
wait_cycles() {  # <pid> <n-beat-advances> <secs>  -> 0 alive after n advances, 1 exited, 2 timeout
  local beat="$H4/state/.last-watcher-beat" seen=0 last="" now i=0
  while [ $i -lt $(( $3 * 10 )) ]; do
    kill -0 "$1" 2>/dev/null || return 1
    now=$(stat -c %Y "$beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then last=$now; seen=$((seen+1)); [ $seen -gt "$2" ] && return 0; fi
    sleep 0.1; i=$((i+1))
  done; return 2
}
stop_watch() { kill "$1" 2>/dev/null; wait_exit "$1" 10 || kill -9 "$1" 2>/dev/null; }
ack_cycle() {
  local err="$H4/drain.err" seq gen
  FM_ROOT_OVERRIDE="$LAB/noroot" FM_HOME="$H4" FM_STATE_OVERRIDE="$H4/state" PATH="$H4/fakebin:$PATH" "$ROOT/bin/fm-wake-drain.sh" > "$H4/drain.out" 2> "$err" || return 1
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] || { cat "$err"; return 1; }
  FM_ROOT_OVERRIDE="$LAB/noroot" FM_HOME="$H4" FM_STATE_OVERRIDE="$H4/state" PATH="$H4/fakebin:$PATH" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
stale_rows() { awk -F '\t' -v w="$W" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$H4/state/.wake-queue" 2>/dev/null || echo 0; }

echo "--- round 1: first sight of the delivered idle lane surfaces one terminal stale"
watch_bg "$H4/w1.out"
if wait_exit "$WPID" 90; then :; else bad "watcher did not surface the first terminal stale within 90s"; stop_watch "$WPID"; fi
echo "watcher output:"; cat "$H4/w1.out"; sed -n '1,5p' "$H4/w1.out.err"
check 'grep -Fq "stale: $W" "$H4/w1.out"' "first terminal stale surfaced for $W"
check '! grep -Fq "possible wedge" "$H4/w1.out"' "no wedge label on the delivered lane"
echo "wake queue:"; cat "$H4/state/.wake-queue" 2>/dev/null
HASH1=$(cat "$H4/state/.stale-$KEY" 2>/dev/null); echo "stale suppressor hash = $HASH1"
ack_cycle || bad "could not acknowledge the stale wake through fm-wake-drain.sh"
echo "wake queue after ack:"; cat "$H4/state/.wake-queue" 2>/dev/null; ROWS0=$(stale_rows)

echo "--- round 2: firstmate holds the lane for the captain (real fm-captain-hold.sh), watcher re-armed"
hold "$H4" hold "$ID4" --reason "merge approval" >/dev/null || bad "hold t4 failed"
cat "$H4/state/$ID4.status"
watch_bg "$H4/w2.out" FM_WATCH_HANDLING_SUCCESSOR=1
RC=0; wait_cycles "$WPID" 3 60 || RC=$?
echo "watcher output:"; cat "$H4/w2.out"; grep -v '^$' "$H4/w2.out.err" | head -5
check '[ "$RC" = 0 ]' "watcher stayed alive through 3 poll cycles after the hold (rc=$RC)"
check '[ ! -s "$H4/w2.out" ]' "the hold firstmate just recorded printed no wake"
check '[ "$(stale_rows)" = "$ROWS0" ]' "no new stale row for the held lane (rows before=$ROWS0 after=$(stale_rows))"
check '[ -e "$H4/state/.paused-$KEY" ]' "held done lane took the captain-held cadence (.paused marker present)"
stop_watch "$WPID"

echo "--- round 3: captain releases (real answer --release), watcher re-armed with a 1s wedge bound"
hold "$H4" answer "$ID4" --decision-file "$H/answer.txt" --release >/dev/null || bad "release t4 failed"
cat "$H4/state/$ID4.status"
watch_bg "$H4/w3.out" FM_WATCH_HANDLING_SUCCESSOR=1 FM_STALE_ESCALATE_SECS=1
RC=0; wait_cycles "$WPID" 4 60 || RC=$?
echo "watcher output:"; cat "$H4/w3.out"; grep -v '^$' "$H4/w3.out.err" | head -5
check '[ "$RC" = 0 ]' "watcher stayed alive through 4 poll cycles after the release (rc=$RC)"
check '[ ! -s "$H4/w3.out" ]' "the release printed no wake (delivered outcome not re-surfaced)"
check '[ "$(stale_rows)" = "$ROWS0" ]' "no new stale row after release (rows=$(stale_rows))"
check '[ ! -e "$H4/state/.paused-$KEY" ]' "release lifted the hold's pause marker"
check '[ ! -e "$H4/state/.wedge-escalations-$KEY" ] && [ ! -e "$H4/state/.stale-since-$KEY" ]' "settled mirror over a done lane never wedge-escalated"
check '[ "$(cat "$H4/state/.stale-$KEY" 2>/dev/null)" = "$HASH1" ]' "stale suppressor hash unchanged across hold and release"
check '[ ! -s "$H4/alarms.log" ]' "no wedge alarm fired"
stop_watch "$WPID"
echo "--- state markers for $KEY:"; ls -a "$H4/state" | grep -- "$KEY" || true

echo
echo "TOTAL FAILS: $FAILS"
exit $FAILS
