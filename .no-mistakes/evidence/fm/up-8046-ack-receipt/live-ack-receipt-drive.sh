#!/usr/bin/env bash
# Live drive of bin/fm-contributions.sh ack receipts (issue 8046) in a disposable
# FM_HOME whose path contains a space. GitHub is the only external boundary and
# is emulated by a fake `gh` keyed on the same API calls the product makes; the
# steer goes through the real bin/fm-send.sh against a private tmux server.
set -u
ROOT=${ROOT:?run worktree}
EV=${EV:?evidence dir}
LAB=$(mktemp -d "/tmp/fm ack lab.XXXXXX")
LAB=$(cd "$LAB" && pwd)
H="$LAB/home"
SOCKET="fm-ack-lab-$$"
# The marked lab home is what lets fm-send's lifecycle guard run from a gate worktree.
"$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || { echo 'could not mint the lab home'; exit 1; }
mkdir -p "$LAB/forge" "$LAB/bin" "$LAB/tmux" "$LAB/wt"
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NOW=2026-11-05T10:00:00Z
REAL_TMUX=$(command -v tmux)
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec env TMUX_TMPDIR="$LAB/tmux" "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
printf '#!/bin/sh\nexit 0\n' > "$LAB/bin/no-mistakes"
cat > "$LAB/bin/gh" <<'SH'
#!/usr/bin/env bash
# GitHub emulator: the external boundary. FORGE holds the synthetic PR state.
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
       merged_at:(if $state == "merged" then "2026-11-05T09:00:00Z" else null end)}' ;;
  'api repos/o/r/issues/9')
    jq -n --slurpfile labels "$FORGE/labels.json" '{state:"open",user:{login:"author"},labels:$labels[0]}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/8/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) printf '[[]]\n' ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api graphql '*)
    jq '[{data:{repository:{pullRequest:{reviewThreads:{nodes:.,pageInfo:{hasNextPage:false,endCursor:null}}}}}}]' "$FORGE/threads.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    printf '[{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-11-05T09:00:00Z"}]}]\n' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$LAB/bin/"*
printf '%s\n' "$HEAD_A" > "$LAB/forge/head"
for f in comments reviews inline threads labels events; do printf '[]\n' > "$LAB/forge/$f.json"; done

cleanup() { "$LAB/bin/tmux" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT

run() { # product command under the lab home
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    PATH="$LAB/bin:$PATH" FORGE="$LAB/forge" FM_HOME="$H" FM_CONTRIBUTIONS_NOW="${CLOCK:-$NOW}" "$@"
}
fmc() { run "$ROOT/bin/fm-contributions.sh" "$@"; }
checks() { local c; for c in "$H/state/"*.check.sh; do [ -f "$c" ] && run bash "$c"; done; }
pending() { fmc pending; }
token_of() { pending | jq -er "$1"; }
step() { printf '\n### %s\n' "$*"; }
show() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
expect_fail() { local msg=$1; shift; if "$@" 2>"$LAB/err"; then printf 'UNEXPECTED SUCCESS: %s\n' "$msg"; RESULT=fail; else printf 'refused (exit %s): %s\n' "$?" "$(cat "$LAB/err")"; fi; }
expect_ok() { local msg=$1; shift; if "$@" 2>"$LAB/err"; then printf 'accepted: %s\n' "$msg"; else printf 'UNEXPECTED REFUSAL (%s): %s\n' "$msg" "$(cat "$LAB/err")"; RESULT=fail; fi; }
assert() { local msg=$1; shift; if "$@"; then printf 'ok: %s\n' "$msg"; else printf 'ASSERTION FAILED: %s\n' "$msg"; RESULT=fail; fi; }
RESULT=pass
PR=https://github.com/o/r/pull/8
REC="$H/data/delivery/contributions.json"

step "lab home (path with a space): $H"
# Worker pane: a plain bash in a private tmux server, the endpoint fm-send rings.
"$LAB/bin/tmux" new-session -d -s lab -n delivery -x 120 -y 30 -c "$LAB/wt" bash
printf 'window=lab:delivery\nworktree=%s/wt\nkind=ship\n' "$LAB" > "$H/state/delivery.meta"
chmod 600 "$H/state/delivery.meta"
printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n- [ ] filed - Measured defect https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' "$PR" > "$H/data/backlog.md"
show run "$ROOT/bin/fm-pr-check.sh" delivery "$PR"
checks >/dev/null; echo "baseline poll done; pending: $(pending | jq -c .)"

step "S1 approved review WITH findings text arrives; token-only ack is refused"
jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
  body:"Approved, but the retry loop drops errors and the cache never expires",html_url:"https://github.com/o/r/pull/8#pullrequestreview-12",
  submitted_at:"2026-11-05T10:01:00Z",commit_id:$head,state:"APPROVED"}]' > "$LAB/forge/reviews.json"
