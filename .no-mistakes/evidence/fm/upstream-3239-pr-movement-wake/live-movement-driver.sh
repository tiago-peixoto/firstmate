#!/usr/bin/env bash
# Live driver: real bin/fm-contributions.sh against real GitHub (read-only gh
# API reads) inside a disposable marked lab home. Prior observations are
# rewritten locally to stand in for the earlier forge state a real movement
# would have left behind; the current state is always the live forge read.
set -u
WT=${WT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
C="$WT/bin/fm-contributions.sh"
OPEN=https://github.com/kunchenguid/firstmate/pull/5341        # open, no reviewers (the PR this change keeps mergeable)
REV=https://github.com/cli/cli/pull/14540                      # open, reviewer requested
DRAFT=https://github.com/kubernetes/kubernetes/pull/142474     # open draft with reviewers
MERGED=https://github.com/kunchenguid/firstmate/pull/5916      # merged
printf "# Backlog\n\n## Queued\n" > "$LAB/data/backlog.md"
cat >> "$LAB/data/backlog.md" <<B
- [ ] openpr - Keep PR mergeable $OPEN (repo: sample) (kind: ship)
- [ ] revpr - Reviewer requested $REV (repo: sample) (kind: ship)
- [ ] draftpr - Draft PR $DRAFT (repo: sample) (kind: ship)
- [ ] mergedpr - Merged PR $MERGED (repo: sample) (kind: ship)
B
queued() { [ -f "$LAB/state/.wake-queue" ] && awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$LAB/state/.wake-queue" || echo 0; }
poll_all() { # poll until every task has an observation (budget rotation)
  local i
  for i in 1 2 3 4 5 6; do
    run "$C" poll
    n=$(cat "$LAB"/data/*/contributions.json 2>/dev/null | jq -s '[.[].records[] | select(.checked_at != null and .error == null)] | length')
    [ "$n" -ge "${1:-4}" ] && return 0
  done
}
show() { for t in openpr revpr draftpr mergedpr; do jq -c --arg t $t '.records[0] | {task:$t,state:.observation.state,draft:.observation.draft,head:(.observation.head[0:12]),review_requests:.observation.review_requests,pending:[.pending[]|{type,body}]}' "$LAB/data/$t/contributions.json"; done; echo "durable check wakes queued: $(queued)"; }
echo "== 1. first live observation (baseline) =="
poll_all 4
show
echo "== 2. unchanged re-observation =="
: > "$LAB/stamp"; before=$(queued)
# force every URL to be re-read by spending several polls
for t in openpr revpr draftpr; do jq '.records[0].checked_at="2000-01-01T00:00:00Z"' "$LAB/data/$t/contributions.json" > "$LAB/x" && mv "$LAB/x" "$LAB/data/$t/contributions.json"; done
for i in 1 2 3; do run "$C" poll; done
show
echo "== 3. prior state rewritten: openpr old head, revpr no reviewers, draftpr prior non-draft, mergedpr prior open w/ old head =="
mut() { jq "$2" "$LAB/data/$1/contributions.json" > "$LAB/x" && mv "$LAB/x" "$LAB/data/$1/contributions.json"; }
mut openpr '.records[0].observation.head="1111111111111111111111111111111111111111" | .records[0].observation.draft=true'
mut revpr '.records[0].observation.review_requests=[]'
mut draftpr '.records[0].observation.draft=false | .records[0].observation.review_requests=[.records[0].observation.review_requests[0]]'
mut mergedpr '.records[0].observation.state="open" | .records[0].observation.head="2222222222222222222222222222222222222222"'
for i in 1 2 3; do run "$C" poll; done
show
echo "== 4. pending view =="
run "$C" pending | jq -c '.[] | {task,type,body,source}'
echo "== 5. re-poll after movement (no new wakes expected) =="
w=$(queued); for i in 1 2 3; do run "$C" poll; done; echo "wakes before=$w after=$(queued)"
echo "== 6. ack head signal on openpr =="
tok=$(run "$C" pending | jq -r '.[] | select(.task=="openpr" and .type=="head") | .token')
run "$C" ack openpr "$OPEN" "$tok" && echo "acked $tok"
run "$C" pending | jq -c '[.[] | {task,type}]'
echo "== wake queue =="
cut -f3- "$LAB/state/.wake-queue"
