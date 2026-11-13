#!/usr/bin/env bash
# Live drive of bin/fm-contributions.sh ack receipts in disposable homes.
# Usage: drive-ack-receipts.sh <repo-root> [base]
# The forge is a local fake `gh` on PATH with synthetic PR o/r#8 and issue o/r#9.
# Every other command is the real product script from <repo-root>/bin.
set -u
ROOT=$1
MODE=${2:-head}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-ack-drive.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/o/r/pull/8
FAILS=0
RC=0
H=

with_home() {
  PATH="$H/fakebin:$PATH" FORGE="$H/forge" FM_HOME="$H" FM_ROOT_OVERRIDE="$H/root" \
    FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}
c() { # run fm-contributions.sh and show the transcript
  local out
  printf '$ fm-contributions.sh'; printf ' %q' "$@"; printf '\n'
  out=$(with_home "$ROOT/bin/fm-contributions.sh" "$@" 2>&1); RC=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  printf '[exit %s]\n' "$RC"
}
want() { # expected exit of the last command
  if [ "$RC" = "$1" ]; then printf 'OK   exit %s as expected: %s\n' "$1" "$2"
  else printf 'FAIL expected exit %s, got %s: %s\n' "$1" "$RC" "$2"; FAILS=$((FAILS + 1)); fi
}
pending_tokens() { with_home "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[] | {task,type,token,source}]'; }
want_pending() {
  local n
  n=$(with_home "$ROOT/bin/fm-contributions.sh" pending | jq length)
  if [ "$n" = "$1" ]; then printf 'OK   pending signals = %s: %s\n' "$1" "$2"
  else printf 'FAIL pending signals = %s, expected %s: %s\n' "$n" "$1" "$2"; FAILS=$((FAILS + 1)); fi
}
want_json() { # file jq-filter label
  if jq -e "$2" "$1" >/dev/null 2>&1; then printf 'OK   %s\n' "$3"
  else printf 'FAIL %s\n' "$3"; FAILS=$((FAILS + 1)); fi
}
receipts() { printf 'receipts in data/%s/contributions.json: ' "$1"; jq -c '[.records[] | .receipts // [] | .[]]' "$H/data/$1/contributions.json"; }
token() { with_home "$ROOT/bin/fm-contributions.sh" pending | jq -er --arg t "$1" 'first(.[] | select(.type == $t)) | .token'; }
steer() { # the durable steering-inbox record fm-send.sh writes, through the same library
  printf '$ steer %s: %s\n' "$1" "$2"
  ( . "$ROOT/bin/fm-task-inbox-lib.sh" && fm_task_inbox_write "$H/state" "$1" "$2" >/dev/null )
}
poll() { local check; for check in "$H/state/"*.check.sh; do [ -f "$check" ] && with_home bash "$check" >/dev/null; done; }

home() { # name: one live task `delivery` owning PR 8, observed once
  H="$TMP/$1"
  mkdir -p "$H/data/delivery" "$H/state" "$H/config" "$H/projects" "$H/fakebin" "$H/forge" "$H/root/bin" "$H/wt"
  printf '# Backlog\n\n## Queued\n' > "$H/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$H/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$H" > "$H/state/delivery.meta"
  chmod 600 "$H/state/delivery.meta"
  printf -- '- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$URL" >> "$H/data/backlog.md"
  printf '%s\n' "$HEAD_A" > "$H/forge/head"
  for f in comments reviews inline threads labels events; do printf '[]\n' > "$H/forge/$f.json"; done
  cat > "$H/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:false,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api graphql '*)
    jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$H/fakebin/"* "$H/root/bin/fm-guard.sh"
  with_home "$ROOT/bin/fm-pr-check.sh" delivery "$URL" >/dev/null || { echo "FAIL could not register delivery"; exit 2; }
  poll
}
review() { # id state body: a maintainer review arrives on the forge
  jq --arg head "$HEAD_A" --argjson id "$1" --arg state "$2" --arg body "$3" '. + [{id:$id,user:{login:"maintainer"},
    author_association:"OWNER",body:$body,html_url:("https://github.com/o/r/pull/8#pullrequestreview-" + ($id|tostring)),
    submitted_at:"2026-09-16T08:01:00Z",commit_id:$head,state:$state}]' "$H/forge/reviews.json" > "$H/forge/r.tmp"
  mv "$H/forge/r.tmp" "$H/forge/reviews.json"
  printf '(forge) maintainer submits %s review %s with body: "%s"\n' "$2" "$1" "$3"
}
section() { printf '\n=== %s ===\n' "$1"; }

if [ "$MODE" = base ]; then
  section "BASE 427056c4: reproduce issue 8046 - token alone clears an APPROVED review that carries findings"
  home repro
  review 12 APPROVED 'Approved, but the retry loop drops errors and the cache never expires'; poll
  pending_tokens
  T=$(token review)
  c ack delivery "$URL" "$T"
  want 0 'base clears the findings with no receipt (the reported defect)'
  want_pending 0 'the review is gone and the worker was never told'
  printf '\nFAILS=%s\n' "$FAILS"; exit "$FAILS"
