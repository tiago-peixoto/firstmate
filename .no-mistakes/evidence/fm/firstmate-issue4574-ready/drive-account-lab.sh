#!/usr/bin/env bash
# Drives the real bin/fm-spawn.sh against a throwaway Herdr lab with the real
# claude and pi runners, for the issue-4574 account-selection scenarios.
set -u
# Same escape hatch tests/lib.sh and the herdr safety helpers export: scratch homes in a throwaway lab only.
export FM_GATE_REFUSE_BYPASS=1
ROOT=$1; E=$2
LAB=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
SESSION=$("$LAB" name acct4574)
export HERDR_SESSION=$SESSION
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-acct4574.XXXXXX")
WTS=()
cleanup() {
  for w in "${WTS[@]}"; do treehouse return --force "$w" >/dev/null 2>&1; done
  "$LAB" teardown "$SESSION"; echo "teardown rc=$?"
  rm -rf "$T"
}
trap cleanup EXIT
"$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }
echo "== lab session: $SESSION"

PROJ=$T/proj; mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo x > "$PROJ/README.md"
git -C "$PROJ" add .; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.git"; git -C "$PROJ" remote add origin "file://$PROJ.git"

mkhome() { # <home>
  mkdir -p "$1/state" "$1/data" "$1/config"; printf 'off\n' > "$1/config/herdr-presentation-spaces"
}
brief() { mkdir -p "$1/data/$2"; printf '# Task\n## Captain%ss intent\nAccount lab.\n\n## Firstmate spec\nSay hi.\n' "'" > "$1/data/$2/brief.md"; }
spawn() { # <home> <id> <args...>
  local h=$1 id=$2; shift 2
  FM_SPAWN_NO_GUARD=1 FM_HOME="$h" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$@" --mode no-mistakes --yolo off --backend herdr
}
workspaces() { "$LAB" run "$SESSION" workspace list 2>/dev/null | jq -c '[.. | objects | select(has("label")) | .label]' 2>/dev/null; }
panes() { "$LAB" run "$SESSION" pane list 2>/dev/null | jq -r '.. | objects | select(has("pane_id")) | .pane_id' 2>/dev/null | sort -u; }
state() { ls "$1/state" 2>/dev/null | tr '\n' ' '; }

# Synthetic Claude root signed in by an apiKeyHelper (no real login, no tokens).
CROOT=$T/accounts/claude-work; mkdir -p "$CROOT"
printf '{"apiKeyHelper":"echo sk-ant-fm-lab-synthetic"}\n' > "$CROOT/settings.json"
EMPTY=$T/accounts/claude-empty; mkdir -p "$EMPTY"

echo; echo "### S1 Claude spawn from a home with no config/claude-account"
H1=$T/h1; mkhome "$H1"; brief "$H1" s1
echo "before: workspaces=$(workspaces) state=[$(state "$H1")] treehouse-leases=$(treehouse list 2>/dev/null | grep -c "$PROJ")"
CLAUDE_CONFIG_DIR=$HOME/.claude spawn "$H1" s1 --harness claude; echo "rc=$?"
echo "after: workspaces=$(workspaces) state=[$(state "$H1")] treehouse-leases=$(treehouse list 2>/dev/null | grep -c "$PROJ")"

echo; echo "### S2 Pi spawn: claude-account present but no config/pi-account"
H2=$T/h2; mkhome "$H2"; brief "$H2" s2; printf '%s\n' "$CROOT" > "$H2/config/claude-account"
spawn "$H2" s2 --harness pi --model anthropic/claude-sonnet-4-5; echo "rc=$?"
echo "after: workspaces=$(workspaces) state=[$(state "$H2")]"

echo; echo "### S3 env-credential only: ANTHROPIC_API_KEY in firstmate env, file names a root with no stored login"
H3=$T/h3; mkhome "$H3"; brief "$H3" s3; printf '%s\n' "$EMPTY" > "$H3/config/claude-account"
ANTHROPIC_API_KEY=sk-ant-fm-lab-ambient CLAUDE_CODE_USE_BEDROCK=1 spawn "$H3" s3 --harness claude; echo "rc=$?"
echo "after: workspaces=$(workspaces) state=[$(state "$H3")]"

echo; echo "### S4 raw Claude command that sets ANTHROPIC_API_KEY under a pin"
H4=$T/h4; mkhome "$H4"; brief "$H4" s4; printf '%s\n' "$CROOT" > "$H4/config/claude-account"
spawn "$H4" s4 "ANTHROPIC_API_KEY=sk-ant-x claude"; echo "rc=$?"

echo; echo "### S5 raw Pi command under a pin"
H5=$T/h5; mkhome "$H5"; brief "$H5" s5; printf '%s\n' "$T/accounts/pi" anthropic > "$H5/config/pi-account"; mkdir -p "$T/accounts/pi"
spawn "$H5" s5 "pi --provider anthropic --model anthropic/claude-sonnet-4-5"; echo "rc=$?"

echo; echo "### S6 pinned Claude launch from a firstmate with ambient CLAUDE_CONFIG_DIR + API key + Bedrock"
H6=$T/h6; mkhome "$H6"; brief "$H6" s6; printf '%s\n' "$CROOT" > "$H6/config/claude-account"
before=$(panes)
CLAUDE_CONFIG_DIR=$HOME/.claude ANTHROPIC_API_KEY=sk-ant-fm-lab-ambient CLAUDE_CODE_USE_BEDROCK=1 \
  spawn "$H6" s6 --harness claude > "$T/s6.out" 2>&1; rc=$?
cat "$T/s6.out"; echo "rc=$rc"
wt=$(grep -o 'worktree=[^ ]*' "$T/s6.out" | head -1 | cut -d= -f2); [ -z "$wt" ] || WTS+=("$wt")
echo "task record account fields:"; grep -h -E '^(account|account_provider|harness)=' "$H6"/state/s6* 2>/dev/null
sleep 12
new=$(comm -13 <(printf '%s\n' "$before") <(panes) | head -1); echo "worker pane=$new"
for p in $(pgrep -f claude); do
  envline=$(ps -E -ww -o command= -p "$p" 2>/dev/null) || continue
  case "$envline" in *"CLAUDE_CONFIG_DIR=$CROOT"*) ;; *) continue ;; esac
  echo "worker process $p env (account-relevant vars):"
  printf '%s\n' "$envline" | tr ' ' '\n' | grep -E '^(CLAUDE_CONFIG_DIR|ANTHROPIC_API_KEY|CLAUDE_CODE_USE_BEDROCK|CLAUDE_CODE_OAUTH_TOKEN)=' | sed 's/^/  /'
  printf '%s\n' "$envline" | grep -q 'ANTHROPIC_API_KEY=' || echo "  ANTHROPIC_API_KEY: absent"
  printf '%s\n' "$envline" | grep -q 'CLAUDE_CODE_USE_BEDROCK=' || echo "  CLAUDE_CODE_USE_BEDROCK: absent"
  break
done
echo "--- worker pane screen ---"
"$LAB" run "$SESSION" pane read "$new" --source visible --format text
