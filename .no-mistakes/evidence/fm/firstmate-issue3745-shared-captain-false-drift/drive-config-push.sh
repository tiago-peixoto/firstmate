#!/usr/bin/env bash
# Live drive for firstmate issue 3745: shared-captain source-only updates.
# Usage: drive-config-push.sh <label> <bin-dir> <scenario>
# Stands up an isolated primary home + seeded secondmate worktree and drives the
# real bin/fm-config-push.sh CLI from <bin-dir>, printing a transcript.
set -u
LABEL=$1
BIN=$2
SCENARIO=$3
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3745-$SCENARIO.XXXXXX")
W=$(cd "$W" && pwd -P)
ROOT="$W/root"; HOME_P="$W/home"; SM="$W/sm"; SRC="$HOME_P/data/captain-shared.md"; DEST="$SM/data/captain-shared.md"

shared() {
  cat <<EOF
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
$1
EOF
}

setup() {
  mkdir -p "$HOME_P/state" "$HOME_P/data" "$HOME_P/config" "$HOME_P/projects"
  touch "$HOME_P/state/.last-watcher-beat"
  git init -q -b main "$ROOT"
  printf '%s\n' .fm-secondmate-home data/ state/ config/ projects/ > "$ROOT/.gitignore"
  echo instructions > "$ROOT/AGENTS.md"
  mkdir -p "$ROOT/bin"; echo "echo spawn" > "$ROOT/bin/fm-spawn.sh"
  git -C "$ROOT" add -A
  git -C "$ROOT" -c user.name=t -c user.email=t@example.invalid commit -qm initial
  git -C "$ROOT" worktree add -q --detach "$SM" HEAD
  echo sm > "$SM/.fm-secondmate-home"
  mkdir -p "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
  printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$SM" > "$HOME_P/state/sm.meta"
}

say() { printf '\n### %s\n' "$*"; }

push() {
  local bin=${1:-$BIN}
  if [ "$bin" = "${OLD_BIN:-}" ]; then printf '$ fm-config-push.sh   [base 9bc051f code]\n'; else printf '$ fm-config-push.sh   [%s code]\n' "$LABEL"; fi
  PATH="$BASE_PATH" FM_HOME="$HOME_P" FM_ROOT_OVERRIDE="$ROOT" "$bin/fm-config-push.sh" 2>&1 \
    | grep -E 'captain-shared|SECONDMATE_SYNC|error' | sed "s|$W|<world>|g; s/^/    /"
  printf '    (exit %s)\n' "${PIPESTATUS[0]}"
}

state() {
  local q
  q=$(find "$SM/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  printf '    secondmate copy: mode=%s last-line=%s matches-primary=%s quarantine-files=%s receipt=%s\n' \
    "$(stat -f %Lp "$DEST" 2>/dev/null || echo absent)" \
    "$(tail -n1 "$DEST" 2>/dev/null | tr ' ' '_' || echo -)" \
    "$(cmp -s "$SRC" "$DEST" && echo yes || echo no)" "$q" \
    "$( [ -f "$SM/data/.captain-shared.md.inherited" ] && echo present || echo absent)"
}

show_quarantines() {
  local f
  for f in "$SM"/data/.captain-shared.md.quarantine.*; do
    [ -f "$f" ] || continue
    printf '    recovery copy %s ends with: %s\n' "${f##*/data/}" "$(tail -n1 "$f")"
  done
}

local_edit() {
  chmod u+w "$DEST"; printf '%s\n' "$1" >> "$DEST"; chmod 444 "$DEST"
}

setup
printf '## %s: scenario %s\n' "$LABEL" "$SCENARIO"
case "$SCENARIO" in
  source-only)
    say "first copy"; shared "shared v1" > "$SRC"; push; state
    say "unchanged rerun"; push; state
    say "edit ONLY the primary source (secondmate copy untouched)"; shared "shared v2" > "$SRC"; push; state; show_quarantines
    say "second source-only edit"; shared "shared v3" > "$SRC"; push; state; show_quarantines
    ;;
  local-edit)
    say "first copy"; shared "shared v1" > "$SRC"; push; state
    say "secondmate edits its inherited copy; primary unchanged"; local_edit "LOCAL EDIT A"; push; state; show_quarantines
    say "secondmate edits again AND primary advances"; local_edit "LOCAL EDIT B"; shared "shared v2" > "$SRC"; push; state; show_quarantines
    say "source-only edit afterwards is quiet again"; shared "shared v3" > "$SRC"; push; state
    ;;
  interrupted)
    say "first copy"; shared "shared v1" > "$SRC"; push; state
    say "simulate crash after destination write, before receipt write (dest=v2, receipt still v1)"
    shared "shared v2" > "$SRC"; chmod u+w "$DEST"; cp "$SRC" "$DEST"; chmod 444 "$DEST"; push; state
    say "later source-only edit after healed receipt"; shared "shared v3" > "$SRC"; push; state
    say "simulate torn destination (partial bytes matching neither primary nor receipt), primary advances"
    chmod u+w "$DEST"; head -c 40 "$SRC" > "$DEST.tmp"; mv "$DEST.tmp" "$DEST"; chmod 444 "$DEST"
    shared "shared v4" > "$SRC"; push; state; show_quarantines
    ;;
  receipt-damage)
    say "first copy"; shared "shared v1" > "$SRC"; push; state
    say "receipt deleted, then source-only edit (no usable receipt -> conservative quarantine)"
    rm -f "$SM/data/.captain-shared.md.inherited"; shared "shared v2" > "$SRC"; push; state; show_quarantines
    say "receipt corrupted (garbage), then source-only edit"
    echo "not-a-hash" > "$SM/data/.captain-shared.md.inherited"; shared "shared v3" > "$SRC"; push; state
    say "receipt replaced by a symlink to an outside file, then source-only edit"
    echo "outside-sentinel" > "$W/outside"
    rm -f "$SM/data/.captain-shared.md.inherited"; ln -s "$W/outside" "$SM/data/.captain-shared.md.inherited"
    shared "shared v4" > "$SRC"; push; state
    printf '    outside symlink target still reads: %s ; receipt is now symlink=%s\n' "$(cat "$W/outside")" \
      "$( [ -L "$SM/data/.captain-shared.md.inherited" ] && echo yes || echo no)"
    ;;
  absence)
    say "first copy"; shared "shared v1" > "$SRC"; push; state
    say "primary removes its shared file"; rm -f "$SRC"; push; state; show_quarantines
    say "primary recreates its shared file"; shared "shared v2" > "$SRC"; push; state
    say "source-only edit afterwards"; shared "shared v3" > "$SRC"; push; state
    ;;
  upgrade)
    say "first copy with the OLD (base) code - no receipt is written"; shared "shared v1" > "$SRC"; push "$OLD_BIN"; state
    say "NEW code, source unchanged (heals receipt quietly)"; push; state
    say "NEW code, source-only edit"; shared "shared v2" > "$SRC"; push; state
    ;;
  upgrade-changed-first)
    say "first copy with the OLD (base) code - no receipt is written"; shared "shared v1" > "$SRC"; push "$OLD_BIN"; state
    say "source changes BEFORE any new-code run, then NEW code runs"; shared "shared v2" > "$SRC"; push; state; show_quarantines
    say "NEW code, next source-only edit"; shared "shared v3" > "$SRC"; push; state
    ;;
esac
chmod -R u+w "$W" 2>/dev/null; git -C "$ROOT" worktree remove --force "$SM" >/dev/null 2>&1; rm -rf "$W"
