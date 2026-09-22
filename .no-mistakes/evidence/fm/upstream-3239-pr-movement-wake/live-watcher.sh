#!/usr/bin/env bash
# Live watcher drive: real fm-watch-checkpoint.sh + real gh, isolated FM_HOME.
set -u
ROOT=${ROOT:?}; URL=${URL:?}
T=$(mktemp -d /tmp/fm-live-watch.XXXXXX); home=$T/home
mkdir -p "$home/data/delivery" "$home/state" "$home/config" "$home/projects" "$home/root/bin" "$home/wt" "$home/fakebin"
printf '# Backlog\n\n## Queued\n- [ ] delivery - Live %s (repo: sample) (kind: ship)\n' "$URL" > "$home/data/backlog.md"
printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"; chmod +x "$home/fakebin/"*
printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"; chmod +x "$home/root/bin/fm-guard.sh"
printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"; chmod 600 "$home/state/delivery.meta"
H() { PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"; }
W() { H env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$@" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds "$S"; }
wakes() { [ -f "$home/state/.wake-queue" ] && awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$home/state/.wake-queue" || echo 0; }
H "$ROOT/bin/fm-pr-check.sh" delivery "$URL"
echo "--- baseline poll (first observation) via contributions check"; H bash "$home/state/contributions.check.sh"; echo "durable wakes: $(wakes)"
echo "--- watcher checkpoint on unchanged PR (40s)"; S=40; W; echo "watcher rc=$? (124 = quiet expiry)"; echo "durable wakes: $(wakes)"
echo "--- previous observation now records an older head"
jq '.records[0].observation.head = "0000000000000000000000000000000000000001"' "$home/data/delivery/contributions.json" > "$T/x" && mv "$T/x" "$home/data/delivery/contributions.json"
echo "--- watcher checkpoint (60s)"; S=60; W FM_WATCH_HANDLING_SUCCESSOR=1; echo "watcher rc=$?"; echo "durable wakes: $(wakes)"
H "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[]|{type,body}]'
echo "--- watcher checkpoint again, head unchanged (40s)"; S=40; W FM_WATCH_HANDLING_SUCCESSOR=1; echo "watcher rc=$? (124 = quiet expiry)"; echo "durable wakes: $(wakes)"
pkill -f "$T" 2>/dev/null; rm -rf "$T"
