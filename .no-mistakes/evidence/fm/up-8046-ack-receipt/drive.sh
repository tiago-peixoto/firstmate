#!/usr/bin/env bash
# Live drive of bin/fm-contributions.sh in a disposable home.
# The only stand-in is `gh` (a local emulator of the GitHub API with synthetic PR o/r#8).
# usage: drive.sh <scenario> <bin-root> <home>
set -u
SCEN=$1 ROOT=$2 HOME_DIR=$3
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/o/r/pull/8
C="$ROOT/bin/fm-contributions.sh"
h=$HOME_DIR
rm -rf "$h"
mkdir -p "$h/data/delivery" "$h/state" "$h/config" "$h/projects" "$h/fakebin" "$h/forge" "$h/root/bin" "$h/wt"
printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship) \n' "$URL" > "$h/data/backlog.md"
printf '#!/bin/sh\nexit 1\n' > "$h/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$h/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$h/root/bin/fm-guard.sh"
printf 'worktree=%s/wt\nkind=ship\n' "$h" > "$h/state/delivery.meta"; chmod 600 "$h/state/delivery.meta"
jq -n --arg url "$URL" --arg head "$HEAD_A" --arg at "$NOW" '
  {schema:"fm-contributions.v1",task:"delivery",records:[{url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
   observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,
   checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],reviews:[],events:[]}}]}' > "$h/data/delivery/contributions.json"
printf '%s\n' "$HEAD_A" > "$h/forge/head"
for f in comments reviews inline threads; do printf '[]\n' > "$h/forge/$f.json"; done
cat > "$h/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" '{state:"open",user:{login:"author"},head:{sha:$head},draft:false,mergeable:true,merged_at:null}' ;;
  'api repos/o/r/issues/'*'/events?'*) printf '[]\n' ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api graphql '*) jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*) printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$h/fakebin/"* "$h/root/bin/fm-guard.sh"

fm() { # run the real script inside the disposable home
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS PATH="$h/fakebin:$PATH" FORGE="$h/forge" FM_HOME="$h" FM_ROOT_OVERRIDE="$h/root" \
    FM_STATE_OVERRIDE="$h/state" FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" \
    FM_CONTRIBUTIONS_NOW="${AT:-$NOW}" ${REPLY_AGE:+FM_CONTRIBUTIONS_REPLY_AGE=$REPLY_AGE} "$@"
}
run() { # print the command, its combined output and its exit status
  local rc; printf '$ fm-contributions.sh'; printf ' %q' "$@"; printf '\n'
  fm "$C" "$@" 2>&1; rc=$?; printf '[exit %s]\n' "$rc"; return 0
}
token() { fm "$C" pending | jq -er "${1:-first} | .token"; }
saved() { printf -- '--- saved record: pending tokens, receipts, event previews\n'
  jq -c '.records[0] | {pending:[.pending[].token],has_receipts:has("receipts"),receipts:(.receipts // null),
    previews:[.observation.events[]? | {type,body}]}' "$h/data/delivery/contributions.json"; }
steer() { ( . "$ROOT/bin/fm-task-inbox-lib.sh" && fm_task_inbox_write "$h/state" "$1" "$2" ) ; }
review() { # state body
  jq -n --arg head "$HEAD_A" --arg state "$1" --arg body "$2" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:$body,html_url:"https://github.com/o/r/pull/8#pullrequestreview-12",
    submitted_at:"2026-09-16T08:01:00Z",commit_id:$head,state:$state}]' > "$h/forge/reviews.json"; }
inline() { jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",
    body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head}]' > "$h/forge/inline.json"; }
PADDED="$(printf '%600s' '')The retry loop drops errors"

default_flow() { # token-only ack of a finding-carrying approved review, then receipt arguments
  review APPROVED "$PADDED"
  run poll; run pending
  t=$(token) || { echo 'NO PENDING SIGNAL'; return; }
  run ack delivery "$URL" "$t"; saved
  run ack delivery "$URL" "$t" handoff
  run ack delivery "$URL" "$t" disposition "$URL#issuecomment-40" 'reason'
  saved
}

