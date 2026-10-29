#!/usr/bin/env bash
# Live driver: the real fm-pr-check.sh, fm-contributions.sh, fm-watch-checkpoint.sh
# and fm-bearings-snapshot.sh from the run worktree, pointed at a disposable
# FM_HOME whose only forge is a fake `gh` reading fixture files. Each scenario
# prints the product's own output (pending view, wake queue, watcher stdout).
set -u
ROOT=${ROOT:?worktree root}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-movement.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
URL=https://github.com/o/r/pull/8
status=0

say() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; }
check() { # description condition...
  local desc=$1; shift
  if "$@" >/dev/null; then printf 'OK   %s\n' "$desc"; else printf 'FAIL %s\n' "$desc"; status=1; fi
}

new_home() { # name [prior-state] -> home with an owned delivery and a fake forge
  local home="$LAB/$1" state=${2:-open}
  mkdir -p "$home/data/delivery" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/forge" "$home/root/bin" "$home/wt"
  printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$URL" > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '%s\n' "$state" > "$home/forge/state"
  printf 'false\n' > "$home/forge/draft"
  for f in comments reviews inline threads requested teams; do printf '[]\n' > "$home/forge/$f.json"; done
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'gh %s\n' "$*" >> "$FORGE/calls.log"
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*isDraft*) printf 'false\n' ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state")" \
      --argjson draft "$(cat "$FORGE/draft")" --slurpfile requested "$FORGE/requested.json" --slurpfile teams "$FORGE/teams.json" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:$draft,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end),
       requested_reviewers:$requested[0],requested_teams:$teams[0]}' ;;
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
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  printf '%s\n' "$home"
}

with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" FM_BEARINGS_NOW="$NOW" "$@"
}
arm() { with_home "$1" "$ROOT/bin/fm-pr-check.sh" delivery "$URL"; }
sweep() { # run every check fm-pr-check.sh registered, exactly as the watcher does
  local check
  for check in "$1/state/"*.check.sh; do [ -f "$check" ] && with_home "$1" bash "$check"; done
  return 0
}
pending() { with_home "$1" "$ROOT/bin/fm-contributions.sh" pending; }
wakes() { [ -f "$1/state/.wake-queue" ] && awk -F '\t' 'NF >= 5 && $3 == "check" {n++} END {print n+0}' "$1/state/.wake-queue" || printf 0; }
wake_queue() { [ -f "$1/state/.wake-queue" ] && cat "$1/state/.wake-queue" || printf '(empty)\n'; }

