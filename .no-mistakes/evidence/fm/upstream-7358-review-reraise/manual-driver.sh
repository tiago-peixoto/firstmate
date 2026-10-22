#!/usr/bin/env bash
# Drives the real bin/fm-contributions.sh against a disposable FM_HOME whose
# forge is the fake gh from tests/fm-contributions.test.sh. Reuses that file's
# fixture helpers (never its test functions) so the forge shape is identical.
set -u
ROOT_WT=${1:?worktree}
cd "$ROOT_WT" || exit 1
T=tests/fm-contributions.test.sh
# Print one helper function: from its definition line to its closing brace,
# ignoring braces inside the fake-gh heredoc (<<'SH' ... SH) it may contain.
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {p=1} p {print} p && /<<.SH.$/ {h=1} p && h && /^SH$/ {h=0; next} p && !h && /^}/ {p=0}' "$T"; }
. tests/lib.sh
TMP_ROOT=$(fm_test_tmproot fm-manual-7358)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
eval "$(fn new_home)"; eval "$(fn record)"; eval "$(fn mutate_record)"
eval "$(fn forge_home)"; eval "$(fn with_home)"; eval "$(fn wrap_forge)"
eval "$(fn unanswered_home)"; eval "$(fn ack_pending)"
poll_at() { with_home "$1" env FM_CONTRIBUTIONS_REPLY_AGE=86400 FM_CONTRIBUTIONS_NOW="$2" "$ROOT/bin/fm-contributions.sh" poll; }
show() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

show "SCENARIO A: 19-hour unanswered inline comment under a captain hold (FM_CONTRIBUTIONS_REPLY_AGE=86400)"
home=$(unanswered_home manual-hold)
printf 'backlog hold line: '; grep ' delivery ' "$home/data/backlog.md"
printf 'forge inline comments: '; jq -c . "$home/forge/inline.json"
show "A1 poll at 2026-09-16T08:01Z: comment arrives, ordinary wake"
run poll_at "$home" 2026-09-16T08:01:00Z
show "A2 supervisor acknowledges the pending signal"
run ack_pending "$home"
printf 'pending after ack: '; with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -c .
show "A3 poll 19h after the comment (03:00 next day): nothing raised yet"
run poll_at "$home" 2026-09-17T03:00:00Z
printf 'threads in record: '; jq -c '.records[0].threads' "$home/data/delivery/contributions.json"
show "A4 poll 25h after the comment: re-raised with URL and age"
run poll_at "$home" 2026-09-17T09:00:00Z
printf 'durable wake queue:\n'; cat "$home/state/.wake-queue"
printf 'pending now: '; with_home "$home" "$ROOT/bin/fm-contributions.sh" pending | jq -c .
printf 'record threads: '; jq -c '.records[0].threads' "$home/data/delivery/contributions.json"
show "A5 ack the re-raise, poll 24h later (08:00) -> silent, poll 25h later (09:00) -> raised again at 49h"
run ack_pending "$home"
run poll_at "$home" 2026-09-18T08:00:00Z
run poll_at "$home" 2026-09-18T09:00:00Z
printf 'notified unanswered tokens kept: '; jq -c '[.records[0].notified[] | select(startswith("unanswered:"))]' "$home/data/delivery/contributions.json"
show "A6 the author replies in the thread; later polls stay silent and tracking ends"
jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head},
  {id:32,in_reply_to_id:31,user:{login:"author"},author_association:"NONE",body:"Fixed in the next push",html_url:"https://github.com/o/r/pull/8#discussion_r32",created_at:"2026-09-18T10:00:00Z",updated_at:"2026-09-18T10:00:00Z",commit_id:$head}]' > "$home/forge/inline.json"
run poll_at "$home" 2026-09-18T10:05:00Z
run poll_at "$home" 2026-09-20T10:00:00Z
printf 'record threads/pending: '; jq -c '.records[0] | {threads,pending}' "$home/data/delivery/contributions.json"

show "SCENARIO B: a reply from a non-author account does NOT answer the thread (adversarial)"
home=$(unanswered_home manual-stranger)
jq -n --arg head "$HEAD_A" '[{id:31,user:{login:"maintainer"},author_association:"OWNER",body:"Why is this retried?",html_url:"https://github.com/o/r/pull/8#discussion_r31",created_at:"2026-09-16T08:00:00Z",updated_at:"2026-09-16T08:00:00Z",commit_id:$head},
  {id:33,in_reply_to_id:31,user:{login:"stranger"},author_association:"NONE",body:"me too",html_url:"https://github.com/o/r/pull/8#discussion_r33",created_at:"2026-09-16T09:00:00Z",updated_at:"2026-09-16T09:00:00Z",commit_id:$head}]' > "$home/forge/inline.json"
