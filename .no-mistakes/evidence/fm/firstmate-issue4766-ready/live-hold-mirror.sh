#!/usr/bin/env bash
# Live scenario driver: real bin/fm-captain-hold.sh, bin/fm-crew-state.sh and
# bin/fm-capacity.sh against a disposable FM_HOME. Nothing here touches the
# operator's homes; every path is under a mktemp root removed at exit.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-hold.XXXXXX")
# A real tmux server on a private socket inside the lab; every home's fake
# `tmux` forwards to it, so crew-state probes real panes, never the fleet's.
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
REAL_TMUX=$(command -v tmux)
SOCK=fm-live-hold
rtmux() { "$REAL_TMUX" -L "$SOCK" "$@"; }
rtmux new-session -d -s firstmate -n seed -x 120 -y 40 bash
trap 'rtmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
FAILS=0
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
check(){ if eval "$1"; then ok "$2"; else bad "$2"; fi; }

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
crew_state() { PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" "$ROOT/bin/fm-crew-state.sh" "$2"; }
meta() {  # <home> <id> <kind>  (worktree exists; idle busy record armed like a live crew)
  mkdir -p "$1/wt-$2"
  rtmux new-window -d -t firstmate -n "fm-$2" bash
  printf 'window=firstmate:fm-%s\nworktree=%s/wt-%s\nproject=%s/projects/sample\nharness=claude\nkind=%s\nmode=%s\nspawn_gen=fixture-%s\n' \
    "$2" "$1" "$2" "$1" "$3" "$3" "$2" > "$1/state/$2.meta"
  local gen; gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1/state" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1/state" "$2" idle --gen "$gen" --source claude-hook --event stop >/dev/null
}

echo "################ Scenario 1: hold mirrors onto the status log, worker state preserved"
H=$(make_home lane); ID=t1
(cd "$H" && tasks-axi add "$ID" "Ship the sample" --kind ship --repo sample >/dev/null) || bad "tasks-axi add"
meta "$H" "$ID" ship
printf 'working: implementing\ndone: PR ready https://example.test/pr/1 checks green\n' > "$H/state/$ID.status"
echo "--- before hold: crew-state"; crew_state "$H" "$ID" | sed -n '1,4p'
hold "$H" hold "$ID" --reason $'Pick the API shape\nblocked: on vendor reply' >/dev/null || bad "hold command failed"
echo "--- status log after hold:"; cat "$H/state/$ID.status"
check '[ "$(grep -c "^captain-held \[key=captain-hold-$ID-1\]" "$H/state/$ID.status")" = 1 ]' "exactly one captain-held line with key captain-hold-$ID-1"
check '! grep -q "^blocked:" "$H/state/$ID.status"' "two-line reason collapsed: no stray blocked: line"
check '[ "$(wc -l < "$H/state/$ID.status")" = 3 ]' "hold appended exactly one physical line"
L=$(reader last_status_line "$H/state/$ID.status");        echo "last_status_line        = $L"
check 'case "$L" in captain-held*) true;; *) false;; esac' "last_status_line sees the standing hold raw"
L=$(reader last_worker_status_line "$H/state/$ID.status"); echo "last_worker_status_line = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "last_worker_status_line keeps the worker's done line"
L=$(reader status_current_line "$H/state/$ID.status" ship); echo "status_current_line     = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "status_current_line keeps the worker's done line under the hold"
O=$(reader status_open_decisions "$H/state/$ID.status"); echo "status_open_decisions   = [$O]"
check '[ -z "$O" ]' "hold opens no worker decision"
echo "--- crew-state while held:"; CS=$(crew_state "$H" "$ID"); printf '%s\n' "$CS" | sed -n '1,4p'
check 'printf "%s\n" "$CS" | grep -q "^state: done"' "fm-crew-state reports done while held"
echo "--- idempotent re-hold"
hold "$H" hold "$ID" --reason $'Pick the API shape\nblocked: on vendor reply' >/dev/null || bad "idempotent hold failed"
check '[ "$(grep -c "^captain-held " "$H/state/$ID.status")" = 1 ]' "repeated hold does not duplicate the mirror"

echo "################ Scenario 2: release retracts the mirror; readers return the worker's line"
printf 'Use shape A.\n' > "$H/answer.txt"
hold "$H" answer "$ID" --decision-file "$H/answer.txt" --release >/dev/null || bad "answer --release failed"
echo "--- status log after release:"; cat "$H/state/$ID.status"
check 'grep -Eq "^resolved \[key=captain-hold-$ID-1\]( \[at=[0-9]+\])?: captain call released by fm-captain-hold$" "$H/state/$ID.status"' "release appended the keyed retraction"
L=$(reader last_status_line "$H/state/$ID.status"); echo "last_status_line        = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "settled mirror pair reads through to the worker's done line"
L=$(reader status_current_line "$H/state/$ID.status" ship); echo "status_current_line     = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "status_current_line after release is the done line"
CS=$(crew_state "$H" "$ID"); printf '%s\n' "$CS" | sed -n '1,3p'
check 'printf "%s\n" "$CS" | grep -q "^state: done"' "fm-crew-state reports done after release"
echo "--- re-hold starts lifecycle 2, close answer retracts it"
hold "$H" hold "$ID" --reason "second review" >/dev/null || bad "re-hold failed"
check 'grep -q "^captain-held \[key=captain-hold-$ID-2\]" "$H/state/$ID.status"' "re-hold declares key captain-hold-$ID-2"
printf 'Ship it.\n' > "$H/close.txt"
hold "$H" answer "$ID" --decision-file "$H/close.txt" >/dev/null || bad "closing answer failed"
check 'grep -Eq "^resolved \[key=captain-hold-$ID-2\]( \[at=[0-9]+\])?: captain call answered by fm-captain-hold$" "$H/state/$ID.status"' "close appended the keyed retraction for lifecycle 2"
L=$(reader last_status_line "$H/state/$ID.status"); echo "last_status_line        = $L"
check '[ "$L" = "done: PR ready https://example.test/pr/1 checks green" ]' "after close the lane still reads its done line"
echo "--- final status log:"; cat "$H/state/$ID.status"
echo "--- backlog after close:"; sed -n '1,40p' "$H/data/backlog.md"

echo "################ Scenario 3 (adversarial): hold after an answered worker decision does not revive it"
H2=$(make_home revive); ID2=t2
(cd "$H2" && tasks-axi add "$ID2" "Scout the thing" --kind scout --repo sample >/dev/null) || bad "tasks-axi add t2"
meta "$H2" "$ID2" scout
printf 'needs-decision [key=q]: pick\nresolved [key=q]: use a\n' > "$H2/state/$ID2.status"
echo "--- crew-state before hold:"; CSB=$(crew_state "$H2" "$ID2"); printf '%s\n' "$CSB" | sed -n '1,3p'
hold "$H2" hold "$ID2" --reason "captain review" >/dev/null || bad "hold t2 failed"
cat "$H2/state/$ID2.status"
L=$(reader status_current_line "$H2/state/$ID2.status" scout); echo "status_current_line = $L"
check 'case "$L" in needs-decision*) false;; *) true;; esac' "answered needs-decision is not revived by the hold"
echo "--- crew-state while held:"; CSA=$(crew_state "$H2" "$ID2"); printf '%s\n' "$CSA" | sed -n '1,3p'
check '[ "$(printf "%s\n" "$CSB" | head -1 | cut -d" " -f1-2)" = "$(printf "%s\n" "$CSA" | head -1 | cut -d" " -f1-2)" ]' "fm-crew-state state word unchanged by the hold (before: $(printf "%s" "$CSB" | head -1 | cut -d" " -f1-2) / held: $(printf "%s" "$CSA" | head -1 | cut -d" " -f1-2))"
printf 'blocked: daemon socket refused\nresolved [key=default]: restarted\n' > "$H2/state/$ID2.status"
hold "$H2" answer "$ID2" --decision-file "$H/answer.txt" --release >/dev/null || bad "release t2 failed"
hold "$H2" hold "$ID2" --reason "captain review again" >/dev/null || bad "re-hold t2 failed"
L=$(reader status_current_line "$H2/state/$ID2.status" scout); echo "keyless: status_current_line = $L"
check 'case "$L" in blocked*) false;; *) true;; esac' "answered keyless blocked is not revived by the hold"

echo "################ Scenario 4: failed lane stays failed under a standing hold (crew-state)"
H3=$(make_home failed); ID3=t3
(cd "$H3" && tasks-axi add "$ID3" "Ship failing" --kind ship --repo sample >/dev/null) || bad "tasks-axi add t3"
meta "$H3" "$ID3" ship
printf 'working: start\nfailed: build broke\n' > "$H3/state/$ID3.status"
hold "$H3" hold "$ID3" --reason "retry or drop?" >/dev/null || bad "hold t3 failed"
cat "$H3/state/$ID3.status"
L=$(reader last_worker_status_line "$H3/state/$ID3.status"); echo "last_worker_status_line = $L"
check '[ "$L" = "failed: build broke" ]' "worker failure visible under the standing hold"
CS=$(crew_state "$H3" "$ID3"); printf '%s\n' "$CS" | sed -n '1,3p'
check 'printf "%s\n" "$CS" | grep -q "^state: failed"' "fm-crew-state reports failed while held"

echo "################ Scenario 5: upstream fm-capacity.sh works in the merged tree"
H4=$(make_home cap)
meta "$H4" a ship; meta "$H4" b scout
printf 'kind=secondmate\nwindow=firstmate:fm-sm\n' > "$H4/state/sm.meta"
echo "--- no target:"; OUT=$(FM_HOME="$H4" "$ROOT/bin/fm-capacity.sh"); printf '%s\n' "$OUT"
check 'printf "%s\n" "$OUT" | head -1 | grep -q "free_lanes=unknown reason=no-target lanes=2 target=none secondmates=1"' "no target: counts only, no invented target"
printf '3\n' > "$H4/config/lane-capacity"
echo "--- target 3:"; OUT=$(FM_HOME="$H4" "$ROOT/bin/fm-capacity.sh"); printf '%s\n' "$OUT"
check 'printf "%s\n" "$OUT" | head -1 | grep -Eq "free_lanes=(1|0) reason=(ok|cpu|memory|disk|,)+ lanes=2 target=3 secondmates=1"' "target 3 with 2 lanes reports 1 free lane or a named host constraint"
printf 'three\n' > "$H4/config/lane-capacity"
echo "--- malformed target:"; OUT=$(FM_HOME="$H4" "$ROOT/bin/fm-capacity.sh" 2>&1); RC=$?; printf '%s\nexit=%s\n' "$OUT" "$RC"
check '[ "$RC" = 1 ] && printf "%s\n" "$OUT" | grep -q "target=invalid"' "malformed lane-capacity reports invalid and exits 1"

echo
echo "TOTAL FAILS: $FAILS"
exit $FAILS
