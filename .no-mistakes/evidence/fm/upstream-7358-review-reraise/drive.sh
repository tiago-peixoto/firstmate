set -u
cd "/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M57HQCX3DNWERC9T78HQBNF9"
. "/tmp/tmp.KWeffJdxEc/defs.sh"
TARGET=$ROOT
run_ages() { # label root
  echo "== $1 ($2/bin/fm-contributions.sh poll) =="
  local h; h=$(unanswered_home "ages-$1")
  for v in 0 00 000 soon 3600 03600; do
    out=$(with_home "$h" env FM_CONTRIBUTIONS_REPLY_AGE="$v" "$2/bin/fm-contributions.sh" poll 2>&1); rc=$?
    printf 'FM_CONTRIBUTIONS_REPLY_AGE=%-6s exit=%s %s\n' "$v" "$rc" "$(printf '%s' "$out" | head -1)"
  done
}
run_ages target "$TARGET"
run_ages parent "/tmp/tmp.KWeffJdxEc/parent"
echo "== target: 19-hour inline comment under a captain hold, reply age 86400 =="
h=$(unanswered_home hold-demo)
grep ' delivery ' "$h/data/backlog.md"
echo "poll 08:01 ->"; poll_at "$h" 2026-09-16T08:01:00Z
ack_pending "$h"; echo "acked pending signal"
echo "poll +19h (2026-09-17T03:00) ->"; poll_at "$h" 2026-09-17T03:00:00Z; echo "(empty above means no wake)"
echo "poll +25h (2026-09-17T09:00) ->"; poll_at "$h" 2026-09-17T09:00:00Z
echo "pending ->"; with_home "$h" "$TARGET/bin/fm-contributions.sh" pending | jq -c .
echo "== target: unconfigured install, same thread, 9 days later =="
h=$(unanswered_home off-demo); wrap_forge "$h"
with_home "$h" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-16T08:01:00Z "$TARGET/bin/fm-contributions.sh" poll
ack_pending "$h"
echo "poll 2026-09-25 ->"; with_home "$h" env -u FM_CONTRIBUTIONS_REPLY_AGE FM_CONTRIBUTIONS_NOW=2026-09-25T09:00:00Z "$TARGET/bin/fm-contributions.sh" poll
echo "graphql calls: $(grep -c 'api graphql' "$h/forge/calls")"
