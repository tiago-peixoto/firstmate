#!/usr/bin/env bash
# Drive the real fm-pr-check.sh / fm-contributions.sh / fm-watch-checkpoint.sh
# against a disposable FM_HOME whose only stand-in is a fixture `gh` serving a
# fake GitHub pull request. Nothing here touches the operator home or a real forge.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-movement-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_C=cccccccccccccccccccccccccccccccccccccccc
fails=0
say() { printf '\n### %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
show() { printf '$ %s\n' "$*"; "$@"; }

new_home() {
  local home="$LAB/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/forge" "$home/root/bin" "$home/wt"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  mkdir -p "$home/data/delivery"
  printf -- '- [ ] delivery - Contribution delivery https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' >> "$home/data/backlog.md"
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  for f in comments reviews inline threads labels events requested teams; do printf '[]\n' > "$home/forge/$f.json"; done
  printf 'false\n' > "$home/forge/draft"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "gh $*" >> "$FORGE/calls.log"
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" \
      --argjson draft "$(cat "$FORGE/draft")" --slurpfile requested "$FORGE/requested.json" --slurpfile teams "$FORGE/teams.json" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:$draft,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end),
       requested_reviewers:$requested[0],requested_teams:$teams[0]}' ;;
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
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}
with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}
sweep() { # run every registered authenticated check the way the watcher does
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    printf '$ bash %s\n' "state/$(basename "$check")"
    with_home "$home" bash "$check"
  done
}
wakes() { [ -f "$1/state/.wake-queue" ] && awk -F '\t' 'NF >= 5 && $3 == "check" { c++ } END { print c + 0 }' "$1/state/.wake-queue" || printf 0; }
pending() { with_home "$1" "$ROOT/bin/fm-contributions.sh" pending; }
wake_queue() { printf '$ cat state/.wake-queue\n'; cat "$1/state/.wake-queue" 2>/dev/null || printf '(no wake queue)\n'; }

say "Scenario 1: register the owned pull request; an unchanged PR produces no wake"
H=$(new_home s1)
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 && ok 'fm-pr-check.sh registered the delivery' || bad 'fm-pr-check.sh failed'
printf '$ ls state/*.check.sh\n'; ls "$H/state/"*.check.sh | sed "s|$H/||"
sweep "$H"; sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H"
[ "$(wakes "$H")" = 0 ] && [ "$(pending "$H" | jq length)" = 0 ] && ok 'two polls of an unchanged open PR: 0 pending, 0 wakes' || bad 'unchanged PR produced a signal'

say "Scenario 2: head replaced -> one 'head' signal, one durable wake, no repeat on re-poll"
printf '%s\n' "$HEAD_B" > "$H/forge/head"
sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H"
wake_queue "$H"
pending "$H" | jq -e --arg a "$HEAD_A" --arg b "$HEAD_B" 'length == 1 and .[0].type == "head" and .[0].body == "head moved from \($a) to \($b)" and .[0].head == $b' >/dev/null \
  && [ "$(wakes "$H")" = 1 ] && ok 'replaced head became exactly one pending head signal and one wake' || bad 'head movement signal wrong'
sweep "$H"
[ "$(wakes "$H")" = 1 ] && [ "$(pending "$H" | jq length)" = 1 ] && ok 're-poll with same head: still 1 pending, 1 wake' || bad 're-poll duplicated the head signal'

say "Scenario 2b: acknowledge the head signal; a second head move wakes again with a distinct token"
TOKEN=$(pending "$H" | jq -r '.[0].token')
show with_home "$H" "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$TOKEN"
[ "$(pending "$H" | jq length)" = 0 ] && ok 'ack cleared the pending head signal' || bad 'ack did not clear pending'
printf '%s\n' "$HEAD_C" > "$H/forge/head"
NOW=2026-09-16T08:05:00Z sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H"
pending "$H" | jq -e --arg b "$HEAD_B" --arg c "$HEAD_C" 'length == 1 and .[0].type == "head" and .[0].body == "head moved from \($b) to \($c)"' >/dev/null \
  && [ "$(wakes "$H")" = 2 ] && ok 'second head move woke again (2 wakes total)' || bad 'second head move did not wake'

