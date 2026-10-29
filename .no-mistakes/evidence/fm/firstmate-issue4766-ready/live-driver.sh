#!/usr/bin/env bash
# Live driver: runs the real bin/fm-captain-hold.sh (hold, complete, answer,
# open) and the real status readers against a disposable fixture home.
# Usage: live-driver.sh <worktree-root>
set -u
ROOT=$1
export PATH=/home/firstmate/.local/share/mise/installs/node/22.23.1/bin:$PATH
TASKS_AXI_BIN=$(command -v tasks-axi)
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-hold-live.XXXXXX")
trap 'rm -rf "$FIX"' EXIT
FAILS=0

say() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; }
check() {  # <label> <got> <want>
  if [ "$2" = "$3" ]; then printf 'CHECK ok   %s: %q\n' "$1" "$2"
  else printf 'CHECK FAIL %s: got %q want %q\n' "$1" "$2" "$3"; FAILS=$((FAILS+1)); fi
}

make_home() {  # <name> -> path
  local home="$FIX/$1" t
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample" "$home/fakebin"
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for t in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"
  done
  printf '%s\n' "$home"
}
run_captain() {  # <home> <bin-dir> <args...>
  local home=$1 bin=$2; shift 2
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$bin/fm-captain-hold.sh" "$@"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@"); }
write_meta() {  # <home> <id> <kind>
  mkdir -p "$1/projects/missing-$2"
  printf '%s\n' "window=firstmate:fm-$2" "worktree=$1/projects/missing-$2" "project=$1/projects/sample" \
    "harness=codex" "kind=$3" "mode=$3" "spawn_gen=fixture-$2" > "$1/state/$2.meta"
}
hold_reader() {  # <bin-dir> <fn> <file> [kind]
  bash -c '. "$1/fm-classify-lib.sh"; . "$1/fm-hold-status-lib.sh"; "$2" "$3" ${4:+"$4"}' _ "$1" "$2" "$3" "${4:-}"
}
plain_reader() {  # <bin-dir> <fn> <file> [kind]
  bash -c '. "$1/fm-classify-lib.sh"; "$2" "$3" ${4:+"$4"}' _ "$1" "$2" "$3" "${4:-}"
}
unstamp() { sed -E 's/ \[at=[0-9]+\]//g'; }
crew_state() {  # <home> <id>
  PATH="$1/fakebin:$PATH" FM_STATE_OVERRIDE="$1/state" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$2" 2>&1
}
readers() {  # <bin> <file> <kind>
  printf '  raw last line           : %q\n' "$(tail -n 1 "$2" | unstamp)"
  printf '  last_status_line (hold) : %q\n' "$(hold_reader "$1" last_status_line "$2" | unstamp)"
  printf '  last_worker_status_line : %q\n' "$(hold_reader "$1" last_worker_status_line "$2" | unstamp)"
  printf '  status_current_line     : %q\n' "$(hold_reader "$1" status_current_line "$2" "$3" | unstamp)"
  printf '  status_declared_wait    : %q\n' "$(hold_reader "$1" status_declared_wait_line "$2" | unstamp)"
  printf '  status_open_decisions   : %q\n' "$(plain_reader "$1" status_open_decisions "$2" "$3")"
  printf '  open_decisions_increm.  : %q\n' "$(plain_reader "$1" status_open_decisions_incremental "$2")"
}

############################################################################
say "S1 hold mirror on a delivered worker lane, then release"
H=$(make_home s1); L=sample-held-lane
tasks_in "$H" add "$L" "Ship the held sample" --kind ship --repo sample >/dev/null || echo "tasks-axi add failed"
write_meta "$H" "$L" ship
printf 'working: opening the PR\ndone: PR https://example.test/pull/1 checks green\n' > "$H/state/$L.status"
echo "-- before hold"; readers "$ROOT/bin" "$H/state/$L.status" ship
cs0=$(crew_state "$H" "$L"); printf '  crew-state              : %s\n' "$cs0"
show "fm-captain-hold.sh hold $L --reason 'merge approval (captain must approve the merge)'"
run_captain "$H" "$ROOT/bin" hold "$L" --reason $'merge approval (captain must approve\nthe merge)' --repo sample
echo "-- status log after hold:"; unstamp < "$H/state/$L.status" | sed 's/^/  | /'
readers "$ROOT/bin" "$H/state/$L.status" ship
cs1=$(crew_state "$H" "$L"); printf '  crew-state              : %s\n' "$cs1"
check "S1 mirror is one line and current line stays done" \
  "$(hold_reader "$ROOT/bin" status_current_line "$H/state/$L.status" ship | unstamp)" 'done: PR https://example.test/pull/1 checks green'
