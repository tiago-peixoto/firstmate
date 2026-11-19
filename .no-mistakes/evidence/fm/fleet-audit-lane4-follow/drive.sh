#!/usr/bin/env bash
# Independent live drive: real Claude Code TUI + Calm mod in a disposable home; only `gh` is faked.
set -u
ROOT=$PWD
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-follow-drive.XXXXXX")
SOCKET="fm-drive-$$"
home=$T/home
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/tools" "$home/config" "$home/state" "$home/data" "$home/project"
printf '#!/usr/bin/env bash\ncat "$FM_FOLLOW_FIXTURE"\n' > "$T/tools/gh"; chmod +x "$T/tools/gh"
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_ROOT_OVERRIDE="$ROOT"
export FM_FOLLOW_FIXTURE="$home/forge.json" PATH="$T/tools:$PATH"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fixture() { jq -n --arg s "$1" --arg c "${2:-SUCCESS}" --arg h "${3:-$A}" --arg r "${4:-APPROVED}" \
  '{state:$s,headRefOid:$h,reviewDecision:$r,statusCheckRollup:[{name:"test",status:"COMPLETED",conclusion:$c}]}' > "$FM_FOLLOW_FIXTURE"; }
follow() { echo "\$ fm-pr-follow.sh $*"; bash "$ROOT/bin/fm-pr-follow.sh" "$@"; echo "[exit $?]"; }
screen() { tmux -L "$SOCKET" capture-pane -p -S -500 -t subject 2>/dev/null || true; }
start_claude() {
  session=$(node -e 'console.log(require("node:crypto").randomUUID())')
  printf '%s\n' "$session" > "$home/state/.lock-session"
  tmux -L "$SOCKET" new-session -d -s subject -x 200 -y 50 -c "$home/project" \
    "export FM_HOME='$home' FM_ROOT_OVERRIDE='$ROOT' FM_STATE_OVERRIDE='$home/state' FM_DATA_OVERRIDE='$home/data' FM_CONFIG_OVERRIDE='$home/config' FM_FOLLOW_FIXTURE='$home/forge.json' PATH='$PATH'; exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CONFIG_DIR CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --session-id '$session' --setting-sources project --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --plugin-dir '$ROOT/.claude/mods/firstmate-calm' --debug-file '$home/debug-$session.log'"
  tmux -L "$SOCKET" display-message -p -t subject '#{pane_pid}' > "$home/state/.lock"
  rm -f "$home/state/.pr-follow-surface"
  for i in $(seq 1 160); do
    [ -s "$home/state/.pr-follow-surface" ] && { echo "surface: $(cat "$home/state/.pr-follow-surface")"; return 0; }
    case "$(screen)" in *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t subject Down Enter ;; esac
    sleep 0.25
  done
  echo "FAIL: surface never advertised"; screen; exit 1
}
wait_line() { for i in $(seq 1 120); do screen | grep -F -- "$1" >/dev/null && return 0; sleep 0.25; done; echo "FAIL: screen never showed: $1"; screen; return 1; }
wakes() { [ -s "$home/state/.wake-queue" ] && cat "$home/state/.wake-queue" || echo "(wake queue empty)"; }
P1=https://github.com/example/project/pull/11; P2=https://github.com/example/project/pull/12

echo "== S1 opt-in guard: no config/pr-follow"
fixture OPEN; follow add "$P1" --requested "tell me when 11 changes"
echo "== S2 guard: config on, no live model-free surface"
touch "$home/config/pr-follow"; follow add "$P1" --requested "tell me when 11 changes"
ls "$home/data"; echo "(data dir listing above: no follow record)"
echo "== S3 enroll taskless PR with a live Claude+Calm surface"
start_claude
follow add "$P1" --requested "tell me when 11 changes"
follow list
jq . "$home/data/pr-follows.json"
ls "$home/state"/*.meta 2>/dev/null || echo "(no task meta created)"
echo "== S4 review requested changes -> one line; repeat poll adds none"
fixture OPEN SUCCESS $A CHANGES_REQUESTED
follow poll; follow poll
wait_line "Review CHANGES_REQUESTED: $P1"; echo "screen lines for $P1: $(screen | grep -F -c "$P1")"
echo "== S5 failed forge read preserves the previous observation"
before=$(jq -c '.follows[0].observation' "$home/data/pr-follows.json"); rm -f "$FM_FOLLOW_FIXTURE"
follow poll
after=$(jq -c '.follows[0].observation' "$home/data/pr-follows.json"); [ "$before" = "$after" ] && echo "observation unchanged: $after" || echo "FAIL: observation changed"
echo "== S6 the check the watcher runs is silent when nothing changed (no model wake)"
fixture OPEN SUCCESS $A CHANGES_REQUESTED
out=$(bash "$home/state/pr-follow.check.sh" 2>&1); echo "armed check exit=$? output=[${out}]"
wakes
echo "== S7 restart: primary gone, follow survives; pause reported once; new session shows the merge"
tmux -L "$SOCKET" kill-session -t subject; sleep 31
fixture MERGED
follow poll; follow poll
jq -c '{surface_missing,urls:[.follows[].url],state:.follows[0].observation.state}' "$home/data/pr-follows.json"
start_claude
follow poll; follow poll
wait_line "MERGED: $P1"; echo "screen lines for $P1 in new session: $(screen | grep -F -c "$P1")"
wakes
echo "== S8 task-owned PR: non-merge change also queues an action wake; merge does not"
printf 'kind=ship\npr=%s\n' "$P2" > "$home/state/ship-task.meta"
fixture OPEN; follow add "$P2" --requested "follow my task PR 12"
fixture OPEN FAILURE $B
follow poll
wait_line "Checks test: FAILURE on bbbbbbb: $P2"; wakes
n=$(wc -l < "$home/state/.wake-queue")
fixture MERGED FAILURE $B
follow poll
wait_line "MERGED: $P2"; echo "wake queue lines before merge=$n after merge=$(wc -l < "$home/state/.wake-queue")"
echo "== S9 stop following"
follow remove "$P1"; follow list
echo "== final Claude screen"
screen | grep -v '^$'
echo "== outcome store"
cat "$home/state/branch-outcomes.jsonl"
echo "== model-turn evidence"
for f in "$home"/debug-*.log; do echo "$(basename "$f"): model-request log lines=$(grep -E -c 'API Request|api_request|Query.*model|Sending.*request.*anthropic' "$f")"; done
slug=$(printf '%s' "$home/project" | sed 's/[^A-Za-z0-9]/-/g')
for f in "$HOME/.claude/projects/$slug"/*.jsonl; do [ -e "$f" ] && echo "transcript $(basename "$f"): assistant entries=$(grep -c '"type":"assistant"' "$f")" || echo "no Claude transcript file exists for the idle sessions (dir $slug)"; done
