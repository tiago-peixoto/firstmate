#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh in a disposable lab home against
# a recording curl stand-in (the model endpoint) and a quota-axi fixture.
set -u
ROOT=$1; EV=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
FAKEBIN="$LAB/fakebin"; LOG="$LAB/log"; mkdir -p "$FAKEBIN" "$LOG"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Stand-in for the typesafe.ai endpoint: records the request body, answers rule_1.
set -u
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) printf '%s\n' "$1" >> "$FAKE_LOG/argv"; shift ;; esac; done
cat > "$FAKE_LOG/body"
cat > "$out" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.9,
    "probabilities": { "rule_1": 0.95, "default": 0.05 } } },
  "usage": { "input_tokens": 100, "output_tokens": 10 } }
JSON
printf 200
SH
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FAKE_LOG/quota-axi.calls"
[ "${1:-}" = --json ] || exit 2
cat "$QUOTA_FIXTURE"
SH
chmod +x "$FAKEBIN"/*
export FAKE_LOG="$LOG"

cat > "$LAB/brief.md" <<'MD'
# Task
Fix the off-by-one in the pager: root cause is the `<=` on line 40 of pager.sh, expected behavior is one page per call.
MD

# Issue #7863 example: one array, Codex family at 82% remaining, Claude family at 26%,
# Claude's spendPriority higher.
cat > "$LAB/base-rules.json" <<'JSON'
{
  "preferred_provider": "codex",
  "rules": [
    { "when": "A simple bug fix with a stated root cause.",
      "use": [
        { "harness": "claude", "model": "opus" },
        { "harness": "codex", "model": "gpt-5.6-sol" } ],
      "why": "SECRET-WHY-TEXT bug fixes are cheap" } ]
}
JSON
cat > "$LAB/base-quota.json" <<'JSON'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 6, "providers": [
  { "provider": "claude", "accountKey": "default", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 26, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.8 } } ] } },
  { "provider": "codex", "accountKey": "codex-home", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 82, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.2 } } ] } },
  { "provider": "codex", "accountKey": "openai-codex-work", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.3 } } ] } } ] }
JSON

TRANSCRIPT="$EV/resolver-scenarios-extra.txt"; : > "$TRANSCRIPT"
scenario() {  # <name> <rules jq filter> <quota jq filter>
  local name=$1 rf=$2 qf=$3 code
  jq "$rf" "$LAB/base-rules.json" > "$LAB/config/crew-dispatch.json"
  jq "$qf" "$LAB/base-quota.json" > "$LAB/quota-$name.json"
  rm -rf "$LOG"; mkdir -p "$LOG"
  {
    printf '===== scenario: %s =====\n' "$name"
    printf -- '--- config/crew-dispatch.json ---\n'; cat "$LAB/config/crew-dispatch.json"
    printf -- '--- quota-axi --json rows (provider accountKey pct spendPriority runway status) ---\n'
    jq -r '.providers[] | "\(.provider) \(.accountKey) pct=\(.quotaSemantics.effectiveAvailability[0].effectivePercentRemaining // "-") spendPriority=\(.quotaSemantics.effectiveAvailability[0].selection.spendPriority // "-") runway=\(.quotaSemantics.effectiveAvailability[0].runway.status // "-") quota=\(.quotaSemantics.status)"' "$LAB/quota-$name.json"
    printf -- '--- $ FM_HOME=$LAB bin/fm-dispatch-resolve.sh brief.md --project lab ---\n'
    PATH="$FAKEBIN:$PATH" FM_HOME="$LAB" QUOTA_FIXTURE="$LAB/quota-$name.json" TYPESAFE_API_KEY=lab-key-never-real \
      "$ROOT/bin/fm-dispatch-resolve.sh" "$LAB/brief.md" --project lab 2> "$LOG/stderr"; code=$?
    printf -- '--- stderr ---\n'; cat "$LOG/stderr"
    printf -- '--- exit: %s ---\n' "$code"
    if [ -f "$LOG/body" ]; then
      printf -- '--- model request body: mentions preferred_provider? %s; mentions why text? %s ---\n' \
        "$(grep -c preferred_provider "$LOG/body")" "$(grep -c SECRET-WHY-TEXT "$LOG/body")"
    else
      printf -- '--- model request: NOT SENT (no curl call recorded) ---\n'
    fi
    printf -- '--- quota-axi calls: %s ---\n\n' "$( [ -f "$LOG/quota-axi.calls" ] && tr '\n' ';' < "$LOG/quota-axi.calls" || echo none)"
  } | tee -a "$TRANSCRIPT"
}

scenario one-preferred-unknown-other-measured '.rules[0].use += [{harness:"pi",model:"openai-codex-work/gpt-5.6-sol",provider:"codex"}]' '(.providers[] | select(.accountKey == "codex-home").quotaSemantics) = {status:"unknown",effectiveAvailability:[]}'
scenario rule-floor-falls-through-to-default-with-preference '.rules[0].floor = {scope:"all_models",min_percent:50,provider:"claude"} | .default = [{harness:"claude",model:"sonnet"},{harness:"codex",model:"gpt-5.6-sol",effort:"medium"}]' '.'
scenario preferred-family-all-exhausted-two-accounts '.rules[0].use += [{harness:"pi",model:"openai-codex-work/gpt-5.6-sol",provider:"codex"}]' '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[0].runway.status) = "exhausted_now"'
rm -rf "$LAB"
