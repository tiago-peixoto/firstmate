#!/usr/bin/env bash
# Live scenario driver for issue 3473 (Herdr + Claude typed delivery truncation).
# Usage: drive-scenarios.sh <repo-root> <herdr.sh to source> <scenario list>
set -u
ROOT=$1; ADAPTER=$2; shift 2; SCEN="$*"
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/lib.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name scen3473)
TMP_ROOT=$(mktemp -d /tmp/fm-scen3473.XXXXXX)
FAKEBIN=$TMP_ROOT/fakebin; mkdir -p "$FAKEBIN"
log() { printf '%s\n' "$*"; }
cleanup() { trap - EXIT; PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && log "teardown ok: $SESSION"; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@"); n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else echo "wrapper requires trailing --session $SESSION" >&2; exit 98; fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || { log "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ADAPTER"
. "$ROOT/bin/fm-operational-input.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

new_pane() { # label -> pane id
  lab workspace create --cwd "${PANE_CWD:-$ROOT}" --label "$1" --no-focus | jq -er '.result.root_pane.pane_id'
}
wait_idle() { local p=$1 i=0 st
  while [ $i -lt 60 ]; do
    st=$(lab agent get "$p" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) return 0 ;;
      blocked) case "$(lab pane read "$p" --source visible 2>/dev/null)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$p" enter >/dev/null ;; esac ;;
    esac; i=$((i+1)); sleep 1; done; return 1; }
launch_claude() { local p=$1
  lab pane run "$p" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
  wait_idle "$p"; }
screen() { lab pane read "$1" --source recent --lines 200 2>/dev/null; }
count() { printf '%s\n' "$(screen "$1")" | grep -F -o "$2" | wc -l; }
wait_count() { local p=$1 tok=$2 want=$3 i=0
  while [ $i -lt 60 ]; do [ "$(count "$p" "$tok")" -ge "$want" ] && return 0; i=$((i+1)); sleep 1; done; return 1; }
filler() { local n=$1 s='' k=0; while [ ${#s} -lt "$n" ]; do s+="filler sentence number $k about nothing in particular. "; k=$((k+1)); done; printf '%s' "$s"; }
dump() { log "----- visible pane $1 ($2) -----"; lab pane read "$1" --source visible 2>/dev/null; log "----- end -----"; }

P=$(new_pane scen3473) || { log "no pane"; exit 1; }
T="$SESSION:$P"
launch_claude "$P" || { log "claude never idle"; exit 1; }
log "claude $(PATH=$ORIGINAL_PATH claude --version) herdr $(PATH=$ORIGINAL_PATH herdr --version) adapter=$ADAPTER"

for s in $SCEN; do case $s in
long)
  H="HEADTOK$RANDOM$RANDOM"; TL="TAILTOK$RANDOM$RANDOM"
  msg="HEAD MARKER $H. $(filler 2600) END MARKER $TL. Reply with exactly the word that follows HEAD MARKER at the very start of this message, and nothing else."
  log "[long] payload ${#msg} chars, head token $H"
  v=$(fm_backend_herdr_send_text_submit "$T" "$msg" 3 0.4 0.6); log "[long] verdict=$v"
  sleep 3; dump "$P" "after long submit"
  if wait_count "$P" "$H" 1; then
    # the transcript renders the reply line; a head-truncated prompt could not produce the head token
    log "[long] head token visible on screen: $(count "$P" "$H") occurrence(s)"
  else log "[long] head token NEVER visible -> head lost"; fi
  wait_idle "$P"; screen "$P" | grep -n -F "$H" | tail -5
  ;;
multiline)
  H="MLHEAD$RANDOM$RANDOM"
  msg="Line one carries token $H."$'\n'"$(filler 700)"$'\n'"$(filler 700)"$'\n'"Reply with exactly the token from line one and nothing else."
  log "[multiline] payload ${#msg} chars"
  v=$(fm_backend_herdr_send_text_submit "$T" "$msg" 3 0.4 0.6); log "[multiline] verdict=$v"
  sleep 3; dump "$P" "after multiline submit"
  wait_count "$P" "$H" 1 && log "[multiline] token visible: $(count "$P" "$H")" || log "[multiline] token NEVER visible"
  wait_idle "$P"
  ;;
optail)
  H="OPHEAD$RANDOM$RANDOM"; op=
  fm_operational_input_encode away-supervisor "digest head token $H. $(filler 1800) Reply with exactly the digest head token and nothing else." op
  log "[optail] away-supervisor digest ${#op} chars"
  v=$(fm_backend_herdr_send_text_submit "$T" "$op" 3 0.4 0.6); log "[optail] verdict=$v"
  sleep 3; dump "$P" "after long digest submit"
  wait_count "$P" "$H" 1 && log "[optail] token visible: $(count "$P" "$H")" || log "[optail] token NEVER visible"
  wait_idle "$P"
  ;;
