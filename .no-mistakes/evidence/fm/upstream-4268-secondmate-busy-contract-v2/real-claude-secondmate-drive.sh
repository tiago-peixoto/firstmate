#!/usr/bin/env bash
# Real Claude secondmate turn on a private tmux server.
set -u
ROOT=/home/firstmate/.no-mistakes/worktrees/42fe67ed39fa/01M35GH3SYWGYK4V4FVBBEZE8C
GUARD_MODE=${1:-new}   # new | old
LAB=$(mktemp -d /tmp/fm-sm-real/lab.XXXXXX)
SOCK="fm-sm-real-$$"
REAL_TMUX=/usr/bin/tmux
CLAUDE=$(command -v claude)
T() { "$REAL_TMUX" -L "$SOCK" "$@"; }
id=sm-real
primary=$LAB/primary; sm=$LAB/sm
mkdir -p $primary/{data,projects,state,config} $LAB/shim $LAB/sleeper
touch $primary/state/.last-watcher-beat; echo claude > $primary/config/crew-harness
git -c advice.detachedHead=false clone -q "$ROOT" "$sm"
if [ "$GUARD_MODE" = old ]; then
  git -C "$ROOT" show d92cea0c55fe7f5a9ef1b9f204491468ef3831f3:bin/fm-turnend-guard.sh > "$sm/bin/fm-turnend-guard.sh"
fi
mkdir -p $sm/{data,state,config,projects}
echo "$id" > $sm/.fm-secondmate-home; echo charter > $sm/data/charter.md
git -C $sm add -A >/dev/null; git -C $sm -c user.name=t -c user.email=t@t commit -qm seed
printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCK" > $LAB/shim/tmux; chmod +x $LAB/shim/tmux
cat > $LAB/sleeper/claude <<SH
#!/usr/bin/env bash
case "\${1:-}" in --help|--version|-v|-V) exec $CLAUDE "\$@";; esac
printf 'working\n'; exec sleep 600
SH
chmod +x $LAB/sleeper/claude
echo "== spawn (guard=$GUARD_MODE)"
FM_BACKEND=tmux FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" FM_STATE_OVERRIDE="$primary/state" \
  FM_DATA_OVERRIDE="$primary/data" FM_PROJECTS_OVERRIDE="$primary/projects" FM_CONFIG_OVERRIDE="$primary/config" \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 env -u TMUX -u TMUX_PANE -u CLAUDECODE PATH="$LAB/sleeper:$LAB/shim:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$id" "$sm" claude --secondmate 2>&1 | tail -3
st=$primary/state; [ -f $st/$id.busy-state ] || { echo SPAWN FAILED; T kill-server; exit 1; }
echo "== generated settings.local.json hook events:"; python3 -c "import json,sys;print(sorted(json.load(open('$sm/.claude/settings.local.json'))['hooks']))"
echo "== .fm-busy-stop present: $([ -f $sm/.fm-busy-stop ] && echo yes || echo no)"
. "$ROOT/bin/fm-busy-lib.sh"
cls() { fm_busy_classify_meta "$id" "$st" 2>/dev/null || fm_busy_classify tmux x claude "$id" "$st" "working"; }
echo "== after spawn: record=$(cat $st/$id.busy-state 2>/dev/null | tr '\n' ' ')"
T kill-window -t firstmate:fm-$id 2>/dev/null
# Real claude in the mate's home, clean env, real sized pty via tmux
T new-window -d -t firstmate: -n real -c "$sm" -- env -i HOME="$HOME" USER="$USER" PATH="$PATH" TERM=xterm-256color LANG=C.UTF-8 "$CLAUDE" --dangerously-skip-permissions --model haiku
T resize-window -t firstmate:real -x 200 -y 50 2>/dev/null
for i in $(seq 1 60); do
  cap=$(T capture-pane -p -t firstmate:real 2>/dev/null)
  if printf '%s' "$cap" | grep -qiE 'trust|Yes, I accept|Do you trust'; then T send-keys -t firstmate:real Enter; sleep 2; fi
  printf '%s' "$cap" | grep -qE '^\s*(>|❯)' && break
  sleep 1
done
sleep 3
echo "== pre-prompt record: $(tr '\n' ' ' < $st/$id.busy-state)"
T send-keys -t firstmate:real -l 'Use the Bash tool to run: sleep 12. Then reply with just the word DONE.'
sleep 1; T send-keys -t firstmate:real Enter
: > $LAB/timeline
for i in $(seq 1 200); do [ $i = 150 ] && ps -eo pid,etimes,args | grep -E "fm-(turnend-guard|claude-stop|watch)" | grep -v grep > $LAB/ps150;
  printf '%s %s\n' "$(date +%T)" "$(tr "\n" " " < $st/$id.busy-state 2>/dev/null)" >> $LAB/timeline
  sleep 1
done
echo "== timeline (deduped):"; uniq -f1 $LAB/timeline
echo "== parent turn-ended exists: $([ -e $st/$id.turn-ended ] && echo YES || echo no)"
echo "== pane tail:"; T capture-pane -p -t firstmate:real | grep -v '^\s*$' | tail -15
T capture-pane -e -p -t firstmate:real > $LAB/pane.ansi
echo "== hook procs at t+150s:"; cat $LAB/ps150; echo "LAB=$LAB"
T kill-server
