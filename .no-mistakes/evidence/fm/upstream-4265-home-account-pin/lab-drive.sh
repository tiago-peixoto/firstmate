#!/usr/bin/env bash
# Live drive of the worker account pin (issue 4265) through the real
# bin/fm-spawn.sh and bin/fm-control.sh into an isolated fm-lab-* Herdr
# session, with real claude and pi binaries and synthetic account roots.
# No operator credential store is read or written: every Claude launch has a
# synthetic CLAUDE_CONFIG_DIR and every Pi launch a synthetic root.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
LAB=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-acct-lab.XXXXXX")
SESSION=$("$LAB" name acct-pin)
echo "# lab session: $SESSION  scratch: $T"
WTS=()
cleanup() {
  for w in "${WTS[@]:-}"; do [ -z "$w" ] || treehouse return --force "$w" >/dev/null 2>&1; done
  "$LAB" teardown "$SESSION" && echo "# teardown ok: $SESSION removed, default session tripwire unchanged"
  rm -rf "$T"
}
trap cleanup EXIT

# --- synthetic account roots -------------------------------------------------
claude_root() { # <dir> <signed-in:0|1>
  mkdir -p "$1"
  printf '{"hasCompletedOnboarding":true,"theme":"dark"}\n' > "$1/.claude.json"
  if [ "$2" = 1 ]; then printf '{"apiKeyHelper":"echo sk-ant-fm-lab-synthetic"}\n' > "$1/settings.json"; fi
}
claude_root "$T/ambient-claude" 1     # what the invoking firstmate process uses
claude_root "$T/work-claude" 1        # the pinned, signed-in work root
claude_root "$T/empty-claude" 0       # a pinned root with no login
mkdir -p "$T/pi-work" "$T/ambient-pi"
printf '{"openai":{"type":"api_key","key":"sk-fm-lab-synthetic"}}\n' > "$T/pi-work/auth.json"
chmod 600 "$T/pi-work/auth.json"

# --- scratch project and homes -----------------------------------------------
PROJ=$T/proj
mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo '# scratch' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

mkhome() { # <home> <crew-harness>
  mkdir -p "$1/data" "$1/projects" "$1/state" "$1/config"
  touch "$1/state/.last-watcher-beat"
  printf '%s\n' "$2" > "$1/config/crew-harness"
  printf 'off\n' > "$1/config/herdr-presentation-spaces"
}
brief() { # <home> <id>
  mkdir -p "$1/data/$2"
  printf '# Task\n## Captain'"'"'s intent\nLab check of the worker account pin; do nothing.\n\n## Firstmate spec\nReply ok and stop.\n' > "$1/data/$2/brief.md"
}

# Provision the lab server with an ambient environment that names OTHER
# accounts, so every pane starts with credentials a pin must not spend.
CLAUDE_CONFIG_DIR=$T/ambient-claude ANTHROPIC_API_KEY=ambient-pane-key \
  PI_CODING_AGENT_DIR=$T/ambient-pi OPENAI_API_KEY=ambient-pane-openai \
  "$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }

spawn() { # <home> <id> [args...]   invoker carries ambient Claude root + API key
  local home=$1 id=$2; shift 2
  brief "$home" "$id"
  FM_GATE_REFUSE_BYPASS=1 HERDR_SESSION=$SESSION FM_SPAWN_NO_GUARD=1 FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    CLAUDE_CONFIG_DIR=$T/ambient-claude ANTHROPIC_API_KEY=ambient-invoker-key \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" --mode local-only --yolo off --backend herdr "$@" 2>&1
}
meta_get() { sed -n "s/^$2=//p" "$1/state/$3.meta" 2>/dev/null | head -1; }
# pane_env <home> <id> <proc-name>: environment of the harness process in the
# task's real Herdr pane, read from /proc.
pane_proc() {
  local home=$1 id=$2 name=$3 pane pid i
  pane=$(meta_get "$home" x "$id" >/dev/null; sed -n 's/^herdr_pane_id=//p' "$home/state/$id.meta")
  for i in $(seq 1 100); do
    pid=$(herdr pane process-info --pane "$pane" --session "$SESSION" 2>/dev/null |
      jq -r --arg n "$name" '[.result.process_info.foreground_processes[] | select((.name|test($n)) or ((.argv0//"")|test($n)))][0].pid // empty')
    [ -n "$pid" ] && { echo "$pid"; return 0; }
    sleep 0.2
  done
  return 1
}
show_env() { # <pid>
  tr '\0' '\n' < "/proc/$1/environ" | grep -E '^(CLAUDE_CONFIG_DIR|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN|PI_CODING_AGENT_DIR|OPENAI_API_KEY)=' | sort
  grep -q '^CLAUDE_CONFIG_DIR=' <(tr '\0' '\n' < "/proc/$1/environ") || echo "CLAUDE_CONFIG_DIR=<unset>"
  grep -q '^ANTHROPIC_API_KEY=' <(tr '\0' '\n' < "/proc/$1/environ") || echo "ANTHROPIC_API_KEY=<unset>"
}
wt_of() { sed -n 's/^worktree=//p' "$1/state/$2.meta"; }
panes() { herdr pane list --session "$SESSION" 2>/dev/null | jq -r '[.result.panes[]?] | length'; }

