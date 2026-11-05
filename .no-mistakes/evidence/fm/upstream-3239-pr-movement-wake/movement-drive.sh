#!/usr/bin/env bash
# Live drive of pull-request movement wakes: fm-pr-check.sh registers an owned
# PR, the registered contributions check polls a disposable fake GitHub (gh
# stub = external boundary), and fm-contributions.sh pending / the durable wake
# queue are the observed product outputs. The last scenario polls the real
# PR 5341 through the machine's real gh login (read-only API calls).
set -u
ROOT={run-worktree}
TMP_ROOT=$(mktemp -d /tmp/fm-movement-drive.XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
FAILS=0
say() { printf '\n## %s\n' "$*"; }
step() { printf '\n$ %s\n' "$*"; }
check() { if eval "$1"; then printf 'OK   %s\n' "$2"; else printf 'FAIL %s\n' "$2"; FAILS=$((FAILS+1)); fi; }

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/root/bin" "$home/wt"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  printf '%s\n' "$home"
}
record() { # home id number state
  local home=$1 id=$2 number=$3 state=$4
  mkdir -p "$home/data/$id"
  printf -- '- [ ] %s - Contribution %s https://github.com/o/r/pull/%s (repo: sample) (kind: ship)\n' "$id" "$id" "$number" >> "$home/data/backlog.md"
  jq -n --arg task "$id" --arg url "https://github.com/o/r/pull/$number" --arg head "$HEAD_A" --arg at "$NOW" --arg state "$state" '
    {schema:"fm-contributions.v1",task:$task,records:[{url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:$state,draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],reviews:[],events:[]}}]}' \
    > "$home/data/$id/contributions.json"
}
forge_home() {
  local home=$1
  mkdir -p "$home/forge"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"; chmod 600 "$home/state/delivery.meta"
  record "$home" delivery 8 open
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  for f in comments reviews inline threads labels events requested teams; do printf '[]\n' > "$home/forge/$f.json"; done
  printf 'false\n' > "$home/forge/draft"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
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
  'api graphql '*) jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*) printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}
with_home() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}
with_real() { # no frozen clock, no fake forge: gh resolves to the machine's real login
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$@"
}
registered_check() { # run the check fm-pr-check.sh armed (state/contributions.check.sh), printing its output
  local home=$1 out
  out=$(with_home "$home" bash "$home/state/contributions.check.sh" 2>&1); printf '%s\n' "${out:-<no output: no wake>}"
}
wakes() { [ -f "$1/state/.wake-queue" ] || { printf '0'; return; }; awk -F '\t' 'NF >= 5 && $3 == "check" { n++ } END { print n + 0 }' "$1/state/.wake-queue"; }
pending() { with_home "$1" "$ROOT/bin/fm-contributions.sh" pending | jq -c '.'; }

movement() { # kind
  local kind=$1 home p type body
  home=$(new_home "movement-$kind"); forge_home "$home"
  say "Scenario: $kind movement on an open owned PR wakes exactly once"
  step "fm-pr-check.sh delivery https://github.com/o/r/pull/8   (registers pr= and arms the contribution observer)"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8
  check "[ -x '$home/state/contributions.check.sh' ]" 'fm-pr-check armed state/contributions.check.sh'
  step "bash state/contributions.check.sh   (baseline poll, unchanged PR)"; registered_check "$home"
  check "[ \$(wakes '$home') = 0 ]" "no wake queued for an unchanged PR (queue: $(wakes "$home"))"
  case "$kind" in
    head) printf '%s\n' "$HEAD_B" > "$home/forge/head"; type=head; body="head moved from $HEAD_A to $HEAD_B"
      step "forge: head -> $HEAD_B" ;;
    ready) printf 'true\n' > "$home/forge/draft"; step "forge: draft=true, poll (adversarial: converting TO draft must not wake)"
      registered_check "$home"; check "[ \$(wakes '$home') = 0 ]" "converting to draft queued no wake (queue: $(wakes "$home"))"
      printf 'false\n' > "$home/forge/draft"; type=ready-for-review; body='pull request left draft'; step 'forge: draft=false' ;;
    reviewer) printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"; type=review-requested; body='review requested from reviewer'
      step 'forge: requested_reviewers=[reviewer]' ;;
    team) printf '[{"slug":"core","name":"Core"}]\n' > "$home/forge/teams.json"; type=review-requested; body='review requested from team:core'
      step 'forge: requested_teams=[core]' ;;
  esac
  step 'bash state/contributions.check.sh'; registered_check "$home"
  step 'fm-contributions.sh pending'; p=$(pending "$home"); printf '%s\n' "$p"
  check "printf '%s' '$p' | jq -e --arg t '$type' --arg b '$body' 'length == 1 and .[0].type == \$t and .[0].body == \$b and .[0].source == \"https://github.com/o/r/pull/8\"' >/dev/null" \
    "exactly one pending signal of type $type with body '$body'"
  check "[ \$(wakes '$home') = 1 ]" "exactly one durable check wake queued (queue: $(wakes "$home"))"
  step 'state/.wake-queue'; cat "$home/state/.wake-queue"
  step 'bash state/contributions.check.sh   (unchanged re-poll)'; registered_check "$home"
  check "[ \$(wakes '$home') = 1 ] && [ \$(pending '$home' | jq length) = 1 ]" 'unchanged re-poll adds no wake and no signal'
}
movement head; movement ready; movement reviewer; movement team

