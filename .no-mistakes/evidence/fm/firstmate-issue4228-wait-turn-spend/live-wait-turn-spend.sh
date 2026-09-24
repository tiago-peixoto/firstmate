#!/usr/bin/env bash
# Live drive of #4228 against a real Pi secondmate in an isolated Herdr lab.
# Pi's before_agent_start is captured and aborted, so each captured prompt is
# one turn the worker would have spent, and no model tokens are used.
set -u
ROOT=/Users/tiago/.no-mistakes/worktrees/762e4773438f/01M38AFH45XCX7SH6PA8DF77GF
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-backend.sh"
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
SESSION=$("$LAB_HELPER" name wait-turn-4228)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-4228-live.XXXXXX")
SENDER_HOME="$TMP_ROOT/sender-home"
SECOND_HOME="$TMP_ROOT/secondmate-home"
CAPTURE="$TMP_ROOT/pi-turns.jsonl"
FAKEBIN="$TMP_ROOT/fakebin"
ORIGINAL_PATH=$PATH
REAL_PI=$(command -v pi)
ID='wait4228-sm'
FAILED=0

say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }

cleanup() {
  trap - EXIT
  say "teardown lab $SESSION"
  "$LAB_HELPER" teardown "$SESSION" || FAILED=1
  rm -rf "$TMP_ROOT"
  echo "overall: $([ "$FAILED" = 0 ] && echo PASS || echo FAIL)"
  exit "$FAILED"
}
trap cleanup EXIT

mkdir -p "$SENDER_HOME/state" "$SENDER_HOME/data" "$SENDER_HOME/config" "$SENDER_HOME/projects" "$FAKEBIN"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'; session='$SESSION'; real_path='$ORIGINAL_PATH'
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || { echo "wrapper requires the isolated lab session" >&2; exit 98; }
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

git clone -q --no-hardlinks "$ROOT" "$SECOND_HOME"
git -C "$SECOND_HOME" checkout -q --detach HEAD
mkdir -p "$SECOND_HOME/state" "$SECOND_HOME/data" "$SECOND_HOME/config" "$SECOND_HOME/projects"
printf '%s\n' "$ID" > "$SECOND_HOME/.fm-secondmate-home"
printf '# Idle capture secondmate\n\nStay idle.\n' > "$SECOND_HOME/data/charter.md"
printf '<!-- main-authoritative: read-only in secondmate homes and must not be edited there; the main firstmate owns it; request changes with a marked status or document pointer -->\n# Captain shared v1\n' > "$SENDER_HOME/data/captain-shared.md"

CAPTURE_JSON=$(printf '%s' "$CAPTURE" | jq -Rs .)
EXT="$TMP_ROOT/capture.ts"
cat > "$EXT" <<EOF
import { appendFileSync } from "node:fs";
export default function (pi: any) {
  pi.on("project_trust", () => ({ trusted: "yes", remember: false }));
  pi.on("before_agent_start", (event, ctx) => {
    appendFileSync($CAPTURE_JSON, JSON.stringify({ prompt: event.prompt }) + "\\n");
    ctx.abort();
  });
}
EOF
printf '#!/usr/bin/env bash\nexec %q -e %q "$@"\n' "$REAL_PI" "$EXT" > "$FAKEBIN/pi"
chmod +x "$FAKEBIN/pi"

"$LAB_HELPER" provision "$SESSION" || { bad "lab provision"; exit 1; }
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$SECOND_HOME" --secondmate --harness pi --backend herdr >/dev/null \
  || { bad "secondmate spawn"; exit 1; }
