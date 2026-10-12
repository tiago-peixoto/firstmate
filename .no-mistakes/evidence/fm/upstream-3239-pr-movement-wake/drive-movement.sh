#!/usr/bin/env bash
# Live driver: real bin/ scripts on a disposable FM_HOME against a local stand-in forge (fake gh).
set -u
ROOT=$1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-movement.XXXXXX")
trap 'rm -rf "$T"' EXIT
NOW=2026-09-16T08:00:00Z
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
C=cccccccccccccccccccccccccccccccccccccccc
mk() {
  local h=$T/$1; mkdir -p "$h"/{data/delivery,state,config,projects,fakebin,forge,root/bin,wt}
  printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' > "$h/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$h/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$h/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$h/root/bin/fm-guard.sh"; chmod +x "$h/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$h" > "$h/state/delivery.meta"; chmod 600 "$h/state/delivery.meta"
  echo $A > "$h/forge/head"; echo open > "$h/forge/state"; echo false > "$h/forge/draft"
  for f in comments reviews inline requested teams; do echo '[]' > "$h/forge/$f.json"; done
  cat > "$h/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:""}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state")" --argjson draft "$(cat "$FORGE/draft")" \
      --slurpfile requested "$FORGE/requested.json" --slurpfile teams "$FORGE/teams.json" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},head:{sha:$head},draft:$draft,
       mergeable:(if $state == "open" then true else null end),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end),
       requested_reviewers:$requested[0],requested_teams:$teams[0]}' ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*) printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$h/fakebin/"*; echo "$h"
}
wh() { local h=$1; shift
  PATH="$h/fakebin:$PATH" FORGE="$h/forge" FM_HOME="$h" FM_ROOT_OVERRIDE="$h/root" FM_STATE_OVERRIDE="$h/state" \
  FM_DATA_OVERRIDE="$h/data" FM_CONFIG_OVERRIDE="$h/config" FM_CONTRIBUTIONS_NOW="${CLOCK:-$NOW}" "$@"; }
sweep() { local c; for c in "$1/state/"*.check.sh; do [ -f "$c" ] && wh "$1" bash "$c"; done; }
wakes() { [ -f "$1/state/.wake-queue" ] && awk -F '\t' '$3=="check"{n++} END{print n+0}' "$1/state/.wake-queue" || echo 0; }
pend() { wh "$1" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[]|{type,body,token,source}]'; }
show() { printf '   pending=%s\n   durable check wakes=%s\n' "$(pend "$1")" "$(wakes "$1")"; }
say() { printf '\n### %s\n' "$*"; }
arm() { printf '$ fm-pr-check.sh delivery https://github.com/o/r/pull/8\n'; wh "$1" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 2>&1 | sed 's/^/   /'; }
step() { printf -- '-- %s\n' "$2"; printf '   check output: %s\n' "$(sweep "$1" 2>&1 | tr '\n' '|')"; show "$1"; }

say 'S1 arm the monitor on an open PR that already has a requested reviewer and team; poll twice with nothing changing'
h=$(mk s1); echo '[{"login":"existing"}]' > $h/forge/requested.json; echo '[{"slug":"core"}]' > $h/forge/teams.json
arm $h; step $h 'first observation'; step $h 'unchanged re-poll'
printf '   stored review_requests=%s\n' "$(jq -c '.records[0].observation.review_requests' $h/data/delivery/contributions.json)"

say 'S2 head replaced A -> B'
echo $B > $h/forge/head; CLOCK=2026-09-16T08:05:00Z step $h 'poll after push'; CLOCK=2026-09-16T08:06:00Z step $h 'unchanged re-poll'

say 'S3 new reviewer and new team requested (existing ones stay)'
echo '[{"login":"existing"},{"login":"alice"}]' > $h/forge/requested.json; echo '[{"slug":"core"},{"slug":"docs"}]' > $h/forge/teams.json
CLOCK=2026-09-16T08:10:00Z step $h 'poll after request'; CLOCK=2026-09-16T08:11:00Z step $h 'unchanged re-poll'

say 'S4 PR converted to draft, then leaves draft'
echo true > $h/forge/draft; CLOCK=2026-09-16T08:15:00Z step $h 'poll after convert-to-draft (must add nothing)'
echo false > $h/forge/draft; CLOCK=2026-09-16T08:20:00Z step $h 'poll after ready-for-review'

