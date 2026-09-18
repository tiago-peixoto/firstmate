#!/usr/bin/env bash
# Live drive of bin/fm-bootstrap.sh's secondmate re-read nudge against a REAL
# tmux pane: the primary checkout changes its instruction surface while a
# running secondmate waits on its own decision. World builders come from
# tests/fm-secondmate-sync.test.sh (sourced without running its cases); tmux is
# the real binary on a private socket, only node/gh/lavish/chrome probes are stubbed.
set -u
HELPERS=${HELPERS:?}; WT=${WT:?}
. "$HELPERS"
ROOT=$WT
export TMUX_TMPDIR=$(mktemp -d /tmp/fm4228-tmx.XXXXXX); unset TMUX TMUX_PANE
w=$(new_world live-nudge); c1=$(head_of "$w/main")
add_sm_worktree "$w" sm-instr "$c1"
bump_primary "$w" instr
fakebin=$(make_fake_toolchain "$w"); rm -f "$fakebin/tmux"
tmux new-session -d -s firstmate -n fm-sm-instr "cat"
REALPATH="$fakebin:$(dirname "$(command -v tmux)"):$BASE_PATH"
boot() { PATH="$REALPATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" FM_SEND_SETTLE=0 \
  "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null | grep -E 'NUDGE_SECONDMATES|BOOTSTRAP_INFO: nudged' | sed 's/^/  | /'; }
look() {
  echo "  retry marker: $([ -e "$w/home/state/.secondmate-nudge-pending/sm-instr.pending" ] && echo kept || echo gone)" \
       "| inbox records: $(ls "$w/home/state/sm-instr.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
  echo "  secondmate pane:"; tmux capture-pane -p -t firstmate:fm-sm-instr | sed '/^$/d; s/^/    > /'
}
echo "== secondmate sm-instr is running and has opened its own decision"
printf 'needs-decision [key=pick]: alpha or beta?\n' > "$w/home/state/sm-instr.status"; sed 's/^/  status: /' "$w/home/state/sm-instr.status"
echo "== session start (fm-bootstrap.sh) after the primary changed AGENTS.md/bin/skills"
boot; look
echo; echo "== second session start while the decision is still open"
boot; look
echo; echo "== firstmate answers the decision; next session start retries the kept marker"
printf 'resolved [key=pick]: answered: alpha\n' >> "$w/home/state/sm-instr.status"
boot; look
tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR"
