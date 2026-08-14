#!/usr/local/bin/av inject -- /bin/sh
# --- automic-vault
# capabilities:
#   gh: read-only
# ---
# shellcheck shell=sh disable=SC1008,SC2096
# Report authentication health for github.com and nothing else.
# This script accepts no arguments, uses only a fixed signed gh location, and
# removes ambient credential and routing overrides before gh reaches the Vault.
# Any byte change requires re-blessing through bin/fm-gh-wrapper-bless.sh.
set -eu

[ "$#" -eq 0 ] || {
  echo "usage: fm-gh-auth-status.sh" >&2
  exit 2
}

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO GH_CONFIG_DIR
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat PAGER=cat NO_COLOR=1

if [ -x /opt/homebrew/opt/gh-cli/bin/gh ]; then
  GH=/opt/homebrew/opt/gh-cli/bin/gh
elif [ -x /usr/local/bin/gh ]; then
  GH=/usr/local/bin/gh
else
  echo "fm-gh-auth-status: hardened gh is unavailable" >&2
  exit 1
fi

exec "$GH" auth status --hostname github.com
