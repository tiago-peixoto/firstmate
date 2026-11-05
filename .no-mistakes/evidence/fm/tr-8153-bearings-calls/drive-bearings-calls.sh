#!/usr/bin/env bash
# Live driver: disposable FM_HOME, real bin/fm-captain-hold.sh producer for the
# path-only reason, real bin/fm-bearings-snapshot.sh for JSON and TOON output.
set -u
ROOT=$1; EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null || { echo "lab home create failed"; exit 1; }
HOME_DIR=$LAB/home
mkdir -p "$HOME_DIR/projects/waiting-call" "$LAB/fixture-root"
FB=$LAB/fakebin; mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null; exit 0 ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
for t in gh gh-axi curl no-mistakes; do printf '#!/usr/bin/env bash\necho "%s $*" >> "${NET_LOG:-/dev/null}"\nexit 1\n' "$t" > "$FB/$t"; done
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
chmod +x "$FB"/*

# Queued is written BEFORE In flight on purpose: file order must not be what puts
# the worker-stopping call first.
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## Queued
- [ ] blocked-call - Choice with unmet prerequisites blocked-by: missing-prerequisite (repo: firstmate) (kind: captain) (hold: Pick a route) (hold-kind: captain)
- [ ] long-call - Choose how to configure this detailed feature (repo: firstmate) (kind: captain) (hold: Should the feature start enabled? A: Keep it disabled until checks pass. B: Enable it now and accept the initial risk. C: Enable it only for the fleet owner.) (hold-kind: captain)
- [ ] prose-path-call - Read then decide (repo: firstmate) (kind: captain) (hold: See data/prose/report.md and choose A or B) (hold-kind: captain)
- [ ] pending-prerequisite - Groundwork still queued (repo: firstmate) (kind: ship)

## In flight
- [ ] waiting-call - Worker needs a captain choice (repo: firstmate) (kind: ship) (hold: Should the worker continue? A: Continue now. B: Stop safely.) (hold-kind: captain)
- [ ] cleared-call - Worker waits behind landed groundwork blocked-by: finished-prerequisite (repo: firstmate) (kind: ship) (hold: Ship now? A: Yes. B: No.) (hold-kind: captain)
- [ ] gated-call - Worker waits behind queued groundwork blocked-by: pending-prerequisite (repo: firstmate) (kind: ship) (hold: Ship later? A: Yes. B: No.) (hold-kind: captain)

## Done
- [x] finished-prerequisite - Groundwork that landed (repo: firstmate) (kind: ship) (done 2026-07-10)
EOF
printf '%s\n' "window=firstmate:fm-waiting-call" "worktree=$HOME_DIR/projects/waiting-call" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" > "$HOME_DIR/state/waiting-call.meta"
printf 'paused: waiting for the captain choice\n' > "$HOME_DIR/state/waiting-call.status"

echo "== real producer: fm-captain-hold.sh hold path-call --reason data/proposal/report.md"
PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_CAPTAIN_HOLD_NOW=2026-07-11T17:00:00Z \
  "$ROOT/bin/fm-captain-hold.sh" hold path-call --title "Review proposal" --reason data/proposal/report.md
echo "hold exit=$?"
echo "== stored backlog row for path-call (producer storage form):"
grep 'path-call' "$HOME_DIR/data/backlog.md"

run_bearings() {
  PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$LAB/fixture-root" FM_HOME="$HOME_DIR" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    NET_LOG="$LAB/net.log" "$ROOT/bin/fm-bearings-snapshot.sh" "$@"
}
echo "== bin/fm-bearings-snapshot.sh --json --all-decisions"
run_bearings --json --all-decisions > "$EV/bearings-all-decisions.json"; echo "exit=$?"
jq '.decisions_open' "$EV/bearings-all-decisions.json"
echo "== bin/fm-bearings-snapshot.sh --all-decisions (default TOON)"
run_bearings --all-decisions > "$EV/bearings-all-decisions.toon"; echo "exit=$?"
grep -n 'decisions_open' -A8 "$EV/bearings-all-decisions.toon"
echo "== bin/fm-bearings-snapshot.sh --json (default bucket, no --all-decisions)"
run_bearings --json > "$EV/bearings-default.json"; echo "exit=$?"
jq -c '.decisions_open[] | {id,stops_worker,presentation}' "$EV/bearings-default.json"
echo "== network log (expect empty):"; cat "$LAB/net.log" 2>/dev/null || echo "(no network calls)"
