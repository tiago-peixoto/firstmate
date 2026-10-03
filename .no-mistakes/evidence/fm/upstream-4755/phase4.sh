#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
closed=$(cat "$LAB/corr1"); kept=$(cat "$LAB/corr2")
say "Session C (new real claude primary) ran bin/fm-session-start.sh"
show "$ROOT/bin/fm-lock.sh" status; token; queue
echo "closed by operator:"; rec_fields "$closed"
echo "left open:"; rec_fields "$kept"
say "Bearings rows"
"$ROOT/bin/fm-bearings-snapshot.sh" --json | jq -c '.decisions_open[] | {key,verb,owner}'
