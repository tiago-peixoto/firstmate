#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh / fm-pr-check.sh / fm-teardown.sh against a
# guarded fm-lab-* Herdr session and real treehouse, with a throwaway FM_HOME.
set -u
ROOT=${1:?worktree}
EVID=$(cd "$(dirname "$0")" && pwd)
LAB="$ROOT/bin/fm-herdr-lab.sh"
TMP=$(mktemp -d /tmp/fm-cap-live.XXXXXX)
ORIG_PATH=$PATH
REAL_HERDR=$(command -v herdr)
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
export LAB ORIG_PATH REAL_HERDR
SESSION=$("$LAB" name capacity)
export HERDR_LAB_SESSION=$SESSION HERDR_SESSION=$SESSION
unset HERDR_PANE_ID HERDR_PANE HERDR_WORKSPACE_ID HERDR_TAB_ID 2>/dev/null || :
for v in $(env | sed -n 's/^\(HERDR_[A-Z_]*\)=.*/\1/p'); do
  case $v in HERDR_LAB_SESSION|HERDR_SESSION) ;; *) unset "$v" ;; esac
done

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] && [ "${args[$((n-1))]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$((n-1))]" "args[$((n-2))]"
fi
set -- "${args[@]}"
if [ "${1:-}" = --version ]; then exec env PATH="$ORIG_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"; fi
exec env PATH="$ORIG_PATH" "$LAB" run "$HERDR_LAB_SESSION" "$@"
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in *isDraft*) echo '{"isDraft":false}';; *) exit 1;; esac
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"

LAB_UP=0
WTS=()
cleanup() {
  for wt in "${WTS[@]}"; do [ -d "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1; done
  [ "$LAB_UP" = 1 ] && PATH="$ORIG_PATH" "$LAB" teardown "$SESSION" && echo "lab $SESSION torn down"
  rm -rf "$TMP"
}
trap cleanup EXIT

PATH="$ORIG_PATH" "$LAB" provision "$SESSION" || { echo "provision failed"; exit 1; }
LAB_UP=1
echo "== lab session: $SESSION"

HOME_DIR="$TMP/home"; PROJ="$TMP/work/heavy-suite"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data" "$HOME_DIR/projects" "$PROJ"
touch "$HOME_DIR/state/.last-watcher-beat"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
git -C "$PROJ" init -q; echo hi > "$PROJ/README.md"; git -C "$PROJ" add .; git -C "$PROJ" -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"

brief() { mkdir -p "$HOME_DIR/data/$1"; printf '# Task\n## Captain'"'"'s intent\nRun the heavy suite for %s.\n\n## Firstmate spec\nlive capacity.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' "$1" > "$HOME_DIR/data/$1/brief.md"; tasks-axi add "$1" "item for $1" --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null; }
state() { tasks-axi show "$1" --file "$HOME_DIR/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1; }
spawn() { local id=$1; shift
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr "$@"; }
panes() { PATH="$ORIG_PATH" "$LAB" run "$SESSION" pane list 2>/dev/null | jq -r '[.result.panes[]?]|length'; }
report() { echo "   records: $(cd "$HOME_DIR/state" && ls *.meta 2>/dev/null | tr '\n' ' ')| lab panes: $(panes)"; for i in "$@"; do echo "   backlog $i: $(state "$i")"; done; }
remember() { local wt; wt=$(sed -n 's/^worktree=//p' "$HOME_DIR/state/$1.meta"); [ -n "$wt" ] && WTS+=("$wt"); }

for id in cap-a cap-b cap-c cap-d cap-e; do brief "$id"; done

echo; echo "== S1 no declaration: uncapped (spawn cap-a, cap-b, cap-c)"
for id in cap-a cap-b cap-c; do spawn "$id" >/dev/null 2>"$TMP/err"; echo "   spawn $id exit=$?"; remember "$id"; done
report cap-a cap-b cap-c
echo "   teardown cap-c to return to 2 holders"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" cap-c --force >"$TMP/td" 2>&1; echo "   teardown exit=$?"; tail -2 "$TMP/td" | sed 's/^/   | /'
report cap-c

echo; echo "== S2 declare 'heavy-suite 2' and spawn cap-d beyond capacity"
printf '# heavy suite serves two workers\nheavy-suite 2\n' > "$HOME_DIR/config/project-capacity"
before=$(panes)
spawn cap-d >"$TMP/out" 2>"$TMP/err"; rc=$?
echo "   spawn cap-d exit=$rc"; sed 's/^/   stderr| /' "$TMP/err"
echo "   lab panes before=$before after=$(panes); cap-d.meta exists: $([ -e "$HOME_DIR/state/cap-d.meta" ] && echo yes || echo no); rendered launch brief: $(ls "$HOME_DIR/data/cap-d" | tr '\n' ' ')"
report cap-d

echo; echo "== S3 batch spawn at capacity reports DEFERRED"
FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-spawn.sh" "cap-d=$PROJ" "cap-e=$PROJ" --harness "sh -c 'while :; do sleep 60; done'" --mode no-mistakes --yolo off --backend herdr >/dev/null 2>"$TMP/err"; rc=$?
echo "   batch exit=$rc"; grep -E '^batch:' "$TMP/err" | sed 's/^/   stderr| /'
report cap-d cap-e

echo; echo "== S4 cap-a records its ready PR (fm-pr-check.sh) -> place frees -> cap-d admitted"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pr-check.sh" cap-a https://github.com/example/heavy-suite/pull/1 >"$TMP/pr" 2>&1; echo "   pr-check exit=$?; cap-a pr=$(sed -n 's/^pr=//p' "$HOME_DIR/state/cap-a.meta")"
spawn cap-d >/dev/null 2>"$TMP/err"; rc=$?; echo "   spawn cap-d exit=$rc"; [ "$rc" = 0 ] && remember cap-d || sed 's/^/   stderr| /' "$TMP/err"
report cap-d
spawn cap-e >/dev/null 2>"$TMP/err"; rc=$?; echo "   spawn cap-e (now cap-b, cap-d hold) exit=$rc"; sed 's/^/   stderr| /' "$TMP/err"

echo; echo "== S5 cleanup frees a place: teardown cap-b -> cap-e admitted"
FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" cap-b --force >"$TMP/td" 2>&1; echo "   teardown cap-b exit=$?"
spawn cap-e >/dev/null 2>"$TMP/err"; rc=$?; echo "   spawn cap-e exit=$rc"; [ "$rc" = 0 ] && remember cap-e || sed 's/^/   stderr| /' "$TMP/err"
report cap-e

echo; echo "== S6 malformed declaration refuses a fresh spawn"
printf 'heavy-suite two\n' > "$HOME_DIR/config/project-capacity"
brief cap-f
spawn cap-f >/dev/null 2>"$TMP/err"; rc=$?; echo "   spawn cap-f exit=$rc"; sed 's/^/   stderr| /' "$TMP/err"
report cap-f

echo; echo "== teardown remaining workers"
for id in cap-a cap-d cap-e; do FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-teardown.sh" "$id" --force >/dev/null 2>&1; echo "   teardown $id exit=$?"; done
report
