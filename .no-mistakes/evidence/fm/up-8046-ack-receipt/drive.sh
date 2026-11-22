#!/usr/bin/env bash
# Live driver: runs the real fm-contributions.sh / fm-pr-check.sh / fm-captain-hold.sh
# against disposable homes and a local gh emulator (synthetic PR o/r#8).
# usage: drive.sh <worktree> <base-tree> <scratch>
set -u
WT=$1 BASE=$2 S=$3; mkdir -p "$S"
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/o/r/pull/8
FAILS=0
ok() { printf 'PASS  %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS+1)); }
say() { printf '\n=== %s ===\n' "$*"; }

new_home() { # dir
  local home=$1
  mkdir -p "$home"/{data,state,config,projects,fakebin,forge,root/bin,wt}
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"; chmod 600 "$home/state/delivery.meta"
  mkdir -p "$home/data/delivery"
  printf -- '- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship) \n' "$URL" >> "$home/data/backlog.md"
  jq -n --arg url "$URL" --arg head "$HEAD_A" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:"delivery",records:[{
      url:$url,kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$home/data/delivery/contributions.json"
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  for f in comments reviews inline threads labels events; do printf '[]\n' > "$home/forge/$f.json"; done
  cat > "$home/fakebin/gh" <<'SH'
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
  chmod +x "$home/fakebin/gh"
}
H() { # home cmd...
  local home=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS PATH="$home/fakebin:$PATH" FORGE="$home/forge" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_CONTRIBUTIONS_NOW="${AT:-$NOW}" "$@"
}
C() { local root=$1 home=$2; shift 2; H "$home" "$root/bin/fm-contributions.sh" "$@"; }
checks() { local c; for c in "$1/state/"*.check.sh; do [ -f "$c" ] && H "$1" bash "$c"; done; }
register() { H "$2" "$1/bin/fm-pr-check.sh" delivery "$URL" >/dev/null && checks "$2" >/dev/null; }
review() { # home state body
  jq -n --arg head "$HEAD_A" --arg state "$2" --arg body "$3" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:$body,html_url:"https://github.com/o/r/pull/8#pullrequestreview-12",
    submitted_at:"2026-09-16T08:01:00Z",commit_id:$head,state:$state}]' > "$1/forge/reviews.json"
}
inline() { jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",
    body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",
    created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head}]' > "$1/forge/inline.json"; }
comment() { jq -n '[{id:50,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks, looking",
    html_url:"https://github.com/o/r/pull/8#issuecomment-50",updated_at:"2026-09-16T08:01:00Z"}]' > "$1/forge/comments.json"; }
tok() { C "$1" "$2" pending | jq -er --arg s "$3" '.[] | select(.source|contains($s)) | .token'; }
steer() { ( . "$WT/bin/fm-task-inbox-lib.sh" && fm_task_inbox_write "$1/state" "$2" "$3" >/dev/null ); }
show() { printf '$ %s\n' "$*"; }
run() { # label ; then command; prints output and exit
  local out rc; show "${@:3}"; out=$("${@:3}" 2>&1); rc=$?; [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    /'; printf '    [exit %s]\n' "$rc"; RC=$rc OUT=$out; }

# ---------- transcript of one default-path sequence, used for base-vs-target diff
default_sequence() { # root home mode
  local root=$1 home=$2 mode=$3 t1 t2 t3
  new_home "$home"
  case "$mode" in
    existing) printf 'maintainer\nsome-bot[bot]\n' > "$home/config/contribution-review-bots"; touch "$home/config/hold-pr-settle"; export FM_CONTRIBUTIONS_REPLY_AGE=86400 ;;
    *) unset FM_CONTRIBUTIONS_REPLY_AGE ;;
  esac
  register "$root" "$home"
  review "$home" APPROVED "$(printf '%600s' '')Approved, but the retry loop drops errors"; inline "$home"; comment "$home"
  AT=2026-09-16T08:02:00Z C "$root" "$home" poll; echo "poll rc=$?"
  C "$root" "$home" pending; echo "pending rc=$?"
  t1=$(tok "$root" "$home" pullrequestreview); t2=$(tok "$root" "$home" discussion_r31); t3=$(tok "$root" "$home" issuecomment)
  C "$root" "$home" ack delivery "$URL" "$t1" handoff; echo "ack-handoff rc=$?"
  C "$root" "$home" ack delivery "$URL" "$t1" disposition "$URL#issuecomment-40" why; echo "ack-disposition rc=$?"
  C "$root" "$home" ack delivery "$URL" "$t1"; echo "ack-review rc=$?"
  C "$root" "$home" ack delivery "$URL" "$t2"; echo "ack-inline rc=$?"
  C "$root" "$home" ack delivery "$URL" "$t3"; echo "ack-comment rc=$?"
  C "$root" "$home" pending; echo "pending rc=$?"
  if [ "$mode" = existing ]; then
    AT=2026-09-17T08:05:00Z C "$root" "$home" poll; echo "reraise-poll rc=$?"
    AT=2026-09-17T08:05:00Z C "$root" "$home" pending; echo "pending rc=$?"
    t2=$(AT=2026-09-17T08:05:00Z tok "$root" "$home" discussion_r31)
    AT=2026-09-17T08:05:00Z C "$root" "$home" ack delivery "$URL" "$t2"; echo "ack-unanswered rc=$?"
  fi
  echo '--- saved record'; jq -S . "$home/data/delivery/contributions.json"
  unset FM_CONTRIBUTIONS_REPLY_AGE
}

