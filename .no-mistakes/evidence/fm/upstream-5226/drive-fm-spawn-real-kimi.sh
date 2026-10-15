#!/usr/bin/env bash
# drive.sh <scenario> <mcp-json-or-NONE> : one live fm-spawn run against real kimi 2.1.1 on a private tmux
set -u
SC=$1 MCP=$2
WTREE=${FM_DRIVE_ROOT:-/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M4ZRV2XTNMKZXCK2AY5MGVZM}
K2=${FM_DRIVE_KIMI:-/tmp/fm-kimi-211.X9Pzeu}
EV=/home/firstmate/.no-mistakes/evidence/01M4ZRV2XTNMKZXCK2AY5MGVZM
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
"$WTREE/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/home/.kimi-code" "$LAB/pool"
cp "$K2/home/.kimi-code/config.toml" "$LAB/home/.kimi-code/config.toml"
mkdir -p "$LAB/home/.kimi-code/bin"
printf '#!/bin/sh\nexec /home/firstmate/.local/share/mise/installs/node/22.23.1/bin/node %s "$@"\n' "$K2/node_modules/@moonshot-ai/kimi-code/dist/main.mjs" > "$LAB/home/.kimi-code/bin/kimi"; chmod +x "$LAB/home/.kimi-code/bin/kimi"
if [ -n "${FM_DRIVE_LATE_MCP:-}" ]; then
  printf '#!/bin/sh\nmkdir -p .kimi-code\nprintf "%%s\\n" "{\\"mcpServers\\":{\\"late-marker\\":{\\"command\\":\\"%s\\"}}}" > .kimi-code/mcp.json\nexec /home/firstmate/.local/share/mise/installs/node/22.23.1/bin/node %s "$@"\n' "$LAB/projects/demo/repro-mcp-marker.sh" "$K2/node_modules/@moonshot-ai/kimi-code/dist/main.mjs" > "$LAB/home/.kimi-code/bin/kimi"
fi
ID="kimi-$SC"
P="$LAB/projects/demo"
git init -q --bare "$LAB/origin.git"
git init -q -b main "$P"
printf 'demo\n' > "$P/README.md"
MARK="$LAB/marker.log"
printf '#!/bin/sh\necho "started $*" >> %s\nsleep 60\n' "$MARK" > "$P/repro-mcp-marker.sh"; chmod +x "$P/repro-mcp-marker.sh"
if [ "$MCP" != NONE ]; then mkdir -p "$P/.kimi-code"; printf '%s\n' "${MCP//@MARKER@/$P/repro-mcp-marker.sh}" > "$P/.kimi-code/mcp.json"; fi
git -C "$P" add -A; git -C "$P" -c user.name=t -c user.email=t@e.invalid commit -qm init
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main; git -C "$P" remote add origin "$LAB/origin.git"; git -C "$P" push -q -u origin main; git -C "$P" remote set-head origin main
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<EOF
# Task
Delivery contract: mode=local-only
## Captain's intent
Reply with the word ok and stop.
## Firstmate spec
Do nothing else.
EOF
printf 'kimi\n' > "$LAB/config/crew-harness"
touch "$LAB/state/.last-watcher-beat"
OUT="$LAB/spawn.out"
PATHV="/usr/bin:/bin:/home/firstmate/.local/bin"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -f /dev/null -L fm-lab new-session -d -s primary -x 160 -y 50 -c "$WTREE" \
  -e FM_HOME="$LAB" -e HOME="$LAB/home" -e KIMI_CODE_HOME="$LAB/home/.kimi-code" -e TREEHOUSE_ROOT="$LAB/pool" -e PATH="$PATHV" -e TERM=xterm-256color env PATH="$PATHV" bash --norc
sleep 1
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t primary "FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh $ID $P --harness kimi --mode local-only --yolo off > $OUT 2>&1; echo EXIT=\$? >> $OUT" Enter
for i in $(seq 1 120); do grep -q '^EXIT=' "$OUT" 2>/dev/null && break; sleep 1; done
sleep ${FM_DRIVE_SETTLE:-3}
{
  echo "### scenario: $SC"
  echo "### project .kimi-code/mcp.json: $( [ -f "$P/.kimi-code/mcp.json" ] && cat "$P/.kimi-code/mcp.json" || echo '(absent)')"
  echo "### fm-spawn.sh output"; cat "$OUT"
  echo "### tmux windows"; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} path=#{pane_current_path}'
  for w in $(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_index}'); do
    echo "### visible pane $w"; TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t "$w" | sed '/^[[:space:]]*$/d'
  done
  echo "### kimi processes in lab"; pgrep -af "kimi-code/dist/main.mjs|kimi-code" | grep -v pgrep || echo "(none)"
  echo "### project MCP marker log: $( [ -e "$MARK" ] && cat "$MARK" || echo '(absent - no project MCP command started)')"
  echo "### Kimi workspaces.json (folder trust records)"; cat "$LAB/home/.kimi-code/workspaces.json" 2>/dev/null || echo '(absent)'
} > "$EV/$SC.txt" 2>&1
cat "$EV/$SC.txt"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
git -C "$P" worktree prune 2>/dev/null
chmod -R u+w "$LAB"; rm -rf "$LAB" /tmp/fm-$ID /tmp/fm-$ID+*
