#!/usr/bin/env bash
# Drives bin/fm-watch.sh inbox_steer_check against a REAL tmux pane on a private
# socket (TMUX_TMPDIR under a throwaway lab dir), with a fake "grok" worker
# binary (a copy of bash named grok, so the pane's foreground process classifies
# as a live agent) and FM_BUSY_REGEX=BUSYTOKEN deciding busy from the rendered pane.
set -u
ROOT=$PWD
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
mkdir -p "$LAB/state" "$LAB/config" "$LAB/bin" "$LAB/tmux"
cp /bin/bash "$LAB/bin/grok"
cat > "$LAB/bin/worker.sh" <<EOF
#!/usr/bin/env bash
printf 'BUSYTOKEN active\n'
"$LAB/bin/grok" -c 'read -r _'
clear
printf 'worker idle, waiting for input\n'
exec "$LAB/bin/grok" -c 'while read -r _; do :; done'
EOF
chmod +x "$LAB/bin/worker.sh"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
tmux new-session -d -s sess -n fm-t1 -x 100 -y 20 "$LAB/bin/worker.sh"
sleep 0.5
printf 'window=sess:fm-t1\nkind=ship\nharness=grok\n' > "$LAB/state/t1.meta"
INBOX="$LAB/state/t1.inbox"
STATUS=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; STATUS=1; }
lib() { FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }
check() {  # [VAR=val ...] -> one watcher inbox check, fresh process each time (as across watcher restarts)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" \
    FM_BUSY_REGEX=BUSYTOKEN FM_TASK_INBOX_GRACE_SECS=0 "$@" \
    bash -c '. "$1" && inbox_steer_check sess:fm-t1 t1' _ "$ROOT/bin/fm-watch.sh"
  printf 'watcher check exit=%s\n' "$?"
}
show() {
  printf 'inbox root  : %s\n' "$(cd "$INBOX" 2>/dev/null && ls *.msg 2>/dev/null | tr '\n' ' ')"
  printf 'handled/    : %s\n' "$(ls "$INBOX/handled" 2>/dev/null | tr '\n' ' ')"
  printf '.read/      : %s\n' "$(ls -A "$INBOX/.read" 2>/dev/null | tr '\n' ' ')"
  printf '.busy-state : %s\n' "$({ tr '\t' ' ' < "$INBOX/.busy-state"; } 2>/dev/null || printf '<absent>')"
  printf '.ring-state : %s\n' "$({ tr '\t' ' ' < "$INBOX/.ring-state"; } 2>/dev/null || printf '<absent>')"
  printf '.escalated  : %s\n' "$(cat "$INBOX/.escalated" 2>/dev/null || printf '<absent>')"
  printf 'wake-queue  :\n'; sed 's/^/    /' "$LAB/state/.wake-queue" 2>/dev/null || printf '    <empty>\n'
}
pane() { printf 'pane capture (last 6 non-empty lines):\n'; tmux capture-pane -p -t sess:fm-t1 | grep -v '^[[:space:]]*$' | tail -6 | sed 's/^/    | /'; }
wakes() { { wc -l < "$LAB/state/.wake-queue"; } 2>/dev/null || echo 0; }
steer() { local r; r=$(lib fm_task_inbox_write "$LAB/state" t1 "$1") || return 1; touch -d '5 minutes ago' "$r"; printf '%s' "$r"; }

say "S0 setup: real tmux pane, agent liveness and busy verdict as the watcher sees them"
printf 'tmux socket dir: %s\n' "$TMUX_TMPDIR"
tmux list-windows -t sess -F 'window=#{window_name} cmd=#{pane_current_command} tty=#{pane_tty}'
agent=$(FM_STATE_OVERRIDE="$LAB/state" bash -c '. "$1"; fm_backend_agent_state tmux sess:fm-t1' _ "$ROOT/bin/fm-backend.sh")
printf 'fm_backend_agent_state tmux sess:fm-t1 -> %s\n' "$agent"
[ "$agent" = alive ] && ok "pane classifies as a live agent" || bad "pane is not alive: $agent"
pane

say "S1 busy worker, unread aged steer 001: first due check defers (busy budget 1 of default 2), no wake"
REC1=$(steer "please also update the changelog (long-running work)") || bad "could not write steer"
printf 'steer written: %s\n' "$REC1"
check; show
[ "$(wakes)" = 0 ] && ok "no wake after first busy deferral" || bad "woke on first busy deferral"
grep -q '001.msg' "$INBOX/.busy-state" && ok "busy budget consumed for 001.msg" || bad "busy budget not recorded"

say "S2 worker reads 001 and records the read receipt with bin/fm-task-inbox-read.sh (twice: idempotent)"
"$ROOT/bin/fm-task-inbox-read.sh" "$REC1"; printf 'receipt exit=%s\n' "$?"
"$ROOT/bin/fm-task-inbox-read.sh" "$REC1"; printf 'repeat receipt exit=%s\n' "$?"
[ -f "$INBOX/.read/001.msg" ] && ok "receipt .read/001.msg exists" || bad "receipt missing"
[ -f "$REC1" ] && ok "001.msg still in the inbox root (work not finished)" || bad "receipt moved the record"

