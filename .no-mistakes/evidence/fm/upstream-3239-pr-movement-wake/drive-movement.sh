#!/usr/bin/env bash
# Drives the real bin/fm-pr-check.sh, the registered check shim, bin/fm-contributions.sh
# and bin/fm-bearings-snapshot.sh from the run worktree against a disposable home
# and a local gh emulator (the fixture forge from tests/fm-contributions.test.sh).
set -u
ROOT=$1
T=$ROOT/tests/fm-contributions.test.sh
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-movement-drive.XXXXXX"); trap 'rm -rf "$TMP_ROOT"' EXIT
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fail() { printf 'FAIL - %s\n' "$1"; exit 1; }
fn() { awk -v f="$1" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$T"; }
for f in new_home bearings record forge_home with_home registered_checks queued_wakes; do eval "$(fn $f)"; done
U=https://github.com/o/r/pull/8
C() { with_home "$home" "$ROOT/bin/fm-contributions.sh" "$@"; }
show() { printf '  wakes queued: %s\n  pending: %s\n' "$(queued_wakes "$home")" "$(C pending | jq -c '[.[]|{type,body,author}]')"; }
poll() { registered_checks "$home" >/dev/null; }
ackall() { C pending | jq -r '.[].token' | while read -r t; do C ack delivery "$U" "$t" >/dev/null || fail "ack $t"; done; }
step() { printf '\n== %s\n' "$1"; }
rc=0; expect() { if [ "$(queued_wakes "$home")" = "$1" ] && C pending | jq -e "$2" >/dev/null; then echo "  RESULT: ok"; else echo "  RESULT: UNEXPECTED (want wakes=$1, pending: $2)"; rc=1; fi; }

home=$(new_home drive); forge_home "$home"
step "1. register PR with fm-pr-check.sh, poll an unchanged PR twice"
with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery "$U" || fail register
poll; poll; show; expect 0 'length==0'

step "2. head replaced A -> B, poll; then re-poll unchanged"
echo "$HEAD_B" > "$home/forge/head"; poll; show; expect 1 'length==1 and .[0].type=="head"'
poll; show; expect 1 'length==1'

step "3. ack; convert to draft (no wake expected), then leave draft"
ackall; echo true > "$home/forge/draft"; poll; show; expect 1 'length==0'
echo false > "$home/forge/draft"; poll; show; expect 2 'length==1 and .[0].type=="ready-for-review"'

step "4. ack; request a reviewer and a team in one poll (one durable wake per signal); re-poll"
ackall; echo '[{"login":"reviewer"}]' > "$home/forge/requested.json"; echo '[{"slug":"core","name":"Core"}]' > "$home/forge/teams.json"
poll; show; expect 4 'length==2 and all(.[]; .type=="review-requested") and ([.[].body]|sort)==["review requested from reviewer","review requested from team:core"]'
poll; show; expect 4 'length==2'

step "5. ack; maintainer issue comment arrives"
ackall
jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
poll; show; expect 5 'length==1 and .[0].author=="maintainer"'

step "6. ack; maintainer CHANGES_REQUESTED review arrives"
ackall
jq -n --arg h "$HEAD_B" '[{id:13,user:{login:"maintainer"},author_association:"OWNER",body:"Needs work",html_url:"https://github.com/o/r/pull/8#pullrequestreview-13",updated_at:"2026-09-16T08:02:00Z",submitted_at:"2026-09-16T08:02:00Z",commit_id:$h,state:"CHANGES_REQUESTED"}]' > "$home/forge/reviews.json"
poll; show; expect 6 'length==1 and .[0].author=="maintainer"'

step "7. adversarial: ack; reviewer un-requested -> no wake; same reviewer re-requested one hour later -> wakes again"
ackall; echo '[]' > "$home/forge/requested.json"; poll; show; expect 6 'length==0'
NOW=2026-09-16T09:00:00Z
echo '[{"login":"reviewer"}]' > "$home/forge/requested.json"; poll; show; expect 7 'length==1 and .[0].body=="review requested from reviewer"'
poll; show; expect 7 'length==1'

step "8. adversarial: PR merged with a different head in the same observation -> no head movement signal"
ackall; before=$(queued_wakes "$home")
echo "$HEAD_A" > "$home/forge/head"; echo merged > "$home/forge/state"; poll; show
C pending | jq -e 'all(.[]; .type != "head" and .type != "review-requested" and .type != "ready-for-review")' >/dev/null && echo "  RESULT: ok (no movement signal; wakes $before -> $(queued_wakes "$home"))" || { echo "  RESULT: UNEXPECTED"; rc=1; }
echo "  stored: $(jq -c '.records[0].observation|{state,head}' "$home/data/delivery/contributions.json")"

step "9. adversarial: fresh home, reviewer already requested at first observation -> baseline, no wake"
home=$(new_home drive-baseline); forge_home "$home"; rm "$home/data/delivery/contributions.json"
echo '[{"login":"reviewer"}]' > "$home/forge/requested.json"
with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery "$U" >/dev/null || fail register
poll; poll; show; expect 0 'length==0'
echo "  stored review_requests: $(jq -c '.records[0].observation.review_requests' "$home/data/delivery/contributions.json")"
echo; [ $rc = 0 ] && echo "ALL STEPS AS EXPECTED" || echo "SOME STEPS UNEXPECTED"; exit $rc