say 'Adversarial: review requests already present at the FIRST observation are a baseline, not movement'
home=$(new_home baseline-first); forge_home "$home"; rm "$home/data/delivery/contributions.json"
printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"; printf '[{"slug":"core","name":"Core"}]\n' > "$home/forge/teams.json"
with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
step 'poll twice'; registered_check "$home"; registered_check "$home"
step 'fm-contributions.sh pending'; pending "$home"
step 'recorded observation.review_requests'; jq -c '.records[0].observation.review_requests' "$home/data/delivery/contributions.json"
check "[ \$(pending '$home' | jq length) = 0 ] && [ \$(wakes '$home') = 0 ]" 'no pending signal and no wake'
check "jq -e '.records[0].observation.review_requests == [\"reviewer\",\"team:core\"]' '$home/data/delivery/contributions.json' >/dev/null" 'baseline records the current reviewers'

say 'Adversarial: a LEGACY stored observation (no review_requests field) gains reviewers without movement'
home=$(new_home baseline-legacy); forge_home "$home"
printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"
with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null
step 'stored observation has review_requests?'; jq -c '.records[0].observation | has("review_requests")' "$home/data/delivery/contributions.json"
registered_check "$home"; registered_check "$home"
check "[ \$(pending '$home' | jq length) = 0 ] && [ \$(wakes '$home') = 0 ]" 'legacy record: no pending signal and no wake'
check "jq -e '.records[0].observation.review_requests == [\"reviewer\"]' '$home/data/delivery/contributions.json' >/dev/null" 'legacy record now carries the baseline'

say 'Adversarial: a head change observed as merged/closed settles without a movement wake'
for mode in merged closed; do
  home=$(new_home "settled-$mode"); forge_home "$home"
  printf '%s\n' "$HEAD_B" > "$home/forge/head"; printf '%s\n' "$mode" > "$home/forge/state"
  step "fm-contributions.sh poll   (stored head $HEAD_A, forge now $mode at $HEAD_B)"
  out=$(with_home "$home" "$ROOT/bin/fm-contributions.sh" poll 2>&1); printf '%s\n' "${out:-<no output: no wake>}"
  jq -c '.records[0] | {state:.observation.state,head:.observation.head,pending,error}' "$home/data/delivery/contributions.json"
  check "[ -z '$out' ] && [ \$(wakes '$home') = 0 ]" "$mode: no wake output and empty queue"
  check "jq -e --arg m $mode --arg h $HEAD_B '.records[0].observation.state == \$m and .records[0].observation.head == \$h and .records[0].pending == []' '$home/data/delivery/contributions.json' >/dev/null" "$mode: settled at the new head with no pending signal"
done

