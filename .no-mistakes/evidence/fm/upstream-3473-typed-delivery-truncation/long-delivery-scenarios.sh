#!/usr/bin/env bash
# Live scenarios for upstream issue 3473 (Herdr + Claude tail-only submit).
# Drives real Claude Code in an isolated fm-lab-* Herdr session through
# bin/fm-herdr-lab.sh, mirroring tests/fm-herdr-submit-confirm-live-e2e.test.sh.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB_HELPER=$ROOT/bin/fm-herdr-lab.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name issue3473-live)
TMP_ROOT=$(mktemp -d /tmp/fm-issue3473.XXXXXX)
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
RESULTS=()
cleanup() {
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" && echo "teardown ok: $SESSION"
  rm -rf "$TMP_ROOT"
  printf '%s\n' "${RESULTS[@]}"
}
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused" >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
. "$ROOT/bin/fm-operational-input.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
rec() { RESULTS+=("$1"); echo "$1"; }
snap() { lab pane read "$PANE" --source recent --lines 400 > "$EVID/screen-$1.txt" 2>/dev/null || true; }

WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-3473 --no-focus) || exit 1
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || exit 1
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null

wait_idle() {
  local i=0 st
  while [ "$i" -lt 90 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in
      idle|done) return 0 ;;
      blocked) case "$(lab pane read "$PANE" --source visible 2>/dev/null)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;; esac ;;
    esac
    i=$((i + 1)); sleep 1
  done
  return 1
}
wait_reply() {  # <needle> -> 0 when needle rendered
  local i=0
  while [ "$i" -lt 90 ]; do
    lab pane read "$PANE" --source recent --lines 400 2>/dev/null | grep -Fq "$1" && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}
filler() {  # <n> <sep>
  local out='' k=0
  while [ ${#out} -lt "$1" ]; do
    out+="Filler sentence $k is context only and needs no action.$2"; k=$((k + 1))
  done
  printf '%s' "$out"
}
wait_idle || { rec "FATAL: Claude never idle"; exit 1; }
sleep 2
echo "claude=$(claude --version | head -1) herdr=$(herdr --version | head -1) session=$SESSION"

# S1: long single-line steer (~2600 chars). Head carries a code the reply needs.
A="HEADA$RANDOM"; B="TAILB$RANDOM"
msg="The head code is $A. $(filler 2500 ' ')Now reply with only the head code immediately followed by $B with no space, nothing else."
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.6)
if [ "$v" = empty ] && wait_reply "$A$B"; then rec "S1 PASS long single-line (${#msg} chars) verdict=$v reply=$A$B"; else rec "S1 FAIL verdict=$v"; fi
snap S1; wait_idle; sleep 2

# S2: long multi-line steer (~1800 chars, newlines).
A="HEADM$RANDOM"; B="TAILM$RANDOM"
msg="The head code is $A."$'\n'"$(filler 1700 $'\n')"$'\n'"Reply with only the head code immediately followed by $B with no space, nothing else."
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.6)
if [ "$v" = empty ] && wait_reply "$A$B"; then rec "S2 PASS long multi-line (${#msg} chars) verdict=$v reply=$A$B"; else rec "S2 FAIL verdict=$v"; fi
snap S2; wait_idle; sleep 2

# S3: long away-mode operational digest (U+2063 prefix, ~2000 chars).
A="HEADO$RANDOM"; B="TAILO$RANDOM"
op=
fm_operational_input_encode away-supervisor "Digest head code $A. $(filler 1900 ' ')Reply with only the head code immediately followed by $B with no space, nothing else." op
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$op" 3 0.4 0.6)
if [ "$v" = empty ] && wait_reply "$A$B"; then rec "S3 PASS long U+2063 digest (${#op} chars) verdict=$v reply=$A$B"; else rec "S3 FAIL verdict=$v"; fi
snap S3; wait_idle; sleep 2

# S4 adversarial: operator draft already in composer -> nothing typed, send-failed.
DRAFT="operator draft $RANDOM keep me"
lab pane send-text "$PANE" "$DRAFT" >/dev/null; sleep 1
T4="NEVERSENT$RANDOM"
v=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $T4." 3 0.4 0.6)
sleep 3
scr=$(lab pane read "$PANE" --source recent --lines 60 2>/dev/null)
printf '%s\n' "$scr" > "$EVID/screen-S4.txt"
if [ "$v" = send-failed ] && ! grep -Fq "$T4" <<<"$scr" && grep -Fq "$DRAFT" <<<"$scr"; then rec "S4 PASS pre-filled composer refused verdict=$v, draft kept, payload not typed"; else rec "S4 FAIL verdict=$v"; fi
i=0; while [ "$i" -lt 10 ] && [ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ]; do lab pane send-keys "$PANE" ctrl+u >/dev/null; i=$((i+1)); sleep 0.3; done
sleep 1

# S5 adversarial: inject the reported fault - only the tail of the text lands.
eval "orig_$(declare -f fm_backend_herdr_send_literal)"
fm_backend_herdr_send_literal() { orig_fm_backend_herdr_send_literal "$1" "${2: -400}"; }
A="HEADT$RANDOM"; B="TAILT$RANDOM"
msg="The head code is $A. $(filler 2000 ' ')Reply with exactly $B-TRUNCATED and nothing else."
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.6)
st=$(fm_backend_herdr_composer_state "$TARGET")
sleep 5
scr=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null)
printf '%s\n' "$scr" > "$EVID/screen-S5.txt"
n=$(grep -F -c "$B-TRUNCATED" <<<"$scr" || true)
if [ "$v" = send-failed ] && [ "$st" = empty ] && [ "$n" = 0 ]; then rec "S5 PASS tail-only composer refused verdict=$v composer=$st, no turn submitted"; else rec "S5 FAIL verdict=$v composer=$st occurrences=$n"; fi
eval "$(declare -f orig_fm_backend_herdr_send_literal | sed 's/^orig_fm_backend_herdr_send_literal/fm_backend_herdr_send_literal/')"

# S6: clean retry of the same message after refusal delivers it whole.
msg="The head code is $A. $(filler 2000 ' ')Reply with only the head code immediately followed by $B with no space, nothing else."
v=$(fm_backend_herdr_send_text_submit "$TARGET" "$msg" 3 0.4 0.6)
if [ "$v" = empty ] && wait_reply "$A$B"; then rec "S6 PASS clean retry after refusal verdict=$v reply=$A$B"; else rec "S6 FAIL verdict=$v"; fi
snap S6; wait_idle

# S7: non-Claude pane (plain shell) keeps type-then-Enter without the proof.
SH_JSON=$(lab pane split "$PANE" --direction right --no-focus 2>/dev/null || lab tab create --workspace "$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id')" --no-focus)
SH=$(printf '%s' "$SH_JSON" | jq -r '.result.pane.pane_id // .result.root_pane.pane_id')
sleep 2
OUT="$TMP_ROOT/nonclaude.out"
v=$(fm_backend_herdr_send_text_submit "$SESSION:$SH" "echo NONCLAUDE_OK_$(filler 1200 ' ' | tr -dc 'a-z' | head -c 1200) > $OUT" 3 0.4 0.6)
sleep 2
if [ -s "$OUT" ] && grep -q '^NONCLAUDE_OK_' "$OUT"; then rec "S7 PASS non-Claude shell pane executed long command (verdict=$v, ident='$(fm_backend_herdr_agent_identity_raw "$SESSION" "$SH")')"; else rec "S7 FAIL verdict=$v"; fi