checks >/dev/null
pending | jq .
TOKEN=$(token_of 'first | .token')
expect_fail 'token-only ack of an approved review with findings' fmc ack delivery "$PR" "$TOKEN"
assert 'refusal names handoff' grep -q handoff "$LAB/err"
assert 'signal still pending' [ "$(pending | jq length)" = 1 ]

step "S2 disposition guards: self-evidence, other PR, blank summary are refused"
expect_fail 'review cited as its own disposition evidence' fmc ack delivery "$PR" "$TOKEN" disposition "$PR#pullrequestreview-12" 'approved, non-blocking'
expect_fail 'evidence on another PR' fmc ack delivery "$PR" "$TOKEN" disposition https://github.com/o/r/pull/99#issuecomment-40 'fixed elsewhere'
expect_fail 'blank summary' fmc ack delivery "$PR" "$TOKEN" disposition "$PR#issuecomment-40" '   '
expect_fail 'disposition with missing summary arg' fmc ack delivery "$PR" "$TOKEN" disposition "$PR#issuecomment-40"
expect_fail 'unknown receipt kind' fmc ack delivery "$PR" "$TOKEN" shrug
assert 'signal still pending after refused dispositions' [ "$(pending | jq length)" = 1 ]

step "S3 handoff guards: no steer, steer to another task, steer naming review-123 (prefix) are refused"
expect_fail 'handoff with no steer' fmc ack delivery "$PR" "$TOKEN" handoff
printf 'window=lab:delivery\nworktree=%s/wt\nkind=ship\n' "$LAB" > "$H/state/other.meta"; chmod 600 "$H/state/other.meta"
show run "$ROOT/bin/fm-send.sh" other "Read $PR#pullrequestreview-12 and fix it"
show run "$ROOT/bin/fm-send.sh" delivery "Read $PR#pullrequestreview-123 and fix it"
ls -R "$H/state/delivery.inbox" "$H/state/other.inbox"
expect_fail 'handoff when only other task / review-123 steers exist' fmc ack delivery "$PR" "$TOKEN" handoff
assert 'signal still pending after refused handoffs' [ "$(pending | jq length)" = 1 ]

step "S4 real fm-send steer to the owning task naming the review, then handoff is accepted and the receipt persists"
show run "$ROOT/bin/fm-send.sh" delivery "Maintainer review: read $PR#pullrequestreview-12 and fix the retry loop and cache expiry"
echo "--- worker pane after doorbell:"; "$LAB/bin/tmux" capture-pane -p -t lab:delivery | grep -v '^$' | tail -5
expect_ok 'handoff after a steer naming the review' fmc ack delivery "$PR" "$TOKEN" handoff
assert 'nothing pending' [ "$(pending | jq length)" = 0 ]
echo "--- stored receipts:"; jq '.records[0].receipts' "$REC"
assert 'receipt bound to token, task delivery, kind handoff, ref 002.msg' \
  jq -e --arg t "$TOKEN" '.records[0].receipts == [{token:$t,task:"delivery",kind:"handoff",ref:"002.msg",at:"2026-11-05T10:00:00Z"}]' "$REC"
checks >/dev/null
assert 'later poll keeps receipt and does not re-raise the review' jq -e '(.records[0].receipts|length)==1 and (.records[0].pending|length)==0' "$REC"

step "S5 inline review comment: token-only ack refused; its 25h re-raise also refused; handoff via steer clears each"
jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",
  body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",
  created_at:"2026-11-05T10:02:00Z",updated_at:"2026-11-05T10:02:00Z",commit_id:$head}]' > "$LAB/forge/inline.json"
