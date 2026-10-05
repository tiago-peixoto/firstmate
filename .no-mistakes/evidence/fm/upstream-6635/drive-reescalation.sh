#!/usr/bin/env bash
# Live driver for issue 6635: escalate, operator close, second escalate.
# Usage: drive-reescalation.sh <source-root> <lab-home>
# Runs the real scripts of <source-root> against the disposable <lab-home>.
# The clock is the real clock; only the grace period is configured to 0.
set -u
ROOT=$1; HOME_DIR=$2
STATE="$HOME_DIR/state"
export FM_HOME="$HOME_DIR" FM_PENDING_REPLY_GRACE_SECS=0 FM_SEND_SETTLE=0
. "$ROOT/bin/fm-classify-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
STATUS="$STATE/mate.status"
fails=0
say() { printf '\n== %s\n' "$*"; }
show() {
  printf -- '-- status log (%s):\n' "$STATUS"; sed 's/^/   | /' "$STATUS"
  printf -- '-- blocked lines for the key: %s\n' "$(grep -cF "blocked [key=pending-reply-$corr]" "$STATUS")"
  printf -- '-- status_open_decisions: [%s]\n' "$(status_open_decisions "$STATUS" | tr '\t' ' ' | tr '\n' ';')"
  printf -- '-- record phase: %s\n' "$(fm_pending_reply_get "$(fm_pending_reply_path "$STATE" "$corr")" phase)"
}
expect() {  # <label> <want-blocked-count> <want-open: yes|no>
  local n open got
  n=$(grep -cF "blocked [key=pending-reply-$corr]" "$STATUS")
  open=$(status_open_decisions "$STATUS" | cut -f1 | grep -cxF "pending-reply-$corr")
  [ "$open" = 1 ] && got=yes || got=no
  if [ "$n" = "$2" ] && [ "$got" = "$3" ]; then
    printf 'RESULT ok   - %s (blocked lines=%s, decision open=%s)\n' "$1" "$n" "$got"
  else
    printf 'RESULT FAIL - %s (blocked lines=%s want %s, decision open=%s want %s)\n' "$1" "$n" "$2" "$got" "$3"
    fails=$((fails + 1))
  fi
}
lose_again() {  # the correlation-reusing resend path, then the watcher tick
  fm_pending_reply_reset_known_undelivered "$STATE" "$corr" || echo "reset refused rc=$?"
  fm_pending_reply_prepare_delivery "$STATE" "$corr" || echo "prepare refused rc=$?"
  sleep 1
  fm_pending_reply_tick "$STATE"
}

say "source root: $ROOT @ $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.rev")"
say "1. create an undelivered pending reply, attempt delivery, run the watcher tick"
corr=$(fm_pending_reply_create "$HOME_DIR" "$STATE" mate "wake after lost transport")
echo "corr=$corr"
fm_pending_reply_prepare_delivery "$STATE" "$corr"
sleep 1
fm_pending_reply_tick "$STATE"
show; expect "first loss appends one blocked line and opens the decision" 1 yes

say "2. retry while the decision is still open (idempotent retry)"
lose_again
show; expect "a retry of an open decision appends nothing" 1 yes

say "3. adversarial: a resolved line for ANOTHER key must not end this episode"
printf 'needs-decision [key=scope]: narrow or wide?\nresolved [key=scope]: answered: narrow\n' >> "$STATUS"
lose_again
show; expect "a resolve for another key does not reopen the dedupe" 1 yes

say "4. adversarial: a forged resolved line the reserved-key rule rejects must not end this episode"
printf 'resolved [key=pending-reply-%s]: answered: looks fine\n' "$corr" >> "$STATUS"
lose_again
show; expect "a rejected resolve neither closes nor allows a duplicate" 1 yes

say "5. operator close: bin/fm-send.sh mate --resolve-key pending-reply-$corr"
"$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$corr" "dismiss the unknown-delivery hold"
echo "fm-send exit=$?"
show; expect "the operator close closes the decision" 1 no

say "6. second same-kind loss after the operator close"
lose_again
show; expect "a new escalation after the close appends and reopens the decision" 2 yes

say "7. retry of the reopened decision"
lose_again
show; expect "a retry of the reopened decision appends nothing" 2 yes

say "8. second operator close, then a third loss"
"$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$corr" "dismiss again"
echo "fm-send exit=$?"
expect "the second operator close closes the decision" 2 no
lose_again
show; expect "a third episode appends and reopens again" 3 yes

say "SUMMARY: $fails failed expectation(s)"
echo "DRIVER-DONE fails=$fails"
