#!/usr/bin/env bash
# Live proof of the issue-7280 intent with a REAL Claude worker:
#  1. bin/fm-brief.sh scaffolds a ship brief in a throwaway lab home; its
#     "Firstmate instruction inbox" section is handed to a real `claude` session
#     launched the way bin/fm-spawn.sh launches it (FM_TASK_INBOX exported,
#     unattended flags), on a private tmux socket under the lab dir.
#  2. The real bin/fm-send.sh steers it with a deliberately long-running
#     instruction (sleep 75 then touch a file).
#  3. We watch the inbox: the read receipt .read/001.msg must appear BEFORE the
#     work finishes (the acted file), and while the worker is still busy the
#     real watcher check (bin/fm-watch.sh inbox_steer_check, fresh process per
#     poll, grace 0, busy budget 2) must stay quiet: no wake, no doorbell typed.
#  4. Finally the worker must still complete handling with the mv into handled/.
set -u
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LAB=$(cd "$LAB" && pwd)
# A marked lab home is the only FM_HOME the fleet lifecycle entrypoints
# (fm-send among them) accept from inside a no-mistakes gate worktree.
bin/fm-lab-home.sh create "$LAB" >/dev/null || { echo "FAIL: could not mint the lab home"; exit 1; }
SOCKET="fm-lab-claude-$$"
mkdir -p "$LAB/shim" "$LAB/work" "$LAB/tmux"
REAL_TMUX=$(command -v tmux)
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"
STATUS=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; STATUS=1; }
now() { date +%s; }
pane() { printf 'pane capture (%s):\n' "$1"; tmux capture-pane -p -t lab:w | grep -v '^[[:space:]]*$' | tail -"${2:-12}" | sed 's/^/    | /'; }

TASK=live-claude
INBOX="$LAB/state/$TASK.inbox"
ACTED="$LAB/acted"

say "S0 scaffold the real brief and extract its inbox section"
FM_HOME="$LAB" "$ROOT/bin/fm-brief.sh" "$TASK" lab-project --mode local-only >/dev/null || bad "fm-brief scaffold failed"
BRIEF="$LAB/data/$TASK/brief.md"
awk '/^# Firstmate instruction inbox/{p=1;print;next} p&&/^# /{p=0} p' "$BRIEF" > "$LAB/work/inbox-contract.md"
sed 's/^/    /' "$LAB/work/inbox-contract.md"
grep -q 'fm-task-inbox-read.sh' "$LAB/work/inbox-contract.md" && ok "brief names the receipt command" || bad "brief lacks the receipt command"

say "S1 launch a real claude worker on private tmux socket $SOCKET (cwd $LAB/work)"
claude --version 2>/dev/null | head -1
tmux new-session -d -s lab -n w -x 200 -y 50 -c "$LAB/work" \
  -- bash -lc "export FM_TASK_INBOX=$(printf '%q' "$INBOX"); CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" \
  || bad "could not launch claude in the lab tmux server"
i=0; verdict=
while [ "$i" -lt 90 ]; do
  screen=$(tmux capture-pane -p -t lab:w 2>/dev/null || true)
  if printf '%s\n' "$screen" | grep -qi 'trust'; then
    printf 'trust dialog at %ss: default is "No, exit", so move to "Yes, I trust this folder" (throwaway lab dir) and confirm\n' "$i"
    tmux send-keys -t lab:w Down; sleep 0.3; tmux send-keys -t lab:w Enter
    sleep 2
  fi
  verdict=$(fm_tmux_composer_state lab:w)
  [ "$verdict" = empty ] && break
  sleep 1; i=$((i + 1))
done
printf 'composer verdict after %ss: %s\n' "$i" "$verdict"
pane "idle claude" 8
if [ "$verdict" = pending ]; then bad "claude composer stayed pending; not steerable"; exit 1; fi

say "S2 hand the worker its inbox contract (one short turn)"
tmux send-keys -t lab:w -l "Read the file $LAB/work/inbox-contract.md now. It is your binding Firstmate instruction-inbox contract for this session: whenever a terminal message says a Firstmate instruction is waiting, follow that contract exactly, step by step, in order. Reply with the single word ready and then wait."
sleep 0.5; tmux send-keys -t lab:w Enter
sleep 8
i=0
while [ "$i" -lt 120 ]; do
  verdict=$(fm_tmux_composer_state lab:w)
  screen=$(tmux capture-pane -p -t lab:w)
  if [ "$verdict" = empty ] && ! printf '%s\n' "$screen" | grep -q 'esc to interrupt' \
    && printf '%s\n' "$screen" | grep -q '^⏺.*ready'; then break; fi
  sleep 1; i=$((i + 1))
done
printf 'contract acknowledged after %ss (composer=%s)\n' "$i" "$verdict"
pane "after contract" 8

