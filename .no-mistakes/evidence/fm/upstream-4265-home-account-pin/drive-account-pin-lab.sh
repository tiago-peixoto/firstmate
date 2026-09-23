#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh + bin/fm-control.sh, real claude and pi,
# in an isolated fm-lab-* Herdr session. Synthetic account roots only (a Claude
# apiKeyHelper root, a Pi root with a stored fake OpenAI key), so no real
# account is spent and no model call can succeed.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-acct-lab.XXXXXX")
SESSION=$("$HELPER" name acctpin) || exit 1
export HERDR_SESSION="$SESSION"
WTS=()
LOG="$EV/lab-transcript.txt"
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  local wt
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  "$HELPER" teardown "$SESSION" 2>&1 | tee -a "$LOG"
  say "teardown rc=${PIPESTATUS[0]}"
  rm -rf "$TMP"
}
trap cleanup EXIT

# Synthetic roots.
AMB="$TMP/ambient-claude"; WORK="$TMP/work-claude"; EMPTY="$TMP/signed-out-claude"
mkdir -p "$AMB" "$WORK" "$EMPTY"
printf '{"apiKeyHelper":"echo sk-ant-ambient-synthetic"}\n' > "$AMB/settings.json"
printf '{"apiKeyHelper":"echo sk-ant-work-synthetic","skipDangerousModePermissionPrompt":true}\n' > "$WORK/settings.json"
# Skip first-run onboarding in the synthetic roots so the worker reaches its prompt.
for r in "$AMB" "$WORK"; do printf '{"hasCompletedOnboarding":true,"theme":"dark","bypassPermissionsModeAccepted":true}\n' > "$r/.claude.json"; done
PIROOT="$TMP/pi-work"; mkdir -p "$PIROOT"
printf '{"openai":{"type":"api_key","key":"sk-fm-synthetic"}}\n' > "$PIROOT/auth.json"; chmod 600 "$PIROOT/auth.json"

# The lab server (and so every pane) inherits an ambient account: another
# Claude root and a credential Claude ranks above a stored login.
export CLAUDE_CONFIG_DIR="$AMB" ANTHROPIC_API_KEY=sk-ant-ambient-pane-synthetic
"$HELPER" provision "$SESSION" 2>&1 | tee -a "$LOG" || exit 1
SOCK=$("$HELPER" run "$SESSION" session list --json | jq -r --arg s "$SESSION" '.sessions[]|select(.name==$s)|.socket_path')

PROJ="$TMP/proj"; mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo x > "$PROJ/README.md"
git -C "$PROJ" add .; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm i
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

H="$TMP/home"; mkdir -p "$H/state" "$H/config" "$H/data"
printf 'off\n' > "$H/config/herdr-presentation-spaces"
brief() {
  mkdir -p "$H/data/$1"
  cat > "$H/data/$1/brief.md" <<EOF
# Task
Delivery contract: mode=local-only
## Captain's intent
Live account pin check for $1; do nothing.

## Firstmate spec
Do nothing.
EOF
}
spawn() { # <id> <args...>
  local id=$1; shift
  brief "$id"
  env -u HERDR_ENV -u HERDR_PANE_ID HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$SOCK" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" --mode local-only --yolo off --backend herdr "$@" 2>&1
}
meta() { cat "$H/state/$1.meta" 2>/dev/null; }
track() { local w; w=$(meta "$1" | sed -n 's/^worktree=//p'); [ -z "$w" ] || WTS+=("$w"); }
# proc_env <id> <exe-name>: env + argv of the runner process running in the task worktree.
proc_env() {
  local wt pid c
  wt=$(meta "$1" | sed -n 's/^worktree=//p')
  for i in $(seq 1 40); do
    for pid in $(pgrep -u "$UID" -x "$2" 2>/dev/null) $(pgrep -u "$UID" -f "$2" 2>/dev/null); do
      c=$(readlink "/proc/$pid/cwd" 2>/dev/null) || continue
      [ "$c" = "$wt" ] || continue
      printf 'pid=%s cwd=%s\nargv: %s\n' "$pid" "$c" "$(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-200)"
      [ "$2" != pi ] || printf 'launch line: %s\n' "$(grep -o 'PI_CODING_AGENT_DIR=[^;]*--provider [^ ]* --model [^ ]*' "$(ls -t /tmp/fm-$1+*/launch.*.sh 2>/dev/null | head -1)" | head -1)"
      tr '\0' '\n' < "/proc/$pid/environ" | grep -E '^(CLAUDE_CONFIG_DIR|ANTHROPIC_API_KEY|PI_CODING_AGENT_DIR)=' | sed 's/^/env: /'
      tr '\0' '\n' < "/proc/$pid/environ" | grep -qE '^ANTHROPIC_API_KEY=' || echo "env: ANTHROPIC_API_KEY <absent>"
      return 0
    done
    sleep 0.5
  done
  echo "no $2 process found in $wt"
}
case_hdr() { say ""; say "=================== $* ==================="; }

