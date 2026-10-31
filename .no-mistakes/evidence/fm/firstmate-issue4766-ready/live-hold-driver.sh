#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh and real readers against disposable homes.
# Usage: live-hold-driver.sh <worktree-root> <scratch-root>
set -u
ROOT=$1; SCRATCH=$2
REAL_TASKS_AXI=$(command -v tasks-axi)
export REAL_TASKS_AXI
pass_n=0; fail_n=0
ok()   { printf 'ok   - %s\n' "$1"; pass_n=$((pass_n+1)); }
bad()  { printf 'FAIL - %s\n' "$1"; fail_n=$((fail_n+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
show() { printf -- '--- %s ---\n' "$1"; cat "$2"; printf -- '---\n'; }

make_home() {
  local home="$SCRATCH/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"; done
  printf '%s\n' "$home"
}
meta() { # <home> <id> [kind]
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=%s\nmode=%s\nspawn_gen=fixture-%s\n' \
    "$2" "$1" "$2" "$1" "${3:-scout}" "${3:-scout}" "$2" > "$1/state/$2.meta"
}
captain() { local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks() { local home=$1; shift; (cd "$home" && tasks-axi "$@"); }
reader() { # <fn> <status-file> [args]
  bash -c '. "$1"; . "$2"; f=$3; fn=$4; shift 4; "$fn" "$f" "$@"' _ "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-hold-status-lib.sh" "$2" "$1" "${@:3}"; }
plain() { bash -c '. "$1"; "$2" "$3"' _ "$ROOT/bin/fm-classify-lib.sh" "$1" "$2"; }
crew() { local home=$1; shift; PATH="$home/fakebin:$PATH" FM_STATE_OVERRIDE="$home/state" FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" "$@"; }
unstamp() { sed -E 's/ \[at=[0-9]+\]//'; }

echo "===== S1/S2: hold mirrors onto the worker lane log; release and answer retract it ====="
H=$(make_home s1-lane); ID=lane-a
tasks "$H" add "$ID" "Ship lane a" --kind ship --repo sample >/dev/null || bad "create lane-a"
meta "$H" "$ID" ship
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which API shape\npaused: waiting on upstream release\n' > "$H/state/$ID.status"
echo "+ crew-state before hold:"; crew "$H" "$ID"
echo "+ hold:"; captain "$H" hold "$ID" --reason "operator review pending" ; echo "exit=$?"
show "status log after hold" "$H/state/$ID.status"
check "S1 mirror line captain-hold-$ID-1 appended" "grep -qE '^captain-held \[key=captain-hold-$ID-1\]( \[at=[0-9]+\])?: operator review pending$' '$H/state/$ID.status'"
echo "+ tasks-axi show after hold:"; tasks "$H" show "$ID" | sed -n '1,12p'
echo "+ hold-aware last_status_line: $(reader last_status_line "$H/state/$ID.status")"
echo "+ hold-aware status_current_line ship: $(reader status_current_line "$H/state/$ID.status" ship)"
echo "+ hold-aware status_declared_wait_line: $(reader status_declared_wait_line "$H/state/$ID.status")"
echo "+ crew-state while held:"; crew "$H" "$ID"
check "S1 declared wait is the hold mirror" "reader status_declared_wait_line '$H/state/$ID.status' | unstamp | grep -q '^captain-held \[key=captain-hold-$ID-1\]'"
echo "+ repeated hold:"; captain "$H" hold "$ID" --reason "operator review pending"; echo "exit=$?"
check "S1 repeated hold does not duplicate the mirror" "[ \"\$(grep -c '^captain-held ' '$H/state/$ID.status')\" = 1 ]"
printf 'Proceed as planned.\n' > "$H/go.txt"
echo "+ answer --release:"; captain "$H" answer "$ID" --decision-file "$H/go.txt" --release; echo "exit=$?"
show "status log after release" "$H/state/$ID.status"
check "S2 release retracts under its own key" "grep -qE '^resolved \[key=captain-hold-$ID-1\]( \[at=[0-9]+\])?: captain call released by fm-captain-hold$' '$H/state/$ID.status'"
L=$(reader last_status_line "$H/state/$ID.status"); echo "+ last_status_line after release: $L"
check "S2 readers read past the settled pair to the worker's paused line" "[ \"$L\" = 'paused: waiting on upstream release' ]"
O=$(plain status_open_decisions "$H/state/$ID.status"); echo "+ open decisions: $O"
check "S2 worker's own open decision api-shape untouched" "case \"$O\" in api-shape*) true;; *) false;; esac"
echo "+ crew-state after release:"; crew "$H" "$ID"
echo "+ re-hold:"; captain "$H" hold "$ID" --reason "second review"; echo "exit=$?"
check "S2 re-hold declares occurrence 2" "grep -qE '^captain-held \[key=captain-hold-$ID-2\]( \[at=[0-9]+\])?: second review$' '$H/state/$ID.status'"
printf 'Ship it.\n' > "$H/ship.txt"
echo "+ answer (close):"; captain "$H" answer "$ID" --decision-file "$H/ship.txt"; echo "exit=$?"
check "S2 closing answer retracts occurrence 2" "grep -qE '^resolved \[key=captain-hold-$ID-2\]( \[at=[0-9]+\])?: captain call answered by fm-captain-hold$' '$H/state/$ID.status'"
echo "+ answer replay:"; captain "$H" answer "$ID" --decision-file "$H/ship.txt"; echo "exit=$?"
check "S2 replayed answer appends no second retraction" "[ \"\$(grep -c 'resolved \[key=captain-hold-$ID-2\]' '$H/state/$ID.status')\" = 1 ]"
show "final status log" "$H/state/$ID.status"
echo "+ tasks-axi show after close:"; tasks "$H" show "$ID" --full | sed -n '1,40p'

echo; echo "===== S3: a refused backend hold publishes no mirror and no origin ====="
H=$(make_home s3-refused)
for o in origin-a origin-b; do tasks "$H" add "$o" "Review $o" --kind scout --repo sample >/dev/null; meta "$H" "$o"; done
printf 'done: report ready\n' > "$H/state/origin-b.status"
captain "$H" hold call-1 --title "Separate call" --reason "Choose for A" --origin origin-a >/dev/null || bad "initial hold with origin-a"
captain "$H" complete origin-a call-1 >/dev/null || bad "complete origin-a inventory"
printf 'Pick A.\n' > "$H/a.txt"
captain "$H" answer call-1 --release --decision-file "$H/a.txt" >/dev/null || bad "release call-1"
echo "+ verify origin-a after answered hold:"; captain "$H" verify origin-a; echo "exit=$?"
check "S3 baseline: earlier answer satisfies origin-a" "PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' verify origin-a >/dev/null 2>&1"
cp "$H/data/backlog.md" "$H/backlog-before.md"
cat > "$H/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  : > "$FM_HOME/hold-refused"
  printf 'error: backend refused the hold\n' >&2
  exit 9
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$H/fakebin/tasks-axi"
echo "+ hold call-1 --origin origin-b with backend refusing:"; captain "$H" hold call-1 --reason "Choose for B" --origin origin-b; echo "exit=$?"
check "S3 backend refusal observed" "[ -f '$H/hold-refused' ]"
check "S3 hold exits non-zero" "! PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' hold call-1 --reason 'Choose for B' --origin origin-b >/dev/null 2>&1"
rm -f "$H/fakebin/tasks-axi"
show "origin-b status log after refused hold" "$H/state/origin-b.status"
check "S3 no mirror on origin-b lane" "! grep -q captain-held '$H/state/origin-b.status'"
echo "+ call-1 after refused hold:"; tasks "$H" show call-1 --full | sed -n '1,30p'
check "S3 new origin origin-b not published" "! tasks '$H' show call-1 --full | grep -q 'Captain hold origin: origin-b'"
check "S3 backlog restored to pre-attempt bytes" "diff -q '$H/backlog-before.md' '$H/data/backlog.md' >/dev/null"
echo "+ verify origin-a still passes (earlier answer stays valid):"; captain "$H" verify origin-a; echo "exit=$?"
check "S3 earlier answer still satisfies origin-a" "PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' verify origin-a >/dev/null 2>&1"
echo "+ verify origin-b (never completed, must not pass):"; captain "$H" verify origin-b; echo "exit=$?"
check "S3 origin-b does not inherit the answer" "! PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' verify origin-b >/dev/null 2>&1"

echo; echo "===== S4: successful backend hold mirrors the held lane before a failed origin write ====="
H=$(make_home s4-origin-write)
tasks "$H" add origin-a "Review origin-a" --kind scout --repo sample >/dev/null; meta "$H" origin-a
tasks "$H" add lane-c "Ship lane c" --kind ship --repo sample >/dev/null; meta "$H" lane-c ship
printf 'done: PR https://example.test/pull/7 checks green\n' > "$H/state/lane-c.status"
cat > "$H/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = update ]; then
  previous=''
  for arg in "$@"; do
    if [ "$previous" = --body-file ] && grep -qx 'Captain hold origin: origin-a' "$arg"; then
      cp "$FM_HOME/state/lane-c.status" "$FM_HOME/lane-at-origin-write"
      : > "$FM_HOME/write-refused"; exit 9
    fi
    previous=$arg
  done
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$H/fakebin/tasks-axi"
echo "+ hold lane-c --origin origin-a with origin write refused:"; captain "$H" hold lane-c --reason "Merge approval" --origin origin-a; echo "exit=$?"
rm -f "$H/fakebin/tasks-axi"
check "S4 origin write refusal observed" "[ -f '$H/write-refused' ]"
show "lane-c log captured at the moment of the origin write" "$H/lane-at-origin-write"
check "S4 mirror (occurrence 1) was on lane-c before the origin write" "grep -qE '^captain-held \[key=captain-hold-lane-c-1\]( \[at=[0-9]+\])?: Merge approval$' '$H/lane-at-origin-write'"
echo "+ tasks-axi show lane-c:"; tasks "$H" show lane-c --full | sed -n '1,30p'
check "S4 lane-c is backend-held for the captain" "tasks '$H' show lane-c --full | grep -q 'hold_kind: captain'"
check "S4 origin-a not published after the failed write" "! tasks '$H' show lane-c --full | grep -q 'Captain hold origin: origin-a'"
echo "+ crew-state of the held lane:"; crew "$H" lane-c
echo "+ retry the hold with the backend healthy:"; captain "$H" hold lane-c --reason "Merge approval" --origin origin-a; echo "exit=$?"
check "S4 retry does not duplicate the mirror" "[ \"\$(grep -c '^captain-held ' '$H/state/lane-c.status')\" = 1 ]"
check "S4 retry publishes the origin" "tasks '$H' show lane-c --full | grep -q 'Captain hold origin: origin-a'"
show "lane-c log after retry" "$H/state/lane-c.status"

echo; echo "===== S5: transfer settlement, concurrent re-ask during checks, long key ====="
H=$(make_home s5-race); LANE=raced-lane
tasks "$H" add "$LANE" "Scout the raced sample" --kind scout --repo sample >/dev/null; meta "$H" "$LANE"
printf 'needs-decision [key=route]: choose route north or route south\n' > "$H/state/$LANE.status"
captain "$H" hold raced-choice --title "Choose the raced route" --reason "route choice pending" >/dev/null || bad "hold raced-choice"
echo "+ complete (transfer):"; captain "$H" complete "$LANE" raced-choice; echo "exit=$?"
show "lane log after transfer" "$H/state/$LANE.status"
echo "+ verify lane:"; captain "$H" verify "$LANE"; echo "exit=$?"
cat > "$H/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = raced-lane ] && [ ! -e "$FM_HOME/worker-reasked" ]; then
  : > "$FM_HOME/worker-reasked"
  printf 'needs-decision [key=route]: choose route east or route west\n' >> "$FM_HOME/state/raced-lane.status"
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$H/fakebin/tasks-axi"
printf 'Take route north.\n' > "$H/route.txt"
echo "+ answer raced-choice while worker re-asks during the checks:"; captain "$H" answer raced-choice --decision-file "$H/route.txt"; echo "exit=$?"
rm -f "$H/fakebin/tasks-axi"
check "S5 re-ask landed during settlement" "[ -f '$H/worker-reasked' ]"
show "lane log after raced answer" "$H/state/$LANE.status"
check "S5 no retraction of the re-asked key route" "! grep -q '^resolved \[key=route\]' '$H/state/$LANE.status'"
O=$(plain status_open_decisions "$H/state/$LANE.status"); echo "+ open decisions: $O"
check "S5 new question stays open" "case \"$O\" in route*east\ or\ route\ west*) true;; *) false;; esac"
echo "+ status_current_line scout: $(reader status_current_line "$H/state/$LANE.status" scout)"
echo "+ crew-state:"; crew "$H" "$LANE"

H=$(make_home s5-longkey); LANE=long-lane; KEY=$(printf '%0160d' 0 | tr 0 k)
tasks "$H" add "$LANE" "Scout the long-key sample" --kind scout --repo sample >/dev/null; meta "$H" "$LANE"
printf 'needs-decision [key=%s]: north or south\n' "$KEY" > "$H/state/$LANE.status"
captain "$H" hold long-choice --title "Choose the long-key route" --reason "route choice pending" >/dev/null || bad "hold long-choice"
captain "$H" complete "$LANE" long-choice >/dev/null || bad "complete long lane"
printf 'Take route north.\n' > "$H/route.txt"
echo "+ answer long-choice:"; captain "$H" answer long-choice --decision-file "$H/route.txt"; echo "exit=$?"
show "long-key lane log" "$H/state/$LANE.status"
check "S5 long key retraction keeps key and closing text" "grep -qE '^resolved \[key=$KEY\]( \[at=[0-9]+\])?: captain call .+ by fm-captain-hold$' '$H/state/$LANE.status'"
L=$(reader last_status_line "$H/state/$LANE.status"); echo "+ last_status_line: $L"
check "S5 long-key transfer settles for the hold reader" "[ \"$L\" = \"needs-decision [key=$KEY]: north or south\" ]"

echo; echo "===== S6: hold a decision-only task (no lane) mints no status log ====="
H=$(make_home s6-nolane)
captain "$H" hold lone-call --title "Lone call" --reason "captain decides" >/dev/null; echo "exit=$?"
check "S6 no status log minted for a lane-less hold" "[ ! -e '$H/state/lone-call.status' ]"
ls "$H/state"

echo; printf '\nRESULT: ok=%d fail=%d\n' "$pass_n" "$fail_n"
[ "$fail_n" -eq 0 ]