case "$SCEN" in
  default-unconfigured) echo "config/: $(ls "$h/config" | tr '\n' ' ')"; default_flow ;;
  default-review-bots)
    printf 'maintainer\n' > "$h/config/contribution-review-bots"; echo "config/: $(ls "$h/config" | tr '\n' ' ')"; default_flow ;;
  default-reply-age) # existing opt-in setting: inline comment, then its re-raise 25 hours later
    REPLY_AGE=86400; echo "config/: $(ls "$h/config" | tr '\n' ' ') env FM_CONTRIBUTIONS_REPLY_AGE=86400"
    inline; AT=2026-09-16T08:01:00Z run poll; run pending
    t=$(token); run ack delivery "$URL" "$t"; saved
    AT=2026-09-17T09:00:00Z run poll; run pending
    t=$(token '.[] | select(.type == "unanswered")'); run ack delivery "$URL" "$t"; saved ;;
  optin-review)
    touch "$h/config/contribution-ack-receipts"; echo "config/: $(ls "$h/config" | tr '\n' ' ')"
    review APPROVED "$PADDED"; run poll; run pending; t=$(token)
    echo '# token-only ack of an approved review that carries findings'
    run ack delivery "$URL" "$t"; saved
    echo '# handoff before any steer reached the owning worker'
    run ack delivery "$URL" "$t" handoff
    echo '# the review cited as evidence for its own disposition'
    run ack delivery "$URL" "$t" disposition "$URL#pullrequestreview-12" 'approved, non-blocking'
    echo '# evidence from another contribution, then a blank summary, then an unknown receipt kind'
    run ack delivery "$URL" "$t" disposition https://github.com/o/r/pull/99#issuecomment-40 fixed
    run ack delivery "$URL" "$t" disposition "$URL#issuecomment-40" '   '
    run ack delivery "$URL" "$t" waved
    echo '# steers that must not count: another task, and a review whose id only shares a prefix'
    steer other "Read $URL#pullrequestreview-12 and fix it"
    steer delivery "Read $URL#pullrequestreview-123 and fix it"
    run ack delivery "$URL" "$t" handoff; saved
    echo '# a steer to the owning task that names the review'
    steer delivery "Read $URL#pullrequestreview-12 and fix it"
    run ack delivery "$URL" "$t" handoff; saved
    echo '# a later poll keeps the receipt and does not raise the review again'
    run poll; saved ;;
  optin-disposition-and-inline)
    touch "$h/config/contribution-ack-receipts"; REPLY_AGE=86400; echo "config/: $(ls "$h/config" | tr '\n' ' ') env FM_CONTRIBUTIONS_REPLY_AGE=86400"
    inline; AT=2026-09-16T08:01:00Z run poll; run pending; t=$(token)
    run ack delivery "$URL" "$t"
    run ack delivery "$URL" "$t" disposition "$URL#issuecomment-40" 'author replied that the loop is bounded by the caller'; saved
    AT=2026-09-17T09:00:00Z run poll; run pending
    t=$(token '.[] | select(.type == "unanswered")')
    echo '# the re-raised unanswered thread'
    run ack delivery "$URL" "$t"; saved ;;
  optin-no-findings) # flag on: an approved review with no text and a plain PR comment
    touch "$h/config/contribution-ack-receipts"; echo "config/: $(ls "$h/config" | tr '\n' ' ')"
    review APPROVED ''
    jq -n '[{id:40,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks, looks good",
      html_url:"https://github.com/o/r/pull/8#issuecomment-40",updated_at:"2026-09-16T08:01:00Z"}]' > "$h/forge/comments.json"
    run poll; run pending
    for t in $(fm "$C" pending | jq -r '.[].token'); do run ack delivery "$URL" "$t"; done; saved ;;
  flag-toggle) # contents ignored; removing the file restores token-only ack and keeps saved receipts
    printf 'false\n' > "$h/config/contribution-ack-receipts"; echo "config/contribution-ack-receipts contains: false"
    review CHANGES_REQUESTED 'The retry loop drops errors'; run poll; t=$(token)
    run ack delivery "$URL" "$t"
    steer delivery "Read $URL#pullrequestreview-12 and fix it"
    run ack delivery "$URL" "$t" handoff; saved
    echo '# a second review arrives; the flag file is removed'
    jq --arg head "$HEAD_A" '. + [{id:13,user:{login:"maintainer"},author_association:"OWNER",body:"The cache never expires",
      html_url:"https://github.com/o/r/pull/8#pullrequestreview-13",submitted_at:"2026-09-16T08:02:00Z",commit_id:$head,state:"COMMENTED"}]' \
      "$h/forge/reviews.json" > "$h/forge/r.json" && mv "$h/forge/r.json" "$h/forge/reviews.json"
    run poll; t=$(token)
    run ack delivery "$URL" "$t"
    rm "$h/config/contribution-ack-receipts"; echo "config/: $(ls "$h/config" | tr '\n' ' ')"
    run ack delivery "$URL" "$t"; saved
    run ack delivery "$URL" "$t" handoff ;;
esac