case_hdr "S1 unpinned home: Claude ship spawn (today's behaviour)"
say "$ ls $H/config  -> $(ls "$H/config" | tr '\n' ' ')"
out=$(spawn acctU --harness claude); rc=$?; say "$out"; say "rc=$rc"; track acctU
say "--- task record (account lines) ---"; say "$(meta acctU | grep -E '^(harness|account)' )"
say "--- worker process ---"; say "$(proc_env acctU claude)"

case_hdr "S2 pinned home (signed-in root): Claude ship spawn"
printf '%s\n' "$WORK" > "$H/config/claude-account"
say "config/claude-account = $(cat "$H/config/claude-account")"
out=$(spawn acctP --harness claude); rc=$?; say "$out"; say "rc=$rc"; track acctP
say "--- task record (account lines) ---"; say "$(meta acctP | grep -E '^(harness|account)' )"
say "--- worker process ---"; say "$(proc_env acctP claude)"
say "--- trust registered in pinned root? ---"; say "$(jq -r '.projects|keys[]' "$WORK/.claude.json" 2>/dev/null | grep -c "$(meta acctP | sed -n 's/^worktree=//p')") entry"

case_hdr "S3 pinned home, signed-out root: spawn refuses before any endpoint"
printf '%s\n' "$EMPTY" > "$H/config/claude-account"
panes_before=$("$HELPER" run "$SESSION" pane list 2>/dev/null | jq '[.result.panes[]?]|length')
out=$(spawn acctO --harness claude); rc=$?; say "$out"; say "rc=$rc"
say "task record exists? $([ -e "$H/state/acctO.meta" ] && echo yes || echo no)"
panes_after=$("$HELPER" run "$SESSION" pane list 2>/dev/null | jq '[.result.panes[]?]|length')
say "lab panes before=$panes_before after=$panes_after"

case_hdr "S4 malformed pin (relative path) refuses"
printf 'relative/path\n' > "$H/config/claude-account"
out=$(spawn acctM --harness claude); rc=$?; say "$out"; say "rc=$rc"
say "task record exists? $([ -e "$H/state/acctM.meta" ] && echo yes || echo no)"

case_hdr "S5 pinned home refuses raw Claude overrides"
printf '%s\n' "$WORK" > "$H/config/claude-account"
out=$(spawn acctR1 "CLAUDE_CONFIG_DIR=$AMB claude"); rc=$?; say "$out"; say "rc=$rc"
say "task record exists? $([ -e "$H/state/acctR1.meta" ] && echo yes || echo no)"
out=$(spawn acctR2 "ANTHROPIC_API_KEY=sk-ant-raw-synthetic claude"); rc=$?; say "$out"; say "rc=$rc"
say "task record exists? $([ -e "$H/state/acctR2.meta" ] && echo yes || echo no)"

case_hdr "S5b pinned home: raw Claude command without override gets the pin"
out=$(spawn acctR3 "claude"); rc=$?; say "$out"; say "rc=$rc"; track acctR3
say "$(meta acctR3 | grep -E '^(harness|account)')"
say "--- worker process ---"; say "$(proc_env acctR3 claude)"