META="$SENDER_HOME/state/$ID.meta"
TARGET=$(fm_backend_target_of_meta "$META"); PANE=${TARGET#*:}
STATUS="$SENDER_HOME/state/$ID.status"
echo "spawned real Pi secondmate $ID at Herdr target $TARGET (session $SESSION)"

turns() { [ -s "$CAPTURE" ] && wc -l < "$CAPTURE" | tr -d ' ' || echo 0; }
wait_idle() {
  local s _ stable=0
  for _ in $(seq 1 240); do
    s=$("$LAB_HELPER" run "$SESSION" agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$s" in idle|done) stable=$((stable+1)); [ "$stable" -ge 4 ] && return 0 ;; *) stable=0 ;; esac
    sleep 0.25
  done
  return 1
}
wait_turns() { # <n> <secs>
  local _; for _ in $(seq 1 $(( $2 * 4 ))); do [ "$(turns)" -ge "$1" ] && return 0; sleep 0.25; done; return 1
}
send() { PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" "$ROOT/bin/fm-send.sh" "$@"; }

wait_turns 1 60 || bad "startup charter turn never reached Pi"
wait_idle || bad "Pi never idle after startup"
BASE=$(turns); echo "turns after startup: $BASE"

say "S1 automatic send to a worker waiting on its own needs-decision"
printf 'needs-decision [key=pick]: ship alpha or beta?\n' >> "$STATUS"
out=$(send "$ID" --automatic "AUTO-4228 re-read your instructions" 2>&1); rc=$?
echo "fm-send --automatic rc=$rc: $out"
sleep 8
echo "turns now: $(turns); inbox: $(ls "$SENDER_HOME/state/$ID.inbox" 2>/dev/null | tr '\n' ' ')"
if [ "$rc" = 4 ] && [ "$(turns)" = "$BASE" ] && ! grep -q AUTO-4228 "$CAPTURE"; then ok "S1 deferred with exit 4, no turn spent"; else bad "S1"; fi

say "S2 firstmate's deliberate answer still wakes the waiting worker"
out=$(send "$ID" --resolve-key pick "ANSWER-4228 use alpha" 2>&1); rc=$?
echo "fm-send --resolve-key pick rc=$rc: $out"
wait_turns $((BASE+1)) 60 || true
echo "turns now: $(turns)"; tail -1 "$CAPTURE" | jq -r .prompt | head -3
if [ "$rc" = 0 ] && [ "$(turns)" -eq $((BASE+1)) ]; then ok "S2 answer delivered as exactly one turn"; else bad "S2"; fi
wait_idle || true
B2=$(turns)
out=$(send "$ID" --automatic "AUTO2-4228 after answer" 2>&1); rc=$?
echo "automatic after answer rc=$rc"
wait_turns $((B2+1)) 60 || true
if [ "$rc" = 0 ] && [ "$(turns)" -eq $((B2+1)) ]; then ok "S2b automatic send resumes once the decision is closed"; else bad "S2b"; fi
wait_idle || true

say "S3 adversarial: parent-raised continuity blocker and relayed captain hold do not freeze automatic sends"
printf 'blocked [key=remote-reply-continuity-%s]: remote reply continuity broke\n' "$ID" >> "$STATUS"
printf 'needs-decision [key=captain-hold-t42-1]: captain hold t42: alpha or beta?\n' >> "$STATUS"
B3=$(turns)
out=$(send "$ID" --automatic "AUTO3-4228 beside parent-owned keys" 2>&1); rc=$?
echo "rc=$rc $out"
wait_turns $((B3+1)) 60 || true
if [ "$rc" = 0 ] && [ "$(turns)" -eq $((B3+1)) ]; then ok "S3 not deferred by parent-owned keys"; else bad "S3"; fi
wait_idle || true
printf 'blocked [key=blk]: own blocker\n' >> "$STATUS"
out=$(send "$ID" --automatic "AUTO4-4228 own blocker" 2>&1); rc=$?
echo "own blocked key -> rc=$rc $out"
if [ "$rc" = 4 ]; then ok "S3b the worker's own blocked key defers"; else bad "S3b"; fi

say "S4 deferred config reread is held, then delivered after the decision closes"
printf 'needs-decision [key=cfg]: which config?\n' >> "$STATUS"
printf 'pi\n' > "$SENDER_HOME/config/crew-harness"  # a real inherited config change
B4=$(turns)
out=$(PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" "$ROOT/bin/fm-config-push.sh" 2>&1); rc=$?
echo "fm-config-push rc=$rc"; printf '%s\n' "$out" | sed 's/^/  | /'
sleep 8
flagdir=$(. "$ROOT/bin/fm-secondmate-nudge-lib.sh"; fm_secondmate_reread_deferred_dir "$SENDER_HOME/state")
echo "turns now: $(turns); deferred flags: $(ls "$flagdir" 2>/dev/null | tr '\n' ' ')"
if [ "$(turns)" = "$B4" ] && [ -e "$flagdir/$ID" ]; then ok "S4a reread deferred, no turn spent, retry flagged"; else bad "S4a"; fi
# Retry while still open: the watcher's command must stay quiet.
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" FM_STATE_OVERRIDE="$SENDER_HOME/state" "$ROOT/bin/fm-config-push.sh" --retry-deferred; echo "retry-deferred while open rc=$?"
sleep 5
[ "$(turns)" = "$B4" ] && ok "S4b --retry-deferred stays quiet while the decision is open" || bad "S4b"
# Firstmate answers; exactly the answer is one turn.
out=$(send "$ID" --resolve-key cfg --resolve-key blk "ANSWER2-4228 use config A" 2>&1); echo "answer rc=$?"
wait_turns $((B4+1)) 60 || true; wait_idle || true
B5=$(turns)
PATH="$FAKEBIN:$ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$SENDER_HOME" FM_STATE_OVERRIDE="$SENDER_HOME/state" "$ROOT/bin/fm-config-push.sh" --retry-deferred; echo "retry-deferred after close rc=$?"
wait_turns $((B5+1)) 60 || true
echo "turns now: $(turns)"; tail -1 "$CAPTURE" | jq -r .prompt | head -5
if [ "$(turns)" -eq $((B5+1)) ] && [ ! -e "$flagdir/$ID" ]; then ok "S4c reread delivered once after the decision closed"; else bad "S4c"; fi

say "full capture of turns the worker took"
jq -r '.prompt | split("\n")[0] | .[0:150]' "$CAPTURE" | nl
echo "final status file:"; cat "$STATUS"
