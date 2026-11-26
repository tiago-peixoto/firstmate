#!/usr/bin/env bash
# Drives bin/fm-contributions.sh and bin/fm-captain-hold.sh in disposable homes with the
# test suite's fake `gh` forge. usage: drive.sh <worktree> <root-under-test> <tmp-root> parity|optin
set -u
WT=$1; ROOT=$2; TMP_ROOT=$3; PART=$4
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fail() { printf 'DRIVER SETUP FAILED - %s\n' "$1"; exit 1; }
# fixture helpers only (homes, fake gh, steering-inbox writer); every product call goes to $ROOT/bin
source <(sed -n '11,19p;27,45p;107,172p;1845,1857p;2100,2102p' "$WT/tests/fm-contributions.test.sh")
PR=https://github.com/o/r/pull/8
norm() { sed -e "s#$TMP_ROOT#<HOME-ROOT>#g" -e "s#$ROOT#<ROOT>#g"; }
say() { printf '\n### %s\n' "$*"; }
run() { # home label cmd...: transcript line, output, exit code
  local home=$1 label=$2 rc; shift 2
  printf '$ %s\n' "$label"
  with_home "$home" "$@" 2>&1 | norm; rc=${PIPESTATUS[0]}
  printf '[exit %s]\n' "$rc"
}
c() { run "$1" "fm-contributions.sh ${*:2}" "$ROOT/bin/fm-contributions.sh" "${@:2}"; }
h() { run "$1" "fm-captain-hold.sh ${*:2}" "$ROOT/bin/fm-captain-hold.sh" "${@:2}"; }
rec() { printf '$ jq %s data/%s/contributions.json\n' "$3" "$2"; jq -c "$3" "$1/data/$2/contributions.json" | norm; }
tok() { with_home "$1" "$ROOT/bin/fm-contributions.sh" pending | jq -er "${2:-first} | .token"; }
review() { # home state body [id]
  jq -n --arg head "$HEAD_A" --arg state "$2" --arg body "$3" --argjson id "${4:-12}" '[{id:$id,user:{login:"maintainer"},author_association:"OWNER",
    body:$body,html_url:"https://github.com/o/r/pull/8#pullrequestreview-\($id)",
    submitted_at:"2026-09-16T08:01:00Z",commit_id:$head,state:$state}]' > "$1/forge/reviews.json"
}
start() { # name [flag]: registered delivery home
  local home; home=$(new_home "$1"); forge_home "$home"
  [ -z "${2:-}" ] || touch "$home/config/contribution-ack-receipts"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery $PR >/dev/null || fail 'register'
  registered_checks "$home" >/dev/null; printf '%s\n' "$home"
}
PREVIEW='.records[0] | {pending:[.pending[]|{token,type}], has_receipts:has("receipts"), receipts:(.receipts // null), event_bodies:[.observation.events[]|.body]}'

if [ "$PART" = parity ]; then
  for mode in unconfigured existing-settings; do
    say "PARITY $mode home (no config/contribution-ack-receipts)"
    home=$(new_home "parity-$mode"); forge_home "$home"
    if [ "$mode" = existing-settings ]; then
      printf 'maintainer\n' > "$home/config/contribution-review-bots"; touch "$home/config/hold-pr-settle"
      sed -i '/ delivery /s/$/ (hold: wait for the scope decision) (hold-kind: captain)/' "$home/data/backlog.md"
      poll() { with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=86400 FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll 2>&1 | norm; printf '[poll exit %s]\n' "${PIPESTATUS[0]}"; }
    else
      poll() { with_home "$home" env FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll 2>&1 | norm; printf '[poll exit %s]\n' "${PIPESTATUS[0]}"; }
    fi
    echo "config: $(ls "$home/config" | tr '\n' ' ')"
    with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery $PR >/dev/null || fail register
    registered_checks "$home" >/dev/null
    review "$home" APPROVED "$(printf '%600s' '')Approved, but the retry loop drops errors"
    jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",body:"Why is this retried?",
      html_url:"https://github.com/o/r/pull/8#discussion_r31",created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head}]' > "$home/forge/inline.json"
    poll 2026-09-16T08:02:00Z
    c "$home" pending
    rt=$(tok "$home" '.[] | select(.type=="review")') || fail 'no review'
    it=$(tok "$home" '.[] | select(.type=="review-comment")') || fail 'no inline'
    say "receipt arguments are not part of the interface"
    c "$home" ack delivery $PR "$rt" handoff
    c "$home" ack delivery $PR "$rt" disposition "$PR#issuecomment-99" 'not actionable'
    say "token-only ack of a review with findings and of an inline comment"
    c "$home" ack delivery $PR "$rt"
    c "$home" ack delivery $PR "$it"
    rec "$home" delivery "$PREVIEW"
    say "one day later"
    poll 2026-09-17T09:00:00Z
    c "$home" pending
    if ut=$(tok "$home" '.[] | select(.type=="unanswered")'); then
      c "$home" ack delivery $PR "$ut"
      rec "$home" delivery "$PREVIEW"
    fi
    say "saved record with an unknown receipts field, then hold settlement on merge"
    mutate_record "$home" delivery '.records[0].receipts=[{}]'
    c "$home" pending
    if [ "$mode" = existing-settings ]; then
      h "$home" hold delivery --reason 'Merge this PR?'
      h "$home" pr-policy delivery $PR terminal close
      mutate_record "$home" delivery '.records[0].observation.state="merged"'
      h "$home" settle-pr delivery $PR
      h "$home" open delivery
    fi
  done
  exit 0
