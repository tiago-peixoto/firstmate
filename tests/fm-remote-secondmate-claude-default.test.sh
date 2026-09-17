#!/usr/bin/env bash
# Host-local remote-secondmate Claude launch uses the default login.
#
# A remote second mate is launched on the host by
# bin/fm-remote-secondmate-control.sh, with FM_HOME pointed at that host's
# Firstmate code root. That checkout has no config/claude-config-dir. The pane
# command must still start bare `claude` with CLAUDE_CONFIG_DIR unset, including
# when the launching environment exports one.
#
# This asserts the launch command/environment written into the pane, not Herdr
# agent-process or composer detection. A live-agent relaunch /exit depends on
# that unrelated Herdr behaviour, so relaunch is not driven here: it uses the
# same spawn prefix already covered by the local Claude launch tests.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-remote-claude-default)

assert_claude_launch_unsets_config_dir() { # <herdr-log> <what>
  local log=$1 what=$2
  grep -q 'env -u CLAUDE_CONFIG_DIR' "$log" \
    || fail "$what did not unset CLAUDE_CONFIG_DIR"$'\n'"$(cat "$log")"
  if grep -q 'CLAUDE_CONFIG_DIR=' "$log"; then
    fail "$what exported CLAUDE_CONFIG_DIR"$'\n'"$(cat "$log")"
  fi
}

test_host_local_claude_launch_uses_default_login() {
  local w coderoot home fakebin user_home leftover env_root out status
  w="$TMP_ROOT/world"
  coderoot="$w/coderoot"
  home="$w/sm"
  user_home="$w/user-home"
  leftover="$w/leftover-pin"
  env_root="$w/inherited-claude"
  mkdir -p "$user_home" "$leftover" "$env_root" "$coderoot"

  (
    cd "$ROOT" || exit 1
    tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
  ) | (cd "$coderoot" && tar -xf -)
  git init -q -b main "$coderoot"
  git -C "$coderoot" add -A
  git -C "$coderoot" commit -qm 'host firstmate copy'
  git clone -q "$coderoot" "$home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  [ ! -e "$coderoot/config/claude-config-dir" ] \
    || fail "precondition: the host code root must not hold config/claude-config-dir"
  printf '%s\n' "$leftover" > "$home/config/claude-config-dir"

  fakebin=$(fm_fakebin "$w/fake")
  fm_test_fake_account_auth "$fakebin"
  fm_fake_exit0 "$fakebin" gh treehouse tmux
  ln -sf "$(command -v node)" "$fakebin/node"
  install_remote_herdr_fixture "$w/herdrhost" "$w/herdr.state" "$w/herdr.log" \
    "$w/herdr.sendfail" "$w/herdr.sock"
  cp "$w/herdrhost/bin/herdr" "$fakebin/herdr"

  : > "$w/herdr.log"
  out=$(PATH="$fakebin:$BASE_PATH" \
    HOME="$user_home" \
    CLAUDE_CONFIG_DIR="$env_root" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$coderoot" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-remote-secondmate-control.sh" launch sm claude - - herdr 2>&1)
  status=$?
  expect_code 0 "$status" "host-local Claude launch with no code-root pin must succeed: $out"
  assert_claude_launch_unsets_config_dir "$w/herdr.log" \
    "a host-local Claude launch"
  grep -q "$env_root" "$w/herdr.log" \
    && fail "an inherited CLAUDE_CONFIG_DIR reached the remote pane"$'\n'"$(cat "$w/herdr.log")"
  grep -q "$leftover" "$w/herdr.log" \
    && fail "a leftover config/claude-config-dir reached the remote pane"$'\n'"$(cat "$w/herdr.log")"
  [ "$(cat "$home/config/claude-config-dir")" = "$leftover" ] \
    || fail "a host-local launch rewrote the leftover config/claude-config-dir"
  pass "host-local Claude launch uses the default login with CLAUDE_CONFIG_DIR unset"
}

test_host_local_claude_launch_uses_default_login

echo "# all fm-remote-secondmate-claude-default tests passed"