say "S3 worker stays busy for four more due polls (would have escalated at poll 2 before the fix)"
for i in 1 2 3 4; do check; done
show; pane
[ "$(wakes)" = 0 ] && ok "no stale wake across 4 busy polls after the read receipt" || bad "read steer escalated"
[ ! -e "$INBOX/.busy-state" ] && ok "busy budget reset by the receipt" || bad "busy budget still counting"
[ -f "$REC1" ] && ok "001.msg still pending in root" || bad "001.msg vanished"
tmux capture-pane -p -t sess:fm-t1 | grep -q 'Firstmate instruction waiting' && bad "doorbell was typed into the busy pane" || ok "nothing typed into the busy pane"

say "S4 never-read successor 002 on the same busy worker still escalates at the default busy budget"
REC2=$(steer "second steer the worker never reads")
printf 'steer written: %s\n' "$REC2"
check; show
[ "$(wakes)" = 0 ] && ok "poll 1 for 002: deferred, no wake" || bad "002 escalated early"
check; show
grep -q 'stuck-busy after 2 consecutive' "$LAB/state/.wake-queue" && ok "002 escalated as stuck-busy after 2 polls" || bad "unread successor did not escalate"
grep -qF "$REC2" "$LAB/state/.wake-queue" && ok "alarm names 002.msg" || bad "alarm names the wrong record"
grep -qF "$REC1" "$LAB/state/.wake-queue" && bad "alarm blamed the read 001.msg" || ok "alarm does not blame read 001.msg"
n=$(wakes); check; [ "$(wakes)" = "$n" ] && ok "escalation surfaced once, not repeated" || bad "escalation repeated"
[ -f "$INBOX/.read/001.msg" ] && [ ! -e "$INBOX/.read/002.msg" ] && ok "receipt for 001 did not leak onto 002" || bad "receipt leaked"

say "S5 adversarial: receipts for missing, out-of-inbox, or non-record paths are refused"
for cand in "$INBOX/009.msg" "$LAB/state/001.msg" "$INBOX/notes.txt" "$INBOX/handled/../001.msgx"; do
  if "$ROOT/bin/fm-task-inbox-read.sh" "$cand" 2>"$LAB/err"; then bad "accepted $cand"; else ok "refused $cand -> $(cat "$LAB/err")"; fi
done
printf '.read/ now: %s\n' "$(ls -A "$INBOX/.read" | tr '\n' ' ')"
[ "$(ls -A "$INBOX/.read" | tr '\n' ' ')" = "001.msg " ] && ok "no forged receipts created" || bad "unexpected receipt files"

say "S6 file-tool fallback: worker handles 001+002, reads 003 and creates .read/003.msg by hand (no script)"
mv "$REC1" "$INBOX/handled/"; mv "$REC2" "$INBOX/handled/"
check   # fresh ladder: no unread record -> bookkeeping reset
REC3=$(steer "third steer, acknowledged through file tools")
check; show
grep -q '003.msg' "$INBOX/.busy-state" && ok "busy budget 1 for unread 003" || bad "003 not counted"
mkdir -p "$INBOX/.read" && : > "$INBOX/.read/003.msg"
n=$(wakes); check; check; show
[ "$(wakes)" = "$n" ] && ok "hand-made receipt silenced stuck-busy for 003" || bad "file-tool receipt ignored"
[ ! -e "$INBOX/.busy-state" ] && ok "busy budget reset by the hand-made receipt" || bad "budget still counting"

say "S7 idle worker: an unread aged steer gets the real doorbell typed; a read receipt stops the ladder"
mv "$REC3" "$INBOX/handled/"
tty=$(tmux display-message -p -t sess:fm-t1 '#{pane_tty}')
gpid=$(ps -t "${tty#/dev/}" -o pid=,args= | awk -v p="$LAB/bin/grok -c" '$0 ~ p {print $1; exit}')
kill "$gpid"; sleep 1
pane
REC4=$(steer "fourth steer, worker idle")
check; show; pane
tmux capture-pane -p -t sess:fm-t1 | grep -q 'record read as briefed, act, then mv into handled/' && ok "doorbell typed into the idle pane with the read-receipt wording" || bad "doorbell not typed"
grep -q '004.msg' "$INBOX/.ring-state" && ok "ring ladder advanced for 004" || bad "ring ladder not recorded"
"$ROOT/bin/fm-task-inbox-read.sh" "$REC4" && ok "worker recorded reading 004" || bad "receipt failed"
bells=$(tmux capture-pane -p -t sess:fm-t1 | grep -c 'Firstmate instruction waiting')
n=$(wakes); check FM_TASK_INBOX_RING_MAX=1; check FM_TASK_INBOX_RING_MAX=1; show; pane
[ "$(wakes)" = "$n" ] && ok "spent ring ladder (max 1) does not escalate a read steer" || bad "read steer escalated on spent ladder"
c=$(tmux capture-pane -p -t sess:fm-t1 | grep -c 'Firstmate instruction waiting'); [ "$c" = "$bells" ] && ok "no further doorbell after the receipt (still $bells on screen)" || bad "doorbell re-rung: $bells before receipt, $c after"
[ -f "$REC4" ] && ok "004.msg still pending until the handled move" || bad "004 vanished"

say "S8 unread idle steer with a spent ladder still escalates (alarm meaning preserved)"
mv "$REC4" "$INBOX/handled/"; check
REC5=$(steer "fifth steer, never read, idle worker")
check; n=$(wakes); check FM_TASK_INBOX_RING_MAX=1; show
grep -q "$REC5 still unhandled after 1 doorbell delivery attempts" "$LAB/state/.wake-queue" && ok "unread 005 escalated after the ring budget" || bad "unread idle steer did not escalate"

say "RESULT: $([ $STATUS = 0 ] && echo ALL PASS || echo FAILURES PRESENT)"
exit $STATUS