say 'Real forge: poll https://github.com/kunchenguid/firstmate/pull/5341 through the real gh login (read-only)'
home=$(new_home real-5341)
printf -- '- [ ] upstream - PR movement wake https://github.com/kunchenguid/firstmate/pull/5341 (repo: firstmate) (kind: ship)\n' >> "$home/data/backlog.md"
real_head=$(gh pr view 5341 -R kunchenguid/firstmate --json headRefOid -q .headRefOid)
step "gh pr view 5341 --json headRefOid,isDraft,reviewRequests,state"; gh pr view 5341 -R kunchenguid/firstmate --json headRefOid,isDraft,reviewRequests,state
rec="$home/data/upstream/contributions.json"; pend="$home/pending.json"
step 'fm-contributions.sh poll   (first observation: the PR already carries maintainer comments, which are expected pre-existing comment wakes)'
out=$(with_real "$home" "$ROOT/bin/fm-contributions.sh" poll 2>&1); rc=$?; printf 'rc=%s\n%s\n' "$rc" "${out:-<no output: no wake>}"
jq -c '.records[0] | {url,error,observation:{head:.observation.head,state:.observation.state,draft:.observation.draft,review_requests:.observation.review_requests}}' "$rec"
with_real "$home" "$ROOT/bin/fm-contributions.sh" pending > "$pend"
step 'fm-contributions.sh pending   (type/author/source only)'; jq -c '.[] | {type,author,source}' "$pend"
base=$(wakes "$home"); npend=$(jq length "$pend")
check "[ $rc -eq 0 ] && jq -e --arg h '$real_head' '.records[0].error == null and .records[0].observation.head == \$h and (.records[0].observation.review_requests | type) == \"array\"' '$rec' >/dev/null" 'first observation recorded the real head and a review_requests array, no error'
check "jq -e 'all(.[]; .type == \"comment\")' '$pend' >/dev/null && [ $base -eq $npend ]" "first observation produced no movement signal: every pending signal is a pre-existing maintainer comment ($npend comments, $base wakes)"
step "synthetic prior state: stored head -> $HEAD_A, stored draft -> true (as if the PR were previously a draft at another head)"
jq --arg h "$HEAD_A" '.records[0].observation.head = $h | .records[0].observation.draft = true' "$rec" > "$home/u.json" && mv "$home/u.json" "$rec"
step 'fm-contributions.sh poll   (second observation against the real forge)'
out=$(with_real "$home" "$ROOT/bin/fm-contributions.sh" poll 2>&1); rc=$?; printf 'rc=%s\n%s\n' "$rc" "${out:-<no output: no wake>}"
with_real "$home" "$ROOT/bin/fm-contributions.sh" pending > "$pend"
step 'fm-contributions.sh pending   (non-comment signals)'; jq -c '.[] | select(.type != "comment") | {type,source,head,body}' "$pend"
check "jq -e --arg h '$real_head' --arg a '$HEAD_A' '[.[] | select(.type != \"comment\")] | (map(.type) | sort) == [\"head\",\"ready-for-review\"] and (.[] | select(.type == \"head\") | .body) == (\"head moved from \" + \$a + \" to \" + \$h) and (.[] | select(.type == \"ready-for-review\") | .body) == \"pull request left draft\"' '$pend' >/dev/null" 'pending gained exactly one head signal naming the real head and one ready-for-review signal'
check "[ \$(wakes '$home') -eq $((base + 2)) ] && [ \$(jq length '$pend') -eq $((npend + 2)) ]" "exactly two more durable wakes and two more signals (queue: $(wakes "$home"), pending: $(jq length "$pend"))"
step 'fm-contributions.sh poll   (third observation, unchanged)'
out=$(with_real "$home" "$ROOT/bin/fm-contributions.sh" poll 2>&1); printf '%s\n' "${out:-<no output: no wake>}"
with_real "$home" "$ROOT/bin/fm-contributions.sh" pending > "$pend"
check "[ -z '$out' ] && [ \$(wakes '$home') -eq $((base + 2)) ] && [ \$(jq length '$pend') -eq $((npend + 2)) ]" "unchanged real re-poll adds no wake and no signal (queue: $(wakes "$home"), pending: $(jq length "$pend"))"

printf '\n== %s check failures ==\n' "$FAILS"
exit "$FAILS"
