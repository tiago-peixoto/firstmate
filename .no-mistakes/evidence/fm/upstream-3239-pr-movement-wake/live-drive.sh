#!/usr/bin/env bash
# Live drive: real bin/ scripts from the run worktree, real gh against real
# GitHub (read-only), disposable lab FM_HOME. Movement is produced by rewriting
# the lab's stored previous observation, because the test may not change a real
# pull request.
set -u
LAB=$1
PR=https://github.com/kunchenguid/firstmate/pull/5341
RPR=https://github.com/cli/cli/pull/$2
MPR=https://github.com/kunchenguid/firstmate/pull/6028
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"; }
poll() { fm bash "$LAB/state/contributions.check.sh"; echo "  check exit=$? (output above is what the watcher would surface)"; }
wakes() { [ -f "$LAB/state/.wake-queue" ] && awk -F '\t' 'NF >= 5 && $3 == "check" {c++} END {print c+0}' "$LAB/state/.wake-queue" || echo 0; }
show() { echo "  durable check wakes queued: $(wakes)"; echo "  pending: $(fm bin/fm-contributions.sh pending | jq -c '[.[] | {task,type,body,source}]')"; }
seed() { jq "$2" "$LAB/data/$1/contributions.json" > "$LAB/seed.tmp" && mv "$LAB/seed.tmp" "$LAB/data/$1/contributions.json"; }
ackall() { fm bin/fm-contributions.sh pending | jq -r '.[] | [.task,.source,.token] | @tsv' | while IFS=$'\t' read -r t s k; do fm bin/fm-contributions.sh ack "$t" "$s" "$k" && echo "  acked $k"; done; }
step() { printf '\n=== %s ===\n' "$*"; }

step "1. unchanged PR, repeat poll (baseline already observed): must stay quiet"
poll; show

step "2. head change: stored previous head rewritten to $A, real forge reports the real head"
seed delivery ".records[0].observation.head = \"$A\""
poll; show
step "2b. unchanged re-poll after the head wake: no second wake"
poll; show
ackall

step "3. leaving draft: stored previous observation rewritten to draft:true, real forge reports draft:false"
seed delivery '.records[0].observation.draft = true'
poll; show
step "3b. adversarial: stored draft:false -> still false is not movement"
poll; show
ackall

step "4. reviewer baseline: first observation of $RPR, which already has a requested reviewer"
printf -- '- [ ] reviewed - Reviewer fixture %s (repo: cli) (kind: ship)\n' "$RPR" >> "$LAB/data/backlog.md"
poll; show
echo "  recorded review_requests: $(jq -c '.records[0].observation.review_requests' "$LAB/data/reviewed/contributions.json")"

step "5. legacy baseline: stored observation with no review_requests field at all"
seed reviewed '.records[0].observation |= del(.review_requests)'
poll; show

step "6. newly requested reviewer: stored previous review_requests rewritten to []"
seed reviewed '.records[0].observation.review_requests = []'
poll; show
step "6b. unchanged re-poll: no second wake"
poll; show
ackall

step "7. settlement is not movement: stored open observation with head $A, real forge reports $MPR merged"
mkdir -p "$LAB/data/landed"
printf -- '- [ ] landed - Merged fixture %s (repo: firstmate) (kind: ship)\n' "$MPR" >> "$LAB/data/backlog.md"
jq -n --arg url "$MPR" --arg head "$A" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
  {schema:"fm-contributions.v1",task:"landed",records:[{url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
   observation:{head:$head,state:"open",draft:true,mergeable:"mergeable",review_decision:"",can_merge:false,review_requests:[],checks:[],reviews:[],events:[]}}]}' \
  > "$LAB/data/landed/contributions.json"
before=$(wakes); poll; show
echo "  landed record: $(jq -c '.records[0] | {state:.observation.state,head:.observation.head,pending,error}' "$LAB/data/landed/contributions.json")"
echo "  movement wakes added by settlement: $(( $(wakes) - before ))"

step "8. watcher end to end: quiet on the unchanged PR, then surfaces a head change once"
rc=0; fm env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 bin/fm-watch-checkpoint.sh --seconds 20 > "$LAB/w1.out" 2> "$LAB/w1.err" || rc=$?
echo "  quiet watcher exit=$rc (124 = checkpoint expired with nothing to surface)"; sed 's/^/  out: /' "$LAB/w1.out"; grep -v '●' "$LAB/w1.err" | sed 's/^/  err: /'
seed delivery ".records[0].observation.head = \"$A\""
rc=0; fm env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 bin/fm-watch-checkpoint.sh --seconds 40 > "$LAB/w2.out" 2> "$LAB/w2.err" || rc=$?
echo "  watcher after head change exit=$rc"; sed 's/^/  out: /' "$LAB/w2.out"; grep -v '●' "$LAB/w2.err" | sed 's/^/  err: /'
show
rc=0; fm env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 bin/fm-watch-checkpoint.sh --seconds 15 > "$LAB/w3.out" 2> "$LAB/w3.err" || rc=$?
echo "  repeat watcher exit=$rc"; sed 's/^/  out: /' "$LAB/w3.out"; grep -v '●' "$LAB/w3.err" | sed 's/^/  err: /'
show
