#!/usr/bin/env bash
# Live drive of bin/fm-send.sh --automatic against a real tmux pane in an
# isolated firstmate home. Private tmux socket via TMUX_TMPDIR.
set -u
ROOT=${ROOT:?}
W=$(mktemp -d /tmp/fm4228-send.XXXXXX)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX TMUX_PANE
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
HOME_DIR="$W/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"; chmod 755 "$HOME_DIR/state"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"
tmux new-session -d -s sess -n fm-t1 "cat"
printf 'window=sess:fm-t1\nkind=ship\nharness=%s\n' "${HARNESS:-claude}" > "$HOME_DIR/state/t1.meta"
STATUS="$HOME_DIR/state/t1.status"
send() { echo "\$ fm-send.sh $*"; "$ROOT/bin/fm-send.sh" "$@" 2>&1 | grep -v -e '^$' | sed 's/^/  | /'; echo "  exit=${PIPESTATUS[0]}"; }
inbox() { echo "  inbox records: $(ls "$HOME_DIR/state/t1.inbox"/*.msg 2>/dev/null | xargs -n1 basename 2>/dev/null | paste -sd' ' -)"; }
pane() { echo "  pane shows:"; tmux capture-pane -p -t sess:fm-t1 | sed '/^$/d; s/^/    > /'; }
step() { echo; echo "== $*"; }

step "1. worker opens its own decision, then an automatic re-read nudge fires"
printf 'working: implementing\nneeds-decision [key=pick]: ship alpha or beta?\n' > "$STATUS"; cat "$STATUS" | sed 's/^/  status: /'
send t1 --automatic "re-read your instructions"; inbox; pane

step "2. a blocked: line (blocker, not decision) also defers"
printf 'working: implementing\nblocked [key=creds]: need the deploy token\n' > "$STATUS"; cat "$STATUS" | sed 's/^/  status: /'
send t1 --automatic "re-read your instructions"; inbox; pane

step "3. firstmate's deliberate answer still wakes the worker (--resolve-key closes the blocker)"
send t1 --resolve-key creds "token is in 1password item deploy"; inbox; pane
tail -1 "$STATUS" | sed 's/^/  status: /'

step "4. automatic nudge now goes through (no open decision of its own)"
send t1 --automatic "re-read your instructions"; inbox; pane

step "5. adversarial: open pending-reply escalation (reserved key) must NOT defer"
printf 'blocked [key=pending-reply-0123456789abcdef]: pending-reply-missed: no report\n' >> "$STATUS"
send t1 --automatic "re-read your instructions"; inbox

step "6. adversarial: open captain-hold relay must NOT defer"
printf 'needs-decision [key=captain-hold-t42-1]: captain hold t42: ship alpha or beta?\n' >> "$STATUS"
send t1 --automatic "re-read your instructions"; inbox

step "7. adversarial: own decision opened beside those still defers"
printf 'needs-decision [key=scope]: narrow or wide?\n' >> "$STATUS"
send t1 --automatic "re-read your instructions"; inbox

step "8. adversarial: --automatic refused with --resolve-key, and with an explicit backend target"
send t1 --automatic --resolve-key scope "narrow"; inbox
send tmux:sess:fm-t1 --automatic "re-read your instructions"
send sess:fm-t1 --automatic "re-read your instructions"; inbox

step "9. a plain (non-automatic) firstmate steer is never deferred by an open decision"
send t1 "holding note: still thinking about scope"; inbox
tmux kill-server 2>/dev/null; rm -rf "$W"
