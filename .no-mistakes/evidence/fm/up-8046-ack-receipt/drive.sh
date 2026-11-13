#!/usr/bin/env bash
# Live drive of bin/fm-contributions.sh ack receipts (issue 8046) in a disposable home.
# Real: fm-pr-check.sh, fm-contributions.sh (poll/pending/ack/retire), fm-send.sh, tmux on a private socket.
# Every home is a marked lab home from bin/fm-lab-home.sh, which is what lets fm-send run inside the gate.
# Synthetic: the forge (a fake `gh` serving JSON files) and the worker pane (a `cat` process).
# Usage: drive.sh <worktree-root> [<bin-dir-for-fm-contributions>]
set -u
ROOT=$1
CBIN=${2:-$ROOT/bin}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-ack-drive.XXXXXX")
REAL_TMUX=$(command -v tmux)
REAL_AWK=$(command -v awk)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/o/r/pull/8
FAILS=0
"$ROOT/bin/fm-lab-home.sh" create "$LAB/tmuxhome" >/dev/null || exit 2
TMUXDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB/tmuxhome") || exit 2
ltmux() { TMUX_TMPDIR="$TMUXDIR" "$REAL_TMUX" -L fm-lab "$@"; }
cleanup() {
  ltmux kill-server 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB/tmuxhome"
  rm -rf "$LAB"
}
trap cleanup EXIT
ltmux new-session -d -s lab -x 200 -y 50 -c "$LAB" cat

# Fixture helpers copied from tests/fm-contributions.test.sh (new_home, forge_home, with_home).
. <(sed -n '/^new_home() {/,/^}/p;/^record() {/,/^}/p;/^forge_home() {/,/^}/p;/^with_home() {/,/^}/p' "$ROOT/tests/fm-contributions.test.sh")
TMP_ROOT=$LAB

c() { with_home "$HOME_" "$CBIN/fm-contributions.sh" "$@"; }
poll() { local check; for check in "$HOME_/state/"*.check.sh; do with_home "$HOME_" bash "$check" >/dev/null; done; }
pending() { c pending | jq -c '[.[] | {type,token,source}]'; }
token() { c pending | jq -er "${1:-first} | .token"; }
receipts() { jq -c '.records[0].receipts // []' "$HOME_/data/${1:-delivery}/contributions.json"; }
say() { printf '\n## %s\n' "$*"; }
expect() { # want-rc label cmd...
  local want=$1 label=$2 rc; shift 2
  printf '$ fm-contributions.sh %s\n' "$*"
  c "$@" 2>&1 | sed 's/^/    /'; rc=${PIPESTATUS[0]}
  if { [ "$want" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$want" = refuse ] && [ "$rc" -ne 0 ]; }; then
    printf '  => exit %s  OK (%s)\n' "$rc" "$label"
  else
    printf '  => exit %s  UNEXPECTED (%s)\n' "$rc" "$label"; FAILS=$((FAILS + 1))
  fi
}
check() { # label jq-or-test result
  if [ "$2" = "$3" ]; then printf '  OK   %s: %s\n' "$1" "$2"; else printf '  FAIL %s: got %s want %s\n' "$1" "$2" "$3"; FAILS=$((FAILS + 1)); fi
}
home() { # name: registered delivery on PR 8 with a live worker pane and a real tmux behind fm-send
  "$ROOT/bin/fm-lab-home.sh" create "$LAB/$1" >/dev/null || { echo 'setup: fm-lab-home create failed'; exit 2; }
  HOME_=$(new_home "$1"); forge_home "$HOME_"
  printf '#!/bin/sh\nTMUX_TMPDIR=%s exec %s -L fm-lab "$@"\n' "$TMUXDIR" "$REAL_TMUX" > "$HOME_/fakebin/tmux"
  ltmux new-window -d -t lab: -n "fm-$1" cat
  printf 'window=lab:fm-%s\nkind=ship\nharness=claude\nworktree=%s/wt\n' "$1" "$HOME_" > "$HOME_/state/delivery.meta"
  with_home "$HOME_" "$ROOT/bin/fm-pr-check.sh" delivery "$URL" >/dev/null || { echo 'setup: fm-pr-check failed'; exit 2; }
  poll
}
review() { # state body
  jq -n --arg head "$HEAD_A" --arg state "$1" --arg body "$2" '[{id:12,user:{login:"maintainer"},author_association:"OWNER",
    body:$body,html_url:"https://github.com/o/r/pull/8#pullrequestreview-12",
    submitted_at:"2026-09-16T08:01:00Z",commit_id:$head,state:$state}]' > "$HOME_/forge/reviews.json"
  poll
}
send() { # task text: the real fm-send, as the supervisor runs it
  printf '$ fm-send.sh %s %q\n' "$1" "$2"
  env -u TMUX -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$HOME_/fakebin:$PATH" FM_HOME="$HOME_" "$ROOT/bin/fm-send.sh" "$1" "$2" 2>&1 | sed 's/^/    /'
  printf '  => exit %s; inbox: %s\n' "${PIPESTATUS[0]}" "$(cd "$HOME_/state/$1.inbox" 2>/dev/null && find . -name '*.msg' | sort | tr '\n' ' ')"
}

