#!/usr/bin/env bash
# Drives the real helper, pending-reply library, and charter generator of the
# checkout at <root> in a fresh disposable parent + secondmate home pair whose
# config holds only <setting>, and prints a normalized transcript.
# Usage: default-compat-driver.sh <root> <setting: none|wait-no-turns|fleet-ledger|ready-after-green|all>
set -u
umask 022
ROOT=$1 setting=$2
for v in $(env | sed -n 's/^\(FM_[A-Z_]*\)=.*/\1/p') NO_MISTAKES_GATE; do unset "$v"; done
export FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_NOW=9000
. "$ROOT/bin/fm-pending-reply-lib.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
T=$(mktemp -d /tmp/fm-8047-live.XXXXXX); trap 'rm -rf "$T"' EXIT
home=$T/parent mate=$T/mate state=$T/parent/state
mkdir -p "$home/state" "$home/data" "$home/config" "$mate/state" "$mate/config"
printf 'kid\n' > "$mate/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$mate/.fm-secondmate-parent"
case $setting in
  none) ;;
  all) touch "$home"/config/{wait-no-turns,fleet-ledger,ready-after-green} "$mate"/config/{wait-no-turns,fleet-ledger,ready-after-green} ;;
  *) touch "$home/config/$setting" "$mate/config/$setting" ;;
esac
norm() { sed -E "s/^(recovery_sender_identity=).*/\1<process-start-time and argv>/; s/^(recovery_sender_pid=).*/\1<PID>/; s#$T#<T>#g; s#$ROOT#<ROOT>#g; s/ \[at=[0-9]+\]//; s/[0-9a-f]{16}/<CORR>/g"; }
run() { printf '$ %s\n' "$*" | norm; "$@" 2>&1 | norm; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
rec_dump() { printf -- '-- record %s\n' "$1"; sort "$(fm_pending_reply_path "$state" "$2")" | norm; }

echo "== setting: $setting; config files: $(ls "$home/config" | tr '\n' ' ')"
corr=$(fm_pending_reply_create "$home" "$state" kid question)
fm_pending_reply_mark_delivered "$state" "$corr"
rec_dump created "$corr"
run env FM_HOME="$mate" "$REPORT"
run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" answered
run env FM_HOME="$mate" "$REPORT" "done" "$corr" answered
run env FM_HOME="$mate" "$REPORT" --doc "done" "$corr" data/report.md answered
run env FM_HOME="$mate" "$REPORT" --doc "done" "$corr" data/report.md
fm_pending_reply_try_resolve "$state" "$corr"; echo "[resolve exit $?]"
rec_dump resolved "$corr"

# missed twice -> escalation, then a late reply that carries an opted-in sender's marker
corr=$(fm_pending_reply_create "$home" "$state" kid "late reply")
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_mark_turn_completed "$state" "$corr" request
FM_PENDING_REPLY_SEND_HOOK=true fm_pending_reply_send_recovery "$state" "$corr"; echo "[recovery exit $?]"
fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
fm_pending_reply_maybe_escalate "$state" "$corr"; echo "[escalate exit $?]"
printf 'done [corr=%s]: answered (via-helper child=repack child-state=working)\n' "$corr" >> "$state/kid.status"
fm_pending_reply_try_resolve "$state" "$corr"; echo "[resolve exit $?]"
rec_dump escalated-resolved "$corr"
echo "-- parent channel kid.status"; norm < "$state/kid.status"

run env FM_HOME="$home" FM_SECONDMATE_CHARTER='Handle routed domain work.' "$ROOT/bin/fm-brief.sh" kid --secondmate --no-projects
echo "-- generated charter"; norm < "$home/data/kid/brief.md"