say 'S5 ack each pending token; then the same head A returns (force-push back) and must wake again with a fresh token'
for t in $(wh $h "$ROOT/bin/fm-contributions.sh" pending | jq -r '.[].token'); do
  printf '$ fm-contributions.sh ack delivery <url> %s -> rc=' "$t"; wh $h "$ROOT/bin/fm-contributions.sh" ack delivery https://github.com/o/r/pull/8 "$t"; echo $?; done
show $h; before=$(wakes $h)
echo $A > $h/forge/head; CLOCK=2026-09-16T08:25:00Z step $h 'head B -> A'
echo $B > $h/forge/head; CLOCK=2026-09-16T08:30:00Z step $h 'head A -> B again (same sha as S2, new observation time)'

say 'S6 maintainer comment and review still wake (pre-existing behavior kept after the merge with main)'
h2=$(mk s6); arm $h2 >/dev/null; step $h2 'baseline'
echo '[{"id":12,"user":{"login":"maintainer"},"author_association":"OWNER","body":"Please clarify","html_url":"https://github.com/o/r/pull/8#issuecomment-12","updated_at":"2026-09-16T08:01:00Z"}]' > $h2/forge/comments.json
step $h2 'maintainer comment'
jq -n --arg h $A '[{id:13,user:{login:"maintainer"},author_association:"MEMBER",body:"needs work",html_url:"https://github.com/o/r/pull/8#pullrequestreview-13",submitted_at:"2026-09-16T08:02:00Z",commit_id:$h,state:"CHANGES_REQUESTED"}]' > $h2/forge/reviews.json
step $h2 'maintainer review'

say 'S7 adversarial: head changes in the same observation that shows the PR merged / closed'
for mode in merged closed; do h3=$(mk s7-$mode); arm $h3 >/dev/null; step $h3 "baseline ($mode case)"
  echo $C > $h3/forge/head; echo $mode > $h3/forge/state; echo '[{"login":"late"}]' > $h3/forge/requested.json
  CLOCK=2026-09-16T08:05:00Z step $h3 "poll sees $mode + new head + new reviewer"
  printf '   stored state=%s\n' "$(jq -c '.records[0].observation|{state,head}' $h3/data/delivery/contributions.json)"; done

say 'S8 adversarial: record stored before review requests were recorded (legacy), forge already has a reviewer'
h4=$(mk s8)
jq -n --arg h $A --arg at $NOW '{schema:"fm-contributions.v1",task:"delivery",records:[{url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
  observation:{head:$h,state:"open",draft:false,mergeable:"mergeable",review_decision:"",can_merge:false,checks:[],reviews:[],events:[]}}]}' > $h4/data/delivery/contributions.json
echo '[{"login":"existing"}]' > $h4/forge/requested.json
arm $h4 >/dev/null; step $h4 'first poll over legacy record (baseline only)'
echo '[{"login":"existing"},{"login":"bob"}]' > $h4/forge/requested.json; CLOCK=2026-09-16T08:05:00Z step $h4 'bob requested afterwards'

say 'S9 real watcher (fm-watch-checkpoint.sh): quiet while unchanged, surfaces one wake on a replaced head, quiet again'
h5=$(mk s9); arm $h5 >/dev/null
run() { local secs=$1; shift; local rc=0; out=$(wh $h5 env "$@" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch-checkpoint.sh" --seconds $secs 2>&1) || rc=$?
  printf '   rc=%s (124 = quiet expiry) output: %s\n' "$rc" "$(printf '%s' "$out" | tr '\n' '|' | cut -c1-300)"; show $h5; }
echo '-- checkpoint 8s, PR unchanged'; run 8
# let any poll that outlived the timer finish before changing the forge
sleep 3; echo "   wakes before movement=$(wakes $h5)"
echo $B > $h5/forge/head
echo '-- checkpoint 30s after head A -> B'; run 30 FM_WATCH_HANDLING_SUCCESSOR=1
echo '-- checkpoint 4s, nothing new'; run 4 FM_WATCH_HANDLING_SUCCESSOR=1
