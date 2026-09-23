#!/usr/bin/env bash
# Real bin/fm-spawn.sh + REAL installed pi answering the pin check; only tmux is faked.
set -u
ROOT=$1
. "$ROOT/tests/lib.sh"; . "$ROOT/tests/fixtures.sh"
T=$(mktemp -d); export HOME=$T/h; mkdir -p $HOME
FB=$(fm_test_make_spawn_fakebin "$T/fake")
H=$T/home; fm_test_spawn_home "$H" pi
fm_git_worktree "$T/proj" "$T/wt" wt-live >/dev/null 2>&1
mkdir -p $T/pi; printf '{"openai":{"type":"api_key","key":"sk-fm-live-synthetic"}}\n' > $T/pi/auth.json; chmod 600 $T/pi/auth.json
printf '%s\nopenai\n' "$T/pi" > "$H/config/pi-account"
run() { : > $T/launch.log; fm_test_spawn_brief "$H" "$1"; FM_FAKE_LAUNCH_LOG=$T/launch.log OPENAI_API_KEY=sk-ambient \
  fm_test_run_spawn "$H" "$T/wt" "$FB" "$1" "$T/proj" --mode no-mistakes --yolo off "${@:2}"; echo "[exit $?] launch.log bytes: $(wc -c < $T/launch.log)"; }
echo "pi: $(pi --version | head -1); config/pi-account:"; sed 's/^/  /' "$H/config/pi-account"
echo; echo "## 1. pinned Pi without --model"; run p1
echo; echo "## 2. pinned Pi with undeclared provider --model anthropic/claude-sonnet-5"; run p2 --model anthropic/claude-sonnet-5
echo; echo "## 3. pinned Pi with --model openai/gpt-5"; run p3 --model openai/gpt-5; grep -E '^account' "$H/state/p3.meta"; grep -o "PI_CODING_AGENT_DIR=[^ ]*\|--provider [^ ]* --model [^ ]*" $T/launch.log
rm -rf "$T"
