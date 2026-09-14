#!/usr/bin/env bash
# Drives the real bin/fm-spawn.sh of <repo> for a Claude scout launch whose pin
# is a throwaway root, with the fixture's fake quota-axi REMOVED so the spawn
# preflight asks the real installed quota-axi. tmux is the suite's capture stub,
# so no real Claude session starts; a delivered launch shows up in launch.log.
# Usage: spawn-claude-pin-driver.sh <repo>
set -u
REPO=$1
# shellcheck source=/dev/null
. "$REPO/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-claude-pin-live)
echo "repo: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "$REPO")   quota-axi $(quota-axi --version)"

spawn_case() {  # <name> <setup-fn>
  local name=$1 setup=$2 dir="$TMP_ROOT/$1" home proj wt fakebin log id out status
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"; log="$dir/launch.log"; id="pin-$name"
  fakebin=$(fm_test_make_spawn_fakebin "$dir/fake")
  rm -f "$fakebin/quota-axi"                      # real quota-axi answers
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$name" >/dev/null 2>&1
  fm_test_spawn_brief "$home" "$id"
  "$setup" "$home/accounts/claude"
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --harness claude); status=$?
  echo
  echo "== case $name: pin root contents: $(cd "$home/accounts/claude" && ls -A | tr '\n' ' ')"
  echo "   real quota-axi answer: $(env -i HOME="$home/user-home" PATH="$PATH" CLAUDE_CONFIG_DIR="$home/accounts/claude" quota-axi auth --json --provider claude </dev/null 2>/dev/null | jq -c '[.auth[].sources[] | {source,status,error,credentialPresent}]')"
  echo "   fm-spawn exit=$status"
  printf '%s\n' "$out" | grep -E "error:|spawned" | sed 's/^/   /'
  if [ -s "$log" ]; then echo "   launch delivered: yes"; else echo "   launch delivered: no"; fi
  if [ -e "$home/state/$id.meta" ]; then echo "   task meta published: yes"; else echo "   task meta published: no"; fi
}

setup_empty() { :; }
setup_unlogged() { printf '{"numStartups":3,"hasCompletedOnboarding":true}\n' > "$1/.claude.json"; }
setup_null_account() { printf '{"oauthAccount":null}\n' > "$1/.claude.json"; }
setup_keychain_login_shape() { printf '{"oauthAccount":{"emailAddress":"fm@example.invalid","accountUuid":"00000000-0000-0000-0000-000000000000"}}\n' > "$1/.claude.json"; }
setup_filed() {
  local expires=$(( ($(date +%s) + 86400) * 1000 ))
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-fake","refreshToken":"sk-ant-ort01-fake","expiresAt":%s,"scopes":["user:inference"]}}\n' "$expires" > "$1/.credentials.json"
  chmod 600 "$1/.credentials.json"
}

for c in ${CASES:-empty unlogged null_account keychain_login_shape filed}; do spawn_case "$c" "setup_$c"; done