case_hdr "S6 unpinned home keeps a raw Claude account override"
rm -f "$H/config/claude-account"
out=$(spawn acctR4 "CLAUDE_CONFIG_DIR=$WORK claude"); rc=$?; say "$out"; say "rc=$rc"; track acctR4
say "$(meta acctR4 | grep -E '^(harness|account)' || echo '(no account= line)')"
say "--- worker process ---"; say "$(proc_env acctR4 claude)"

case_hdr "S7 Pi pin: provider guard, raw refusal, and pinned launch"
printf '%s\nopenai\n' "$PIROOT" > "$H/config/pi-account"
say "config/pi-account = $(tr '\n' '|' < "$H/config/pi-account")"
out=$(spawn acctPiU --harness pi --model gpt-5); rc=$?; say "[unqualified model] $out"; say "rc=$rc"
out=$(spawn acctPiX --harness pi --model anthropic/claude-x); rc=$?; say "[undeclared provider] $out"; say "rc=$rc"
out=$(spawn acctPiR "pi --model openai/gpt-5"); rc=$?; say "[raw pi] $out"; say "rc=$rc"
out=$(spawn acctPi --harness pi --model openai/gpt-4o-mini); rc=$?; say "[pinned] $out"; say "rc=$rc"; track acctPi
say "$(meta acctPi | grep -E '^(harness|model|account)')"
say "--- worker process ---"; say "$(proc_env acctPi pi)"
lf=$(ls -t /tmp/fm-acctPi+*/launch.*.sh 2>/dev/null | head -1); say "launch file: ${lf:-<gone>}"
[ -z "$lf" ] || say "$(grep -o 'PI_CODING_AGENT_DIR=.*' "$lf" | cut -c1-300)"
sleep 6
"$HELPER" run "$SESSION" pane read "$(meta acctPi | sed -n 's/^herdr_pane_id=//p')" --lines 30 > "$EV/pinned-pi-worker-pane.txt" 2>&1 || true
rm -f "$H/config/pi-account"

case_hdr "S8 relaunch under a now signed-out pin refuses before stopping the agent"
printf '%s\n' "$EMPTY" > "$H/config/claude-account"
cp "$H/state/acctP.meta" "$TMP/acctP.meta.before"
before=$(proc_env acctP claude | head -1)
out=$(env -u HERDR_ENV -u HERDR_PANE_ID HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$SOCK" \
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-control.sh" acctP relaunch --note "signed out" 2>&1); rc=$?
say "$out"; say "rc=$rc"
after=$(proc_env acctP claude | head -1)
say "agent before: $before"; say "agent after:  $after"
cmp -s "$TMP/acctP.meta.before" "$H/state/acctP.meta" && say "task record unchanged" || say "task record CHANGED"

sleep 8
"$HELPER" run "$SESSION" pane read "$(meta acctP | sed -n 's/^herdr_pane_id=//p')" --lines 30 > "$EV/pinned-worker-pane-before-relaunch.txt" 2>&1 || true
case_hdr "S9 relaunch after re-pinning to the signed-in root follows the pin"
printf '%s\n' "$WORK" > "$H/config/claude-account"
# The synthetic key never lets the brief submit, so clear the composer the way
# an operator would before relaunching.
P=$(meta acctP | sed -n 's/^herdr_pane_id=//p')
"$HELPER" run "$SESSION" pane send-keys "$P" ctrl+c >/dev/null 2>&1; sleep 1
"$HELPER" run "$SESSION" pane read "$P" --lines 8 > "$EV/pinned-worker-pane-cleared.txt" 2>&1
out=$(env -u HERDR_ENV -u HERDR_PANE_ID HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$SOCK" \
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-control.sh" acctP relaunch --note "pinned" 2>&1); rc=$?
say "$out"; say "rc=$rc"
say "$(meta acctP | grep -E '^(harness|account)')"
sleep 3
say "--- worker process ---"; say "$(proc_env acctP claude)"

# Screenshot-ish: capture the pinned worker pane text.
pane=$(meta acctP | sed -n 's/^herdr_pane_id=//p')
"$HELPER" run "$SESSION" pane read "$pane" --lines 40 > "$EV/pinned-worker-pane.txt" 2>&1 || true