fi

section "S1: token alone no longer clears an APPROVED review that carries findings"
home s1
review 12 APPROVED 'Approved, but the retry loop drops errors and the cache never expires'; poll
pending_tokens
T=$(token review)
c ack delivery "$URL" "$T"
want 1 'token-only ack of a review with findings is refused'
want_pending 1 'the review stays pending'

section "S2: handoff needs a steering-inbox record of the owning task that names the review source"
c ack delivery "$URL" "$T" handoff
want 1 'handoff with an empty steering inbox is refused'
steer delivery 'Read https://github.com/o/r/pull/8#pullrequestreview-123 and fix it'
c ack delivery "$URL" "$T" handoff
want 1 'a steer naming review 123 (review 12 is only a prefix of it) is refused'
want_pending 1 'the review stays pending after refused handoffs'
steer delivery 'Read https://github.com/o/r/pull/8#pullrequestreview-12 and fix the retry loop'
c ack delivery "$URL" "$T" handoff
want 0 'handoff accepted once a steer names the review source'
want_pending 0 'the handed-off review left pending'
receipts delivery
want_json "$H/data/delivery/contributions.json" \
  ".records[0].receipts == [{token:\"$T\",task:\"delivery\",kind:\"handoff\",ref:\"002.msg\",at:\"$NOW\"}]" \
  'receipt is bound to the event token and owning task and names the matching steer 002.msg'

section "S3: a steer the worker already handled (moved to handled/) also earns the handoff"
home s3
review 12 CHANGES_REQUESTED 'The retry loop drops errors'; poll
T=$(token review)
steer delivery 'Read https://github.com/o/r/pull/8#pullrequestreview-12 and fix it'
mkdir -p "$H/state/delivery.inbox/handled"
mv "$H/state/delivery.inbox/001.msg" "$H/state/delivery.inbox/handled/001.msg"
printf '$ mv state/delivery.inbox/001.msg state/delivery.inbox/handled/001.msg\n'
c ack delivery "$URL" "$T" handoff
want 0 'handled steer accepted as the handoff'
receipts delivery

section "S4: disposition needs different evidence on the same pull request and a written reason"
home s4
review 12 CHANGES_REQUESTED 'The retry loop drops errors'; poll
T=$(token review)
c ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" 'approved, non-blocking'
want 1 'citing the signal itself is refused while the task is live'
c ack delivery "$URL" "$T" disposition 'https://github.com/o/r/pull/80#issuecomment-40' 'covered elsewhere'
want 1 'evidence on another pull request (pull/80) is refused'
c ack delivery "$URL" "$T" disposition "$URL" 'covered elsewhere'
want 1 'the bare contribution URL with no comment or review fragment is refused'
c ack delivery "$URL" "$T" disposition "$URL#issuecomment-40" '   '
want 1 'a blank reason is refused'
c ack delivery "$URL" "$T" disposition
want 1 'disposition with no evidence and no reason is refused'
c ack delivery "$URL" "$T" bogus
want 1 'an unknown receipt kind is refused'
want_pending 1 'the review stays pending after every refused disposition'
c ack delivery "$URL" "$T" disposition "$URL#issuecomment-40" 'author replied that the loop is bounded by the caller'
want 0 'disposition accepted with different evidence on the same pull request and a reason'
want_pending 0 'the disposed review left pending'
receipts delivery
want_json "$H/data/delivery/contributions.json" \
  ".records[0].receipts == [{token:\"$T\",task:\"delivery\",kind:\"disposition\",ref:\"$URL#issuecomment-40\",summary:\"author replied that the loop is bounded by the caller\",at:\"$NOW\"}]" \
  'disposition receipt stores token, task, evidence and reason'

section "S5: an inline review comment also needs a receipt"
home s5
jq -n --arg head "$HEAD_A" '[{id:21,user:{login:"maintainer"},author_association:"OWNER",commit_id:$head,
  body:"P1: unchecked error",html_url:"https://github.com/o/r/pull/8#discussion_r21",
  created_at:"2026-09-16T08:01:00Z",updated_at:"2026-09-16T08:01:00Z"}]' > "$H/forge/inline.json"
printf '(forge) maintainer leaves inline comment discussion_r21\n'; poll
pending_tokens
T=$(token review-comment)
c ack delivery "$URL" "$T"
want 1 'token-only ack of an inline review comment is refused'
want_pending 1 'the inline comment stays pending'
steer delivery 'Fix https://github.com/o/r/pull/8#discussion_r21'
c ack delivery "$URL" "$T" handoff
want 0 'inline comment acknowledged with a handoff'

section "S6: signals without findings still acknowledge with the token alone"
home s6
review 12 APPROVED ''; poll
T=$(token review)
c ack delivery "$URL" "$T"
want 0 'an approval with no text acknowledges with the token alone'
jq -n '[{id:40,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks, will look next week",
  html_url:"https://github.com/o/r/pull/8#issuecomment-40",updated_at:"2026-09-16T08:02:00Z"}]' > "$H/forge/comments.json"
