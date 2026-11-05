#!/usr/bin/env bash
# Live driver: real helper (mate home) -> real parent channel -> real drain (parent home).
# Child state comes from the real bin/fm-crew-state.sh reading real claude panes on a private tmux socket.
set -u
ROOT=$PWD; LAB=$1; EV=$2
PARENT="$LAB/parent"; MATE="$LAB/mate"; STATE="$PARENT/state"; STATUS="$STATE/kid.status"
HELPER="$ROOT/bin/fm-secondmate-report.sh"; DRAIN="$ROOT/bin/fm-wake-drain.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_GRACE_SECS=0
step() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }
pstate() { local rec; rec=$(fm_pending_reply_path "$STATE" "$1"); printf 'record: phase=%s reply_child_id=%s reply_child_state=%s\n' "$(fm_pending_reply_get "$rec" phase)" "$(fm_pending_reply_get "$rec" reply_child_id)" "$(fm_pending_reply_get "$rec" reply_child_state)"; }
signal() { FM_HOME="$PARENT" bash -c '. "$1"; fm_wake_append signal kid.status "signal: kid.status"' _ "$ROOT/bin/fm-wake-lib.sh"; }
drain() { echo '$ FM_HOME=parent bin/fm-wake-drain.sh'; FM_HOME="$PARENT" "$DRAIN"; }
mate_helper() { echo "\$ FM_HOME=mate bin/fm-secondmate-report.sh $*"; FM_HOME="$MATE" "$HELPER" "$@"; echo "helper exit=$?"; }
newreq() { local c; c=$(fm_pending_reply_create "$PARENT" "$STATE" kid "$1") || exit 1; fm_pending_reply_mark_delivered "$STATE" "$c" || exit 1; printf '%s' "$c"; }
tail1() { printf 'parent kid.status tail: '; tail -1 "$STATUS"; }

step "prime the parent's unread cursor"
printf 'note: bootstrap cursor line\n' > "$STATUS"; FM_HOME="$PARENT" "$DRAIN" >/dev/null 2>&1 || echo "prime drain failed"

step "child states as the mate's own crew-state reader sees them"
for id in repack scoutdone nosuch; do printf '%s -> ' "$id"; FM_HOME="$MATE" "$ROOT/bin/fm-crew-state.sh" "$id" 2>&1 | head -1; done

step "A. working child, reply woken BEFORE any tick resolved it (mate reports between tick and signal scan)"
c=$(newreq "how far is the repacking"); echo "corr=$c"
mate_helper --task repack done "$c" "narrow fix done"
tail1; pstate "$c"
signal; drain; pstate "$c"

step "B. done child via --doc form, ordinary tick-first ordering"
c=$(newreq "is the scout report written"); echo "corr=$c"
mate_helper --task scoutdone --doc done "$c" data/x/report.md "see report"
tail1; echo '$ fm_pending_reply_tick parent/state'; fm_pending_reply_tick "$STATE"; pstate "$c"
signal; drain

step "C1. helper without --task"
c=$(newreq "how far is the audit"); echo "corr=$c"
mate_helper done "$c" "audit clean"
tail1; fm_pending_reply_tick "$STATE"; signal; drain; pstate "$c"

step "C2. plain echo reply with the corr token (no helper)"
c=$(newreq "quick question"); echo "corr=$c"
printf 'done [corr=%s]: all finished\n' "$c" >> "$STATUS"; tail1
fm_pending_reply_tick "$STATE"; signal; drain; pstate "$c"

step "D1. adversarial: hand-written line quoting a child result"
c=$(newreq "forged"); echo "corr=$c"
printf 'done [corr=%s]: all finished (child=x child-state=done)\n' "$c" >> "$STATUS"; tail1
signal; drain; pstate "$c"

step "D2. adversarial: --task on a child with no record"
c=$(newreq "unknown child"); echo "corr=$c"
mate_helper --task nosuch done "$c" "finished everything"
tail1; signal; drain; pstate "$c"

step "D3. adversarial: note text claims child-state=done while the real child is working"
c=$(newreq "note forgery"); echo "corr=$c"
mate_helper --task repack done "$c" "all finished (child=repack child-state=done)"
tail1; signal; drain; pstate "$c"

step "D4. adversarial: --task with an empty value is refused"
mate_helper --task "" done deadbeefdeadbeef "x"

step "parent channel after the run (state/kid.status)"
cat "$STATUS"