run poll_at "$home" 2026-09-16T09:01:00Z
run ack_pending "$home"
run poll_at "$home" 2026-09-17T09:30:00Z

show "SCENARIO C: unconfigured install (no FM_CONTRIBUTIONS_REPLY_AGE) never reads reviewThreads and never re-raises"
home=$(unanswered_home manual-off)
wrap_forge "$home"
poll_off() { with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW="$1" "$ROOT/bin/fm-contributions.sh" poll; }
run poll_off 2026-09-16T08:01:00Z
run ack_pending "$home"
run poll_off 2026-09-18T09:00:00Z
run poll_off 2026-09-25T09:00:00Z
printf 'graphql calls made by fake gh: %s\n' "$(grep -c 'api graphql' "$home/forge/calls" || true)"
printf 'distinct gh call kinds:\n'; awk '{print $1, $2}' "$home/forge/calls" | sed -E 's/[?].*//' | sort | uniq -c
printf 'record has threads key: '; jq -c '.records[0] | has("threads")' "$home/data/delivery/contributions.json"
show "C2 switch it on: the graphql reviewThreads read appears and the thread is raised"
run poll_at "$home" 2026-09-27T09:00:00Z
printf 'graphql calls now: %s\n' "$(grep -c 'api graphql' "$home/forge/calls" || true)"
grep 'api graphql' "$home/forge/calls" | head -1 | cut -c1-160

show "SCENARIO D: reply-age validation refuses 0, 00, 000, -5, soon, 1.5, empty-is-off, accepts 03600"
home=$(unanswered_home manual-validate)
for bad in 0 00 000 -5 soon 1.5; do
  printf '$ FM_CONTRIBUTIONS_REPLY_AGE=%s poll -> ' "$bad"
  out=$(with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE="$bad" "$ROOT/bin/fm-contributions.sh" poll 2>&1); rc=$?
  printf 'exit %s: %s\n' "$rc" "$out"
done
printf '$ FM_CONTRIBUTIONS_REPLY_AGE=03600 poll -> '
out=$(with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=03600 "$ROOT/bin/fm-contributions.sh" poll 2>&1); printf 'exit %s: %s\n' "$?" "$out"
printf '$ FM_CONTRIBUTIONS_REPLY_AGE= (empty) poll -> '
out=$(with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE= FM_CONTRIBUTIONS_NOW=2026-09-18T09:00:00Z "$ROOT/bin/fm-contributions.sh" poll 2>&1); printf 'exit %s: %s\n' "$?" "$out"

show "SCENARIO E: arm copies a configured reply age into the generated check shim"
home=$(unanswered_home manual-arm)
run poll_at "$home" 2026-09-16T08:01:00Z
run ack_pending "$home"
with_home "$home" env FM_CONTRIBUTIONS_REPLY_AGE=3600 "$ROOT/bin/fm-contributions.sh" arm >/dev/null; echo "[arm exit $?]"
printf 'generated shim:\n'; sed 's/^/    /' "$home/state/contributions.check.sh"
printf '$ run the shim with the variable unset in the caller env at +1.5h -> '
with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-16T09:30:00Z bash "$home/state/contributions.check.sh"; echo "[exit $?]"
with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE "$ROOT/bin/fm-contributions.sh" arm >/dev/null
printf 'shim re-armed without the setting mentions REPLY_AGE: '; grep -c REPLY_AGE "$home/state/contributions.check.sh"
printf '$ run unconfigured shim at +2d -> '
with_home "$home" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-18T09:30:00Z bash "$home/state/contributions.check.sh"; echo "[exit $?]"

show "SCENARIO F: merged pull request drops threads and unanswered signals"
home=$(unanswered_home manual-merged)
run poll_at "$home" 2026-09-16T08:01:00Z
run poll_at "$home" 2026-09-17T09:00:00Z
printf 'merged\n' > "$home/forge/state"
run poll_at "$home" 2026-09-18T09:00:00Z
printf 'record: '; jq -c '.records[0] | {state:.observation.state,threads,pending:[.pending[].type]}' "$home/data/delivery/contributions.json"
printf '\n(disposable homes under %s are removed by the test lib EXIT trap)\n' "$TMP_ROOT"