movement() { # name mutate-fn expected-type expected-body [expected-source]
  local name=$1 expected_type=$3 expected_body=$4 expected_source=${5:-$URL} home p
  say "scenario: $name"
  home=$(new_home "$name")
  show "fm-pr-check.sh delivery $URL"; arm "$home"
  show 'ls state/*.check.sh'; (cd "$home/state" && ls ./*.check.sh)
  show 'sweep registered checks (baseline observation)'; sweep "$home"
  check 'unchanged pull request queues no wake' [ "$(wakes "$home")" = 0 ]
  "$2" "$home"
  show 'sweep registered checks (after movement)'; sweep "$home"
  show 'fm-contributions.sh pending'; p=$(pending "$home"); printf '%s\n' "$p"
  check "exactly one pending $expected_type signal with body '$expected_body'" \
    jq -e --arg t "$expected_type" --arg b "$expected_body" --arg u "$expected_source" \
      'length == 1 and .[0].type == $t and .[0].body == $b and .[0].source == $u' <<<"$p"
  show 'cat state/.wake-queue'; wake_queue "$home"
  check 'exactly one durable check wake queued' [ "$(wakes "$home")" = 1 ]
  show 'sweep registered checks (unchanged re-poll)'; sweep "$home"
  check 're-poll does not duplicate the wake' [ "$(wakes "$home")" = 1 ]
  check 're-poll does not add a signal' jq -e 'length == 1' <<<"$(pending "$home")"
  show 'fm-bearings-snapshot.sh --json | .contributions'
  with_home "$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '.contributions | {counts, fleet: (.fleet // null)}'
  show 'contributions.json .records[0].verdict_actor/pending types'
  jq -c '.records[0] | {state: .observation.state, head: .observation.head, review_requests: .observation.review_requests, pending: [.pending[].type]}' "$home/data/delivery/contributions.json"
}

move_head() { show "forge: head $HEAD_A -> $HEAD_B"; printf '%s\n' "$HEAD_B" > "$1/forge/head"; }
leave_draft() {
  show 'forge: convert to draft (adversarial: must not wake)'; printf 'true\n' > "$1/forge/draft"
  sweep "$1"
  check 'converting to draft does not wake' [ "$(wakes "$1")" = 0 ]
  show 'forge: mark ready for review'; printf 'false\n' > "$1/forge/draft"
}
request_reviewer() { show 'forge: request review from reviewer'; printf '[{"login":"reviewer"}]\n' > "$1/forge/requested.json"; }
request_team() { show 'forge: request review from team core'; printf '[{"slug":"core","name":"Core"}]\n' > "$1/forge/teams.json"; }
maintainer_comment() {
  show 'forge: maintainer comment'
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
    html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z"}]' > "$1/forge/comments.json"
}

movement head-replaced move_head head "head moved from $HEAD_A to $HEAD_B"
movement left-draft leave_draft ready-for-review 'pull request left draft'
movement reviewer-requested request_reviewer review-requested 'review requested from reviewer'
movement team-requested request_team review-requested 'review requested from team:core'
movement maintainer-comment maintainer_comment comment 'Please clarify the contract' https://github.com/o/r/pull/8#issuecomment-12

say 'scenario: existing review requests at the first observation are a baseline, not movement'
home=$(new_home first-observation)
printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"
printf '[{"slug":"core","name":"Core"}]\n' > "$home/forge/teams.json"
show "fm-pr-check.sh delivery $URL (reviewer and team already requested)"; arm "$home"
sweep "$home"; sweep "$home"
show 'fm-contributions.sh pending'; pending "$home"
check 'no pending signal' jq -e 'length == 0' <<<"$(pending "$home")"
check 'no wake queued' [ "$(wakes "$home")" = 0 ]
show 'recorded baseline'; jq -c '.records[0].observation.review_requests' "$home/data/delivery/contributions.json"
check 'baseline recorded' jq -e '.records[0].observation.review_requests == ["reviewer","team:core"]' "$home/data/delivery/contributions.json"

say 'scenario: a legacy observation without review_requests treats the current value as baseline'
home=$(new_home legacy-observation)
jq -n --arg task delivery --arg url "$URL" --arg head "$HEAD_A" --arg at "$NOW" '
  {schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
    observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,
      checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],reviews:[],events:[]}}]}' \
  > "$home/data/delivery/contributions.json"
printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"
arm "$home"; sweep "$home"; sweep "$home"
show 'fm-contributions.sh pending'; pending "$home"
check 'legacy record: no pending signal' jq -e 'length == 0' <<<"$(pending "$home")"
check 'legacy record: no wake' [ "$(wakes "$home")" = 0 ]
check 'legacy record: baseline recorded' jq -e '.records[0].observation.review_requests == ["reviewer"]' "$home/data/delivery/contributions.json"

for mode in merged closed; do
  say "scenario: a head change observed as $mode settles without a movement wake"
  home=$(new_home "settled-$mode")
  arm "$home"; sweep "$home"
  printf '%s\n' "$HEAD_B" > "$home/forge/head"; printf '%s\n' "$mode" > "$home/forge/state"
  show 'fm-contributions.sh poll'; out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll); printf '%s\n' "${out:-(no output)}"
  check "$mode: poll printed nothing" [ -z "$out" ]
  check "$mode: no wake queued" [ "$(wakes "$home")" = 0 ]
  show 'recorded observation'; jq -c '.records[0] | {state: .observation.state, head: .observation.head, pending}' "$home/data/delivery/contributions.json"
  check "$mode: settled with the new head and no pending" jq -e --arg m "$mode" --arg h "$HEAD_B" \
    '.records[0].observation.state == $m and .records[0].observation.head == $h and .records[0].pending == []' "$home/data/delivery/contributions.json"
done

say 'scenario: the checkpoint watcher surfaces a replaced head as a check wake, then acknowledging it clears pending'
home=$(new_home watcher)
arm "$home"; sweep "$home"
check 'armed, unchanged: no wake' [ "$(wakes "$home")" = 0 ]
printf '%s\n' "$HEAD_B" > "$home/forge/head"
show 'fm-watch-checkpoint.sh --seconds 30 (FM_POLL=1)'
rc=0
with_home "$home" env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 30 > "$home/watcher.out" 2> "$home/watcher.err" || rc=$?
printf 'exit=%s\nstdout:\n' "$rc"; cat "$home/watcher.out"; printf 'stderr:\n'; cat "$home/watcher.err"
check 'watcher exited 0 with a wake' [ "$rc" -eq 0 ]
check 'watcher printed check: contributions delivery <sha>' grep -Eq '^check: contributions delivery [0-9a-f]{64}$' "$home/watcher.out"
check 'one durable wake' [ "$(wakes "$home")" = 1 ]
show 'fm-contributions.sh pending'; p=$(pending "$home"); printf '%s\n' "$p"
token=$(jq -er '.[0].token' <<<"$p")
show "fm-contributions.sh ack delivery $URL $token"
with_home "$home" "$ROOT/bin/fm-contributions.sh" ack delivery "$URL" "$token"
show 'fm-contributions.sh pending (after ack)'; pending "$home"
check 'ack clears pending' jq -e 'length == 0' <<<"$(pending "$home")"
sweep "$home"
check 'after ack an unchanged re-poll stays quiet' [ "$(wakes "$home")" = 1 ]
check 'after ack an unchanged re-poll adds no signal' jq -e 'length == 0' <<<"$(pending "$home")"

say "result: $([ "$status" -eq 0 ] && printf 'all checks passed' || printf 'SOME CHECKS FAILED')"
exit "$status"