CLOCK=2026-11-05T10:03:00Z run env FM_CONTRIBUTIONS_REPLY_AGE=86400 "$ROOT/bin/fm-contributions.sh" poll >/dev/null
pending | jq -c '.[] | {type,source,token}'
TOKEN=$(token_of '.[] | select(.type=="review-comment") | .token')
expect_fail 'token-only ack of inline review comment' fmc ack delivery "$PR" "$TOKEN"
assert 'refusal names handoff' grep -q handoff "$LAB/err"
show run "$ROOT/bin/fm-send.sh" delivery "Answer $PR#discussion_r31"
expect_ok 'inline comment handoff' fmc ack delivery "$PR" "$TOKEN" handoff
CLOCK=2026-11-06T11:00:00Z run env FM_CONTRIBUTIONS_REPLY_AGE=86400 "$ROOT/bin/fm-contributions.sh" poll >/dev/null
pending | jq -c '.[] | {type,source,token}'
TOKEN=$(token_of '.[] | select(.type=="unanswered") | .token')
expect_fail 'token-only ack of re-raised unanswered thread' fmc ack delivery "$PR" "$TOKEN"
assert 'refusal names handoff' grep -q handoff "$LAB/err"
assert 'unanswered still pending' [ "$(pending | jq -c '[.[]|select(.type=="unanswered")]|length')" = 1 ]
expect_ok 'disposition for re-raise citing a reply comment on the PR' fmc ack delivery "$PR" "$TOKEN" disposition "$PR#issuecomment-40" 'author replied that the loop is bounded by the caller'
echo "--- receipts now:"; jq -c '.records[0].receipts[]' "$REC"
assert 'disposition receipt stored with evidence and summary' \
  jq -e --arg t "$TOKEN" 'any(.records[0].receipts[]; .token==$t and .kind=="disposition" and .ref=="https://github.com/o/r/pull/8#issuecomment-40" and .summary=="author replied that the loop is bounded by the caller" and .task=="delivery")' "$REC"

step "S6 signals without findings still ack with the token alone: bare approval, PR issue comment, ready-for-pr"
jq -n --arg head "$HEAD_A" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
  body:"Approved, but the retry loop drops errors and the cache never expires",html_url:"https://github.com/o/r/pull/8#pullrequestreview-12",
  submitted_at:"2026-11-05T10:01:00Z",commit_id:$head,state:"APPROVED"},
  {id:13,user:{login:"maintainer"},author_association:"OWNER",body:"",html_url:"https://github.com/o/r/pull/8#pullrequestreview-13",
  submitted_at:"2026-11-05T10:05:00Z",commit_id:$head,state:"APPROVED"}]' > "$LAB/forge/reviews.json"
jq -n '[{id:40,user:{login:"maintainer"},author_association:"OWNER",body:"Thanks, will merge after CI",html_url:"https://github.com/o/r/pull/8#issuecomment-40",
  updated_at:"2026-11-05T10:06:00Z",created_at:"2026-11-05T10:06:00Z"}]' > "$LAB/forge/comments.json"
printf '[{"name":"ready-for-pr"}]\n' > "$LAB/forge/labels.json"
CLOCK=2026-11-06T11:01:00Z checks >/dev/null
pending | jq -c '.[] | {type,source,token,body}'
T=$(token_of '.[] | select(.type=="review" and .source=="https://github.com/o/r/pull/8#pullrequestreview-13") | .token')
expect_ok 'bare approval token-only ack' fmc ack delivery "$PR" "$T"
T=$(token_of '.[] | select(.type=="comment") | .token')
expect_ok 'PR issue comment token-only ack' fmc ack delivery "$PR" "$T"
T=$(token_of '.[] | select(.type=="ready-for-pr") | .token')
expect_ok 'ready-for-pr token-only ack' fmc ack filed https://github.com/o/r/issues/9 "$T"
assert 'pending now empty' [ "$(pending | jq length)" = 0 ]
assert 'token-only acks stored no receipts' jq -e '(.records[0].receipts|length)==3' "$REC"

step "S7 a task that owns the PR later does not inherit the receipts"
printf 'merged\n' > "$LAB/forge/state"
CLOCK=2026-11-06T11:02:00Z checks >/dev/null
printf -- '- [ ] latecomer - Filed %s (repo: sample) (kind: ship)\n' "$PR" >> "$H/data/backlog.md"
CLOCK=2026-11-06T11:03:00Z checks >/dev/null
echo "--- latecomer record:"; jq -c '{task, receipts:(.records[0].receipts//[]), state:.records[0].observation.state}' "$H/data/latecomer/contributions.json"
assert 'latecomer has no receipts' jq -e '((.records[0].receipts//[])|length)==0' "$H/data/latecomer/contributions.json"
assert 'delivery still has its receipts' jq -e '(.records[0].receipts|length)==3' "$REC"

printf '\n=== RESULT: %s ===\n' "$RESULT"
[ "$RESULT" = pass ]