for mode in unconfigured existing; do
  say "S-default-$mode: target vs upstream main 427056c4, same sequence, no config/contribution-ack-receipts"
  default_sequence "$BASE" "$S/base-$mode" "$mode" > "$S/base-$mode.txt" 2>&1
  default_sequence "$WT" "$S/tgt-$mode" "$mode" > "$S/tgt-$mode.txt" 2>&1
  sed "s#$S/base-$mode#HOME#g" "$S/base-$mode.txt" > "$S/base-$mode.norm"
  sed "s#$S/tgt-$mode#HOME#g" "$S/tgt-$mode.txt" > "$S/tgt-$mode.norm"
  if diff -u "$S/base-$mode.norm" "$S/tgt-$mode.norm"; then ok "$mode: output, exit codes and saved record identical to upstream main"; else bad "$mode: differs from upstream main"; fi
  echo "--- target transcript ($mode)"; sed 's/^/    /' "$S/tgt-$mode.norm"
  grep -q '^ack-review rc=0' "$S/tgt-$mode.norm" && grep -q '^ack-inline rc=0' "$S/tgt-$mode.norm" && grep -q '^ack-handoff rc=1' "$S/tgt-$mode.norm" \
    && ! grep -q '"receipts"' "$S/tgt-$mode.norm" && ok "$mode: token-only acks accepted, receipt args refused, no receipts saved" || bad "$mode: default acks wrong"
done

