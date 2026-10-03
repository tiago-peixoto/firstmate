#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
export TMUX="$(cat "$LAB/sock"),0,0"
"$ROOT/bin/fm-wake-drain.sh" >/dev/null 2>&1; : > "$STATE/.wake-queue"
say "Session E, flag present: a send whose delivery is unknown escalates"
token
c=$(fm_pending_reply_create "$LAB" "$STATE" mate "wake after lost transport"); echo "$c" > "$LAB/corr4"
fm_pending_reply_prepare_delivery "$STATE" "$c"; fm_pending_reply_mark_delivery_unknown "$STATE" "$c"
fm_pending_reply_maybe_escalate "$STATE" "$c"; rec_fields "$c"
say "Operator closes it; the reminder pass records the close"
show "$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$c" "ack, will resend"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"; rec_fields "$c" | grep dismissed_epoch
say "The send is reset and resent, the flag is removed, and the record escalates again as missed"
fm_pending_reply_reset_known_undelivered "$STATE" "$c"; echo "reset exit $?"
rm -f "$LAB/config/pending-reply-resurface"
fm_pending_reply_prepare_delivery "$STATE" "$c"; fm_pending_reply_confirm_delivery "$STATE" "$c"
fm_pending_reply_mark_turn_completed "$STATE" "$c" request
fm_pending_reply_send_recovery "$STATE" "$c"; fm_pending_reply_mark_turn_completed "$STATE" "$c" recovery
fm_pending_reply_maybe_escalate "$STATE" "$c"; echo "second escalation exit $?"
rec_fields "$c"
grep -n "key=pending-reply-$c" "$STATE/mate.status" | cut -c1-150
say "The flag is added back"
touch "$LAB/config/pending-reply-resurface"
show "$ROOT/bin/fm-pending-reply-remind.sh" "$STATE"; queue