fi

say "1. flag present: approved review with findings (text after 600 spaces)"
home=$(start refuse flag); echo "config: $(ls "$home/config" | tr '\n' ' ')"
review "$home" APPROVED "$(printf '%600s' '')Approved, but the retry loop drops errors"; registered_checks "$home" >/dev/null
c "$home" pending
t=$(tok "$home") || fail 'no review'
c "$home" ack delivery $PR "$t"
echo "pending after refusal: $(pending_count "$home")"
say "2. handoff needs a steering-inbox record naming this exact review"
c "$home" ack delivery $PR "$t" handoff
steer "$home" delivery "Read $PR#pullrequestreview-123 and fix it"
echo "(steered the worker about review 123, a different review)"
c "$home" ack delivery $PR "$t" handoff
echo "pending: $(pending_count "$home")"
say "3. disposition guards"
c "$home" ack delivery $PR "$t" disposition "$PR#pullrequestreview-12" 'approved, non-blocking'
c "$home" ack delivery $PR "$t" disposition "https://github.com/o/r/pull/9#issuecomment-5" 'answered elsewhere'
c "$home" ack delivery $PR "$t" disposition "$PR#issuecomment-99" '   '
c "$home" ack delivery $PR "$t" disposition "$PR#issuecomment-99"
c "$home" ack delivery $PR "$t" waived
c "$home" ack delivery $PR "$t" handoff extra
echo "pending after every refusal: $(pending_count "$home")"; rec "$home" delivery '.records[0] | has("receipts")'
say "4. handoff accepted once the owning worker is steered with the review"
steer "$home" delivery "Read $PR#pullrequestreview-12 and fix it"
ls "$home/state/delivery.inbox" | sed 's/^/inbox: /'
c "$home" ack delivery $PR "$t" handoff
echo "pending: $(pending_count "$home")"; rec "$home" delivery '.records[0].receipts'

say "5. handoff follows a steer the worker already handled (moved to handled/)"
home=$(start handled flag); review "$home" CHANGES_REQUESTED 'The retry loop drops errors'; registered_checks "$home" >/dev/null
t=$(tok "$home") || fail 'no review'
steer "$home" delivery "Read $PR#pullrequestreview-12 and fix it"
mv "$home/state/delivery.inbox/001.msg" "$home/state/delivery.inbox/handled/001.msg" || fail mv
(cd "$home/state/delivery.inbox" && find . -name '*.msg' | sort | sed 's/^/inbox: /')
c "$home" ack delivery $PR "$t" handoff
echo "pending: $(pending_count "$home")"; rec "$home" delivery '.records[0].receipts'

say "6. disposition accepted with a different comment on this contribution as evidence"
home=$(start dispose flag); review "$home" COMMENTED 'Consider renaming the helper'; registered_checks "$home" >/dev/null
t=$(tok "$home") || fail 'no review'
c "$home" ack delivery $PR "$t" disposition "$PR#issuecomment-99" 'maintainer withdrew the suggestion in the cited comment'
echo "pending: $(pending_count "$home")"; rec "$home" delivery '.records[0].receipts'

