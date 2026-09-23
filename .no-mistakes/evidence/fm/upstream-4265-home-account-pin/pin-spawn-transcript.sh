#!/usr/bin/env bash
# Drives the real bin/fm-spawn.sh from a throwaway home with the REAL installed
# claude binary answering the pin's sign-in check; only tmux is faked.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/fixtures.sh"
T=$(mktemp -d); export HOME=$T/h; mkdir -p $HOME
FB=$(fm_test_make_spawn_fakebin "$T/fake")
H=$T/home; fm_test_spawn_home "$H" claude
fm_git_worktree "$T/proj" "$T/wt" wt-live >/dev/null 2>&1
run() { : > $T/launch.log; fm_test_spawn_brief "$H" "$1"; FM_FAKE_LAUNCH_LOG=$T/launch.log ANTHROPIC_API_KEY=sk-ant-ambient-invoker \
  fm_test_run_spawn "$H" "$T/wt" "$FB" "$1" "$T/proj" --mode no-mistakes --yolo off "${@:2}"; echo "[exit $?]"; }
echo "claude: $(claude --version | head -1)"
echo; echo "## 1. unpinned home (no config/claude-account)"; run live-none; grep -E '^(account|model)=' "$H/state/live-none.meta"; echo "launch: $(cat $T/launch.log | head -c 300)"
mkdir -p $T/empty; echo "$T/empty" > "$H/config/claude-account"
echo; echo "## 2. pin -> signed-out root, invoker has ANTHROPIC_API_KEY"; run live-out; ls "$H/state/live-out.meta" 2>&1; echo "launch.log bytes: $(wc -c < $T/launch.log)"
mkdir -p $T/signed; printf '{"apiKeyHelper":"echo sk-ant-fm-live-synthetic"}\n' > $T/signed/settings.json; echo "$T/signed" > "$H/config/claude-account"
echo; echo "## 3. pin -> signed-in root"; run live-in; grep -E '^(account|account_provider)=' "$H/state/live-in.meta"; echo "launch: $(head -c 400 $T/launch.log)"
echo; echo "## 4. pinned home, raw Claude command overriding CLAUDE_CONFIG_DIR"; fm_test_spawn_brief "$H" live-raw; : > $T/launch.log
FM_FAKE_LAUNCH_LOG=$T/launch.log fm_test_run_spawn "$H" "$T/wt" "$FB" live-raw "$T/proj" "CLAUDE_CONFIG_DIR=/tmp/other claude" --mode no-mistakes --yolo off; echo "[exit $?]"
echo "launch.log bytes: $(wc -c < $T/launch.log)"
rm -rf "$T"
