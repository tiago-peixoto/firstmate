#!/usr/bin/env bash
# Run the real bin/fm-crew-state.sh for a crew with no no-mistakes run and an
# idle pane, so its reported state comes from its status log. Backends are the
# fakes from tests/fm-crew-state.test.sh (make_fakebin); everything else is real.
# Usage: drive-crew-state.sh <repo-root> <fixture-source-root>
set -u
ROOT=$1; FIX=$2; d=$(mktemp -d /tmp/fm-cs.XXXX); mkdir -p "$d/state"
eval "$(awk '/^make_fakebin\(\) *\{/{p=1} p{print} p&&/^}/{exit}' "$FIX/tests/fm-crew-state.test.sh")"
make_fakebin "$d" >/dev/null
git init -q -b fm/feat "$d/wt"; git -C "$d/wt" -c user.email=a@b -c user.name=a commit -q --allow-empty -m init
printf 'window=fm:fm-feat\nworktree=%s\nkind=ship\nharness=claude\n' "$d/wt" > "$d/state/feat.meta"
export NM_HOME="$d/nm" FM_FAKE_AXI_STATUS="" FM_FAKE_BUSY=0 FM_CREW_STATE_NO_FORGE=1 FM_ROOT_OVERRIDE="$d"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$d/state" feat)
"$ROOT/bin/fm-busy-event.sh" apply "$d/state" feat idle --gen "$gen" --source claude-hook --event stop
run() {  # <label> <content>
  printf '%s' "$2" > "$d/state/feat.status"
  printf '== %s\n' "$1"; sed 's/^/     | /' "$d/state/feat.status"
  PATH="$d/fakebin:$PATH" FM_STATE_OVERRIDE="$d/state" "$ROOT/bin/fm-crew-state.sh" feat 2>&1 | sed 's/^/   => /'
}
run "control: paused: alone" $'paused: waiting on upstream release\n'
for c in 'https://github.com/o/r/pull/12' 'Reason: upstream is slow' 'Note: see above' 'e.g.: foo' '10:30 retry scheduled'; do
  run "adversarial: paused: + continuation '$c'" "paused: waiting on upstream release"$'\n'"$c"$'\n'
done
run "parked: after paused: (new declaration replaces the pause)" $'paused: waiting on upstream release\nparked: waiting for upstream\n'
run "done with mismatched corr token after needs-decision" $'needs-decision [key=kept]: a real decision\ndone corr=deadbeef: shipped\n'
run "control: done: shipped" $'working: x\ndone: shipped\n'
rm -rf "$d"
