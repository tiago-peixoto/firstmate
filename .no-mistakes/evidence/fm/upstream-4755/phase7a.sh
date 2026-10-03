#!/usr/bin/env bash
. "$(dirname "$0")/lab-lib.sh"
say "Session D: remove the flag, then a third request escalates"
rm -f "$LAB/config/pending-reply-resurface"; ls -A "$LAB/config"; token
c=$(escalate_new "confirm the release date"); echo "$c" > "$LAB/corr3"
rec_fields "$c"; : > "$STATE/.wake-queue"