say "S3 steer through the REAL bin/fm-send.sh with a long-running instruction"
printf 'window=lab:w\nkind=ship\nharness=claude\n' > "$LAB/state/$TASK.meta"
T_SEND=$(now)
if FM_HOME="$LAB" "$ROOT/bin/fm-send.sh" "$TASK" \
  "Firstmate live check: run exactly this shell command now: sleep 75 && touch $ACTED - then finish your inbox procedure for this message. Reply with one short line." \
  > "$LAB/send.out" 2>&1; then ok "fm-send wrote the record and rang the doorbell"; else bad "fm-send refused: $(cat "$LAB/send.out")"; fi
cat "$LAB/send.out" | sed 's/^/    /'
REC="$INBOX/001.msg"
[ -f "$REC" ] && ok "durable record $REC" || bad "no record"
sleep 1; pane "doorbell typed" 6

say "S4 watch for the read receipt, the finished work, and the handled move"
T_READ=; T_ACTED=; T_HANDLED=; CHECKS_DONE=0; WAKES_SEEN=0
bells_before=$(tmux capture-pane -p -t lab:w | grep -c 'Firstmate instruction waiting')
i=0
while [ "$i" -lt 240 ]; do
  [ -z "$T_READ" ] && [ -f "$INBOX/.read/001.msg" ] && { T_READ=$(now); printf '+%ss read receipt .read/001.msg appeared\n' $((T_READ - T_SEND)); pane "receipt moment" 10; }
  [ -z "$T_ACTED" ] && [ -e "$ACTED" ] && { T_ACTED=$(now); printf '+%ss work finished (acted file)\n' $((T_ACTED - T_SEND)); }
  [ -z "$T_HANDLED" ] && [ -f "$INBOX/handled/001.msg" ] && { T_HANDLED=$(now); printf '+%ss handled/001.msg appeared\n' $((T_HANDLED - T_SEND)); }
  if [ -n "$T_READ" ] && [ -z "$T_ACTED" ] && [ "$CHECKS_DONE" -lt 3 ] && [ $(( $(now) - T_READ )) -ge $((CHECKS_DONE * 5 + 3)) ]; then
    CHECKS_DONE=$((CHECKS_DONE + 1))
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 \
      bash -c '. "$1" && inbox_steer_check lab:w live-claude' _ "$ROOT/bin/fm-watch.sh" > "$LAB/check.$CHECKS_DONE.out" 2>&1
    printf '+%ss real watcher inbox_steer_check #%s while the worker is mid-sleep: exit=%s wake-queue=%s busy-state=%s\n' \
      $(( $(now) - T_SEND )) "$CHECKS_DONE" "$?" "$( { wc -l < "$LAB/state/.wake-queue"; } 2>/dev/null || echo 0)" "$( { tr '\t' ' ' < "$INBOX/.busy-state"; } 2>/dev/null || echo '<absent>')"
  fi
  [ -n "$T_HANDLED" ] && [ -n "$T_ACTED" ] && break
  sleep 1; i=$((i + 1))
done
pane "end state" 14
printf 'inbox root: %s | .read/: %s | handled/: %s\n' "$(ls "$INBOX" 2>/dev/null | grep msg | tr '\n' ' ')" "$(ls -A "$INBOX/.read" 2>/dev/null | tr '\n' ' ')" "$(ls "$INBOX/handled" 2>/dev/null | tr '\n' ' ')"
printf 'wake-queue:\n'; sed 's/^/    /' "$LAB/state/.wake-queue" 2>/dev/null || printf '    <empty>\n'
[ -n "$T_READ" ] && ok "worker recorded the read receipt (+$((T_READ - T_SEND))s)" || bad "no read receipt ever appeared"
[ -n "$T_ACTED" ] && ok "worker finished the long-running work (+$((T_ACTED - T_SEND))s)" || bad "work never finished"
[ -n "$T_READ" ] && [ -n "$T_ACTED" ] && [ "$T_READ" -lt "$T_ACTED" ] && ok "receipt preceded the work by $((T_ACTED - T_READ))s: read-before-act" || bad "receipt did not precede the work"
[ "$CHECKS_DONE" -ge 1 ] && ok "$CHECKS_DONE real watcher checks ran during the long-running work" || bad "no watcher check ran while the worker was busy"
[ ! -s "$LAB/state/.wake-queue" ] && ok "no stale wake for the read, still-running steer" || bad "watcher woke firstmate for a read steer"
bells_after=$(tmux capture-pane -p -t lab:w | grep -c 'Firstmate instruction waiting')
[ "$bells_after" -le "$bells_before" ] && ok "no doorbell re-typed while the worker was busy (doorbells on screen: $bells_before -> $bells_after)" || bad "doorbell re-rung into the busy worker ($bells_before -> $bells_after)"
[ -n "$T_HANDLED" ] && ok "worker still acknowledged completed handling with the mv (+$((T_HANDLED - T_SEND))s)" || bad "handled/ move never happened"
say "RESULT: $([ $STATUS = 0 ] && echo ALL PASS || echo FAILURES PRESENT)"
exit $STATUS
