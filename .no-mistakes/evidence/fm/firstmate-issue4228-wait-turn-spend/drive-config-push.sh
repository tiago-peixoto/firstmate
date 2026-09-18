#!/usr/bin/env bash
# Live drive of bin/fm-config-push.sh against a REAL tmux pane: an inherited
# config value changes while a local secondmate waits on its own decision.
# World builders come from tests/fm-secondmate-harness.test.sh (sourced without
# running its cases); tmux is real on a private socket, other probes stubbed.
set -u
HELPERS=${HELPERS:?}; WT=${WT:?}
. "$HELPERS"
ROOT=$WT
export TMUX_TMPDIR=$(mktemp -d /tmp/fm4228-tmx.XXXXXX); unset TMUX TMUX_PANE
w=$(new_world live-config); head=$(git -C "$w/main" rev-parse HEAD)
add_sm_worktree "$w" sm "$head"
mkdir -p "$w/sm/config" "$w/sm/state"
printf 'old-harness\n' > "$w/sm/config/crew-harness"
printf 'codex\n' > "$w/home/config/crew-harness"
fakebin=$(make_fake_toolchain "$w"); rm -f "$fakebin/tmux"
tmux new-session -d -s firstmate -n fm-sm "cat"
push() { echo "\$ fm-config-push.sh"; PATH="$fakebin:$(dirname "$(command -v tmux)"):$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
  FM_SEND_SETTLE=0 "$ROOT/bin/fm-config-push.sh" 2>/dev/null | sed 's/^/  | /'; echo "  exit=${PIPESTATUS[0]}"; }
look() {
  echo "  retry marker: $([ -e "$(reread_pending_path "$w/sm")" ] && echo kept || echo gone)" \
       "| sm inbox records: $(ls "$w/home/state/sm.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')" \
       "| sm crew-harness: $(cat "$w/sm/config/crew-harness")"
  echo "  secondmate pane:"; tmux capture-pane -p -t firstmate:fm-sm | sed '/^$/d; s/^/    > /'
}
echo "== secondmate sm waits on its own decision; parent crew-harness changed old-harness -> codex"
printf 'needs-decision [key=pick]: alpha or beta?\n' > "$w/home/state/sm.status"; sed 's/^/  status: /' "$w/home/state/sm.status"
push; look
echo; echo "== firstmate answers the decision; config-push is run again"
printf 'resolved [key=pick]: answered: alpha\n' >> "$w/home/state/sm.status"
push; look
tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR"