say "S-optin: flag present (empty file) - findings need a receipt"
h="$S/optin"; new_home "$h"; touch "$h/config/contribution-ack-receipts"; register "$WT" "$h"
review "$h" APPROVED "Approved, but the retry loop drops errors"; inline "$h"; comment "$h"
AT=2026-09-16T08:02:00Z C "$WT" "$h" poll >/dev/null
tr=$(tok "$WT" "$h" pullrequestreview); ti=$(tok "$WT" "$h" discussion_r31); tc=$(tok "$WT" "$h" issuecomment)
run x x C "$WT" "$h" ack delivery "$URL" "$tr"; [ "$RC" != 0 ] && ok 'token-only ack of approved review with findings refused' || bad 'token-only review ack accepted'
run x x C "$WT" "$h" ack delivery "$URL" "$ti"; [ "$RC" != 0 ] && ok 'token-only ack of inline comment refused' || bad 'token-only inline ack accepted'
[ "$(C "$WT" "$h" pending | jq length)" = 3 ] && ok 'refusals left all 3 signals pending' || bad 'refusal removed a signal'
run x x C "$WT" "$h" ack delivery "$URL" "$tc"; [ "$RC" = 0 ] && ok 'plain comment (no findings) acks with token alone' || bad 'plain comment refused'
run x x C "$WT" "$h" ack delivery "$URL" "$tr" handoff; [ "$RC" != 0 ] && ok 'handoff with no steer in the owner inbox refused' || bad 'handoff without steer accepted'
steer "$h" other "Read $URL#pullrequestreview-12"
run x x C "$WT" "$h" ack delivery "$URL" "$tr" handoff; [ "$RC" != 0 ] && ok 'steer to a different task is not a handoff' || bad 'foreign steer accepted'
steer "$h" delivery "Read $URL#pullrequestreview-12 and fix it"
run x x C "$WT" "$h" ack delivery "$URL" "$tr" handoff; [ "$RC" = 0 ] && ok 'handoff accepted after steer naming the review' || bad 'valid handoff refused'
run x x C "$WT" "$h" ack delivery "$URL" "$ti" disposition "https://github.com/o/r/pull/99#issuecomment-40" fixed; [ "$RC" != 0 ] && ok 'disposition citing another PR refused' || bad 'foreign evidence accepted'
run x x C "$WT" "$h" ack delivery "$URL" "$ti" disposition "$URL#discussion_r31" 'self cite'; [ "$RC" != 0 ] && ok 'disposition citing the signal itself refused (live task)' || bad 'self-cite accepted'
run x x C "$WT" "$h" ack delivery "$URL" "$ti" disposition "$URL#issuecomment-40" '   '; [ "$RC" != 0 ] && ok 'blank disposition summary refused' || bad 'blank summary accepted'
run x x C "$WT" "$h" ack delivery "$URL" "$ti" disposition "$URL#issuecomment-40" 'author replied: bounded by caller'; [ "$RC" = 0 ] && ok 'disposition with evidence on this PR accepted' || bad 'valid disposition refused'
show "jq .records[0].receipts,.records[0].pending"; jq -c '.records[0] | .receipts, .pending' "$h/data/delivery/contributions.json" | sed 's/^/    /'
jq -e --arg tr "$tr" --arg ti "$ti" '.records[0] | .pending == [] and (.receipts | length == 2 and .[0].token == $tr and .[0].kind == "handoff" and .[0].task == "delivery" and .[1].token == $ti and .[1].kind == "disposition")' "$h/data/delivery/contributions.json" >/dev/null && ok 'two receipts saved, bound to token and task; nothing pending' || bad 'receipts not saved as documented'

say "S-toggle: flag contents ignored; flag outside the effective config ignored; removing it restores token-only and keeps receipts"
h="$S/toggle"; new_home "$h"; printf 'off\nfalse\n0\n' > "$h/config/contribution-ack-receipts"; register "$WT" "$h"
review "$h" CHANGES_REQUESTED "The retry loop drops errors"; inline "$h"
AT=2026-09-16T08:02:00Z C "$WT" "$h" poll >/dev/null
tr=$(tok "$WT" "$h" pullrequestreview); ti=$(tok "$WT" "$h" discussion_r31)
run x x C "$WT" "$h" ack delivery "$URL" "$tr"; [ "$RC" != 0 ] && ok 'flag file containing "off/false/0" still enforces (presence flag)' || bad 'contents changed behavior'
steer "$h" delivery "Read $URL#pullrequestreview-12"; C "$WT" "$h" ack delivery "$URL" "$tr" handoff || bad 'handoff failed'
mkdir "$h/elsewhere"; mv "$h/config/contribution-ack-receipts" "$h/elsewhere/"
run x x C "$WT" "$h" ack delivery "$URL" "$ti" handoff; [ "$RC" != 0 ] && [ "$OUT" = 'fm-contributions: ack needs one exact event token' ] && ok 'flag removed: receipt arguments refused with the upstream usage error' || bad 'receipt args after removal'
show "FM_CONFIG_OVERRIDE=elsewhere ack <inline token>"; if H "$h" env FM_CONFIG_OVERRIDE="$h/elsewhere" "$WT/bin/fm-contributions.sh" ack delivery "$URL" "$ti" 2>&1 | sed 's/^/    /'; [ "${PIPESTATUS[0]}" != 0 ]; then ok 'flag in the effective (overridden) config dir enforces'; else bad 'override config flag ignored'; fi
run x x C "$WT" "$h" ack delivery "$URL" "$ti"; [ "$RC" = 0 ] && [ -z "$OUT" ] && ok 'flag removed from effective config: token-only ack of inline comment accepted silently' || bad 'token-only after removal'
jq -e --arg tr "$tr" '.records[0] | .pending == [] and (.receipts | length == 1 and .[0].token == $tr)' "$h/data/delivery/contributions.json" >/dev/null && ok 'saved receipt survived flag removal; no new receipt written' || bad 'receipt lost or added after removal'

