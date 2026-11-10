#!/usr/bin/env bash
# Live drive of fm-contributions.sh ack receipts against a disposable home and a fake gh forge.
set -u
ROOT=$1; H=$(mktemp -d /tmp/fm-live-8046/home.XXXX); "$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null
NOW=2026-09-16T08:00:00Z; HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$H"/{data/delivery,state,config,projects,fakebin,forge,root/bin,wt}
printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$H/root/bin/fm-guard.sh"; chmod +x "$H"/fakebin/* "$H/root/bin/fm-guard.sh"
printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' > "$H/data/backlog.md"
printf 'worktree=%s/wt\nkind=ship\nwindow=fm-lab:fm-delivery\nharness=claude\n' "$H" > "$H/state/delivery.meta"; chmod 600 "$H/state/delivery.meta"
echo "$HEAD_A" > "$H/forge/head"; for f in comments reviews inline threads labels events; do echo '[]' > "$H/forge/$f.json"; done
awk '/cat > "\$home\/fakebin\/gh" <<.SH./{f=1;next} f&&/^SH$/{exit} f' "$ROOT/tests/fm-contributions.test.sh" > "$H/fakebin/gh"; chmod +x "$H/fakebin/gh"
run() { PATH="$H/fakebin:$PATH" FORGE="$H/forge" FM_HOME="$H" FM_ROOT_OVERRIDE="$H/root" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_CONTRIBUTIONS_NOW="$NOW" "$@"; }
C="$ROOT/bin/fm-contributions.sh"; U=https://github.com/o/r/pull/8
send() { say "${*/#$ROOT\//}"; PATH="$H/fakebin:$PATH" FM_HOME="$H" "$@"; echo "[exit=$?]"; }
say() { printf '\n$ %s\n' "$*"; }
cmd() { say "${*/#$ROOT\//}"; run "$@"; echo "[exit=$?]"; }
poll() { run "$C" poll >/dev/null 2>&1 || echo "[poll exit=$?]"; }
review() { jq -n --arg h "$HEAD_A" --arg s "$1" --arg b "$2" --argjson id "$3" '[{id:$id,user:{login:"maintainer"},author_association:"OWNER",body:$b,
  html_url:"https://github.com/o/r/pull/8#pullrequestreview-\($id)",submitted_at:"2026-09-16T08:0\($id%10):00Z",commit_id:$h,state:$s}]' > "$H/forge/reviews.json"; }
tok() { run "$C" pending | jq -r --arg t "$1" '[.[]|select(.type==$t)]|last|.token'; }
jq -n --arg h "$HEAD_A" --arg at "$NOW" '{schema:"fm-contributions.v1",task:"delivery",records:[{url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,observation:{head:$h,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,checks:[],reviews:[],events:[]}}]}' > "$H/data/delivery/contributions.json"
echo "== disposable lab home $H seeded with owned delivery https://github.com/o/r/pull/8 =="

echo; echo "== S1: approved review WITH findings, token-only ack is refused =="
review APPROVED 'Approved, but the retry loop drops errors' 12; poll
cmd "$C" pending; T=$(tok review)
cmd "$C" ack delivery $U "$T"
cmd "$C" ack delivery $U "$T" disposition $U#pullrequestreview-12 'approved, non-blocking'
cmd "$C" ack delivery $U "$T" disposition https://github.com/o/r/pull/99#issuecomment-4 'fixed elsewhere'
cmd "$C" ack delivery $U "$T" disposition $U#issuecomment-40 '   '
cmd "$C" ack delivery $U "$T" handoff
echo "== S2: steer to wrong review (prefix review-123) and to another task do not count =="
send "$ROOT/bin/fm-send.sh" delivery "Read $U#pullrequestreview-123 and fix it"
printf 'worktree=%s/wt\nkind=ship\nwindow=fm-lab:fm-other\nharness=claude\n' "$H" > "$H/state/other.meta"; chmod 600 "$H/state/other.meta"
send "$ROOT/bin/fm-send.sh" other "Read $U#pullrequestreview-12 and fix it"
cmd "$C" ack delivery $U "$T" handoff
echo "== S3: real fm-send steer naming the review, then handoff succeeds =="
send "$ROOT/bin/fm-send.sh" delivery "Read $U#pullrequestreview-12 and fix it"
ls "$H/state/delivery.inbox"
cmd "$C" ack delivery $U "$T" handoff
cmd "$C" pending
say "jq .records[0].receipts data/delivery/contributions.json"; jq .records[0].receipts "$H/data/delivery/contributions.json"
poll; say "after another poll: pending + receipts"; run "$C" pending; jq -c '.records[0].receipts' "$H/data/delivery/contributions.json"

echo; echo "== S4: CHANGES_REQUESTED review, disposition citing other evidence on same PR =="
review CHANGES_REQUESTED 'The cache never expires' 13; poll; T=$(tok review)
cmd "$C" ack delivery $U "$T"
cmd "$C" ack delivery $U "$T" disposition $U#issuecomment-40 'author replied that the caller bounds the cache'
say "receipts"; jq '.records[0].receipts' "$H/data/delivery/contributions.json"

echo; echo "== S5: signals without findings ack with the token alone =="
review APPROVED '' 14; poll; T=$(tok review)
cmd "$C" ack delivery $U "$T"
jq -n '[{id:15,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks!",html_url:"https://github.com/o/r/pull/8#issuecomment-15",updated_at:"2026-09-16T08:05:00Z"}]' > "$H/forge/comments.json"; poll
T=$(tok comment); cmd "$C" pending
cmd "$C" ack delivery $U "$T"
cmd "$C" pending
echo "HOME=$H"
