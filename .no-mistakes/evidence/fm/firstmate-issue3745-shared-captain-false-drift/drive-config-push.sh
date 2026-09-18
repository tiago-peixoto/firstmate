#!/usr/bin/env bash
# Drive bin/fm-config-push.sh (local secondmate route) against a scratch primary
# home and a seeded secondmate home, the way an operator runs it.
# Usage: drive-config-push.sh <firstmate-bin-dir> <scenario>
set -u
BIN=$1
SCENARIO=$2
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue3745.XXXXXX")
W=$(cd "$W" && pwd -P)
trap 'chmod -R u+rwx "$W" 2>/dev/null; rm -rf "$W"' EXIT
root="$W/root"; home="$W/home"; sm="$W/sm"
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
touch "$home/state/.last-watcher-beat"
git init -q -b main "$root"
printf '%s\n' .fm-secondmate-home data/ state/ config/ projects/ > "$root/.gitignore"
printf 'instructions\n' > "$root/AGENTS.md"
mkdir -p "$root/bin" "$root/.agents/skills"; printf "echo spawn\n" > "$root/bin/fm-spawn.sh"; printf "skill\n" > "$root/.agents/skills/example.md"
git -C "$root" add -A
git -C "$root" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git -C "$root" worktree add -q --detach "$sm" HEAD
printf 'sm\n' > "$sm/.fm-secondmate-home"
mkdir -p "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$sm" > "$home/state/sm.meta"

src="$home/data/captain-shared.md"
dest="$sm/data/captain-shared.md"
write_shared() {
  cat > "$1" <<HDR
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
HDR
  printf '%s\n' "$2" >> "$1"
}
mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
push() {
  local rc
  echo
  echo "\$ fm-config-push.sh    # $1"
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$BIN/fm-config-push.sh" 2>&1 | sed "s#$W#<scratch>#g"
  rc=${PIPESTATUS[0]}
  echo "[exit $rc]"
}
show() {
  echo "-- secondmate data/ captain files:"
  ( cd "$sm/data" && for f in captain-shared.md .captain-shared.md.*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      if [ -f "$f" ] && [ ! -L "$f" ]; then
        printf '   %-60s mode=%s last-line=%s\n' "$f" "$(mode "$f")" "$(tail -n1 "$f" 2>/dev/null)"
      else
        printf '   %-60s (%s)\n' "$f" "$(file -b "$f" | cut -c1-30)"
      fi
    done )
}
local_edit() { chmod u+w "$dest"; write_shared "$dest" "$1"; chmod 444 "$dest"; }

echo "=== scenario: $SCENARIO (bin: $BIN) ==="
write_shared "$src" "shared v1"
push "first copy"
show
push "unchanged re-run"
case "$SCENARIO" in
  issue-controls)
    write_shared "$src" "shared v2"
    push "source-only edit (secondmate copy untouched)"
    show
    write_shared "$src" "shared v3"
    push "second source-only edit"
    show
    ;;
  true-divergence)
    local_edit "LOCAL EDIT made inside the secondmate home"
    write_shared "$src" "shared v2"
    push "secondmate copy edited locally, then primary source edited"
    show
    for q in "$sm"/data/.captain-shared.md.quarantine.*; do echo "-- recovery copy $(basename "$q") ends with: $(tail -n1 "$q")"; done
    write_shared "$src" "shared v3"
    push "later source-only edit after drift was quarantined"
    show
    ;;
  interrupted-publication)
    # Crash state: v2 bytes landed in the destination but the receipt still names v1.
    write_shared "$src" "shared v2"
    local_edit "shared v2"
    echo "-- simulated crash: destination now holds v2 bytes, receipt still names v1: $(cat "$sm/data/.captain-shared.md.inherited")"
    write_shared "$src" "shared v3"
    push "source advanced again after interrupted publication"
    show
    ;;
  interrupted-matching)
    # Crash state: v2 landed, receipt still v1, source still v2.
    write_shared "$src" "shared v2"
    local_edit "shared v2"
    push "interrupted publication already matches source"
    show
    write_shared "$src" "shared v3"
    push "later source-only edit after the receipt healed"
    show
    ;;
  legacy-no-receipt)
    rm -f "$sm/data/.captain-shared.md.inherited"
    echo "-- receipt removed (home inherited before this fix, or receipt lost)"
    write_shared "$src" "shared v2"
    push "source edit with no receipt"
    show
    write_shared "$src" "shared v3"
    push "next source-only edit (receipt now recorded)"
    show
    ;;
  corrupt-receipt)
    chmod u+w "$sm/data/.captain-shared.md.inherited" 2>/dev/null
    printf 'not-a-digest\n' > "$sm/data/.captain-shared.md.inherited"
    echo "-- receipt overwritten with garbage"
    write_shared "$src" "shared v2"
    push "source edit with corrupt receipt"
    show
    echo "-- receipt now: $(cat "$sm/data/.captain-shared.md.inherited")"
    echo "-- sha256(dest): $(shasum -a 256 "$dest" | awk '{print $1}')"
    ;;
  forged-receipt-symlink)
    other="$W/outside-target"
    shasum -a 256 "$dest" | awk '{print $1}' > "$other"
    rm -f "$sm/data/.captain-shared.md.inherited"
    ln -s "$other" "$sm/data/.captain-shared.md.inherited"
    local_edit "LOCAL EDIT hidden behind a symlinked receipt"
    shasum -a 256 "$dest" | awk '{print $1}' > "$other"
    echo "-- receipt replaced by a symlink to a file naming the edited copy's hash"
    write_shared "$src" "shared v2"
    push "source edit with symlinked receipt"
    show
    echo "-- symlink target untouched: $(cat "$other")"
    ;;
  receipt-write-fails)
    rm -f "$sm/data/.captain-shared.md.inherited"
    mkdir "$sm/data/.captain-shared.md.inherited"
    echo "-- receipt path blocked by a directory"
    write_shared "$src" "shared v2"
    push "source edit while the receipt cannot be written"
    show
    rm -rf "$sm/data/.captain-shared.md.inherited"
    echo "-- operator removes the blocking directory"
    push "re-run after the blocker is gone"
    show
    write_shared "$src" "shared v3"
    push "later source-only edit"
    show
    ;;
  primary-absence)
    rm -f "$src"
    push "primary deletes its shared file"
    show
    write_shared "$src" "shared v2 re-added"
    push "primary re-adds the shared file"
    show
    write_shared "$src" "shared v3"
    push "later source-only edit"
    show
    ;;
  unreadable-destination)
    chmod 000 "$dest"
    write_shared "$src" "shared v2"
    push "source edit while the secondmate copy is unreadable (mode 000)"
    chmod 444 "$dest"
    show
    ;;
esac
