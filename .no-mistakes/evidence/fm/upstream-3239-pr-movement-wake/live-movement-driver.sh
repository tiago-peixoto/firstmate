#!/usr/bin/env bash
# Live driver: real bin/fm-contributions.sh + real authenticated gh against
# real GitHub pull requests (read-only), inside disposable lab homes.
set -u
WT=$1
ZERO=0000000000000000000000000000000000000000
fc() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-contributions.sh" "$@"; }
wakes() { [ -f "$LAB/state/.wake-queue" ] && awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$LAB/state/.wake-queue" || echo 0; }
lab() { # task url
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
  printf '# Backlog\n\n## Queued\n- [ ] %s - Live contribution %s (repo: sample) (kind: ship)\n' "$1" "$2" > "$LAB/data/backlog.md"
  mkdir -p "$LAB/data/$1"
}
mut() { jq "$2" "$LAB/data/$1/contributions.json" > "$LAB/m.json" && mv "$LAB/m.json" "$LAB/data/$1/contributions.json"; }
show() { echo "--- poll stdout:"; echo "$1"; echo "--- record:"; jq -c '.records[0] | {url,error,state:.observation.state,head:.observation.head,draft:.observation.draft,review_requests:.observation.review_requests,pending:[.pending[]|{type,body}]}' "$LAB/data/$2/contributions.json"; echo "--- durable check wakes: $(wakes)"; }

echo "===== S1/S2: real open PR kunchenguid/firstmate#5341 - baseline, then head replaced + left draft"
lab fm https://github.com/kunchenguid/firstmate/pull/5341
show "$(fc poll 2>&1)" fm
echo ">> rewrite prior observation: head=$ZERO, draft=true (simulates movement since last poll)"
mut fm ".records[0].observation.head=\"$ZERO\" | .records[0].observation.draft=true"
show "$(FM_CONTRIBUTIONS_NOW=$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ) fc poll 2>&1)" fm
echo "--- pending view:"; fc pending | jq -c '.[] | {task,type,body,source}'
echo ">> unchanged re-poll"
show "$(FM_CONTRIBUTIONS_NOW=$(date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ) fc poll 2>&1)" fm
rm -rf "$LAB"

echo; echo "===== S3/S4: real PR cli/cli#14485 with a requested reviewer - first observation baseline, new reviewer, legacy record"
lab rv https://github.com/cli/cli/pull/14485
show "$(fc poll 2>&1)" rv
echo ">> rewrite prior observation: review_requests=[] (reviewer newly requested since last poll)"
mut rv '.records[0].observation.review_requests=[]'
show "$(FM_CONTRIBUTIONS_NOW=$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ) fc poll 2>&1)" rv
echo ">> ack the reviewer signal, then rewrite prior observation as legacy (no review_requests field)"
tok=$(fc pending | jq -r '.[0].token'); fc ack rv https://github.com/cli/cli/pull/14485 "$tok" && echo "acked $tok"
mut rv '.records[0].observation |= del(.review_requests)'
show "$(FM_CONTRIBUTIONS_NOW=$(date -u -d '+2 min' +%Y-%m-%dT%H:%M:%SZ) fc poll 2>&1)" rv
rm -rf "$LAB"

echo; echo "===== S5: real merged PR kunchenguid/firstmate#6306 - prior open observation on another head"
lab st https://github.com/kunchenguid/firstmate/pull/6306
show "$(fc poll 2>&1)" st
echo ">> rewrite prior observation: state=open, head=$ZERO, draft=true, review_requests=[] (forces a re-read)"
mut st ".records[0].observation.state=\"open\" | .records[0].observation.head=\"$ZERO\" | .records[0].observation.draft=true | .records[0].observation.review_requests=[]"
show "$(FM_CONTRIBUTIONS_NOW=$(date -u -d '+1 min' +%Y-%m-%dT%H:%M:%SZ) fc poll 2>&1)" st
rm -rf "$LAB"
