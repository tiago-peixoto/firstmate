#!/usr/bin/env bash
# Live scenarios for upstream issue 3473 (Herdr + Claude typed delivery that
# submits only the tail of a long message). Every Herdr call goes through
# bin/fm-herdr-lab.sh in a named fm-lab-* session, torn down on exit.
#
# Usage: live-long-steer-scenarios.sh <repo-root-under-test> <label>
set -u
ROOT=$(cd "$1" && pwd)
LABEL=$2
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
[ -x "$LAB_HELPER" ] || LAB_HELPER=$(cd "$(dirname "$0")" && pwd)/fm-herdr-lab.sh

. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

say() { printf '%s\n' "$*"; }
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name "long-$LABEL")
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-long-steer.XXXXXX")
FAKEBIN=$TMP_ROOT/fakebin
mkdir -p "$FAKEBIN"
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && say "teardown: $SESSION removed"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || { say "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

WS=$(lab workspace create --cwd "$ROOT" --label fm-long --no-focus) || exit 1
PANE=$(printf '%s' "$WS" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"
say "== [$LABEL] session=$SESSION pane=$PANE herdr=$(PATH=$ORIGINAL_PATH herdr --version) claude=$(PATH=$ORIGINAL_PATH claude --version)"

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null

wait_idle() {
  local i=0 st
  while [ "$i" -lt 90 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in
      idle|done) return 0 ;;
      blocked)
        case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
          *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;;
        esac ;;
    esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
wait_reply() { # <token> <min-occurrences>
  local i=0 n
  while [ "$i" -lt 90 ]; do
    n=$(lab pane read "$PANE" --source recent --lines 400 2>/dev/null | grep -F -c "$1" || true)
    [ "$n" -ge "$2" ] && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }

wait_idle || { say "claude never idle"; screen | tail -30; exit 1; }
sleep 2

# ---- Scenario 1: long steer (~2.6k chars) with a code only in the head.
HEAD="HEADCODE${RANDOM}X"
TAIL="TAILCODE${RANDOM}Y"
filler=
for n in $(seq 1 30); do filler+="Background note $n: this sentence is padding for a long steer and needs no action. "; done
LONG="The secret head code is $HEAD. $filler Final instruction: reply with exactly the secret head code, a dash, and $TAIL, and nothing else."
say "-- S1 long steer: ${#LONG} chars; head code $HEAD appears only at the start"
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$LONG" 3 0.4 0.6)
say "S1 verdict=$v"
if wait_reply "$HEAD-$TAIL" 1; then say "S1 RESULT: Claude replied '$HEAD-$TAIL' -> full message (head included) was submitted"
elif wait_reply "$TAIL" 2; then say "S1 RESULT: Claude answered without the head code -> TAIL-ONLY submit"
else say "S1 RESULT: no reply containing $TAIL observed"; fi
say "S1 screen after:"; screen | tail -25
wait_idle; sleep 2

# ---- Scenario 2: operator draft already in the composer.
DRAFT="operator draft $RANDOM do not clobber"
lab pane send-text "$PANE" "$DRAFT" >/dev/null; sleep 1
TOK2="DRAFTCASE${RANDOM}"
v=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOK2 and nothing else." 3 0.4 0.4)
say "-- S2 non-empty composer: verdict=$v"
sleep 1; s=$(screen)
case "$s" in *"$DRAFT"*) say "S2 draft still present in composer: yes";; *) say "S2 draft still present in composer: NO";; esac
case "$s" in *"$TOK2"*) say "S2 steer text typed into composer: YES";; *) say "S2 steer text typed into composer: no";; esac
say "S2 screen:"; printf '%s\n' "$s" | tail -8
for _ in 1 2 3 4; do lab pane send-keys "$PANE" ctrl+u >/dev/null; done; sleep 1
say "S2 composer state after manual clear: $(fm_backend_herdr_composer_state "$TARGET")"

# ---- Scenario 3 (target only): injected head loss, then clean retry.
if declare -F fm_backend_herdr_composer_payload_shown >/dev/null; then
  TOK3="TRUNCCASE${RANDOM}"
  MSG3="Head part that goes missing. Reply with exactly $TOK3 and nothing else."
  eval "orig_$(declare -f fm_backend_herdr_send_literal)"
  fm_backend_herdr_send_literal() {  # fault: deliver only the last 40 chars
    local t=$2; orig_fm_backend_herdr_send_literal "$1" "${t: -40}"
  }
  v=$(fm_backend_herdr_send_text_submit "$TARGET" "$MSG3" 3 0.4 0.6)
  say "-- S3 tail-only composer (injected): verdict=$v"
  sleep 3
  say "S3 composer state after refusal: $(fm_backend_herdr_composer_state "$TARGET")"
  st=$(lab agent get "$PANE" | jq -r '.result.agent.agent_status')
  n=$(lab pane read "$PANE" --source recent --lines 400 | grep -F -c "$TOK3" || true)
  say "S3 agent_status=$st occurrences of $TOK3 on screen=$n (0 = nothing submitted)"
  say "S3 screen:"; screen | tail -8
  eval "$(declare -f orig_fm_backend_herdr_send_literal | sed 's/^orig_//')"
  v=$(fm_backend_herdr_send_text_submit "$TARGET" "$MSG3" 3 0.4 0.6)
  say "-- S3b clean retry: verdict=$v"
  if wait_reply "$TOK3" 2; then say "S3b RESULT: retry delivered once and Claude replied $TOK3"; else say "S3b RESULT: no reply"; fi
  wait_idle; sleep 1
fi

# ---- Scenario 4: non-Claude pane (plain shell) keeps type-then-Enter.
WS2=$(lab workspace create --cwd "$TMP_ROOT" --label fm-shell --no-focus) || exit 1
PANE2=$(printf '%s' "$WS2" | jq -er '.result.root_pane.pane_id')
sleep 2
TOK4="SHELLCASE${RANDOM}"
v=$(fm_backend_herdr_send_text_submit "$SESSION:$PANE2" "echo $TOK4-\$((6*7))" 3 0.4 0.4)
say "-- S4 shell pane identity=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE2" | cut -f1) verdict=$v"
sleep 1
if lab pane read "$PANE2" --source recent --lines 50 | grep -q "$TOK4-42"; then say "S4 RESULT: shell ran the command ($TOK4-42 printed)"; else say "S4 RESULT: command output missing"; fi