inject)
  # Fault injection: the transport types only the tail of the message, the shape issue 3473 reports.
  H="INJHEAD$RANDOM$RANDOM"; X="INJTAIL$RANDOM$RANDOM"
  full="Reply with exactly $H and nothing else. $(filler 400) Ignore this: $X"
  eval "orig_send_literal() $(declare -f fm_backend_herdr_send_literal | tail -n +2)"
  fm_backend_herdr_send_literal() { orig_send_literal "$1" "${2: -120}"; }
  log "[inject] full ${#full} chars, transport types only last 120 chars"
  before_turns=$(count "$P" "$X")
  v=$(fm_backend_herdr_send_text_submit "$T" "$full" 3 0.4 0.6); log "[inject] verdict=$v"
  log "[inject] composer state after refusal: $(fm_backend_herdr_composer_state "$T")"
  log "[inject] native agent status: $(lab agent get "$P" | jq -r .result.agent.agent_status)"
  sleep 4; dump "$P" "after refused tail-only submit"
  log "[inject] tail token occurrences before=$before_turns after=$(count "$P" "$X") (0 => nothing submitted)"
  eval "fm_backend_herdr_send_literal() $(declare -f orig_send_literal | tail -n +2)"
  v=$(fm_backend_herdr_send_text_submit "$T" "$full" 3 0.4 0.6); log "[inject] clean retry verdict=$v"
  wait_count "$P" "$H" 2 && log "[inject] retry reply rendered (head token x$(count "$P" "$H"))" || log "[inject] retry reply NOT rendered"
  wait_idle "$P"; dump "$P" "after clean retry"
  ;;
prefill)
  lab pane send-text "$P" "leftover draft from captain" >/dev/null; sleep 1
  log "[prefill] composer state before send: $(fm_backend_herdr_composer_state "$T")"
  v=$(fm_backend_herdr_send_text_submit "$T" "Reply with exactly PREFILLTOK and nothing else." 3 0.4 0.6); log "[prefill] verdict=$v"
  sleep 1; dump "$P" "after refused send into non-empty composer"
  log "[prefill] PREFILLTOK occurrences on screen: $(count "$P" PREFILLTOK) (0 => nothing typed)"
  lab pane send-keys "$P" ctrl+u >/dev/null; sleep 1
  ;;
shell)
  S=$(new_pane scen3473sh); ST="$SESSION:$S"; sleep 2
  OUT=$TMP_ROOT/shell-out.txt
  log "[shell] native identity: '$(fm_backend_herdr_agent_identity_raw "$SESSION" "$S" 2>/dev/null)'"
  v=$(fm_backend_herdr_send_text_submit "$ST" "echo SHELLTOK > $OUT" 2 0.4 0.4); log "[shell] verdict=$v"
  sleep 1; log "[shell] file content: $(cat "$OUT" 2>/dev/null || echo MISSING)"
  ;;
esac; done