say "Scenario 3: leaving draft -> 'ready-for-review' signal; entering draft is not movement"
H=$(new_home s3)
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H" >/dev/null
printf 'true\n' > "$H/forge/draft"
sweep "$H"
[ "$(wakes "$H")" = 0 ] && [ "$(pending "$H" | jq length)" = 0 ] && ok 'open -> draft: no signal, no wake' || bad 'converting to draft woke'
printf 'false\n' > "$H/forge/draft"
sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H"
wake_queue "$H"
pending "$H" | jq -e 'length == 1 and .[0].type == "ready-for-review" and .[0].body == "pull request left draft"' >/dev/null \
  && [ "$(wakes "$H")" = 1 ] && ok 'draft -> ready: exactly one ready-for-review signal and one wake' || bad 'leaving draft signal wrong'

say "Scenario 4: reviewer and team requested -> one 'review-requested' signal each; removing a reviewer is not movement"
H=$(new_home s4)
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H" >/dev/null
printf '[{"login":"alice"}]\n' > "$H/forge/requested.json"
sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H"
pending "$H" | jq -e 'length == 1 and .[0].type == "review-requested" and .[0].body == "review requested from alice"' >/dev/null \
  && [ "$(wakes "$H")" = 1 ] && ok 'newly requested reviewer alice: one signal, one wake' || bad 'reviewer request signal wrong'
printf '[{"login":"alice"},{"login":"bob"}]\n' > "$H/forge/requested.json"
printf '[{"slug":"core","name":"Core"}]\n' > "$H/forge/teams.json"
sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H" | jq -c '.[] | {type,body}'
wake_queue "$H"
pending "$H" | jq -e '(map(.body) | sort) == ["review requested from alice","review requested from bob","review requested from team:core"]' >/dev/null \
  && [ "$(wakes "$H")" = 3 ] && ok 'bob and team:core added: two new signals (alice not re-raised), one wake each (3 total)' || bad 'second reviewer wave wrong'
printf '[{"login":"bob"}]\n' > "$H/forge/requested.json"
printf '[]\n' > "$H/forge/teams.json"
sweep "$H"
[ "$(pending "$H" | jq length)" = 3 ] && [ "$(wakes "$H")" = 3 ] && ok 'removing alice and team:core: no new signal, no new wake' || bad 'reviewer removal produced a signal'

say "Scenario 5 (adversarial): a reviewer already present at the first observation is baseline, not movement"
H=$(new_home s5)
printf '[{"login":"alice"}]\n' > "$H/forge/requested.json"
printf '[{"slug":"core","name":"Core"}]\n' > "$H/forge/teams.json"
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H"; sweep "$H"
printf '$ jq .records[0].observation.review_requests data/delivery/contributions.json\n'
jq -c '.records[0].observation.review_requests' "$H/data/delivery/contributions.json"
[ "$(wakes "$H")" = 0 ] && [ "$(pending "$H" | jq length)" = 0 ] \
  && jq -e '.records[0].observation.review_requests == ["alice","team:core"]' "$H/data/delivery/contributions.json" >/dev/null \
  && ok 'first observation recorded the reviewers as baseline with no wake' || bad 'first observation treated existing reviewers as movement'

say "Scenario 6 (adversarial): a legacy record without review_requests does not infer movement; a head change is still caught"
H=$(new_home s6)
jq -n --arg head "$HEAD_A" --arg at "$NOW" '
  {schema:"fm-contributions.v1",task:"delivery",records:[{url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
    observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,
      checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],reviews:[],events:[]}}]}' > "$H/data/delivery/contributions.json"