say "7. signals without findings still acknowledge with the token alone"
home=$(start nofinding flag); review "$home" APPROVED ''
printf '{"id":77,"user":{"login":"maintainer"},"author_association":"OWNER","body":"Thanks, looking","html_url":"%s#issuecomment-77","created_at":"2026-09-16T08:01:00Z","updated_at":"2026-09-16T08:01:00Z"}\n' "$PR" > "$home/forge/comments.json"
printf '[%s]\n' "$(cat "$home/forge/comments.json")" > "$home/forge/comments.json"
registered_checks "$home" >/dev/null
c "$home" pending
for t in $(with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -r '.[].token'); do c "$home" ack delivery $PR "$t"; done
echo "pending: $(pending_count "$home")"; rec "$home" delivery '.records[0] | has("receipts")'

say "8. inline comment and its re-raise one day later both need a receipt"
home=$(unanswered_home inline); touch "$home/config/contribution-ack-receipts"
poll_at "$home" 2026-09-16T08:01:00Z >/dev/null || fail poll
t=$(tok "$home") || fail 'no inline'
c "$home" ack delivery $PR "$t"
steer "$home" delivery "Answer $PR#discussion_r31"
c "$home" ack delivery $PR "$t" handoff
poll_at "$home" 2026-09-17T09:00:00Z >/dev/null || fail poll
c "$home" pending
t=$(tok "$home" '.[] | select(.type=="unanswered")') || fail 'no reraise'
c "$home" ack delivery $PR "$t"
echo "pending: $(pending_count "$home")"

say "9. malformed saved receipt: unreadable with the flag, ignored without it; hold settlement"
home=$(new_home malformed); forge_home "$home"; touch "$home/config/hold-pr-settle" "$home/config/contribution-ack-receipts"
h "$home" hold delivery --reason 'Merge this PR?'
h "$home" pr-policy delivery $PR terminal close
mutate_record "$home" delivery '.records[0].observation.state="merged" | .records[0].receipts=[{"token":"review:12","task":"delivery","kind":"disposition","ref":"x","at":"2026-09-16T08:00:00Z"}]'
echo "(saved a disposition receipt with no summary)"
c "$home" pending
h "$home" settle-pr delivery $PR
h "$home" open delivery
mutate_record "$home" delivery '.records[0].receipts[0].summary="withdrawn by the maintainer"'
echo "(repaired the receipt)"
c "$home" pending
h "$home" settle-pr delivery $PR
h "$home" open delivery

say "10. late owner of a merged PR gets no receipt, also when the flag is removed and returns"
home=$(start late flag); review "$home" CHANGES_REQUESTED 'The retry loop drops errors'; registered_checks "$home" >/dev/null
t=$(tok "$home") || fail 'no review'
steer "$home" delivery "Read $PR#pullrequestreview-12"
c "$home" ack delivery $PR "$t" handoff
rm "$home/config/contribution-ack-receipts"; echo "(removed the flag; PR merges; task latecomer links the same PR)"
printf 'merged\n' > "$home/forge/state"; registered_checks "$home" >/dev/null
printf -- '- [ ] latecomer - Filed %s (repo: sample) (kind: ship)\n' "$PR" >> "$home/data/backlog.md"
registered_checks "$home" >/dev/null
touch "$home/config/contribution-ack-receipts"; echo "(flag created again)"
c "$home" pending
rec "$home" delivery '.records[0].receipts'
rec "$home" latecomer '.records[0] | {state:.observation.state, has_receipts:has("receipts")}'

say "11. only the one new file turns enforcement on"
home=$(start gate); review "$home" APPROVED 'The retry loop drops errors'
printf 'maintainer\ncontribution-ack-receipts\n' > "$home/config/contribution-review-bots"
touch "$home/config/hold-pr-settle" "$home/config/supervision-host" "$home/config/contribution-ack-receipt" "$home/config/contribution-ack-receipts.bak"
echo "config: $(ls "$home/config" | tr '\n' ' ')"
with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=86400 "$ROOT/bin/fm-contributions.sh" poll >/dev/null || fail poll
t=$(tok "$home") || fail 'no review'
c "$home" ack delivery $PR "$t" handoff
printf 'false\n' > "$home/config/contribution-ack-receipts"; echo "(created config/contribution-ack-receipts containing the word false)"
c "$home" ack delivery $PR "$t"
rm "$home/config/contribution-ack-receipts"; echo "(removed config/contribution-ack-receipts)"
c "$home" ack delivery $PR "$t"
echo "pending: $(pending_count "$home")"; rec "$home" delivery '.records[0] | has("receipts")'