check "S1 mirror line shape" "$(sed -n 3p "$H/state/$L.status" | unstamp)" \
  'captain-held [key=captain-hold-sample-held-lane-1]: merge approval (captain must approve the merge)'
check "S1 declared wait is the standing mirror" "$(hold_reader "$ROOT/bin" status_declared_wait_line "$H/state/$L.status" | unstamp)" \
  'captain-held [key=captain-hold-sample-held-lane-1]: merge approval (captain must approve the merge)'
check "S1 crew state unchanged by the hold" "$cs1" "$cs0"
show "fm-captain-hold.sh hold $L --reason ... (repeat: no duplicate mirror)"
run_captain "$H" "$ROOT/bin" hold "$L" --reason 'merge approval again' --repo sample >/dev/null
check "S1 repeated hold appends nothing" "$(wc -l < "$H/state/$L.status" | tr -d ' ')" 3
show "fm-captain-hold.sh open $L (exit code, 0 = open captain call)"
run_captain "$H" "$ROOT/bin" open "$L"; echo "  exit=$?"
printf 'Approved, merge it.\n' > "$H/answer.txt"
show "fm-captain-hold.sh answer $L --decision-file answer.txt --release"
run_captain "$H" "$ROOT/bin" answer "$L" --decision-file "$H/answer.txt" --release
echo "-- status log after release:"; unstamp < "$H/state/$L.status" | sed 's/^/  | /'
readers "$ROOT/bin" "$H/state/$L.status" ship
cs2=$(crew_state "$H" "$L"); printf '  crew-state              : %s\n' "$cs2"
check "S1 retraction line shape" "$(sed -n 4p "$H/state/$L.status" | unstamp)" \
  'resolved [key=captain-hold-sample-held-lane-1]: captain call released by fm-captain-hold'
check "S1 last_status_line reads past settled pair" "$(hold_reader "$ROOT/bin" last_status_line "$H/state/$L.status" | unstamp)" \
  'done: PR https://example.test/pull/1 checks green'
check "S1 crew state unchanged by the release" "$cs2" "$cs0"
show "fm-captain-hold.sh open $L (after release)"
run_captain "$H" "$ROOT/bin" open "$L"; rc=$?; echo "  exit=$rc"; check "S1 open reports released" "$rc" 1
show "fm-captain-hold.sh answer ... --release (exact replay appends nothing)"
run_captain "$H" "$ROOT/bin" answer "$L" --decision-file "$H/answer.txt" --release >/dev/null 2>&1; echo "  exit=$?"
check "S1 replayed settlement appends nothing" "$(wc -l < "$H/state/$L.status" | tr -d ' ')" 4
echo "-- backlog row:"; tasks_in "$H" show "$L" 2>&1 | sed 's/^/  | /' | head -20

############################################################################
say "S2 transfer a worker question to a captain call, then answer it"
H=$(make_home s2); L=sample-route-lane
tasks_in "$H" add "$L" "Scout the route sample" --kind scout --repo sample >/dev/null
write_meta "$H" "$L" scout
printf 'needs-decision [key=route]: choose route north or route south\n' > "$H/state/$L.status"
echo "-- before transfer"; readers "$ROOT/bin" "$H/state/$L.status" scout
show "fm-captain-hold.sh hold sample-route-call --title ... --reason ... --origin $L"
run_captain "$H" "$ROOT/bin" hold sample-route-call --title "Choose the route" --reason "route choice pending" --repo sample --origin "$L"
show "fm-captain-hold.sh complete $L sample-route-call"
run_captain "$H" "$ROOT/bin" complete "$L" sample-route-call
echo "-- status log after complete:"; unstamp < "$H/state/$L.status" | sed 's/^/  | /'
readers "$ROOT/bin" "$H/state/$L.status" scout
check "S2 transfer line" "$(sed -n 2p "$H/state/$L.status" | unstamp)" 'captain-held [key=route]: tracked by sample-route-call'
check "S2 transfer closes the worker question" "$(plain_reader "$ROOT/bin" status_open_decisions "$H/state/$L.status" scout)" ''
show "fm-captain-hold.sh verify $L"; run_captain "$H" "$ROOT/bin" verify "$L"; echo "  exit=$?"
printf 'Take route north.\n' > "$H/route.txt"
show "fm-captain-hold.sh answer sample-route-call --decision-file route.txt"
run_captain "$H" "$ROOT/bin" answer sample-route-call --decision-file "$H/route.txt"
echo "-- status log after answer:"; unstamp < "$H/state/$L.status" | sed 's/^/  | /'
readers "$ROOT/bin" "$H/state/$L.status" scout
check "S2 retraction line" "$(sed -n 3p "$H/state/$L.status" | unstamp)" 'resolved [key=route]: captain call answered by fm-captain-hold'
check "S2 original question stays settled (whole-file)" "$(plain_reader "$ROOT/bin" status_open_decisions "$H/state/$L.status" scout)" ''
check "S2 original question stays settled (incremental)" "$(plain_reader "$ROOT/bin" status_open_decisions_incremental "$H/state/$L.status")" ''
show "fm-captain-hold.sh open sample-route-call"; run_captain "$H" "$ROOT/bin" open sample-route-call; rc=$?; echo "  exit=$rc"
check "S2 call is closed" "$rc" 1

