#!/usr/bin/env bash
# Drives the real bin/fm-captain-hold.sh from <tree> against a throwaway home.
# usage: drive.sh <tree> <home> [config-flag...]   (transcript on stdout)
set -u
tree=$1 home=$2; shift 2
export PATH="~/.local/bin:~/.local/share/mise/installs/node/22.23.1/bin:$PATH"
mkdir -p "$home"/{data,state,config,projects,fakebin}
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$home/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/$t"; chmod +x "$home/fakebin/$t"; done
for f in "$@"; do touch "$home/config/$f"; done
echo "### config flags: $(ls "$home/config" | tr '\n' ' ')"
cap() { PATH="$home/fakebin:$PATH" REAL_TASKS_AXI=$(command -v tasks-axi) FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  "$tree/bin/fm-captain-hold.sh" "$@"; }
hold() { cap hold "$1" --title "Choose the start state" \
  --reason "Should the feature start enabled? A: Off until checks pass. B: On now." --repo sample >/dev/null 2>&1 \
  || echo "!! hold $1 failed"; }
show() { echo "--- record $1"; (cd "$home" && tasks-axi show "$1" --full 2>&1); }
direct() {  # <id> <decision bytes> [--release]
  local id=$1 text=$2; shift 2
  hold "$id"; printf '%b' "$text" > "$home/decision.txt"
  echo "\$ answer $id --decision-file <$(printf '%q' "$text")> $*"
  cap answer "$id" --decision-file "$home/decision.txt" "$@" 2>&1; echo "exit=$?"; show "$id"; }
keyed() {  # <id> <answer> <label>
  hold "$1"
  echo "\$ printf '$1\\t$2\\t$3\\n' | answers --source fixture"
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" | cap answers --source "fixture" 2>&1; echo "exit=$?"; show "$1"; }
direct d-bare 'A\n'
direct d-paren '(b)\n'
direct d-padded '  C.  \n'
direct d-words 'A - Off until checks pass.\n'
direct d-multi 'From chat:\nAnswer: Off until checks pass.\nBecause the gate is flaky.\n'
direct d-multi-plain 'First line.\nSecond line.\n'
direct d-release 'A\n' --release
keyed k-bare A ''
keyed k-digit 7 ''
keyed k-blank A ' '
keyed k-labelled A 'Off until checks pass.'
keyed k-free 'Keep it off for now' ''
keyed k-free-blank 'Keep it off for now' ' '
echo "### backlog"; cat "$home/data/backlog.md"
