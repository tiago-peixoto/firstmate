#!/usr/bin/env bash
# Runs only the three test functions this change added to
# tests/fm-secondmate-harness.test.sh, each in its own subshell so every
# failure is reported. Run from the worktree root.
set -u -o pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset CLAUDECODE CLAUDE_CONFIG_DIR PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS
. tests/fixtures.sh
. "$ROOT/bin/fm-ff-lib.sh"
. "$ROOT/bin/fm-config-inherit-lib.sh"
for fn in make_noop_tmux make_seeded_home make_launch_capturing_tmux spawn_secondmate_capture \
          new_world add_sm_worktree make_fake_toolchain run_config_push reread_instruction_path \
          test_spawn_claude_config_dir_precedence test_spawn_refuses_invalid_claude_config_dir \
          test_claude_config_dir_inheritance_present_unchanged_and_absent; do
  eval "$(sed -n "/^$fn()/,/^}/p" tests/fm-secondmate-harness.test.sh)"
done
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-claude-config-newtests)
export FM_BACKEND=tmux
trap 'rm -rf "$TMP_ROOT"' EXIT
echo "bin/fm-spawn.sh + bin/fm-config-inherit-lib.sh at: $(git hash-object bin/fm-spawn.sh | cut -c1-12) / $(git hash-object bin/fm-config-inherit-lib.sh | cut -c1-12)"
rc=0
for t in test_claude_config_dir_inheritance_present_unchanged_and_absent \
         test_spawn_claude_config_dir_precedence \
         test_spawn_refuses_invalid_claude_config_dir; do
  ( "$t" ) 2>&1 | sed "s#$TMP_ROOT#\$W#g" || rc=1
done
exit $rc
