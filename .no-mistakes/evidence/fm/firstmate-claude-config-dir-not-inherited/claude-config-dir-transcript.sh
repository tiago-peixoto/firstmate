#!/usr/bin/env bash
# End-to-end transcript for config/claude-config-dir. Run from the worktree root.
# Uses the repo's test fixtures (fake tmux that records the launch line) and the
# production bin/fm-spawn.sh + bin/fm-config-push.sh; nothing here is mocked
# beyond tmux/gh/no-mistakes.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDECODE CLAUDE_CONFIG_DIR PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS
. tests/fixtures.sh
. "$ROOT/bin/fm-ff-lib.sh"
. "$ROOT/bin/fm-config-inherit-lib.sh"
# Borrow the world builders from the secondmate harness suite (pure helper functions).
for fn in make_noop_tmux make_seeded_home make_launch_capturing_tmux spawn_secondmate_capture \
          new_world add_sm_worktree make_fake_toolchain run_config_push reread_instruction_path; do
  eval "$(sed -n "/^$fn()/,/^}/p" tests/fm-secondmate-harness.test.sh)"
done
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-claude-config-demo)
export FM_BACKEND=tmux
trap 'rm -rf "$TMP_ROOT"' EXIT
say() { printf '\n$ %s\n' "$*"; }
show() { sed "s#$TMP_ROOT#\$W#g"; }

echo "################ 1. fm-config-push.sh: present -> pushed, again -> unchanged, removed -> absence"
w=$(new_world demo); head=$(git -C "$w/main" rev-parse HEAD)
add_sm_worktree "$w" sm "$head"
mkdir -p "$w/claude-account-pers"
printf '%s\n' "$w/claude-account-pers" > "$w/home/config/claude-config-dir"
say "cat \$W/home/config/claude-config-dir   # primary home"; cat "$w/home/config/claude-config-dir" | show
say "bin/fm-config-push.sh"; run_config_push "$w" 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "cat \$W/sm/config/claude-config-dir     # secondmate home now has the inherited copy"; cat "$w/sm/config/claude-config-dir" | show
say "cat <config-reread instruction delivered to secondmate sm>"; cat "$(reread_instruction_path "$w/sm")" | show
say "bin/fm-config-push.sh                    # second push, nothing changed"; run_config_push "$w" 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "rm \$W/home/config/claude-config-dir && bin/fm-config-push.sh"; rm -f "$w/home/config/claude-config-dir"; run_config_push "$w" 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "ls \$W/sm/config/claude-config-dir"; ls "$w/sm/config/claude-config-dir" 2>&1 | show
say "cat <latest config-reread instruction>"; cat "$(reread_instruction_path "$w/sm")" | show

echo; echo "################ 2. fm-spawn.sh --secondmate on claude: config file supplies the root"
w="$TMP_ROOT/spawn-file"; mkdir -p "$w/home/config" "$w/claude-account-pers"
printf '%s\n' "$w/claude-account-pers" > "$w/home/config/claude-config-dir"
make_seeded_home "$w/sm" sm
say "fm-spawn.sh sm \$W/sm --harness claude --secondmate   (no CLAUDE_CONFIG_DIR in env)"
spawn_secondmate_capture "$w" sm "$w/sm" "$w/launch.log" --harness claude 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "launch line sent to the tmux pane:"; cat "$w/launch.log" | show

echo; echo "################ 3. explicit CLAUDE_CONFIG_DIR in the spawner environment wins over the file"
w="$TMP_ROOT/spawn-env"; mkdir -p "$w/home/config" "$w/from-file" "$w/from-env"
printf '%s\n' "$w/from-file" > "$w/home/config/claude-config-dir"
make_seeded_home "$w/sm" sm
say "CLAUDE_CONFIG_DIR=\$W/from-env fm-spawn.sh sm \$W/sm --harness claude --secondmate"
CLAUDE_CONFIG_DIR="$w/from-env" spawn_secondmate_capture "$w" sm "$w/sm" "$w/launch.log" --harness claude 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "launch line:"; cat "$w/launch.log" | show

echo; echo "################ 4. neither env nor file: no prefix (Claude default root)"
w="$TMP_ROOT/spawn-unset"; mkdir -p "$w/home/config"; make_seeded_home "$w/sm" sm
say "fm-spawn.sh sm \$W/sm --harness claude --secondmate"
spawn_secondmate_capture "$w" sm "$w/sm" "$w/launch.log" --harness claude 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "launch line:"; cat "$w/launch.log" | show

echo; echo "################ 5. configured path is not an existing directory: spawn refused"
w="$TMP_ROOT/spawn-invalid"; mkdir -p "$w/home/config"; make_seeded_home "$w/sm" sm
printf '%s\n' "$w/does-not-exist" > "$w/home/config/claude-config-dir"
say "fm-spawn.sh sm \$W/sm --harness claude --secondmate"
spawn_secondmate_capture "$w" sm "$w/sm" "$w/launch.log" --harness claude 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "launch log (should be empty):"; cat "$w/launch.log" | show; echo "(end)"

echo; echo "################ 6. non-Claude harness never gets the prefix, even with file + env set"
w="$TMP_ROOT/spawn-codex"; mkdir -p "$w/home/config" "$w/root"; make_seeded_home "$w/sm" sm
printf '%s\n' "$w/root" > "$w/home/config/claude-config-dir"
say "CLAUDE_CONFIG_DIR=\$W/root fm-spawn.sh sm \$W/sm --harness codex --secondmate"
CLAUDE_CONFIG_DIR="$w/root" spawn_secondmate_capture "$w" sm "$w/sm" "$w/launch.log" --harness codex 2>&1 | show; echo "exit=${PIPESTATUS[0]}"
say "launch line:"; cat "$w/launch.log" | show

echo; echo "################ 7. crewmate (ship) spawn from a home with the file: same prefix on the claude launch"
c="$TMP_ROOT/ship"; fakebin=$(make_spawn_fakebin "$c/fake")
fm_test_spawn_home "$c/home" claude; fm_git_worktree "$c/project" "$c/wt" wt-ship
fm_test_spawn_brief "$c/home" ship-a1
mkdir -p "$c/claude-account-pers"; printf '%s\n' "$c/claude-account-pers" > "$c/home/config/claude-config-dir"
say "fm-spawn.sh ship-a1 \$W/ship/project --mode no-mistakes --yolo off   (crew-harness=claude)"
CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$c/launch.log" GROK_HOME="$c/home/grok-home" \
  fm_test_run_spawn "$c/home" "$c/wt" "$fakebin" ship-a1 "$c/project" --mode no-mistakes --yolo off | show
say "launch line:"; cat "$c/launch.log" | show
