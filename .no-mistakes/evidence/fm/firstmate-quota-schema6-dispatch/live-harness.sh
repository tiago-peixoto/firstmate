#!/usr/bin/env bash
# Live harness: REAL quota-axi 0.1.48 on PATH, REAL bin/fm-dispatch-resolve.sh,
# isolated FM_HOME. Only typesafe.ai (external paid API) is answered by a fake curl.
set -u
WT=$1 MODE=$2   # MODE: schema5 | schema6 | replay:<file>
T=$(mktemp -d); mkdir -p "$T/home/config" "$T/bin"
cat > "$T/home/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "Research work across providers.",
  "use": [
    { "harness": "pi", "model": "openai-codex-work/gpt-5.6-terra", "provider": "codex" },
    { "harness": "pi", "model": "openai-codex/gpt-5.6-sol", "provider": "codex" },
    { "harness": "claude", "model": "opus" },
    { "harness": "cursor", "model": "cursor-grok-4.6-high" } ] } ] }
JSON
printf '# Task\nResearch no-mistakes everywhere.\n' > "$T/brief.md"
cat > "$T/resp.json" <<'JSON'
{ "model": "jev-1.13.0", "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.95,
  "probabilities": { "rule_1": 0.97, "default": 0.03 } } }, "usage": { "input_tokens": 1, "output_tokens": 1 } }
JSON
cat > "$T/bin/curl" <<CURL
#!/usr/bin/env bash
out=''; while [ \$# -gt 0 ]; do case "\$1" in -o) out=\$2; shift 2;; *) shift;; esac; done
cat >/dev/null; cp "$T/resp.json" "\$out"; printf 200
CURL
chmod +x "$T/bin/curl"
case $MODE in
  schema6) export PI_CODING_AGENT_DIR=/tmp/tmp.DRcDZ3lMrA ;;
  replay:*) f=${MODE#replay:}; printf '#!/usr/bin/env bash\ncat %q\n' "$f" > "$T/bin/quota-axi"; chmod +x "$T/bin/quota-axi" ;;
esac
echo "\$ quota-axi resolved to: $(PATH="$T/bin:$PATH" command -v quota-axi)"
echo "\$ fm-dispatch-resolve.sh brief.md   (mode=$MODE)"
PATH="$T/bin:$PATH" FM_HOME="$T/home" TYPESAFE_API_KEY=lab-fake-key "$WT/bin/fm-dispatch-resolve.sh" "$T/brief.md"; echo "exit=$?"
rm -rf "$T"