############################################################################
say "S3 adversarial: worker re-asks the same key between the final check and the retraction append"
cat > "$FIX/append-hook.sh" <<'EOF'
set -T
trap 'if [[ "$BASH_COMMAND" == '\''status_append_retraction "$id" "$f" "$key" "$note"'\'' && "${f-}" == "${RACE_STATUS-}" && ! -e "${RACE_MARK-}" ]]; then
  printf "needs-decision [key=route]: choose route east or route west\n" >> "$RACE_STATUS"
  : > "$RACE_MARK"
fi' DEBUG
EOF
race_run() {  # <home-name> <bin-dir>
  local H=$1 bin=$2 L=sample-race-lane
  tasks_in "$H" add "$L" "Scout the raced sample" --kind scout --repo sample >/dev/null
  write_meta "$H" "$L" scout
  printf 'needs-decision [key=route]: choose route north or route south\n' > "$H/state/$L.status"
  run_captain "$H" "$bin" hold sample-race-call --title "Choose the raced route" --reason "route choice pending" --repo sample >/dev/null
  run_captain "$H" "$bin" complete "$L" sample-race-call >/dev/null
  plain_reader "$bin" status_open_decisions_incremental "$H/state/$L.status" >/dev/null   # persist a cursor before the race
  printf 'Take route north.\n' > "$H/route.txt"
  show "fm-captain-hold.sh answer sample-race-call (worker appends a re-ask of key=route right before the retraction append)"
  BASH_ENV="$FIX/append-hook.sh" RACE_STATUS="$H/state/$L.status" RACE_MARK="$H/worker-reasked" \
    run_captain "$H" "$bin" answer sample-race-call --decision-file "$H/route.txt"
  [ -e "$H/worker-reasked" ] && echo "  (hook fired: the worker re-ask landed before the retraction append)" || echo "  HOOK DID NOT FIRE"
  echo "-- status log after the raced answer:"; unstamp < "$H/state/$L.status" | sed 's/^/  | /'
  readers "$bin" "$H/state/$L.status" scout
}
H=$(make_home s3); race_run "$H" "$ROOT/bin"
want=$'route\tneeds-decision\tchoose route east or route west'
check "S3 hook fired" "$([ -e "$H/worker-reasked" ] && echo yes)" yes
check "S3 re-asked question open (whole-file fold)" "$(plain_reader "$ROOT/bin" status_open_decisions "$H/state/sample-race-lane.status" scout)" "$want"
check "S3 re-asked question open (incremental fold, cursor persisted before the race)" "$(plain_reader "$ROOT/bin" status_open_decisions_incremental "$H/state/sample-race-lane.status")" "$want"
check "S3 re-asked question is the current line" "$(hold_reader "$ROOT/bin" status_current_line "$H/state/sample-race-lane.status" scout | unstamp)" 'needs-decision [key=route]: choose route east or route west'
check "S3 re-asked question is last_status_line" "$(hold_reader "$ROOT/bin" last_status_line "$H/state/sample-race-lane.status" | unstamp)" 'needs-decision [key=route]: choose route east or route west'
S3_LOG="$H/state/sample-race-lane.status"

