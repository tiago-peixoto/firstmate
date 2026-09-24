#!/usr/bin/env bash
# Live: interactive Codex idles with a Stop-started supervisor; a turn-style
# foreground checkpoint (the command the Codex protocol runs each turn) must
# take over rather than fail "already running"; the next Codex turn's allowing
# Stop must start a fresh supervisor. Repeated for two turns.
# The checkpoint is invoked from outside Codex because the model's shell tool
# cannot run on this host (codex-code-mode-host binary is not installed).
set -u
umask 077
ROOT=${1:?worktree}
LAB=$(mktemp -d /tmp/fm-codex-handover.XXXXXX)
PROJECT=$LAB/project HOME_DIR=$LAB/fmhome CH=$LAB/codex-home LOG=$LAB/hits SRC=$LAB/source.sh SOCK=fm-codex-handover-$$
say(){ printf '[%s] %s\n' "$(date +%T)" "$*"; }
cleanup(){ tmux -L $SOCK kill-server 2>/dev/null; FM_HOME=$HOME_DIR $ROOT/bin/fm-codex-idle-continuity.sh --handover >/dev/null 2>&1; FM_HOME=$HOME_DIR $ROOT/bin/fm-procevent.sh sweep-home >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p $HOME_DIR/state $CH
git clone -q "$ROOT" $PROJECT 2>/dev/null
cp ~/.codex/auth.json $CH/auth.json
printf '[projects."%s"]\ntrust_level = "trusted"\n' "$(cd $PROJECT && pwd -P)" > $CH/config.toml
printf '#!/bin/sh\nprintf "x\\n" >> %s\n' "$LOG" > $SRC; chmod +x $SRC
FM_HOME=$HOME_DIR $ROOT/bin/fm-procevent.sh register lavish shot -- $SRC >/dev/null
FM_HOME=$HOME_DIR $ROOT/bin/fm-procevent.sh reconcile >/dev/null
sleep 3
sup(){ cat $HOME_DIR/state/.codex-idle-continuity.lock/pid 2>/dev/null || echo none; }
wl(){ cat $HOME_DIR/state/.watch.lock/pid 2>/dev/null || echo none; }
hits(){ wc -l < $LOG | tr -d ' '; }
say "source hits before codex: $(hits)"
tmux -L $SOCK new-session -d -s s -x 200 -y 50 -c $PROJECT -- env CODEX_HOME=$CH FM_HOME=$HOME_DIR FM_POLL=1 codex \
  --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c 'model_reasoning_effort="low"' \
  'Reply with exactly IDLE-OK. Do not call tools.'
cpid=$(tmux -L $SOCK display-message -p -t s '#{pane_pid}')
say "codex pid $cpid"
for _ in $(seq 1 120); do [ "$(sup)" != none ] && break; sleep 1; done
PREV=$(sup); say "turn 1 ended: idle supervisor pid=$PREV owner=$(cat $HOME_DIR/state/.codex-idle-continuity.lock/owner 2>/dev/null) watcher-lock=$(wl)"
h=$(hits); sleep 8; say "source hits while idle: $h -> $(hits)"
for turn in 2 3; do
  say "== turn $turn: foreground checkpoint while supervisor $PREV holds watcher $(wl)"
  rc=0; out=$(cd $PROJECT && FM_HOME=$HOME_DIR bin/fm-watch-checkpoint.sh --seconds 15 2>&1) || rc=$?
  printf '%s\n' "$out" | sed 's/^/  | /'; say "checkpoint rc=$rc; old supervisor $PREV alive? $(kill -0 $PREV 2>/dev/null && echo yes || echo no); supervisor lock=$(sup)"
  printf '%s\n' "$out" | grep -q 'already running' && say "FAIL: checkpoint collided with the supervisor"
  tmux -L $SOCK send-keys -t s -l "Reply with exactly TURN$turn-OK. Do not call tools."; sleep 1; tmux -L $SOCK send-keys -t s Enter
  for _ in $(seq 1 120); do s=$(sup); [ "$s" != none ] && [ "$s" != "$PREV" ] && break; sleep 1; done
  NEW=$(sup); say "after turn $turn Stop: supervisor pid=$NEW (fresh? $([ "$NEW" != none ] && [ "$NEW" != "$PREV" ] && echo yes || echo no)) owner=$(cat $HOME_DIR/state/.codex-idle-continuity.lock/owner 2>/dev/null)"
  h=$(hits); sleep 8; say "source hits while idle after turn $turn: $h -> $(hits)"
  PREV=$NEW
done
say "failure notice present? $([ -e $HOME_DIR/state/.codex-idle-continuity-failure-notified ] && echo yes || echo no)"
say "screen:"; tmux -L $SOCK capture-pane -p -t s | grep '[^[:space:]]' | tail -14 | sed 's/^/  # /'
tmux -L $SOCK kill-server; sleep 5
say "after codex exit: supervisor=$(sup) watcher-lock=$(wl) (old supervisor alive? $(kill -0 $PREV 2>/dev/null && echo yes || echo no))"
