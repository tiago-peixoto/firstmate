#!/usr/bin/env bash
# Live drive of fm-contributions.sh against real GitHub (read-only) in a disposable lab home.
set -u
LAB=$1
R() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
F=$LAB/data/movement/contributions.json
wakes() { [ -f "$LAB/state/.wake-queue" ] && awk -F '\t' '$3=="check"{c++} END{print c+0}' "$LAB/state/.wake-queue" || echo 0; }
obs() { jq -c '.records[0]|{pending:[.pending[]|{type,body}],obs:(.observation|{head,state,draft,review_requests})}' "$F"; }
seed() { jq "$1" "$F" > "$F.tmp" && mv "$F.tmp" "$F"; }
echo "== S1: re-poll unchanged real PR #5341 (baseline already recorded)"
out=$(R bin/fm-contributions.sh poll); echo "poll stdout: [${out}]"; echo "check wakes queued: $(wakes)"; obs
echo
echo "== S2: seed prior observation = older head, draft=true, prior reviewer 'ghost' (since removed); re-poll real PR"
seed '.records[0].observation.head="1f2c9548f4680efeda76fabe9f057b4021b97272" | .records[0].observation.draft=true | .records[0].observation.review_requests=["ghost"]'
out=$(R bin/fm-contributions.sh poll); echo "poll stdout: [${out}]"; echo "check wakes queued: $(wakes)"; obs
echo "-- pending view:"; R bin/fm-contributions.sh pending | jq -c '.[]|{type,body,source}'
echo
echo "== S3: re-poll again with no forge change -> no new wake, pending retained"
out=$(R bin/fm-contributions.sh poll); echo "poll stdout: [${out}]"; echo "check wakes queued: $(wakes)"; R bin/fm-contributions.sh pending | jq 'length'
echo
echo "== S4: ack each pending token -> inbox empty"
for t in $(R bin/fm-contributions.sh pending | jq -r '.[].token'); do R bin/fm-contributions.sh ack movement https://github.com/kunchenguid/firstmate/pull/5341 "$t" && echo "acked $t"; done
R bin/fm-contributions.sh pending | jq -c .
echo
echo "== S5: legacy observation (no review_requests field) -> baseline, no movement"
seed 'del(.records[0].observation.review_requests)'
out=$(R bin/fm-contributions.sh poll); echo "poll stdout: [${out}]"; echo "check wakes queued: $(wakes)"; obs
