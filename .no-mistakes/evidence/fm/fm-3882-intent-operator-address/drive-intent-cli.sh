#!/usr/bin/env bash
# Drives firstmate's real CLI (fm-brief.sh, fm-spawn.sh, fm-promote.sh) against an
# isolated FM_HOME to show what text reaches no-mistakes pipeline input.
# Usage: drive-intent-cli.sh <firstmate-root> <label>
# Spawn runs the real script end to end through validation and launch-brief.md
# publication; a refusing `tmux` on PATH stops it only at backend creation so no
# real agent window or worktree is created.
set -u
ROOT=$1 LABEL=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-intent-drive.XXXXXX")
trap 'rm -rf "$W"' EXIT
HOME_DIR="$W/home" PROJ="$W/projects/proj" FAKEBIN="$W/bin"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ" "$FAKEBIN"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 FM_GATE_REFUSE_BYPASS=1
unset FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
git -C "$PROJ" init -q
printf '#!/bin/sh\necho "tmux $*" >> "%s/tmux.log"\nexit 1\n' "$W" > "$FAKEBIN/tmux"; chmod +x "$FAKEBIN/tmux"
umask 022

hr() { printf '\n==================== [%s] %s ====================\n' "$LABEL" "$*"; }
spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$W/projects-unused" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$FAKEBIN:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}
promote() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    "$ROOT/bin/fm-promote.sh" "$@" 2>&1
}
scaffold() {  # <id> [--scout|--mode m]
  local id=$1; shift
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" proj "$@" >/dev/null 2>&1
}
fill() {  # <file> <intent> <spec>
  local c; c=$(cat "$1"); c=${c//'{TASK}'/$2}; c=${c//'{FIRSTMATE_SPEC}'/$3}; printf '%s\n' "$c" > "$1"
}
authorized() { awk '$0 == "## Captain intent authorized for --intent" { e=1; next } e { print }' "$1"; }
labels_in() {  # <file>: count lines carrying an operator-address spelling anywhere
  grep -cE "Captain:|Captain's (words|ask|intent):|Captain," "$1" || true
}
show_result() {  # <id> <exit>
  printf 'exit=%s\n' "$2"
  if [ -s "$W/tmux.log" ]; then echo "backend reached (spawn passed validation): $(head -1 "$W/tmux.log")"; else echo "backend reached: no (spawn stopped before backend creation)"; fi
  rm -f "$W/tmux.log"
  [ -f "$HOME_DIR/data/$1/launch-brief.md" ] && echo "launch-brief.md: PUBLISHED" || echo "launch-brief.md: absent"
  [ -f "$HOME_DIR/state/$1.meta" ] && echo "state/$1.meta: WRITTEN" || echo "state/$1.meta: absent"
}

hr "S1 scaffold no-mistakes ship brief: Definition-of-done --intent contract"
scaffold s1 --mode no-mistakes
grep -n -- "--intent\|legacy brief\|provenance" "$HOME_DIR/data/s1/brief.md"
echo "lines with operator-address spellings in scaffolded brief: $(labels_in "$HOME_DIR/data/s1/brief.md")"

hr "S2 modern brief with plain captain words incl. nested ### subheadings -> spawn"
scaffold s2 --mode no-mistakes
WORDS=$(cat <<'EOF'
Do items 1 and 7 of the report, and don't touch the watcher.
### Item 1: session floor
The fold refuses sessions under `min_floor=3`; keep the refusal but log it.
### Item 7: PR body
Stop the "Intent" section from leaking internal chat vocabulary.
EOF
)
fill "$HOME_DIR/data/s2/brief.md" "$WORDS" 'Build constraint: add a regression test first.'
out=$(spawn s2 "$PROJ" claude --mode no-mistakes --yolo off); st=$?
show_result s2 "$st"
echo "--- overlay contract section of launch-brief.md ---"
awk '/^# Current no-mistakes intent contract/{e=1} e' "$HOME_DIR/data/s2/launch-brief.md"
echo "--- comparison: authorized --intent section vs ## Captain's intent body ---"
if [ "$(authorized "$HOME_DIR/data/s2/launch-brief.md")" = "$WORDS" ]; then echo "IDENTICAL (words intact, nested subheadings kept, no spec, no labels)"; else echo "DIFFERENT"; fi
echo "lines with operator-address spellings in launch-brief.md: $(labels_in "$HOME_DIR/data/s2/launch-brief.md")"

hr "S3 adversarial: ## Captain's intent body line opening with each address spelling -> spawn"
n=0
for marker in 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:" 'Captain,' '   Captain:'; do
  n=$((n + 1)); id="s3-$n"
  scaffold "$id" --mode no-mistakes
  fill "$HOME_DIR/data/$id/brief.md" "Fix the fold refusal.
$marker keep the successful session path unchanged." 'Reproduce first.'
  before=$(shasum "$HOME_DIR/data/$id/brief.md" | cut -d' ' -f1)
  echo "--- marker <$marker> ---"
  out=$(spawn "$id" "$PROJ" claude --mode no-mistakes --yolo off); st=$?
  printf '%s\n' "$out" | sed "s#$HOME_DIR#<FM_HOME>#g" | tail -1
  show_result "$id" "$st"
  [ ! -f "$HOME_DIR/data/$id/launch-brief.md" ] || { echo "LEAKED into authorized --intent:"; authorized "$HOME_DIR/data/$id/launch-brief.md" | sed -n '1,2p' | sed 's/^/  | /'; }
  [ "$before" = "$(shasum "$HOME_DIR/data/$id/brief.md" | cut -d' ' -f1)" ] && echo "brief.md: unchanged (not scrubbed)" || echo "brief.md: MODIFIED"
done
echo "--- labeled line nested under a ### subheading inside ## Captain's intent ---"
scaffold s3-nested --mode no-mistakes
fill "$HOME_DIR/data/s3-nested/brief.md" "Do item 7.
### Item 7
Captain: stop the leak." 'Spec.'
out=$(spawn s3-nested "$PROJ" claude --mode no-mistakes --yolo off); st=$?
printf '%s\n' "$out" | sed "s#$HOME_DIR#<FM_HOME>#g" | tail -1; show_result s3-nested "$st"
echo "--- same scenario as a scout spawn (shared boundary) ---"
scaffold s3-scout --scout
fill "$HOME_DIR/data/s3-scout/brief.md" "Captain, investigate the refusal." 'Spec.'
out=$(spawn s3-scout "$PROJ" claude --scout); st=$?
printf '%s\n' "$out" | sed "s#$HOME_DIR#<FM_HOME>#g" | tail -1; show_result s3-scout "$st"

hr "S4 labels mentioned mid-line (and under ## Firstmate spec) are accepted verbatim"
scaffold s4 --mode no-mistakes
WORDS=$(cat <<'EOF'
Stop composing Captain:, Captain's words:, Captain's ask:, and Captain's intent: into PR bodies.
Keep the literal example `Captain, hello` in the docs.
EOF
)
fill "$HOME_DIR/data/s4/brief.md" "$WORDS" 'Captain: this spec line is not scanned and never becomes intent.'
out=$(spawn s4 "$PROJ" claude --mode no-mistakes --yolo off); st=$?
printf '%s\n' "$out" | grep -c "operator-address line" | sed 's/^/operator-address refusals: /'
show_result s4 "$st"
echo "--- authorized --intent section ---"; authorized "$HOME_DIR/data/s4/launch-brief.md"
[ "$(authorized "$HOME_DIR/data/s4/launch-brief.md")" = "$WORDS" ] && echo "IDENTICAL to ## Captain's intent body (not scrubbed; spec excluded)" || echo "DIFFERENT"

hr "S5 promote a scout whose ## Captain's intent opens with an address label"
id=s5-bad; scaffold "$id" --scout
fill "$HOME_DIR/data/$id/brief.md" "Captain's ask: investigate the refusal." 'Reproduce it first.'
printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$HOME_DIR/state/$id.meta"
out=$(promote "$id" --mode no-mistakes --yolo off); st=$?
printf '%s\n' "$out" | sed "s#$HOME_DIR#<FM_HOME>#g" | tail -1
echo "exit=$st"; cat "$HOME_DIR/state/$id.meta" | sed 's/^/meta: /'
[ -f "$HOME_DIR/data/$id/ship-instructions.md" ] && echo "ship-instructions.md: PUBLISHED" || echo "ship-instructions.md: absent"
echo "--- promote a scout with plain words ---"
id=s5-good; scaffold "$id" --scout
fill "$HOME_DIR/data/$id/brief.md" "Investigate the refusal and keep the successful path." 'Reproduce it first.'
printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$HOME_DIR/state/$id.meta"
out=$(promote "$id" --mode no-mistakes --yolo off); st=$?
printf '%s\n' "$out" | sed "s#$HOME_DIR#<FM_HOME>#g" | head -2
echo "exit=$st"
sed -n '/^## Captain.s intent/,/^## Firstmate spec/p' "$HOME_DIR/data/$id/ship-instructions.md"
grep -n -- "--intent\|legacy brief" "$HOME_DIR/data/$id/ship-instructions.md"
echo "lines with operator-address spellings in ship-instructions.md: $(labels_in "$HOME_DIR/data/$id/ship-instructions.md")"

rm -f "$W/tmux.log"
hr "S6 legacy mixed # Task briefs (no subsections)"
legacy() {  # <id> <task-body>
  mkdir -p "$HOME_DIR/data/$1"
  printf '# Task\n%s\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' "$2" > "$HOME_DIR/data/$1/brief.md"
}
legacy s6-marker "[captain] Fix the legacy dispatch boundary.
Do not copy this Firstmate-authored constraint into intent.
[captain] Keep existing sessions working."
out=$(spawn s6-marker "$PROJ" claude --mode no-mistakes --yolo off); st=$?
show_result s6-marker "$st"; echo "--- authorized --intent ([captain] marker) ---"; authorized "$HOME_DIR/data/s6-marker/launch-brief.md"
legacy s6-stored "Captain's words: Fix the legacy dispatch boundary.
Do not copy this constraint.
Captain: Keep existing sessions working."
out=$(spawn s6-stored "$PROJ" claude --mode no-mistakes --yolo off); st=$?
show_result s6-stored "$st"; echo "--- authorized --intent (previously stored labels, compat) ---"; authorized "$HOME_DIR/data/s6-stored/launch-brief.md"
legacy s6-none "Fix the legacy dispatch boundary with no provenance marks."
out=$(spawn s6-none "$PROJ" claude --mode no-mistakes --yolo off); st=$?
echo "--- unmarked legacy refusal ---"; printf '%s\n' "$out" | tail -1; show_result s6-none "$st"
