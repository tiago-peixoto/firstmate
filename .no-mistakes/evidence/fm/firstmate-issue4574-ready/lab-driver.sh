# sourced helper for the live account lab
LAB=/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm-acct-live.NSc6vQ
ROOT=/Users/tiago/.no-mistakes/worktrees/762e4773438f/01M2V2N8NS6X43VP13PKQAB1NG
TMUXL=$LAB/shim/tmux
mkhome() { # <home>
  mkdir -p "$1/data" "$1/projects" "$1/state" "$1/config"
  touch "$1/state/.last-watcher-beat"
}
brief() { # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<B
# Task
## Captain's intent
Reply with one short sentence acknowledging this brief, then stop. Do not edit files.

## Firstmate spec
Live account-selection lab task $2. Reply once and stop.
B
}
fm() { # <home> <script> args...  (runs a Firstmate entrypoint as the supervising process)
  local home=$1 script=$2; shift 2
  ( cd "$LAB" && env -i HOME="$LAB/userhome" PATH="$LAB/shim:/Users/tiago/.opencode/bin:/Users/tiago/.grok/bin:/Users/tiago/.kimi-code/bin:/Users/tiago/Library/pnpm:/opt/homebrew/opt/postgresql@18/bin:/Users/tiago/.local/share/mise/installs/ruby/3.4.7/bin:/Users/tiago/.foundry/bin:/Users/tiago/.pyenv/shims:/Users/tiago/.nvm/versions/node/v22.23.1/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/System/Cryptexes/App/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/local/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/bin:/var/run/com.apple.security.cryptexd/codex.system/bootstrap/usr/appleinternal/bin:/pkg/env/global/bin:/Library/Apple/usr/bin:/Users/tiago/.local/bin:/Users/tiago/go/bin:/Users/tiago/.cargo/bin:/Users/tiago/bin:/usr/local/sbin:/Users/tiago/.foundry/bin:/Users/tiago/.orbstack/bin:/Users/tiago/.claude/plugins/cache/claude-plugins-official/context7/c447c3207a42/bin:/Users/tiago/.claude/plugins/cache/ponytail/ponytail/4.9.0/bin:/Users/tiago/.claude/plugins/cache/typesafe-ai/typesafe/0.5.7/bin" TERM=xterm-256color LANG=en_US.UTF-8 TMPDIR="$TMPDIR" \
    FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE= FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    TREEHOUSE_ROOT="$LAB/pool" PI_OFFLINE=1 \
    CLAUDE_CONFIG_DIR="$LAB/ambient-spawn-claude" ANTHROPIC_API_KEY=AMBIENT-SPAWN-KEY \
    PERSONAL_ENV_KEY=AMBIENT-SPAWN-ENV-KEY PI_CODING_AGENT_DIR="$LAB/accounts/pi-other" \
    "$ROOT/bin/$script" "$@" )
}
spawn() { local home=$1; shift; fm "$home" fm-spawn.sh "$@"; }
windows() { $TMUXL list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null; }