printf '# fm-contributions.sh under test: %s\n' "$CBIN"

say 'S1 approved review with findings: token alone is refused'
home s1; review APPROVED 'Approved, but the retry loop drops errors and the cache never expires'
T=$(token); echo "pending: $(pending)"
expect refuse 'token-only ack of a review with text' ack delivery "$URL" "$T"
check 'still pending' "$(c pending | jq length)" 1

say 'S2 handoff needs a steer to the owning task that names this exact review'
expect refuse 'handoff with no steer at all' ack delivery "$URL" "$T" handoff
printf 'window=lab:fm-s1\nkind=ship\nharness=claude\n' > "$HOME_/state/other.meta"
send other "Read $URL#pullrequestreview-12 and fix it"
send delivery "Read $URL#pullrequestreview-123 and fix it"
expect refuse 'steer to another task, and steer naming review-123 (prefix)' ack delivery "$URL" "$T" handoff
check 'still pending' "$(c pending | jq length)" 1
send delivery "Read $URL#pullrequestreview-12 and fix it"
expect ok 'steer naming the review in the owning inbox' ack delivery "$URL" "$T" handoff
check 'pending cleared' "$(c pending | jq length)" 0
echo "receipts: $(receipts)"
check 'receipt bound to token+task+record' "$(receipts | jq -c --arg t "$T" '. == [{token:$t,task:"delivery",kind:"handoff",ref:"002.msg",at:"2026-09-16T08:00:00Z"}]')" true
poll
check 'later poll keeps receipt, does not re-raise' "$(jq -c '[(.records[0].receipts|length),(.records[0].pending|length)]' "$HOME_/data/delivery/contributions.json")" '[1,0]'

say 'S3 handoff is satisfied by a steer the worker already handled'
home s3; review CHANGES_REQUESTED 'The retry loop drops errors'; T=$(token)
send delivery "Read $URL#pullrequestreview-12 and fix it"
mv "$HOME_/state/delivery.inbox/001.msg" "$HOME_/state/delivery.inbox/handled/001.msg"; echo '$ mv 001.msg handled/   (worker acknowledgement)'
expect ok 'handled steer naming the review' ack delivery "$URL" "$T" handoff
echo "receipts: $(receipts)"
check 'receipt names handled record' "$(receipts | jq -r '.[0].ref')" 001.msg

say 'S4 race: the worker moves the listed steer into handled/ just before ack opens it'
home s4; review CHANGES_REQUESTED 'The retry loop drops errors'; T=$(token)
send delivery "Read $URL#pullrequestreview-12 and fix it"
cat > "$HOME_/fakebin/awk" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$MOVING_STEER" ] && [ -f "$MOVING_STEER" ]; then
    mv "$MOVING_STEER" "${MOVING_STEER%/*}/handled/" || exit 99
  fi
done
exec "$REAL_AWK" "$@"
SH
chmod +x "$HOME_/fakebin/awk"
export REAL_AWK MOVING_STEER="$HOME_/state/delivery.inbox/001.msg"
expect ok 'steer moved to handled/ during the read' ack delivery "$URL" "$T" handoff
unset MOVING_STEER; rm -f "$HOME_/fakebin/awk"
check 'record was moved mid-ack' "$(cd "$HOME_/state/delivery.inbox" && find . -name '*.msg')" ./handled/001.msg
check 'pending cleared' "$(c pending | jq length)" 0
echo "receipts: $(receipts)"

