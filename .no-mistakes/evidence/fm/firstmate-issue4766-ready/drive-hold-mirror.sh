#!/usr/bin/env bash
# Live drive of bin/fm-captain-hold.sh hold/answer/complete against real tasks-axi
# in a throwaway FM_HOME. Usage: drive-hold-mirror.sh <repo-root>
set -u
ROOT=$1
TMP=$(mktemp -d /tmp/fm-hold-live.XXXXXX)
home=$TMP/home
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"; done
TA=$(command -v tasks-axi)
cap() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TA" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
meta() { printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=%s\nmode=%s\nspawn_gen=fixture-%s\n' \
  "$1" "$home" "$1" "$home" "$2" "$2" "$1" > "$home/state/$1.meta"; }
reader() { bash -c '. "$1"; "$3" "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$2" "$1"; }
crew() { PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-crew-state.sh" "$@" 2>&1; }
show() { echo "--- $1"; cat -n "$2"; }
(cd "$home" && tasks-axi add gated "Ship the gated sample" --kind ship --repo sample >/dev/null)
(cd "$home" && tasks-axi add lane "Scout transfer" --kind scout --repo sample >/dev/null)
meta gated ship; meta lane scout

echo "=== S1: hold on a lane writes a stamped captain-held mirror"
printf 'working: mid implementation\npaused: waiting on the sample upstream release\n' > "$home/state/gated.status"
cap hold gated --reason "operator review pending"; echo "hold rc=$?"
show "gated.status after hold" "$home/state/gated.status"
echo "last_status_line: $(reader last_status_line "$home/state/gated.status")"
echo "last_worker_status_line: $(reader last_worker_status_line "$home/state/gated.status")"

echo "=== S2: repeat hold does not duplicate the stamped declaration"
cap hold gated --reason "operator review pending"; echo "hold rc=$?"
echo "captain-held lines: $(grep -c '^captain-held ' "$home/state/gated.status")"

echo "=== S3: release retracts the stamped mirror; readers return to the worker's event"
printf 'Proceed.\n' > "$TMP/go.txt"
cap answer gated --decision-file "$TMP/go.txt" --release; echo "answer rc=$?"
show "gated.status after release" "$home/state/gated.status"
echo "last_status_line: $(reader last_status_line "$home/state/gated.status")"
echo "status_hold_settled: $(bash -c '. "$1"; status_hold_settled "$2" && echo yes || echo no' _ "$ROOT/bin/fm-classify-lib.sh" "$home/state/gated.status")"
cap answer gated --decision-file "$TMP/go.txt" --release >/dev/null 2>&1
echo "resolved lines after replayed answer: $(grep -c '^resolved ' "$home/state/gated.status")"

echo "=== S4: complete transfer (stamped) is retracted when the call is answered"
printf 'done: report complete\nneeds-decision [key=route]: choose route north or route south\n' > "$home/state/lane.status"
cap hold lane --reason "route choice pending" >/dev/null
cap complete lane lane >/dev/null; echo "complete rc=$?"
echo "last_status_line after complete: $(reader last_status_line "$home/state/lane.status")"
printf 'Take route north.\n' > "$TMP/t.txt"
cap answer lane --decision-file "$TMP/t.txt"; echo "answer rc=$?"
show "lane.status after answer" "$home/state/lane.status"
echo "last_status_line: $(reader last_status_line "$home/state/lane.status")"

echo "=== S5: long reason stays within the 220-byte line cap after stamping"
(cd "$home" && tasks-axi add longr "Long reason" --kind ship --repo sample >/dev/null); meta longr ship
printf 'working: x\n' > "$home/state/longr.status"
cap hold longr --reason "$(printf 'r%.0s' $(seq 1 400))" >/dev/null
awk '{print "line", NR, "bytes", length($0)}' "$home/state/longr.status"

echo "=== S6: worker wrote newer state after hold - settlement must not append"
(cd "$home" && tasks-axi add moved "Moved on" --kind ship --repo sample >/dev/null); meta moved ship
printf 'working: x\n' > "$home/state/moved.status"
cap hold moved --reason "gate" >/dev/null
printf 'done: finished after hold\n' >> "$home/state/moved.status"
cap answer moved --decision-file "$TMP/go.txt" >/dev/null; echo "answer rc=$?"
show "moved.status after answer" "$home/state/moved.status"
rm -rf "$TMP"
