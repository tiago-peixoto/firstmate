#!/usr/bin/env bash
# Re-bless the exact tracked GitHub wrapper bytes at their installed paths.
# Run this after the wrappers land in a firstmate home and after every wrapper
# edit. Automic Vault binds each blessing to both bytes and canonical path.
#
# Exact re-bless command from any directory:
#   /absolute/path/to/firstmate/bin/fm-gh-wrapper-bless.sh
#
# The fixed list below is intentionally limited to firstmate's measured
# recurring unattended GitHub operations. Each review requests a Launcher
# Endorsement so a verified launcher can execute it without human approval.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AV=/usr/local/bin/av

[ "$#" -eq 0 ] || {
  echo "usage: fm-gh-wrapper-bless.sh" >&2
  exit 2
}
[ -x "$AV" ] || {
  echo "fm-gh-wrapper-bless: /usr/local/bin/av is unavailable" >&2
  exit 1
}

"$AV" bless --endorse-launcher "$SCRIPT_DIR/fm-gh-auth-status.sh"
"$AV" bless --endorse-launcher "$SCRIPT_DIR/fm-gh-pr-state.sh"
"$AV" bless --endorse-launcher "$SCRIPT_DIR/fm-gh-pr-head.sh"