echo; echo "=== S1 unpinned home: Claude launch unchanged ==="
H1=$T/home-unpinned; mkhome "$H1" claude
out=$(spawn "$H1" acct1 --harness claude); rc=$?
echo "$out" | tail -3; echo "rc=$rc"
[ -n "$(wt_of "$H1" acct1)" ] && WTS+=("$(wt_of "$H1" acct1)")
echo "meta account line: $(grep '^account' "$H1/state/acct1.meta" || echo '<none>')"
pid=$(pane_proc "$H1" acct1 claude) && { echo "pane claude pid=$pid argv: $(tr '\0' ' ' < /proc/$pid/cmdline | cut -c1-80)"; show_env "$pid"; } || echo "no claude process in pane"

echo; echo "=== S2 pinned home, signed-in work root: launch lands on the pin, ambient key shed ==="
H2=$T/home-pinned; mkhome "$H2" claude
printf '%s\n' "$T/work-claude" > "$H2/config/claude-account"
out=$(spawn "$H2" acct2 --harness claude); rc=$?
echo "$out" | tail -3; echo "rc=$rc"
[ -n "$(wt_of "$H2" acct2)" ] && WTS+=("$(wt_of "$H2" acct2)")
echo "meta account line: $(grep '^account' "$H2/state/acct2.meta" || echo '<none>')"
pid=$(pane_proc "$H2" acct2 claude) && { echo "pane claude pid=$pid"; show_env "$pid"; } || echo "no claude process in pane"
echo "trust registered in pinned store: $(jq -r '.projects | keys | length' "$T/work-claude/.claude.json" 2>/dev/null) project(s)"

echo; echo "=== S3 pinned home, signed-out root: refused before any pane/worktree/record ==="
H3=$T/home-signedout; mkhome "$H3" claude
printf '%s\n' "$T/empty-claude" > "$H3/config/claude-account"
before=$(panes)
out=$(spawn "$H3" acct3 --harness claude); rc=$?
echo "$out" | tail -3; echo "rc=$rc"
echo "record exists: $([ -e "$H3/state/acct3.meta" ] && echo yes || echo no); panes before=$before after=$(panes)"

echo; echo "=== S4 malformed pin (relative path) refused ==="
H4=$T/home-malformed; mkhome "$H4" claude
printf 'relative/claude\n' > "$H4/config/claude-account"
out=$(spawn "$H4" acct4 --harness claude); rc=$?
echo "$out" | tail -2; echo "rc=$rc record exists: $([ -e "$H4/state/acct4.meta" ] && echo yes || echo no)"

echo; echo "=== S5 Pi pin ==="
H5=$T/home-pi; mkhome "$H5" pi
printf '%s\nopenai\n' "$T/pi-work" > "$H5/config/pi-account"
echo "-- unqualified model:"
out=$(spawn "$H5" acct5a --harness pi --model gpt-5); echo "$out" | tail -1; echo "rc=$? record: $([ -e "$H5/state/acct5a.meta" ] && echo yes || echo no)"
echo "-- undeclared provider:"
out=$(spawn "$H5" acct5b --harness pi --model anthropic/claude-x); echo "$out" | tail -1; echo "record: $([ -e "$H5/state/acct5b.meta" ] && echo yes || echo no)"
echo "-- raw pi launch command:"
out=$(spawn "$H5" acct5c pi); echo "$out" | tail -1; echo "record: $([ -e "$H5/state/acct5c.meta" ] && echo yes || echo no)"
echo "-- declared, signed-in provider:"
out=$(spawn "$H5" acct5 --harness pi --model openai/gpt-4o-mini); rc=$?
echo "$out" | tail -2; echo "rc=$rc"
[ -n "$(wt_of "$H5" acct5)" ] && WTS+=("$(wt_of "$H5" acct5)")
echo "meta account lines: $(grep '^account' "$H5/state/acct5.meta" | tr '\n' ' ')"
pid=$(pane_proc "$H5" acct5 'pi|node') && { echo "pane pi pid=$pid argv: $(tr '\0' ' ' < /proc/$pid/cmdline | grep -o -- '--provider [^ ]* --model [^ ]*')"; show_env "$pid" | grep -E 'PI_|OPENAI'; } || echo "no pi process in pane"

echo; echo "=== S6 relaunch after the pinned root signs out: refused before the old agent stops ==="
rm -f "$T/work-claude/settings.json"
oldpid=$(pane_proc "$H2" acct2 claude)
out=$(FM_GATE_REFUSE_BYPASS=1 HERDR_SESSION=$SESSION FM_HOME="$H2" FM_ROOT_OVERRIDE="$ROOT" CLAUDE_CONFIG_DIR=$T/ambient-claude \
  "$ROOT/bin/fm-control.sh" acct2 relaunch --note "lab pin check" 2>&1); rc=$?
echo "$out" | tail -3; echo "rc=$rc"
echo "old claude pid $oldpid still alive: $(kill -0 "$oldpid" 2>/dev/null && echo yes || echo no)"
