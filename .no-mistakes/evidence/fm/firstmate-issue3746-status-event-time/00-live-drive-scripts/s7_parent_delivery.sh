. /tmp/fm-live/common.sh
nap() { perl -e 'select(undef,undef,undef,$ARGV[0])' "$1"; }
W=$(mktemp -d /tmp/fm-live/world.XXXXXX)
MAIN="$W/main"; MATE="$W/mate"
mkdir -p "$W/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
: > "$MATE/AGENTS.md"; : > "$W/forge.log"
FB=$(make_fakebin "$W")
for tool in gh gh-axi curl; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$(basename "$0")" >> "${FM_FORGE_LOG:?}"\nexit 97\n' > "$FB/$tool"
done
chmod +x "$FB"/*
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
rc=0

set_old() { touch -t "$(date -r $(( $(date +%s) - 120 )) +%Y%m%d%H%M.%S)" "$@"; }

hr "a child of the secondmate finishes and writes the brief's stamped ready signal"
CHILD_LINE="done [at=$(date +%s)]: PR https://example.test/owner/repo/pull/3746 checks green"
write_meta "$MATE/state/child.meta" "window=firstmate:fm-child" "worktree=$MATE/projects/child" \
  "project=alpha" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s1.1"
printf '%s\n' "$CHILD_LINE" > "$MATE/state/child.status"
: > "$MATE/state/child.turn-ended"
set_old "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
echo "  (no pr= recorded in meta, so the PR can only come from the stamped ready line)"
cat "$MATE/state/child.status"
write_meta "$MAIN/state/mate.meta" "window=firstmate:fm-mate" "endpoint_task_id=mate" \
  "worktree=$MATE" "project=$MATE" "harness=echo" "kind=secondmate" "mode=secondmate" "home=$MATE" "projects=alpha"
printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
set_old "$MAIN/state/mate.meta" "$MAIN/state/mate.status"

run_reconcile() {
  env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$W/root" FM_HOME="$MATE" \
    FM_STATE_OVERRIDE="$MATE/state" FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$FB/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: unknown · source: none' FM_FORGE_LOG="$W/forge.log" \
    "$BIN/fm-inactive-reconcile.sh" scan
}

hr "the secondmate's poll publishes it on the parent channel (real bin/fm-inactive-reconcile.sh scan)"
run_reconcile | sed 's/^/  /'
printf 'parent channel (main/state/mate.status):\n'; sed 's/^/  /' "$MAIN/state/mate.status"

if grep -q 'pr=https://example.test/owner/repo/pull/3746' "$MAIN/state/mate.status"; then
  echo "  ok   the stamped ready signal still yielded the delivered PR"
else
  echo "  FAIL the stamped ready line lost its PR"; rc=1
fi
DELIVERED=$(grep 'child-outcome-child-done' "$MAIN/state/mate.status" | head -1)
EPOCH=$(bash -c '. "$1"; status_line_at_epoch "$2"' _ "$BIN/fm-classify-lib.sh" "$DELIVERED")
[ -n "$EPOCH" ] && echo "  ok   the upward delivery carries its own emission time ($EPOCH)" \
  || { echo "  FAIL the upward delivery is unstamped"; rc=1; }

hr "a replayed poll after the delivery receipt is lost (restart / restored state)"
nap 1.2
rm -rf "$MATE/state/terminal-outcomes"
echo "  receipts removed; re-running the same poll a second later"
run_reconcile | sed 's/^/  /'
printf 'parent channel now:\n'; sed 's/^/  /' "$MAIN/state/mate.status"
COUNT=$(grep -c 'child-outcome-child-done' "$MAIN/state/mate.status")
if [ "$COUNT" = 1 ]; then
  echo "  ok   the retry was recognised as the same event despite a newer clock: 1 delivered line"
else
  echo "  FAIL the retry duplicated the event ($COUNT copies)"; rc=1
fi

hr "captain's view of the parent home"
FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_ROOT_OVERRIDE="$MAIN" "$BIN/fm-wake-drain.sh" 2>/dev/null | sed -n '1,8p' | sed 's/^/  /'
[ ! -s "$W/forge.log" ] || { echo "  note: forge was called: $(cat "$W/forge.log")"; }
[ "$rc" = 0 ] && echo "RESULT S7/S8: PASS" || echo "RESULT S7/S8: FAIL"
exit $rc
