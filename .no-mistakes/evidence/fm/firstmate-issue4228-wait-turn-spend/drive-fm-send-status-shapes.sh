#!/usr/bin/env bash
# fm-send --automatic against a real tmux pane across status-log shapes a
# worker actually writes: unkeyed decision/blocker lines, a later working: line
# (which never closes a decision), paused:, and --key.
set -u
ROOT=${ROOT:?}
W=$(mktemp -d /tmp/fm4228-shp.XXXXXX)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
H="$W/home"; mkdir -p "$H/state"; chmod 755 "$H/state"
export FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT"
tmux new-session -d -s sess -n fm-t1 "cat"
printf 'window=sess:fm-t1\nkind=ship\nharness=claude\n' > "$H/state/t1.meta"
case_() {  # <label> <status-lines...>
  local label=$1; shift; printf '%s\n' "$@" > "$H/state/t1.status"
  local before after rc
  before=$(ls "$H/state/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')
  out=$("$ROOT/bin/fm-send.sh" t1 --automatic "re-read your instructions" 2>&1); rc=$?
  after=$(ls "$H/state/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')
  printf '%-58s exit=%s new-records=%s %s\n' "$label" "$rc" "$((after - before))" "$(printf '%s\n' "$out" | grep -E '^(deferred|error):' | head -1)"
}
case_ "unkeyed needs-decision"            'needs-decision: alpha or beta?'
case_ "unkeyed blocked"                   'blocked: need creds'
case_ "needs-decision then working:"      'needs-decision [key=pick]: alpha or beta?' 'working: started alpha anyway'
case_ "needs-decision then done:"         'needs-decision [key=pick]: alpha or beta?' 'done: PR x checks green'
case_ "decision resolved by worker"       'blocked [key=slot]: waiting slot' 'resolved [key=slot]: slot freed'
case_ "paused: (external wait, not a decision)" 'paused: my own validation round'
case_ "working only"                      'working: implementing'
case_ "no status file" ; rm -f "$H/state/t1.status"
out=$("$ROOT/bin/fm-send.sh" t1 --automatic "x" 2>&1); echo "status file absent                                          exit=$? $(printf '%s\n' "$out" | grep -E '^(deferred|error):' | head -1)"
printf 'needs-decision [key=pick]: alpha or beta?\n' > "$H/state/t1.status"
out=$("$ROOT/bin/fm-send.sh" t1 --automatic --key Escape 2>&1); echo "--automatic --key Escape                                    exit=$? $(printf '%s\n' "$out" | grep -E '^(deferred|error):' | head -1)"
tmux kill-server 2>/dev/null; rm -rf "$W"
