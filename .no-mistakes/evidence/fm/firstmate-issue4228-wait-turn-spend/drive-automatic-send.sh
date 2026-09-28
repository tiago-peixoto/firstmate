#!/usr/bin/env bash
# Live driver: real bin/fm-send.sh against a real tmux pane on a private lab socket.
set -u
LAB=$1; WT=$2
export TMUX_TMPDIR="$LAB/tmux"
SOCK="$LAB/tmux/fm-lab"
export TMUX="$SOCK,0,0"
export FM_HOME="$LAB" FM_SEND_SETTLE=0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
S="$LAB/state"
printf 'window=lab:fm-t1\nkind=ship\nharness=claude\n' > "$S/t1.meta"
cap() { tmux -L fm-lab capture-pane -p -t lab:fm-t1 | sed '/^$/d'; }
step() { echo; echo "=== $* ==="; }

step "1. worker t1 opens a decision"
printf 'working: implementing\nneeds-decision [key=pick]: ship alpha or beta?\n' > "$S/t1.status"
cat "$S/t1.status"

step "2. automatic re-read nudge while decision is open"
"$WT/bin/fm-send.sh" t1 --automatic "re-read your instructions"; echo "exit=$?"
echo "inbox records: $(ls "$S/t1.inbox/"*.msg 2>/dev/null | wc -l)"
echo "pane after deferred send:"; cap

step "3. adversarial: --automatic combined with --resolve-key is refused"
"$WT/bin/fm-send.sh" t1 --automatic --resolve-key pick "use alpha"; echo "exit=$?"

step "4. firstmate's deliberate answer (--resolve-key pick) still wakes the worker"
"$WT/bin/fm-send.sh" t1 --resolve-key pick "use alpha"; echo "exit=$?"
ls "$S/t1.inbox/"; echo "status now:"; cat "$S/t1.status"
echo "pane after answer:"; cap

step "5. automatic nudge after decision closed is delivered"
"$WT/bin/fm-send.sh" t1 --automatic "re-read your instructions"; echo "exit=$?"
ls "$S/t1.inbox/"
echo "pane:"; cap

step "6. an open blocker also defers an automatic nudge"
printf 'blocked [key=ci]: waiting on CI credentials\n' >> "$S/t1.status"
"$WT/bin/fm-send.sh" t1 --automatic "re-read your instructions"; echo "exit=$?"
echo "inbox records: $(ls "$S/t1.inbox/"*.msg | wc -l)"

step "7. a captain-hold relayed decision does NOT defer (not the worker's own wait)"
printf 'resolved [key=ci]: creds landed\nneeds-decision [key=captain-hold-t42-1]: captain hold t42: ship?\n' >> "$S/t1.status"
"$WT/bin/fm-send.sh" t1 --automatic "re-read your instructions"; echo "exit=$?"
echo "inbox records: $(ls "$S/t1.inbox/"*.msg | wc -l)"
