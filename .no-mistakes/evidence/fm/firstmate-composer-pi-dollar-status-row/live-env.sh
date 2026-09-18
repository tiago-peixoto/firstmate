# Shared environment for the live Pi dollar-footer lab run (sourced by each stage).
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/bbb16e1f0808/01M2TR1JDWEA6RNHTW49D4G1N1
BASE=/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm-pidollar-base.OAlLmT
EV=/Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1
STATEF=$EV/.live-state
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
[ -f "$STATEF" ] && . "$STATEF"
lab() { fm_herdr_lab_cli "$SESSION" "$@"; }
# composer verdict computed by a given code root's real herdr adapter
verdict() {  # <root> <target>
  ( export HERDR_SESSION="$SESSION"; . "$1/bin/fm-backend.sh"; fm_backend_source herdr >/dev/null 2>&1; fm_backend_herdr_composer_state "$2" )
}
screen() {  # [ansi] - the same `pane read --source recent` the adapter classifies
  if [ "${1:-}" = ansi ]; then herdr pane read "$PANE_ID" --session "$SESSION" --source recent --lines 60 --format ansi; else herdr pane read "$PANE_ID" --session "$SESSION" --source recent --lines 60; fi
}
control() {  # <root> <verb...>
  local r=$1; shift
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=30 "$r/bin/fm-control.sh" pidollar "$@" 2>&1
}
