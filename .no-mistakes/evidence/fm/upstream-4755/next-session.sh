#!/usr/bin/env bash
# Stop the lab primary and start a new real claude primary, then have it run session start.
LAB=$(cat /tmp/fm-lab-4755.path); T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
old=$(cat "$LAB/state/.lock")
T kill-window -t primary:claude
timeout 30 bash -c "while kill -0 $old 2>/dev/null; do /bin/sleep 1; done"
rm -f "$LAB/state/.session-start-complete"
T new-window -d -t primary -n claude -c "$PWD" claude
/bin/sleep 12
T send-keys -t primary:claude -l 'Run the command bin/fm-session-start.sh once, then print only its WAKE QUEUE section verbatim. Do nothing else.'; /bin/sleep 1; T send-keys -t primary:claude Enter
timeout 240 bash -c 'until [ -e "'$LAB'/state/.session-start-complete" ] && [ "$(cat "'$LAB'/state/.lock" 2>/dev/null)" != "'$old'" ]; do /bin/sleep 5; done'
/bin/sleep 30
T capture-pane -p -S -200 -t primary:claude | grep -v '^$'
