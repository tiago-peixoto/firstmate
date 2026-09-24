#!/usr/bin/env bash
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/762e4773438f/01M38AFH45XCX7SH6PA8DF77GF
EV=/Users/tiago/.no-mistakes/evidence/01M38AFH45XCX7SH6PA8DF77GF
unset NO_MISTAKES_GATE; export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=1
SOCKET=fm-waitlive-$$; S=waitlive; W=worker
LAB=$(mktemp -d /tmp/fm-waitlive.XXXX); LAB=$(cd $LAB && pwd)
trap 'tmux -L $SOCKET kill-server 2>/dev/null; rm -rf $LAB' EXIT
mkdir -p $LAB/shim $LAB/home/state
REAL=$(command -v tmux); printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL" "$SOCKET" > $LAB/shim/tmux; chmod +x $LAB/shim/tmux
export PATH=$LAB/shim:$PATH FM_HOME=$LAB/home FM_ROOT_OVERRIDE=$LAB/home
. $ROOT/bin/fm-tmux-lib.sh
tmux new-session -d -s $S -x 200 -y 50 -c "$ROOT"
tmux new-window -d -t "$S:" -n $W -c /Users/tiago/Workspace -- bash -lc 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '\''{"feedbackDrafts":"off"}'\'''
for i in $(seq 60); do v=$(fm_tmux_composer_state $S:$W); [ "$v" = empty ] && break; sleep 1; done
echo "composer verdict at start: $v (after ${i}s)"
cap(){ tmux capture-pane -p -t $S:$W | grep '[^[:space:]]'; }
printf 'window=%s:%s\nkind=ship\nharness=claude\n' $S $W > $LAB/home/state/t1.meta
ST=$LAB/home/state/t1.status
echo; echo "== worker is waiting on its own decision"
printf 'needs-decision [key=pick]: ship alpha or beta?\n' | tee $ST
before=$(cap)
echo "\$ fm-send.sh t1 --automatic 'Firstmate: re-read your brief now'"
$ROOT/bin/fm-send.sh t1 --automatic "Firstmate: re-read your brief now" 2>&1 | grep -v '^●\|WARNING: watcher'; echo "exit=${PIPESTATUS[0]}"
sleep 20
after=$(cap)
[ "$before" = "$after" ] && echo "RESULT: worker pane unchanged 20s later - no turn spent" || { echo "RESULT: pane CHANGED"; diff <(echo "$before") <(echo "$after"); }
echo "inbox records: $(ls $LAB/home/state/t1.inbox 2>/dev/null | grep -c '\.msg' || true)"
echo "--- worker pane while waiting ---"; cap | tail -12
echo; echo "== firstmate answers deliberately"
ACT=$LAB/acted
echo "\$ fm-send.sh t1 --resolve-key pick '<answer: touch acted, then ack>'"
$ROOT/bin/fm-send.sh t1 --resolve-key pick "Answer to pick: alpha. Run exactly this shell command now: touch $ACT - then follow the mv instruction you were given for this message. Reply with one short line." 2>&1 | grep -v '^●\|WARNING: watcher'; echo "exit=${PIPESTATUS[0]}"
for i in $(seq 180); do [ -e $ACT ] && [ -f $LAB/home/state/t1.inbox/handled/001.msg ] && break; sleep 1; done
echo "acted=$([ -e $ACT ] && echo yes || echo no) acked=$([ -f $LAB/home/state/t1.inbox/handled/001.msg ] && echo yes || echo no) after ${i}s"
echo "status tail: $(tail -1 $ST)"
echo "--- worker pane after the answer ---"; cap | tail -20
