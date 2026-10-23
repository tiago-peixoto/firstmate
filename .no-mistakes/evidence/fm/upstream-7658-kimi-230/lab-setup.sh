#!/usr/bin/env bash
# Mint a disposable Firstmate lab home with one registered project per case,
# a marker MCP command, and Kimi Code 2.3.0 on PATH. Prints the lab path.
set -eu
ROOT=$1 PREFIX=$2 PYBIN=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/home/.kimi-code" "$LAB/treehouse"
: > "$LAB/home/.kimi-code/config.toml"
: > "$LAB/marker.log"
cat > "$LAB/marker.sh" <<SH
#!/bin/sh
printf '%s\n' "\$*" >> '$LAB/marker.log'
sleep 2
SH
chmod +x "$LAB/marker.sh"
printf '## Projects\n' > "$LAB/data/projects.md"
for case_name in plain rootmcp kimimcp paged; do
  proj=$LAB/projects/$case_name
  mkdir -p "$proj"
  git -C "$proj" init -q -b main
  printf '# %s\n' "$case_name" > "$proj/README.md"
  case "$case_name" in
    rootmcp|paged)
      printf '{"mcpServers":{"lab-marker":{"command":"%s","args":["--from-root-mcp-json-%s"]}}}\n' "$LAB/marker.sh" "$case_name" > "$proj/.mcp.json" ;;
    kimimcp)
      mkdir -p "$proj/.kimi-code"
      printf '{"mcpServers":{"lab-marker":{"command":"%s","args":["--from-kimi-code-mcp-json"]}}}\n' "$LAB/marker.sh" > "$proj/.kimi-code/mcp.json" ;;
  esac
  git -C "$proj" add -A
  git -C "$proj" -c user.name='Lab' -c user.email='lab@example.invalid' commit -qm initial
  git clone --quiet --bare "$proj" "$LAB/origins/$case_name.git"
  git -C "$proj" remote add origin "file://$LAB/origins/$case_name.git"
  printf -- '- %s [local-only] - lab project for the Kimi 2.3.0 %s case (added 2026-10-23)\n' "$case_name" "$case_name" >> "$LAB/data/projects.md"
  id=kimi230-$case_name
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
Delivery contract: mode=local-only

## Captain's intent
Say hello and stop. This is a live lab spawn exercising the Kimi 2.3.0 folder prompt ($case_name case).

## Firstmate spec
Do nothing beyond acknowledging the brief.
EOF
done
printf 'kimi\n' > "$LAB/config/crew-harness"
printf '%s\n' "$LAB"