printf '[{"login":"alice"}]\n' > "$H/forge/requested.json"
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H"
[ "$(wakes "$H")" = 0 ] && [ "$(pending "$H" | jq length)" = 0 ] && ok 'legacy record (no review_requests field) + present reviewer: no inferred movement' || bad 'legacy record inferred reviewer movement'
printf '%s\n' "$HEAD_B" > "$H/forge/head"
sweep "$H"
printf '$ fm-contributions.sh pending\n'; pending "$H" | jq -c '.[] | {type,body}'
pending "$H" | jq -e 'length == 1 and .[0].type == "head"' >/dev/null && [ "$(wakes "$H")" = 1 ] && ok 'legacy record still catches a replaced head' || bad 'legacy record missed head movement'

say "Scenario 7 (adversarial): head change observed as merged or closed settles with no wake"
for mode in merged closed; do
  H=$(new_home "s7-$mode")
  with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
  sweep "$H" >/dev/null
  printf '%s\n' "$HEAD_B" > "$H/forge/head"; printf '%s\n' "$mode" > "$H/forge/state"
  printf '[{"login":"alice"}]\n' > "$H/forge/requested.json"
  sweep "$H"
  printf '$ jq .records[0].observation.state data/delivery/contributions.json -> %s\n' "$(jq -r '.records[0].observation.state' "$H/data/delivery/contributions.json")"
  [ "$(wakes "$H")" = 0 ] && [ "$(pending "$H" | jq length)" = 0 ] \
    && jq -e --arg m "$mode" --arg b "$HEAD_B" '.records[0].observation.state == $m and .records[0].observation.head == $b' "$H/data/delivery/contributions.json" >/dev/null \
    && ok "$mode PR with new head and new reviewer: settled, no signal, no wake" || bad "$mode PR produced a movement signal"
done

say "Scenario 8: the watcher (fm-watch-checkpoint.sh) surfaces a head move once as 'check: contributions delivery <token>' and stays quiet afterwards"
H=$(new_home s8)
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H" >/dev/null
printf '%s\n' "$HEAD_B" > "$H/forge/head"
rc=0
with_home "$H" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 30 > "$H/watch.out" 2> "$H/watch.err" || rc=$?
printf '$ fm-watch-checkpoint.sh --seconds 30   (exit %s)\n' "$rc"; cat "$H/watch.out"; sed 's/^/stderr: /' "$H/watch.err"
[ "$rc" -eq 0 ] && grep -Eq '^check: contributions delivery [0-9a-f]{64}$' "$H/watch.out" && [ "$(wakes "$H")" = 1 ] \
  && ok 'watcher woke with the durable contributions check line for the head move' || bad 'watcher did not surface the head move'
rc=0
with_home "$H" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$H/watch2.out" 2> "$H/watch2.err" || rc=$?
printf '$ fm-watch-checkpoint.sh --seconds 3   (exit %s)\n' "$rc"; cat "$H/watch2.out"
[ "$rc" -eq 124 ] && [ "$(wakes "$H")" = 1 ] && ok 'watcher stayed quiet (124) on the unchanged head; still exactly one wake' || bad 'watcher re-rang on an unchanged head'

say "Scenario 9: the supervisor snapshot routes the pending movement to the fleet as 'incoming forge signal needs triage'"
H=$(new_home s9)
with_home "$H" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
sweep "$H" >/dev/null
printf '[{"login":"alice"}]\n' > "$H/forge/requested.json"
sweep "$H" >/dev/null
with_home "$H" "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$H/input.json" || bad 'fleet snapshot contribution input failed'
printf '$ fm-contributions.sh snapshot input.json --all | jq .rows\n'
with_home "$H" "$ROOT/bin/fm-contributions.sh" snapshot "$H/input.json" --all > "$H/snapshot.json" || bad 'snapshot failed'
jq '.rows' "$H/snapshot.json"
jq -e '.rows[0].url == "https://github.com/o/r/pull/8" and .rows[0].actor == "fleet" and .rows[0].reason == "incoming forge signal needs triage"' "$H/snapshot.json" >/dev/null \
  && ok 'snapshot names the fleet as required actor with reason "incoming forge signal needs triage"' || bad 'snapshot did not route the movement to the fleet'

printf '\n=== %s scenario assertions failed ===\n' "$fails"
exit "$fails"