say 'S5 disposition needs different evidence on the same pull request and a reason'
home s5; review CHANGES_REQUESTED 'The retry loop drops errors'; T=$(token)
expect refuse 'evidence on another pull request' ack delivery "$URL" "$T" disposition https://github.com/o/r/pull/99#issuecomment-40 fixed
expect refuse 'blank reason' ack delivery "$URL" "$T" disposition "$URL#issuecomment-40" '  '
expect refuse 'the review cited as its own evidence, live task' ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" 'approved, non-blocking'
expect refuse 'unknown receipt kind' ack delivery "$URL" "$T" waived
check 'still pending' "$(c pending | jq length)" 1
expect ok 'different comment on this PR plus a reason' ack delivery "$URL" "$T" disposition "$URL#issuecomment-40" 'author replied that the loop is bounded by the caller'
echo "receipts: $(receipts)"
check 'receipt stores evidence and reason' "$(receipts | jq -c --arg t "$T" --arg u "$URL" '. == [{token:$t,task:"delivery",kind:"disposition",ref:($u+"#issuecomment-40"),summary:"author replied that the loop is bounded by the caller",at:"2026-09-16T08:00:00Z"}]')" true

say 'S6 torn-down task (no state/delivery.meta): self-citing disposition, then retire'
home s6; review CHANGES_REQUESTED 'The retry loop drops errors'; T=$(token)
rm -f "$HOME_/state/delivery.meta"; echo '$ rm state/delivery.meta   (as fm-teardown does)'
expect refuse 'retire with the review unacknowledged' retire delivery "$URL" captain 'task finished'
expect refuse 'self-citing disposition with a blank reason' ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" ' '
expect ok 'self-citing disposition with a reason' ack delivery "$URL" "$T" disposition "$URL#pullrequestreview-12" 'task finished and torn down; follow-up filed'
expect ok 'retire after disposition' retire delivery "$URL" captain 'task finished'

say 'S7 inline review comment: token alone is refused'
home s7
jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",body:"Why is this retried?",
  html_url:"https://github.com/o/r/pull/8#discussion_r31",created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head}]' > "$HOME_/forge/inline.json"
poll; T=$(token); echo "pending: $(pending)"
expect refuse 'token-only ack of an inline comment' ack delivery "$URL" "$T"
check 'still pending' "$(c pending | jq length)" 1

say 'S8 signals without findings still acknowledge with the token alone'
home s8a; review APPROVED ''; T=$(token); echo "pending: $(pending)"
expect ok 'approval with no text' ack delivery "$URL" "$T"
check 'pending cleared' "$(c pending | jq length)" 0
home s8b
jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
  html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z"}]' > "$HOME_/forge/comments.json"
poll; T=$(token); echo "pending: $(pending)"
expect ok 'issue comment' ack delivery "$URL" "$T"
check 'pending cleared' "$(c pending | jq length)" 0
home s8c
printf -- '- [ ] filed - Filed https://github.com/o/r/issues/9 (repo: sample) (kind: ship)\n' >> "$HOME_/data/backlog.md"
c poll >/dev/null
printf '[{"event":"labeled","id":88,"label":{"name":"ready-for-pr"}}]\n' > "$HOME_/forge/events.json"
c poll >/dev/null; T=$(token '.[] | select(.type=="ready-for-pr")'); echo "pending: $(pending)"
expect ok 'ready-for-pr transition' ack filed https://github.com/o/r/issues/9 "$T"
check 'pending cleared' "$(c pending | jq length)" 0

say 'S9 receipt is bound to its token and task'
home s9; review CHANGES_REQUESTED 'The retry loop drops errors'; T=$(token)
send delivery "Read $URL#pullrequestreview-12 and fix it"
expect ok 'handoff under a token that is not pending is a no-op' ack delivery "$URL" "review:999:x" handoff
check 'no receipt minted for a token that is not pending' "$(receipts)" '[]'
expect refuse 'handoff claimed by a task that does not own the record' ack other "$URL" "$T" handoff
check 'still pending' "$(c pending | jq length)" 1
expect ok 'handoff by the owning task under the pending token' ack delivery "$URL" "$T" handoff
echo "receipts: $(receipts)"

printf '\n# unexpected results: %s\n' "$FAILS"
[ "$FAILS" -eq 0 ]
