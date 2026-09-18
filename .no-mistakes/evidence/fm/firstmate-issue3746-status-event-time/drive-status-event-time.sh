#!/usr/bin/env bash
# Live driver for issue 3746 (optional [at=<epoch>] status emission time).
# Runs the real firstmate CLIs against an isolated throwaway home. Only tmux and
# forge CLIs are shimmed, so the host's real tmux server and GitHub are untouched.
# Usage: drive-status-event-time.sh <repo-root>
set -u
ROOT=${1:?repo root}
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3746-live.XXXXXX")
trap 'rm -rf "$W"' EXIT
MAIN=$W/main MATE=$W/mate FAKE=$W/fakebin
mkdir -p "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects} "$FAKE"
: > "$MATE/AGENTS.md"
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in display-message) printf '%%1\n' ;; capture-pane) printf 'idle\n> \n' ;; esac
exit 0
SH
for t in gh gh-axi curl no-mistakes; do printf '#!/usr/bin/env bash\nexit 97\n' > "$FAKE/$t"; done
chmod +x "$FAKE"/*
export PATH="$FAKE:$PATH"
FAILS=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi; }
snap() { FM_HOME=$MAIN "$ROOT/bin/fm-fleet-snapshot.sh" --json "$@"; }
last_event() { jq -c --arg id "$1" '.tasks[] | select(.id == $id) | .paths.status_log.last_event'; }

meta() { # <home> <id> <kind> [extra...]
  local home=$1 id=$2 kind=$3; shift 3
  { printf 'window=firstmate:fm-%s\nworktree=%s\nproject=alpha\nharness=codex\nkind=%s\nmode=%s\nyolo=off\n' \
      "$id" "$home/projects/$id" "$kind" "$kind"
    for x in "$@"; do printf '%s\n' "$x"; done; } > "$home/state/$id.meta"
}

echo "=== S1: worker follows the rendered no-mistakes brief (ask-user escalation + done) ==="
FM_HOME=$MAIN "$ROOT/bin/fm-brief.sh" nm-task alpha --mode no-mistakes >/dev/null
BRIEF=$MAIN/data/nm-task/brief.md
echo "--- brief lines carrying the stamp instruction:"
grep -n 'needs-decision \[at=\|done \[at=' "$BRIEF"
tmpl=$(grep -o '`needs-decision \[at=[^`]*\[key=nm-[^`]*`' "$BRIEF" | head -1 | tr -d '`')
prefix='needs-decision [at=$(date +%s)] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='
echo "--- extracted ask-user template: $tmpl"
check "brief renders ask-user line with literal [at=\$(date +%s)] before [key=...]" \
  '[ "${tmpl:0:${#prefix}}" = "$prefix" ]'
meta "$MAIN" nm-task ship
filled=${tmpl//<run>/r42}; filled=${filled//<step>/review}; filled=${filled//<id1>,<id2>,.../f1,f2}
before=$(date +%s)
# Exactly what a worker shell does with the instruction: echo "<template>" >> status
bash -c "echo \"$filled\" >> \"\$1\"" _ "$MAIN/state/nm-task.status"
after=$(date +%s)
echo "--- status line the worker wrote:"; cat "$MAIN/state/nm-task.status"
out=$(snap); ev=$(printf '%s' "$out" | last_event nm-task); echo "--- snapshot last_event: $ev"
e=$(printf '%s' "$ev" | jq -r .emitted_at_epoch)
check "worker line gets a real emission epoch in [$before,$after]" '[ "$e" -ge "$before" ] && [ "$e" -le "$after" ]'
check "age_seconds is known and small" '[ "$(printf "%s" "$ev" | jq ".age_seconds <= 5 and .age_seconds >= 0")" = true ]'
check "decision key nm-r42-review is open in hints" \
  '[ "$(printf "%s" "$out" | jq -c "[.tasks[] | select(.id==\"nm-task\") | .hints.open_decisions[]? | .key]")" = "[\"nm-r42-review\"]" ]'
printf '%s' "$out" | jq '.tasks[] | select(.id=="nm-task") | {last_event: .paths.status_log.last_event, open_decisions: .hints.open_decisions}'

echo; echo "=== S2: secondmate reports via fm-secondmate-report.sh; parent snapshot uses the stamp, not mtime ==="
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
meta "$MAIN" mate secondmate "home=$MATE" "projects=alpha"
printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
before=$(date +%s)
FM_HOME=$MATE "$ROOT/bin/fm-secondmate-report.sh" done 0123456789abcdef 'audit complete'
echo "--- parent state/mate.status:"; cat "$MAIN/state/mate.status"
touch -t 202001010000 "$MAIN/state/mate.status"
emitted=$(tail -1 "$MAIN/state/mate.status")
stamp=$(printf '%s' "$emitted" | sed -nE 's/^done \[corr=0123456789abcdef\] \[at=([0-9]+)\]: audit complete \(via-helper\)$/\1/p')
check "helper appended 'done [corr=..] [at=N]: audit complete (via-helper)' with N=now" '[ -n "$stamp" ] && [ "$stamp" -ge "$before" ]'
out=$(FM_SNAPSHOT_NOW_EPOCH=$((stamp + 100)) snap)
printf '%s' "$out" | jq --arg id mate '{last_event: (.tasks[] | select(.id==$id) | .paths.status_log.last_event),
  secondmate: (.secondmate_current.records[] | select(.id==$id) | {current, parent_event: (.parent_event | {raw, emitted_at_epoch, age_seconds}), freshness})}'
check "task last_event age is 100 from the stamp despite a 2020 file mtime" \
  '[ "$(printf "%s" "$out" | jq -c ".tasks[] | select(.id==\"mate\") | .paths.status_log.last_event | [.emitted_at_epoch, .age_seconds]")" = "[$stamp,100]" ]'
check "secondmate parent_event and fallback freshness carry the same age" \
  '[ "$(printf "%s" "$out" | jq -c ".secondmate_current.records[] | select(.id==\"mate\") | [.parent_event.emitted_at_epoch, .parent_event.age_seconds, .freshness.age_seconds]")" = "[$stamp,100,100]" ]'

echo; echo "=== S3: legacy, malformed, and future stamps stay unknown (adversarial) ==="
meta "$MAIN" probe ship
NOW=1700000100
while IFS='|' read -r line want; do
  printf '%s\n' "$line" > "$MAIN/state/probe.status"
  got=$(FM_SNAPSHOT_NOW_EPOCH=$NOW snap | jq -c '.tasks[] | select(.id=="probe") | .paths.status_log.last_event | [.state, .emitted_at_epoch, .age_seconds]')
  check "$(printf '%-58s -> %s' "$line" "$got")" '[ "$got" = "$want" ]'
done <<'EOF'
working: legacy unstamped line|["working",null,null]
working [at=1700000000]: well-formed|["working",1700000000,100]
working [at=1700000200]: future stamp keeps epoch, age unknown|["working",1700000200,null]
working [at=oops]: non-numeric|["working",null,null]
working [at=]: empty|["working",null,null]
working [at=01700000000]: leading zero|["working",null,null]
working [at=1700000000000]: 13 digits|["working",null,null]
working [at=1700000000] [at=1700000050]: duplicate|["working",null,null]
working [at=-5]: negative|["working",null,null]
working: stamp only in note [at=1700000000]|["working",null,null]
blocked [key=k] [at=1700000090]: stamp after key|["blocked",1700000090,10]
EOF

echo; echo "=== S4: stamped keyed decision opens and a stamped resolve closes it ==="
printf 'needs-decision [at=1700000000] [key=api-shape]: REST or gRPC?\n' > "$MAIN/state/probe.status"
got=$(FM_SNAPSHOT_NOW_EPOCH=$NOW snap | jq -c '[.tasks[] | select(.id=="probe") | .hints.open_decisions[]? | .key]')
check "stamped needs-decision is open under key api-shape: $got" '[ "$got" = "[\"api-shape\"]" ]'
printf 'resolved [key=api-shape] [at=1700000050]: answered: REST\n' >> "$MAIN/state/probe.status"
got=$(FM_SNAPSHOT_NOW_EPOCH=$NOW snap | jq -c '[.tasks[] | select(.id=="probe") | .hints.open_decisions[]? | .key]')
check "stamped resolve closes it: $got" '[ "$got" = "[]" ]'
printf 'needs-decision [at=bad] [key=api-shape]: malformed stamp still opens\n' >> "$MAIN/state/probe.status"
got=$(FM_SNAPSHOT_NOW_EPOCH=$NOW snap | jq -c '[.tasks[] | select(.id=="probe") | .hints.open_decisions[]? | .key]')
check "malformed stamp does not hide the decision: $got" '[ "$got" = "[\"api-shape\"]" ]'

echo; echo "=== S5: human fleet view still renders over stamped status logs (sanity) ==="
FM_HOME=$MAIN "$ROOT/bin/fm-fleet-view.sh" 2>&1 | head -40

echo; echo "=== S6: ledger-first parent delivery is stamped and a replay one second later is not duplicated ==="
meta "$MATE" child ship "spawn_gen=g1" "pr=https://example.test/owner/repo/pull/1"
printf 'done [at=1700000000]: PR https://example.test/owner/repo/pull/7 checks green\n' > "$MATE/state/child.status"
: > "$MATE/state/child.turn-ended"
: > "$MAIN/state/mate.status"
recon() { FM_HOME=$MATE FM_ROOT_OVERRIDE=$W FM_STATE_OVERRIDE=$MATE/state FM_DATA_OVERRIDE=$MATE/data \
  FM_CONFIG_OVERRIDE=$MATE/config "$ROOT/bin/fm-inactive-reconcile.sh" report child; }
recon; echo "--- parent status after first delivery:"; cat "$MAIN/state/mate.status"
first=$(cat "$MAIN/state/mate.status")
check "delivered line is stamped with delivery time, child PR carried" \
  'printf "%s" "$first" | grep -Eq "^done \[key=child-outcome-child-done-[0-9a-f]{8}\] \[at=[0-9]+\]: child child done: PR https://example.test/owner/repo/pull/7 checks green pr=https://example.test/owner/repo/pull/1"'
echo "--- receipts before simulated crash:"; ls "$MATE/state/terminal-outcomes"; rm -f "$MATE"/state/terminal-outcomes/*   # simulate a crash before any receipt landed
t0=$(date +%s); while [ "$(date +%s)" -le "$((t0 + 1))" ]; do :; done   # cross a clock second boundary
recon; echo "--- parent status after replay:"; cat "$MAIN/state/mate.status"
check "replay at a later second did not append a duplicate" '[ "$(wc -l < "$MAIN/state/mate.status" | tr -d " ")" = 1 ]'

echo; [ "$FAILS" -eq 0 ] && echo "ALL LIVE CHECKS PASSED" || echo "LIVE CHECK FAILURES: $FAILS"
exit "$FAILS"
