#!/usr/bin/env bash
# Live driver S7: an origin move interrupted by TERM inside the backend hold must not
# let origin-b inherit origin-a's earlier answer; a healthy retry completes the move.
set -u
ROOT=$1; SCRATCH=$2
REAL_TASKS_AXI=$(command -v tasks-axi); export REAL_TASKS_AXI
pass_n=0; fail_n=0
ok(){ printf 'ok   - %s\n' "$1"; pass_n=$((pass_n+1)); }
bad(){ printf 'FAIL - %s\n' "$1"; fail_n=$((fail_n+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
H="$SCRATCH/s7-interrupted"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
captain(){ PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks(){ (cd "$H" && tasks-axi "$@"); }
for o in origin-a origin-b; do
  tasks add "$o" "Review $o" --kind scout --repo sample >/dev/null
  printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=fixture-%s\n' "$o" "$H" "$o" "$H" "$o" > "$H/state/$o.meta"
done
ID=moved-call
captain hold "$ID" --title "Separate call" --reason "Choose for A" --origin origin-a >/dev/null || bad "hold for A"
printf 'Release this work.\n' > "$H/answer.txt"
captain answer "$ID" --release --decision-file "$H/answer.txt" >/dev/null || bad "release A"
captain complete origin-a "$ID" >/dev/null || bad "complete A"
echo "+ verify origin-a before the move:"; captain verify origin-a; echo "exit=$?"
cat > "$H/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  kill -TERM "$(cat "$FM_HOME/hold-pid")"
  exit 9
fi
exec "$REAL_TASKS_AXI" "$@"
SH
chmod +x "$H/fakebin/tasks-axi"
rc=0
echo "+ hold $ID --origin origin-b, process killed with TERM inside the backend hold:"
PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
  bash -c 'printf "%s\n" "$$" > "$FM_HOME/hold-pid"; exec "$@"' _ "$ROOT/bin/fm-captain-hold.sh" hold "$ID" --reason "Choose for B" --origin origin-b || rc=$?
echo "exit=$rc"
check "S7 hold process died from TERM (143)" "[ $rc -eq 143 ]"
rm -f "$H/fakebin/tasks-axi"
check "S7 origin-b was not published before the backend hold" "! grep -q 'Captain hold origin: origin-b' '$H/before-backend-hold'"
echo "+ task after the interrupted move:"; tasks show "$ID" --full
check "S7 task keeps A's association and the uncommitted stamp" "tasks show '$ID' --full | grep -q 'Captain hold origin: origin-a' && tasks show '$ID' --full | grep -q 'Captain hold set:'"
echo "+ complete origin-b with the stale call:"; captain complete origin-b "$ID"; echo "exit=$?"
check "S7 complete refuses the previous call for B" "! PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' complete origin-b '$ID' >/dev/null 2>&1"
echo "+ complete origin-a again (released answer beneath an incomplete hold):"; captain complete origin-a "$ID"; echo "exit=$?"
check "S7 the stamp guard refuses the earlier answer under the incomplete re-hold" "! PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' complete origin-a '$ID' >/dev/null 2>&1"
echo "+ replay A's answer, then the healthy move to B:"
captain answer "$ID" --release --decision-file "$H/answer.txt"; echo "exit=$?"
captain complete origin-a "$ID" >/dev/null && captain verify origin-a; echo "verify-a exit=$?"
captain hold "$ID" --reason "Choose for B" --origin origin-b; echo "exit=$?"
captain complete origin-b "$ID"; echo "exit=$?"
printf 'Ship it for B.\n' > "$H/answer-b.txt"
captain answer "$ID" --release --decision-file "$H/answer-b.txt"; echo "exit=$?"
captain complete origin-b "$ID"; echo "exit=$?"
echo "+ verify origin-b after the genuine answer:"; captain verify origin-b; echo "exit=$?"
check "S7 genuine answer for B verifies B" "PATH='$H/fakebin:$PATH' FM_HOME='$H' FM_STATE_OVERRIDE='$H/state' FM_DATA_OVERRIDE='$H/data' FM_CONFIG_OVERRIDE='$H/config' '$ROOT/bin/fm-captain-hold.sh' verify origin-b >/dev/null 2>&1"
printf '\nRESULT: ok=%d fail=%d\n' "$pass_n" "$fail_n"; [ "$fail_n" -eq 0 ]
