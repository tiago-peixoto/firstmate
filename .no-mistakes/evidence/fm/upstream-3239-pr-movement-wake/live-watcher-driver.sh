#!/usr/bin/env bash
# Live watcher: real fm-contributions.sh arm + fm-watch-checkpoint.sh against
# real GitHub (read-only) in a disposable marked lab home.
set -u
WT=${WT:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$LAB" "$@"; }
OPEN=https://github.com/kunchenguid/firstmate/pull/5341
printf '# Backlog\n\n## Queued\n- [ ] openpr - Keep PR mergeable %s (repo: sample) (kind: ship)\n' "$OPEN" > "$LAB/data/backlog.md"
echo "== arm contributions observer =="; run "$WT/bin/fm-contributions.sh" arm; echo "arm rc=$?"; ls "$LAB/state"
echo "== quiet watcher on unchanged live PR (first observation = baseline) =="
rc=0; run env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WT/bin/fm-watch-checkpoint.sh" --seconds 20 > "$LAB/q.out" 2> "$LAB/q.err" || rc=$?
echo "watcher rc=$rc (124 = quiet expiry)"; echo "stdout:"; cat "$LAB/q.out"; echo "stderr:"; tail -5 "$LAB/q.err"
jq -c '.records[0] | {head:.observation.head,draft:.observation.draft,review_requests:.observation.review_requests,pending:(.pending|length)}' "$LAB/data/openpr/contributions.json"
echo "== stored prior head rewritten to stand in for a force-push; successor watcher =="
jq '.records[0].observation.head="1111111111111111111111111111111111111111" | .records[0].checked_at="2000-01-01T00:00:00Z"' "$LAB/data/openpr/contributions.json" > "$LAB/x" && mv "$LAB/x" "$LAB/data/openpr/contributions.json"
rc=0; run env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WT/bin/fm-watch-checkpoint.sh" --seconds 60 > "$LAB/w.out" 2> "$LAB/w.err" || rc=$?
echo "watcher rc=$rc"; echo "stdout:"; cat "$LAB/w.out"; echo "stderr:"; tail -5 "$LAB/w.err"
run "$WT/bin/fm-contributions.sh" pending | jq -c '.[] | {task,type,body}'
echo "== repeat watcher: already-surfaced head must not re-ring =="
rc=0; run env FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WT/bin/fm-watch-checkpoint.sh" --seconds 20 > "$LAB/r.out" 2> "$LAB/r.err" || rc=$?
echo "watcher rc=$rc"; echo "stdout:"; cat "$LAB/r.out"
echo "queued check wakes: $(awk -F '\t' 'NF>=5 && $3=="check"{c++} END{print c+0}' "$LAB/state/.wake-queue" 2>/dev/null)"