############################################################################
say "S3b control: the same race against a copy of bin/ with the fold guard removed (pre-fix behaviour)"
cp -r "$ROOT/bin" "$FIX/bin-noguard"
python3 - "$FIX/bin-noguard/fm-classify-lib.sh" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
guard='''  if [[ $unstamped =~ $FM_HOLD_RETRACTION_ERE ]]; then
    printf '%s' "$open"
    return 0
  fi
'''
assert guard in s, "guard not found"
s=s.replace(guard,'',1).replace('FM_OPEN_DECISIONS_FOLD_VERSION=10','FM_OPEN_DECISIONS_FOLD_VERSION=9',1)
open(p,'w').write(s)
PY
grep -c 'FM_OPEN_DECISIONS_FOLD_VERSION=9' "$FIX/bin-noguard/fm-classify-lib.sh" | sed 's/^/  guard removed, fold version pinned to 9: count=/'
H=$(make_home s3b); race_run "$H" "$FIX/bin-noguard"
check "S3b pre-fix whole-file fold loses the re-asked question (expected pre-fix defect)" \
  "$(plain_reader "$FIX/bin-noguard" status_open_decisions "$H/state/sample-race-lane.status" scout)" ''
check "S3b pre-fix incremental fold loses the re-asked question (expected pre-fix defect)" \
  "$(plain_reader "$FIX/bin-noguard" status_open_decisions_incremental "$H/state/sample-race-lane.status")" ''
S3B_HOME=$H

############################################################################
say "S4 a persisted version-9 cursor that lost the question rebuilds under fold version 10"
CF="$S3B_HOME/state/.sample-race-lane.open-decisions-cursor"
echo "-- cursor written by the pre-fix code:"; sed 's/^/  | /' "$CF"; echo
show "status_open_decisions_incremental (fixed lib) over the same log and cursor"
got=$(plain_reader "$ROOT/bin" status_open_decisions_incremental "$S3B_HOME/state/sample-race-lane.status")
printf '  -> %q\n' "$got"
check "S4 rebuilt cursor reports the re-asked question" "$got" "$want"
echo "-- cursor after the rebuild:"; sed 's/^/  | /' "$CF"; echo
check "S4 cursor now carries fold version 10" "$(head -n1 "$CF")" 'version=10:scout'

############################################################################
say "S5 an ordinary worker 'resolved' line still closes its question; only hold bookkeeping is ignored"
H=$(make_home s5); mkdir -p "$H/state"
printf 'needs-decision [key=route]: choose route north or route south\nresolved [key=route]: took route north\n' > "$H/state/w.status"
printf 'kind=scout\n' > "$H/state/w.meta"
readers "$ROOT/bin" "$H/state/w.status" scout
check "S5 worker resolved closes (whole-file)" "$(plain_reader "$ROOT/bin" status_open_decisions "$H/state/w.status" scout)" ''
check "S5 worker resolved closes (incremental)" "$(plain_reader "$ROOT/bin" status_open_decisions_incremental "$H/state/w.status")" ''
printf 'needs-decision [key=route]: choose route north or route south\nresolved [key=route]: captain call closed by fm-captain-hold\n' > "$H/state/x.status"
printf 'kind=scout\n' > "$H/state/x.meta"
check "S5 hold-shaped retraction alone never closes a worker question" \
  "$(plain_reader "$ROOT/bin" status_open_decisions "$H/state/x.status" scout)" $'route\tneeds-decision\tchoose route north or route south'

############################################################################
say "S6 a long worker key keeps its whole retraction (key and closing text survive the line cap)"
H=$(make_home s6); L=sample-long-key-lane
key=$(printf 'k%.0s' $(seq 1 160))
tasks_in "$H" add "$L" "Scout the long-key sample" --kind scout --repo sample >/dev/null
write_meta "$H" "$L" scout
printf 'needs-decision [key=%s]: which one\n' "$key" > "$H/state/$L.status"
run_captain "$H" "$ROOT/bin" hold sample-long-call --title "Long key call" --reason "pending" --repo sample >/dev/null
run_captain "$H" "$ROOT/bin" complete "$L" sample-long-call >/dev/null
printf 'The first.\n' > "$H/a.txt"
run_captain "$H" "$ROOT/bin" answer sample-long-call --decision-file "$H/a.txt" >/dev/null
last=$(tail -n1 "$H/state/$L.status" | unstamp)
printf '  retraction (%s bytes): %s\n' "${#last}" "$last"
[[ "$last" == "resolved [key=$key]: captain call "*" by fm-captain-hold" ]] && pair=paired || pair=unpaired
check "S6 retraction keeps the whole key and the closing text (only the note is capped)" "$pair" paired
check "S6 reader reads past the settled long-key transfer" "$(hold_reader "$ROOT/bin" last_status_line "$H/state/$L.status" | unstamp)" "needs-decision [key=$key]: which one"

############################################################################
printf '\n=== live driver finished: %s check failure(s)\n' "$FAILS"
exit "$FAILS"
