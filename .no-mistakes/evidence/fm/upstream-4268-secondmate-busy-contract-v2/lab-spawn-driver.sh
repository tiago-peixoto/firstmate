#!/usr/bin/env bash
# Stage 1: real fm-spawn --secondmate on a private tmux socket; the pane command is a
# recorder that saves the argv the spawn built, so no brief reaches a model.
set -u
ROOT=$1 LAB=$2 HARNESS_ARG=$3 ID=$4
SOCKET=fm-lab
REAL_TMUX=$(command -v tmux); REAL_CLAUDE=$(command -v claude)
primary="$LAB/primary"; sm="$LAB/sm"; shim="$LAB/shim"; rec="$LAB/rec"
mkdir -p "$shim" "$rec" "$LAB/user-home" "$LAB/tmux"
cat > "$shim/tmux" <<SH
#!/usr/bin/env bash
TMUX_TMPDIR="$LAB/tmux" exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
cat > "$rec/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|--version|-v|-V) exec "$REAL_CLAUDE" "\$@" ;; esac
n=\$(ls "$LAB" | grep -c '^argv\.') 
printf '%s\0' "\$@" > "$LAB/argv.\$n"
env | grep -E '^(CLAUDE|FM_)' > "$LAB/env.\$n"
printf 'working\n'; exec sleep 600
SH
chmod +x "$shim/tmux" "$rec/claude"
if [ ! -d "$primary" ]; then
  mkdir -p "$primary/data" "$primary/projects" "$primary/state" "$primary/config"
  touch "$primary/state/.last-watcher-beat"
  printf 'claude\n' > "$primary/config/crew-harness"
fi
FM_BACKEND=tmux FM_HOME="$primary" \
  HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
  FM_SPAWN_NO_GUARD=1 \
  env -u TMUX -u TMUX_PANE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$rec:$shim:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$sm" "$HARNESS_ARG" --secondmate
