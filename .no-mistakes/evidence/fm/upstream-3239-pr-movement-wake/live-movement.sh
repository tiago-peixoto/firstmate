#!/usr/bin/env bash
# Live drive: real fm-contributions.sh + fm-pr-check.sh + registered custom check,
# real authenticated gh against a real public GitHub PR, isolated throwaway FM_HOME.
# The "previous observation" is persisted local state that we set to model what
# the forge looked like at the last poll; the current forge read is real.
set -u
ROOT=${ROOT:?}
URL=${URL:?}
T=$(mktemp -d /tmp/fm-live-movement.XXXXXX)
home=$T/home
mkdir -p "$home/data/delivery" "$home/state" "$home/config" "$home/projects" "$home/root/bin" "$home/wt" "$home/fakebin"
printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"; chmod +x "$home/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"; chmod +x "$home/root/bin/fm-guard.sh"
printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"; chmod 600 "$home/state/delivery.meta"
printf -- '- [ ] delivery - Live contribution %s (repo: sample) (kind: ship)\n' "$URL" >> "$home/data/backlog.md"
H() { PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"; }
check() { local c; for c in "$home/state/"*.check.sh; do [ -f "$c" ] || continue; echo "+ run registered check $(basename "$c")"; H bash "$c"; echo "  (rc=$?)"; done; }
wakes() { [ -f "$home/state/.wake-queue" ] && awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$home/state/.wake-queue" || echo 0; }
rec() { jq -c '.records[0] | {head:.observation.head,draft:.observation.draft,review_requests:.observation.review_requests,pending:[.pending[]|{type,body}]}' "$home/data/delivery/contributions.json"; }
seed() { jq "$1" "$home/data/delivery/contributions.json" > "$T/x" && mv "$T/x" "$home/data/delivery/contributions.json"; echo "+ seed prior observation: $1"; }
echo "=== PR: $URL"
echo "+ fm-pr-check.sh delivery $URL"; H "$ROOT/bin/fm-pr-check.sh" delivery "$URL"; echo "  (rc=$?)"
[ -f "$home/state/contributions.check.sh" ] || { echo "+ fm-contributions.sh arm (backlog-linked ownership)"; H "$ROOT/bin/fm-contributions.sh" arm; echo "  (rc=$?)"; }
echo "--- step 1: first observation (baseline)"
check; echo "record: $(rec)"; echo "durable wakes: $(wakes)"
echo "--- step 2: unchanged re-poll"
check; echo "record: $(rec)"; echo "durable wakes: $(wakes)"
for s in "$@"; do
  echo "--- scenario: $s"
  case "$s" in
    head) seed '.records[0].observation.head = "0000000000000000000000000000000000000001"' ;;
    ready) seed '.records[0].observation.draft = true' ;;
    reviewer) seed '.records[0].observation.review_requests = []' ;;
    todraft) seed '.records[0].observation.draft = false' ;;
    legacy) seed '.records[0].observation |= del(.review_requests)' ;;
  esac
  check; echo "record: $(rec)"; echo "durable wakes: $(wakes)"
  echo "+ fm-contributions.sh pending"; H "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[]|{type,body,source}]'
  echo "--- re-poll unchanged after $s"
  check; echo "record: $(rec)"; echo "durable wakes: $(wakes)"
  for tok in $(H "$ROOT/bin/fm-contributions.sh" pending | jq -r '.[].token'); do
    echo "+ ack $tok"; H "$ROOT/bin/fm-contributions.sh" ack delivery "$URL" "$tok"; done
done
echo "--- wake queue"; cut -f1-5 "$home/state/.wake-queue" 2>/dev/null
rm -rf "$T"
