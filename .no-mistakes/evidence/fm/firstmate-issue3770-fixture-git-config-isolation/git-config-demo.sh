#!/usr/bin/env bash
# Run from the validated worktree. Only scratch repositories/configs are changed.
set -euo pipefail
PROJECT_ROOT=$PWD
BASE=b84e0e362face25f3dd8945297a3df1320d7668c
mkdir -p "$PROJECT_ROOT/scratchpad-git-config-validation"
LAB=$(mktemp -d "$PROJECT_ROOT/scratchpad-git-config-validation/e2e.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export LAB PROJECT_ROOT
mkdir -p "$LAB/tmp" "$LAB/gnupg" "$LAB/baseline/tests"
chmod 700 "$LAB/gnupg"
export TMPDIR="$LAB/tmp" GNUPGHOME="$LAB/gnupg" REAL_GPG="$(command -v gpg)"
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL FM_TEST_LIB_SOURCED
export GIT_CONFIG_GLOBAL="$LAB/global" GIT_CONFIG_SYSTEM="$LAB/system" GIT_CONFIG_NOSYSTEM=0
cat > "$LAB/gpg" <<'SH'
#!/usr/bin/env bash
# Real GPG, with no keyring or agent belonging to the developer involved.
exec "$REAL_GPG" --homedir "$GNUPGHOME" --batch --no-tty --no-autostart "$@"
SH
chmod +x "$LAB/gpg"
: > "$LAB/global"
: > "$LAB/system"
git config --file "$LAB/global" commit.gpgsign true
git config --file "$LAB/global" gpg.format openpgp
git config --file "$LAB/global" gpg.program "$LAB/gpg"
cp "$LAB/global" "$LAB/expected"
git show "$BASE:tests/lib.sh" > "$LAB/baseline/tests/lib.sh"
ln -s "$PROJECT_ROOT/bin" "$LAB/baseline/bin"
printf 'Git fixture isolation demonstration\nHEAD: %s\nBase: %s\n' "$(git rev-parse HEAD)" "$BASE"
git --version
"$REAL_GPG" --version | head -n 1
printf 'Global/system files and empty GPG home are disposable worktree-local fixtures.\n'
expect_no_key() {
  local rc=0
  printf '\n$'; printf ' %q' "$@"; printf '\n'
  "$@" > "$LAB/failure.log" 2>&1 || rc=$?
  cat "$LAB/failure.log"
  printf 'exit=%s (expected signing failure)\n' "$rc"
  [ "$rc" -ne 0 ]
  grep -Fq 'No secret key' "$LAB/failure.log"
}
export -f expect_no_key
printf '\nBEFORE: execute the base shared fixture helper with global signing enabled.\n'
expect_no_key bash -eu -c '. "$1"; fm_git_init_commit "$2"' _ "$LAB/baseline/tests/lib.sh" "$LAB/baseline-repo"
for scope in global system; do
  if [ "$scope" = system ]; then
    cp "$LAB/expected" "$LAB/system"
    : > "$LAB/global"
  fi
  printf '\nAFTER: %s signing=true, execute current tests/lib.sh and its child Git process.\n' "$scope"
  bash -eus -- "$PROJECT_ROOT/tests/lib.sh" "$LAB/$scope-fixture" <<'SH'
. "$1"
fm_git_init_commit "$2"
fm_git_identity
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
git -C "$2" log -2 --format='%s | %an <%ae> | signature=%G?'
[ "$(git -C "$2" rev-list --count HEAD)" = 2 ]
SH
  printf '\nOUTSIDE: caller %s config is still active, and outside-fixture commits still attempt signing.\n' "$scope"
  git config --show-origin --get commit.gpgsign
  cmp "$LAB/$scope" "$LAB/expected"
  git init -q "$LAB/$scope-outside"
  expect_no_key git -C "$LAB/$scope-outside" -c user.name=Outside -c user.email=outside@example.invalid commit -q --allow-empty -m outside
  if [ "$scope" = global ]; then
    printf '\nRUNNER: execute a helper-free Git fixture under inherited global signing.\n'
    cat > "$LAB/probe.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
git init -q "$LAB/runner-repo"
git -C "$LAB/runner-repo" -c user.name=Runner -c user.email=runner@example.invalid commit -q --allow-empty -m runner-fixture
git -C "$LAB/runner-repo" log -1 --format='%s | %an <%ae> | signature=%G?'
SH
    bash "$PROJECT_ROOT/bin/fm-test-run.sh" --jobs 1 "$LAB/probe.test.sh"
    printf '\nDIRECT SUITE: tests/fm-gitignore-config.test.sh with global signing enabled.\n'
    bash "$PROJECT_ROOT/tests/fm-gitignore-config.test.sh"
    printf '\nEXPLICIT CONFIGURATION: local and inline signing remain effective; explicit opt-outs allow commits.\n'
    bash -eus -- "$PROJECT_ROOT/tests/git-config-helpers.sh" "$LAB/global-fixture" <<'SH'
. "$1"
repo=$2
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
git -C "$repo" config commit.gpgsign true
git -C "$repo" config gpg.program "$LAB/gpg"
expect_no_key git -C "$repo" commit -q --allow-empty -m local-signing
git -C "$repo" -c commit.gpgsign=false commit -q --allow-empty -m inline-opt-out
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false git -C "$repo" commit -q --allow-empty -m environment-opt-out
GIT_CONFIG_PARAMETERS="'commit.gpgsign=false'" git -C "$repo" commit -q --allow-empty -m parameters-opt-out
git -C "$repo" config --unset commit.gpgsign
expect_no_key git -C "$repo" -c commit.gpgsign=true commit -q --allow-empty -m inline-signing
expect_no_key env GIT_CONFIG_GLOBAL="$LAB/global" git -C "$repo" commit -q --allow-empty -m explicit-global
expect_no_key env GIT_CONFIG_NOSYSTEM=0 GIT_CONFIG_SYSTEM="$LAB/global" git -C "$repo" commit -q --allow-empty -m explicit-system
git -C "$repo" log -3 --format='%s | %an <%ae> | signature=%G?'
[ "$(git -C "$repo" rev-list --count HEAD)" = 5 ]
SH
    cmp "$LAB/global" "$LAB/expected"
    printf '\nAfter runner and explicit-config checks, caller signing remains: '
    git config --global --get commit.gpgsign
  fi
done
printf '\nBoth isolated config files are unchanged by the fixture processes; no project or host Git configuration was edited.\n'
