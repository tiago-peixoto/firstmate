#!/usr/bin/env bash
# Usage: wronghome-escalation-drive.sh <bin-root>
set -u
root=$1
. "$root/bin/fm-pending-reply-lib.sh"
home=$(mktemp -d "${TMPDIR:-/tmp}/fm-prw.XXXXXX"); trap 'rm -rf "$home"' EXIT
sm="$home/sm"; mkdir -p "$home/state" "$sm/state"
export FM_HOME=$home FM_PENDING_REPLY_NOW=1000
corr=$(fm_pending_reply_create "$home" "$home/state" mate 'Wrong home probe')
fm_pending_reply_mark_delivered "$home/state" "$corr"
rec=$(fm_pending_reply_path "$home/state" "$corr")
# reply landed in the secondmate's own status file at line 5, after a blank line and near-miss tokens
{ printf 'working: a\n\n'; printf 'done [corr=%sff]: near miss\n' "$corr"; printf 'working: b\n'
  printf 'done [corr=%s]: wrong home reply\n' "$corr"; printf 'done [corr=%s]: second, unterminated' "$corr"; } > "$sm/state/child.status"
fm_pending_reply_detect_wrong_home "$home/state" "$corr" "$sm" >/dev/null 2>&1; echo "detect_rc=$?"
echo "hits=$(fm_pending_reply_get "$rec" wrong_home_hits)"
echo "first_sighting_line=$(fm_pending_reply_get "$rec" wrong_home_first_sighting | awk -F: '{print $NF}')"
echo "sightings_lines=$(fm_pending_reply_get "$rec" wrong_home_sightings | tr ',' '\n' | awk -F: '{print $NF}' | paste -sd, -)"
# escalation lookup: published escalation among many unrelated blocked lines, unterminated
pstat="$home/parent.status"
payload=$(fm_pending_reply_escalation_payload "$rec" missed)
key=$(fm_pending_reply_escalation_key "$corr")
{ for i in 1 2 3; do printf 'blocked: unrelated decision %s\n' "$i"; done
  printf 'blocked [key=%s]: %s' "$key" "$payload"; } > "$pstat"
found=$(fm_pending_reply_escalation_line "$pstat" "$rec" "$corr")
[ -n "$found" ] && echo "escalation_found=yes" || echo "escalation_found=no"
other=$(fm_pending_reply_escalation_line "$pstat" "$rec" "0000000000000000")
[ -z "$other" ] && echo "foreign_corr_escalation=none" || echo "foreign_corr_escalation=FOUND"