say "S-late-owner: receipt saved, flag removed, PR merges, second task links PR, flag returns"
h="$S/late"; new_home "$h"; touch "$h/config/contribution-ack-receipts"; register "$WT" "$h"
review "$h" CHANGES_REQUESTED "The retry loop drops errors"; checks "$h" >/dev/null
tr=$(tok "$WT" "$h" pullrequestreview); steer "$h" delivery "Read $URL#pullrequestreview-12"
C "$WT" "$h" ack delivery "$URL" "$tr" handoff || bad 'handoff failed'
rm "$h/config/contribution-ack-receipts"; printf 'merged\n' > "$h/forge/state"; checks "$h" >/dev/null
printf -- '- [ ] latecomer - Filed %s (repo: sample) (kind: ship)\n' "$URL" >> "$h/data/backlog.md"; checks "$h" >/dev/null
touch "$h/config/contribution-ack-receipts"
run x x C "$WT" "$h" pending; [ "$RC" = 0 ] && ok 'home still readable after the flag returns' || bad 'home unreadable after flag returns'
show "latecomer receipts / delivery receipts"; jq -c '.records[0].receipts // "absent"' "$h/data/latecomer/contributions.json" "$h/data/delivery/contributions.json" | sed 's/^/    /'
jq -e '.records[0] | (has("receipts")|not) and .observation.state == "merged"' "$h/data/latecomer/contributions.json" >/dev/null && ok 'late owner got the merged observation without the receipt' || bad 'late owner record wrong'
jq -e '.records[0].receipts | length == 1' "$h/data/delivery/contributions.json" >/dev/null && ok 'owning task kept its receipt' || bad 'owner receipt lost'

say "S-hold: fm-captain-hold.sh settle-pr validates receipts only with the flag"
h="$S/hold"; new_home "$h"; touch "$h/config/hold-pr-settle" "$h/config/contribution-ack-receipts"
H "$h" "$WT/bin/fm-captain-hold.sh" hold delivery --reason 'Merge this PR?' >/dev/null || bad 'hold failed'
H "$h" "$WT/bin/fm-captain-hold.sh" pr-policy delivery "$URL" terminal close >/dev/null || bad 'policy failed'
jq '.records[0].observation.state="merged" | .records[0].receipts=[{}]' "$h/data/delivery/contributions.json" > "$h/u.json" && mv "$h/u.json" "$h/data/delivery/contributions.json"
run x x H "$h" "$WT/bin/fm-captain-hold.sh" settle-pr delivery "$URL"; [ "$RC" != 0 ] && H "$h" "$WT/bin/fm-captain-hold.sh" open delivery && ok 'flag on: malformed receipt refuses settlement, hold stays open' || bad 'flag on: malformed receipt settled'
rm "$h/config/contribution-ack-receipts"
run x x H "$h" "$WT/bin/fm-captain-hold.sh" settle-pr delivery "$URL"; [ "$RC" = 0 ] && ! H "$h" "$WT/bin/fm-captain-hold.sh" open delivery && ok 'flag off: same record settles the hold as on upstream main' || bad 'flag off: settlement refused'
h2="$S/hold-base"; new_home "$h2"; touch "$h2/config/hold-pr-settle"
H "$h2" "$BASE/bin/fm-captain-hold.sh" hold delivery --reason 'Merge this PR?' >/dev/null; H "$h2" "$BASE/bin/fm-captain-hold.sh" pr-policy delivery "$URL" terminal close >/dev/null
jq '.records[0].observation.state="merged" | .records[0].receipts=[{}]' "$h2/data/delivery/contributions.json" > "$h2/u.json" && mv "$h2/u.json" "$h2/data/delivery/contributions.json"
run x x H "$h2" "$BASE/bin/fm-captain-hold.sh" settle-pr delivery "$URL"; [ "$RC" = 0 ] && ok 'upstream main settles the same record too (baseline agrees)' || bad 'baseline differs: upstream refuses this record'

printf '\nRESULT: %s failure(s)\n' "$FAILS"; [ "$FAILS" = 0 ]
