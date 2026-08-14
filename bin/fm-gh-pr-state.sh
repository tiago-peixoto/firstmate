#!/usr/local/bin/av inject -- /bin/sh
# --- automic-vault
# capabilities:
#   gh: read-only
# ---
# shellcheck shell=sh disable=SC1008,SC2096
# Print one GitHub pull request's state through a fixed read-only gh operation.
# The only inputs are strictly validated owner, repository, and positive pull
# request number data. No command, URL, API endpoint, host, or gh option is
# accepted. Any byte change requires re-blessing through
# bin/fm-gh-wrapper-bless.sh.
set -eu

usage() {
  echo "usage: fm-gh-pr-state.sh <owner> <repository> <pull-request-number>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage
owner=$1
repo=$2
number=$3

[ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || usage
case "$owner" in
  *[!A-Za-z0-9-]*|-*|*-|*--*) usage ;;
esac
[ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || usage
case "$repo" in
  .|..|*[!A-Za-z0-9._-]*) usage ;;
esac
case "$number" in
  [1-9]*) ;;
  *) usage ;;
esac
case "$number" in
  *[!0-9]*) usage ;;
esac

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_REPO GH_CONFIG_DIR
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_PAGER=cat PAGER=cat NO_COLOR=1

if [ -x /opt/homebrew/opt/gh-cli/bin/gh ]; then
  GH=/opt/homebrew/opt/gh-cli/bin/gh
elif [ -x /usr/local/bin/gh ]; then
  GH=/usr/local/bin/gh
else
  echo "fm-gh-pr-state: hardened gh is unavailable" >&2
  exit 1
fi

exec "$GH" pr view "$number" --repo "$owner/$repo" --json state --jq .state
