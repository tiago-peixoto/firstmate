#!/usr/bin/env bash
# Manual drive: real Pi TUI on a private tmux socket, disposable home, fake `gh` reads only.
set -u
ROOT=$1; T=$(mktemp -d "${TMPDIR:-/tmp}/fm-follow-drive.XXXXXX"); S="fm-drive-$$"
trap 'tmux -L "$S" kill-server 2>/dev/null; rm -rf "$T"' EXIT
home=$T/home; mkdir -p "$home"/{config,state,data,project,agent} "$T/tools"
cat > "$T/tools/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in *'--json state --jq .state') jq -r .state "$FM_FOLLOW_FIXTURE" ;; *) cat "$FM_FOLLOW_FIXTURE" ;; esac
SH
chmod +x "$T/tools/gh"
cat > "$T/fixture.ts" <<'TS'
import { execFileSync } from "node:child_process";
import { appendFileSync } from "node:fs";
export default function(pi) {
  pi.on("session_start", () => { execFileSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-lock.sh`], {stdio: "ignore"}); });
  pi.on("before_agent_start", () => { appendFileSync(`${process.env.FM_HOME}/turns`, "turn\n"); throw new Error("no model turn allowed"); });
}
TS
export FM_HOME=$home FM_STATE_OVERRIDE=$home/state FM_DATA_OVERRIDE=$home/data FM_CONFIG_OVERRIDE=$home/config FM_ROOT_OVERRIDE=$ROOT
export FM_FOLLOW_FIXTURE=$home/forge.json PATH="$T/tools:$PATH"
fx() { jq -n --arg s "$1" --arg c "${2:-SUCCESS}" --arg h "${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" --arg r "${4:-APPROVED}" \
  '{state:$s,headRefOid:$h,reviewDecision:$r,statusCheckRollup:[{name:"test",status:"COMPLETED",conclusion:$c}]}' > "$FM_FOLLOW_FIXTURE"; }
follow() { bash "$ROOT/bin/fm-pr-follow.sh" "$@"; }
run() { printf '\n$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
screen() { tmux -L "$S" capture-pane -p -S -200 -t subject 2>/dev/null | grep -v '^[[:space:]]*$'; }
start_pi() {
  tmux -L "$S" new-session -d -s subject -x 200 -y 50 -c "$home/project" \
    "export FM_HOME='$home' FM_ROOT_OVERRIDE='$ROOT' FM_STATE_OVERRIDE='$home/state' FM_DATA_OVERRIDE='$home/data' FM_CONFIG_OVERRIDE='$home/config' FM_FOLLOW_FIXTURE='$FM_FOLLOW_FIXTURE' PATH='$PATH'; exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PI_CODING_AGENT_DIR='$home/agent' pi --offline --no-extensions --no-mcp --no-skills --no-prompt-templates --no-context-files --no-themes --session-dir '$home/sessions' -e '$T/fixture.ts' -e '$ROOT/.pi/extensions/fm-branch-supervision.ts'"
}
wait_surface() { for _ in $(seq 1 120); do [ -s "$home/state/.pr-follow-surface" ] && follow_ready && return 0; sleep 0.25; done; echo "SURFACE NEVER READY"; screen; return 1; }
follow_ready() { jq -e --argjson now "$(date +%s)" '$now - .epoch <= 20' "$home/state/.pr-follow-surface" >/dev/null 2>&1; }
wait_screen() { for _ in $(seq 1 80); do screen | grep -qF "$1" && return 0; sleep 0.25; done; echo "NOT ON SCREEN: $1"; return 1; }
A=https://github.com/example/project/pull/11; B=https://github.com/example/project/pull/12
echo "pi $(pi --version)"

echo "=== 1. default off: no config/pr-follow ==="
fx OPEN
run follow add "$A" --requested 'tell me when 11 changes'
run ls "$home/data" "$home/state"

echo "=== 2. opted in, but no live surface (Pi not running) ==="
touch "$home/config/pr-follow"
run follow add "$A" --requested 'tell me when 11 changes'

echo "=== 3. real Pi primary started; .lock-session present? ==="
start_pi; wait_surface
run ls -a "$home/state"
run cat "$home/state/.pr-follow-surface"
run follow add "$A" --requested 'tell me when 11 changes'
run follow add "$B" --requested 'watch 12 for me'
run follow list
run ls "$home/state" 
echo "(no *.meta task record was created for a followed PR)"

echo "=== 4. review requests changes on PR 11: one line, no model turn ==="
fx OPEN SUCCESS aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CHANGES_REQUESTED
run follow poll; run follow poll
wait_screen "Review CHANGES_REQUESTED"
echo "--- Pi screen ---"; screen | grep -F 'github.com'
echo "wake queue bytes: $(wc -c < "$home/state/.wake-queue" 2>/dev/null || echo 0); model turns: $(wc -l < "$home/turns" 2>/dev/null || echo 0)"

echo "=== 5. restart: stop Pi, forge changes while it is down, start Pi again ==="
tmux -L "$S" kill-server; sleep 1
echo "(waiting 31s for the heartbeat to go stale)"; sleep 31
fx MERGED SUCCESS aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa CHANGES_REQUESTED
run follow poll
run follow poll
echo "outcome lines so far: $(wc -l < "$home/state/branch-outcomes.jsonl")"
run follow list
start_pi; wait_surface
run follow list
run follow poll
wait_screen "MERGED"
echo "--- Pi screen after restart ---"; screen | grep -F 'github.com'
echo "wake queue: $(cat "$home/state/.wake-queue" 2>/dev/null | wc -l) lines; model turns: $(wc -l < "$home/turns" 2>/dev/null || echo 0)"

echo "=== 6. task-owned PR: checks turn red -> line AND action wake; merge -> existing poll path ==="
C=https://github.com/example/project/pull/13
printf 'kind=ship\npr=%s\n' "$C" > "$home/state/task13.meta"
fx OPEN
run follow add "$C" --requested 'tell me about 13'
fx OPEN FAILURE cccccccccccccccccccccccccccccccccccccccc
run follow poll
wait_screen "FAILURE on ccccccc"
echo "--- wake queue ---"; cat "$home/state/.wake-queue" 2>/dev/null
before=$(wc -l < "$home/state/.wake-queue" 2>/dev/null || echo 0)
fx MERGED SUCCESS cccccccccccccccccccccccccccccccccccccccc
run follow poll
wait_screen "MERGED: $C"
echo "follow wakes added by the merge: $(( $(wc -l < "$home/state/.wake-queue") - before ))"
echo "existing task merge observer (fm-pr-poll.sh, unchanged interface):"
run bash "$ROOT/bin/fm-pr-poll.sh" "$C"
echo "--- final Pi screen ---"; screen
echo "--- outcome store ---"; jq -c '{verdict,summary}' "$home/state/branch-outcomes.jsonl"
echo "model turns: $(wc -l < "$home/turns" 2>/dev/null || echo 0)"
