#!/usr/bin/env bash
# Drive the real fm-contributions.sh poll against the real GitHub API for
# kunchenguid/firstmate PRs in a disposable lab home. Read-only on GitHub.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$LAB/fakebin/tmux"; chmod +x "$LAB/fakebin/tmux"
OPEN=https://github.com/kunchenguid/firstmate/pull/5341
MERGED=https://github.com/kunchenguid/firstmate/pull/7387
printf '# Backlog\n\n## Queued\n- [ ] live-open - PR movement %s (repo: firstmate) (kind: ship)\n- [ ] live-merged - Settled %s (repo: firstmate) (kind: ship)\n' "$OPEN" "$MERGED" > "$LAB/data/backlog.md"
fm() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" "$ROOT/bin/fm-contributions.sh" "$@"; }
wakes() { [ -f "$LAB/state/.wake-queue" ] && awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$LAB/state/.wake-queue" || echo 0; }
obs() { jq -c --arg u "$2" '.records[] | select(.url==$u) | {state:.observation.state,head:.observation.head,draft:.observation.draft,review_requests:.observation.review_requests,pending:[.pending[]|{type,body}]}' "$LAB/data/$1/contributions.json"; }
edit() { jq "$2" "$LAB/data/$1/contributions.json" > "$LAB/e.json" && mv "$LAB/e.json" "$LAB/data/$1/contributions.json"; }

echo "== 1. first poll of real PRs (baseline)"
fm poll; echo "poll rc=$?"
echo "open:   $(obs live-open $OPEN)"
echo "merged: $(obs live-merged $MERGED)"
echo "pending: $(fm pending | jq -c .)"; echo "durable check wakes: $(wakes)"

echo "== 2. unchanged re-poll"
sleep 2; fm poll; echo "poll rc=$?"; echo "pending: $(fm pending | jq -c .)"; echo "durable check wakes: $(wakes)"

echo "== 3. stored prior observation rewound: older head, draft, a reviewer the live PR no longer requests"
OLD=0000000000000000000000000000000000000001
edit live-open ".records[0].observation.head=\"$OLD\" | .records[0].observation.draft=true | .records[0].observation.review_requests=[]"
echo "== 3a. forge now requests nobody, so only head and left-draft movement should appear"
sleep 2; fm poll; echo "poll rc=$?"
echo "open:   $(obs live-open $OPEN)"
echo "pending: $(fm pending | jq -c '[.[]|{task,type,body,source}]')"; echo "durable check wakes: $(wakes)"
echo "== 3b. unchanged re-poll after movement"
sleep 2; fm poll; echo "poll rc=$?"; echo "pending count: $(fm pending | jq length)"; echo "durable check wakes: $(wakes)"

echo "== 4. settled PR with a rewound open prior observation and different head"
edit live-merged ".records[0].observation.state=\"open\" | .records[0].observation.head=\"$OLD\" | .records[0].observation.draft=true"
sleep 2; fm poll; echo "poll rc=$?"
echo "merged: $(obs live-merged $MERGED)"
echo "pending: $(fm pending | jq -c '[.[]|{task,type}]')"; echo "durable check wakes: $(wakes)"

echo "== 5. ack the head token, the other stays"
tok=$(fm pending | jq -r '.[]|select(.type=="head")|.token')
fm ack live-open "$OPEN" "$tok"; echo "ack rc=$?"
echo "pending: $(fm pending | jq -c '[.[]|{type,body}]')"
