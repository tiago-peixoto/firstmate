#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
say "Session F (new real claude primary) ran bin/fm-session-start.sh with the flag present"
show "$ROOT/bin/fm-lock.sh" status; token; queue
rec_fields "$(cat "$LAB/corr4")"
printf 'Bearings pending-reply rows: '; "$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-")) | .key]'