printf '(forge) maintainer posts issue comment 40\n'; poll
pending_tokens
T=$(token comment)
c ack delivery "$URL" "$T"
want 0 'an issue comment acknowledges with the token alone'
printf '[]\n' > "$H/forge/comments.json"
printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$H/data/backlog.md"
poll
printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$H/forge/events.json"
printf '[{"name":"ready-for-pr"}]\n' > "$H/forge/labels.json"
printf '(forge) issue 9 is labelled ready-for-pr\n'; poll
pending_tokens
T=$(token ready-for-pr)
c ack filed https://github.com/o/r/issues/9 "$T"
want 0 'a ready-for-pr transition acknowledges with the token alone'
want_pending 0 'nothing is left pending'
want_json "$H/data/delivery/contributions.json" '[.records[] | .receipts // [] | .[]] == []' 'token-only acknowledgements store no receipt'

section "S7: a receipt clears only its own token and only for the owning task"
home s7
review 12 CHANGES_REQUESTED 'The retry loop drops errors'
review 13 CHANGES_REQUESTED 'The cache never expires'; poll
pending_tokens
T12=$(with_home "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.source | endswith("review-12")) | .token')
T13=$(with_home "$ROOT/bin/fm-contributions.sh" pending | jq -er '.[] | select(.source | endswith("review-13")) | .token')
steer delivery 'Read https://github.com/o/r/pull/8#pullrequestreview-12'
c ack delivery "$URL" "$T13" handoff
want 1 'the steer about review 12 does not hand off review 13'
c ack stranger "$URL" "$T12" handoff
want 1 'a task that does not own the pull request cannot acknowledge'
c ack delivery "$URL" "$T12" handoff
want 0 'review 12 is handed off'
want_pending 1 'review 13 is still pending'
receipts delivery

section "S8: a later owner of the same merged pull request does not inherit the receipt (settled-record copy)"
c ack delivery "$URL" "$T13" disposition "$URL#issuecomment-41" 'maintainer withdrew the cache comment'
want 0 'review 13 disposed'
printf 'merged\n' > "$H/forge/state"; printf '(forge) PR 8 is merged\n'; poll
printf -- '- [ ] latecomer - Filed %s (repo: sample) (kind: ship)\n' "$URL" >> "$H/data/backlog.md"
printf '(backlog) task latecomer now links PR 8\n'; poll
receipts delivery
receipts latecomer
want_json "$H/data/delivery/contributions.json" '.records[0].receipts | length == 2' 'the owning task keeps both receipts'
want_json "$H/data/latecomer/contributions.json" '.records[0].observation.state == "merged" and ((.records[0].receipts // []) | length == 0)' \
  'latecomer got the settled merged observation with no receipts'

section "S9: a torn-down task (state/<task>.meta removed) may dispose of a review by citing it, then retire"
home s9
review 12 CHANGES_REQUESTED 'The retry loop drops errors'; poll
T=$(token review)
printf '$ ls state/delivery.inbox -> %s; state/delivery.meta -> %s\n' \
  "$([ -e "$H/state/delivery.inbox" ] && echo present || echo absent)" "$([ -e "$H/state/delivery.meta" ] && echo present || echo absent)"
c ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" 'approved, non-blocking'
want 1 'a live never-steered task (record present, no inbox) cannot self-cite'
rm -f "$H/state/delivery.meta"; printf '$ rm state/delivery.meta   (what fm-teardown.sh does)\n'
c retire delivery "$URL" captain 'task finished'
want 1 'retire is refused while the review is pending'
c ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" '  '
want 1 'a blank reason is still refused for a torn-down task'
c ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" 'task finished and torn down; follow-up filed'
want 0 'the torn-down task disposes of the review by citing it'
receipts delivery
c retire delivery "$URL" captain 'task finished'
want 0 'retire succeeds once nothing is pending'

section "S10: unmerged closure under config/hold-pr-settle raises a closed event that acknowledges with the token alone"
home s10
touch "$H/config/hold-pr-settle"
review 12 CHANGES_REQUESTED 'The retry loop drops errors'; poll
T=$(token review)
with_home "$ROOT/bin/fm-captain-hold.sh" hold delivery --reason 'Unfinished work' >/dev/null || { echo 'FAIL hold'; FAILS=$((FAILS + 1)); }
printf '$ fm-captain-hold.sh hold delivery --reason "Unfinished work"\n'
printf 'closed\n' > "$H/forge/state"; printf '(forge) PR 8 is closed without merge\n'
c poll
pending_tokens
TC=$(token closed)
c ack delivery "$URL" "$TC"
want 0 'the closed event acknowledges with the token alone'
c ack delivery "$URL" "$T"
want 1 'the review with findings still needs a receipt after closure'
want_pending 1 'only the review remains pending'

printf '\nFAILS=%s\n' "$FAILS"
exit "$FAILS"
