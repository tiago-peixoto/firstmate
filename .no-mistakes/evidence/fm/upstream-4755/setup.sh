#!/usr/bin/env bash
# Mint the disposable lab home and start session A: a real claude primary on the lab's private tmux socket.
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB" > /tmp/fm-lab-4755.path
bin/fm-lab-home.sh create "$LAB"; mkdir -p "$LAB/tmux"
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -n claude -x 200 -y 50 -c "$PWD" -e FM_HOME="$LAB" claude
T new-window -d -t primary -n fm-mate -c "$PWD" bash
T display-message -p -t primary '#{socket_path}' > "$LAB/sock"
/bin/sleep 12
T send-keys -t primary:claude -l 'Run the command bin/fm-session-start.sh once, then print only its WAKE QUEUE section verbatim. Do nothing else.'; /bin/sleep 1; T send-keys -t primary:claude Enter
timeout 240 bash -c 'until [ -e "'$LAB'/state/.session-start-complete" ] && [ -s "'$LAB'/state/.lock" ]; do /bin/sleep 5; done'
/bin/sleep 30
T capture-pane -p -S -200 -t primary:claude | grep -v '^$'
