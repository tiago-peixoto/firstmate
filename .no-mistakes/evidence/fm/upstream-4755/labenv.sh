# Sourced by every evidence step: all paths resolve inside the disposable lab home.
export EVID=/home/firstmate/.no-mistakes/evidence/01M5XPSSM3WHP49YTJX90GPD0J LAB=/tmp/fm-lab.JufiLO ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5XPSSM3WHP49YTJX90GPD0J
export TMUX_TMPDIR=/tmp/fm-lab.JufiLO/tmux
prod() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=/tmp/fm-lab.JufiLO TMUX_TMPDIR=/tmp/fm-lab.JufiLO/tmux "$@"; }
