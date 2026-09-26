#!/usr/bin/env bash
# Live drive: real Claude secondmate spawned by bin/fm-spawn.sh --secondmate on a
# private tmux server, real launch brief delivered, parent busy record sampled.
set -u
ROOT=$1
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
SOCK=fm-lab-smbusy-$$
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1; chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
P="$LAB/primary"; SM="$LAB/sm"; ID=sm-live
"$ROOT/bin/fm-lab-home.sh" create "$P" >/dev/null
touch "$P/state/.last-watcher-beat"; echo claude > "$P/config/crew-harness"
git clone -q "$ROOT" "$SM"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"
mkdir -p "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
cat > "$SM/data/charter.md" <<'EOF'
# Charter (test lab)
This is a disposable test of turn tracking. Do not start any fleet work.
Run exactly one shell command: `sleep 20`. Then reply with the single word DONE and end your turn.
EOF
git -C "$SM" add -A >/dev/null; git -C "$SM" -c user.email=t@t -c user.name=t commit -qm lab-seed
mkdir -p "$LAB/shim"; printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCK" > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
"$REAL_TMUX" -L "$SOCK" new-session -d -s firstmate -x 200 -y 50
echo "== spawn"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
  FM_BACKEND=tmux FM_HOME="$P" FM_SPAWN_NO_GUARD=1 PATH="$LAB/shim:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SM" claude --secondmate 2>&1 | tail -5
echo "== hooks written into mate home (.claude/settings.local.json)"; cat "$SM/.claude/settings.local.json" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sorted(d["hooks"]))'
echo "== .fm-busy-stop pointer:"; sed 's/^/   /' "$SM/.fm-busy-stop" 2>/dev/null || echo "   (absent)"
. "$ROOT/bin/fm-busy-lib.sh"
T="firstmate:fm-$ID"
for i in $(seq 1 60); do
  rec=$(tr '\n' ' ' < "$P/state/$ID.busy-state" 2>/dev/null)
  tail=$("$REAL_TMUX" -L "$SOCK" capture-pane -p -t "$T" -S -30 2>/dev/null)
  cls=$(fm_busy_classify tmux "$T" claude "$ID" "$P/state" "$tail" 2>/dev/null)
  printf 't=%3ss classify=[%s] record=[%s] turn-ended=%s\n' $((i*5)) "$cls" "$rec" "$([ -e "$P/state/$ID.turn-ended" ] && echo yes || echo no)"
  sleep 5
done
echo "== final pane tail"; "$REAL_TMUX" -L "$SOCK" capture-pane -p -t "$T" -S -40 | grep -v '^\s*$' | tail -25
