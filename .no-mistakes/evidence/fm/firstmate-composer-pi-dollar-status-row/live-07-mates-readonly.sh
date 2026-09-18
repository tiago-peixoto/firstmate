#!/usr/bin/env bash
# Stage 7 (READ-ONLY): the live local pi mates on the default herdr session.
# Only `pane read` and `agent get` are called - no keys, no server ensure.
# Each capture is classified offline exactly as fm_backend_herdr_composer_state
# does (styled ANSI capture, 20 rows, identity from agent get), by base and target.
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/bbb16e1f0808/01M2TR1JDWEA6RNHTW49D4G1N1
BASE=/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T//fm-pidollar-base.OAlLmT
EV=/Users/tiago/.no-mistakes/evidence/01M2TR1JDWEA6RNHTW49D4G1N1
classify() {  # <root> <capture-file> <identity>
  ( . "$1/bin/fm-composer-lib.sh"
    caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=20')
    cap=$(cat "$2")
    v=$(fm_composer_classify_screen "$caps" "$cap")
    if [ "$v" = need-identity ]; then v=$(fm_composer_classify_screen "$caps" "$cap" '' "$3"); [ "$v" != need-identity ] || v=unknown; fi
    printf '%s' "$v" )
}
for pair in solo-dev-mate:wD6:p2 artemis-mate:wC9:p4 opensourcerer-mate:wAZ:p8; do
  name=${pair%%:*}; pane=${pair#*:}
  for s in 1 2 3; do
    f=$(mktemp)  # raw capture stays private: it holds the mate's transcript
    herdr pane read "$pane" --session default --source recent --lines 200 --format ansi 2>/dev/null | tail -n 20 > "$f"
    id=$(herdr agent get "$pane" --session default 2>/dev/null | jq -r '.result.agent | "\(.agent)\t\(.agent_status)"')
    stats=$(sed 's/\x1b\[[0-9;:]*[A-Za-z]//g' "$f" | grep -E '%/[0-9]+k' | tail -1 | sed 's/   .*//')
    printf '%-19s sample %s  identity=%-12s base=%-8s target=%-8s status row: %s\n' \
      "$name" "$s" "$(printf '%s' "$id" | tr '\t' '/')" "$(classify "$BASE" "$f" "$id")" "$(classify "$ROOT" "$f" "$id")" "$stats"
    rm -f "$f"; sleep 3
  done
done
