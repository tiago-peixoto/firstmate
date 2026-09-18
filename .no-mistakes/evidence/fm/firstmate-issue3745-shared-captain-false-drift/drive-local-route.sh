#!/usr/bin/env bash
# Drive the captain-facing shared-captain convergence CLI (bin/fm-config-push.sh)
# through the issue-3745 story in a throwaway sandbox.
#
# Usage: drive-local-route.sh <firstmate-repo-root> <label>
#
# Prints one transcript block per step: what the captain typed, what the captain
# saw, and the resulting secondmate-side filesystem state.
set -u

FM_SRC=$(cd "$1" && pwd -P)
LABEL=$2
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/fm3745-$LABEL.XXXXXX")
SANDBOX=$(cd "$SANDBOX" && pwd -P)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

ROOT="$SANDBOX/firstmate-root"
HOME_DIR="$SANDBOX/captain-home"
SM="$SANDBOX/secondmate-home"

# --- a captain home with one live local secondmate home ---------------------
git init -q -b main "$ROOT"
printf '%s\n' '.fm-secondmate-home' 'data/' 'state/' 'config/' 'projects/' > "$ROOT/.gitignore"
printf 'instructions\n' > "$ROOT/AGENTS.md"
mkdir -p "$ROOT/bin" "$ROOT/.agents/skills"
printf 'echo spawn\n' > "$ROOT/bin/fm-spawn.sh"
printf 'skill\n' > "$ROOT/.agents/skills/example.md"
git -C "$ROOT" add -A >/dev/null
git -C "$ROOT" commit -qm initial
git -C "$ROOT" worktree add -q --detach "$SM" HEAD
printf 'sm\n' > "$SM/.fm-secondmate-home"
mkdir -p "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
touch "$HOME_DIR/state/.last-watcher-beat"
{ printf 'window=firstmate:fm-sm\n'; printf 'kind=secondmate\n'; printf 'home=%s\n' "$SM"; } > "$HOME_DIR/state/sm.meta"

captain_shared() {  # <body>
  cat > "$HOME_DIR/data/captain-shared.md" <<EOF
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.

$1
EOF
}

step() { printf '\n=== %s ===\n' "$1"; }
run_push() {
  printf '$ FM_HOME=<captain-home> fm-config-push.sh\n'
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$FM_SRC/bin/fm-config-push.sh" 2>&1 \
    | sed "s#$SANDBOX#<sandbox>#g"
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
}
show_secondmate() {
  printf -- '--- secondmate data/ ---\n'
  ls -la "$SM/data" | sed -e "s#$SANDBOX#<sandbox>#g" -e '/^total/d' \
    | awk '{ $3=""; $4=""; print }' | sed 's/  */ /g'
  printf -- '--- secondmate data/captain-shared.md body line ---\n'
  tail -n 1 "$SM/data/captain-shared.md" 2>/dev/null || printf '(absent)\n'
  for q in "$SM"/data/.captain-shared.md.quarantine.*; do
    [ -e "$q" ] || continue
    printf -- '--- quarantine %s body line ---\n' "$(basename "$q")"
    tail -n 1 "$q"
  done
}

printf 'firstmate source under test: %s\n' "$FM_SRC"
printf 'revision: %s\n' "$(git -C "$FM_SRC" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"

step "1. captain publishes the first shared-preferences copy"
captain_shared "preference set v1"
run_push
show_secondmate

step "2. captain converges again with nothing changed"
run_push
show_secondmate

step "3. captain edits ONLY the authoritative source (issue 3745 case)"
captain_shared "preference set v2"
run_push
show_secondmate

step "4. secondmate hand-edits its read-only copy, then the captain edits the source"
chmod u+w "$SM/data/captain-shared.md"
printf 'secondmate local edit\n' >> "$SM/data/captain-shared.md"
chmod 444 "$SM/data/captain-shared.md"
captain_shared "preference set v3"
run_push
show_secondmate

step "5. captain edits the source again right after that quarantine"
captain_shared "preference set v4"
run_push
show_secondmate

step "5c. interrupted publication: new bytes landed, receipt write never happened; captain reconverges"
captain_shared "preference set v4b"
chmod u+w "$SM/data/captain-shared.md"
cp "$HOME_DIR/data/captain-shared.md" "$SM/data/captain-shared.md"   # copy finished ...
chmod 444 "$SM/data/captain-shared.md"                               # ... receipt still names v4
printf 'receipt before: %s\n' "$(cut -c1-16 "$SM/data/.captain-shared.md.inherited")"
run_push
printf 'receipt after:  %s\n' "$(cut -c1-16 "$SM/data/.captain-shared.md.inherited")"
show_secondmate

step "5d. interrupted publication, then the source advances again before any convergence"
captain_shared "preference set v4c"
chmod u+w "$SM/data/captain-shared.md"
cp "$HOME_DIR/data/captain-shared.md" "$SM/data/captain-shared.md"   # v4c landed, receipt still v4b
chmod 444 "$SM/data/captain-shared.md"
captain_shared "preference set v4d"
run_push
show_secondmate

step "6a. adversarial: unreadable secondmate copy with NO receipt (pre-upgrade home)"
rm -f "$SM/data/.captain-shared.md.inherited"
chmod 000 "$SM/data/captain-shared.md"
captain_shared "preference set v5"
run_push
chmod 444 "$SM/data/captain-shared.md"
show_secondmate

step "6b. adversarial: unreadable secondmate copy WITH a receipt"
run_push >/dev/null   # heal the receipt first
chmod 000 "$SM/data/captain-shared.md"
captain_shared "preference set v5b"
run_push
chmod 444 "$SM/data/captain-shared.md"
show_secondmate

step "7. adversarial: the inheritance receipt is corrupted, then the source advances"
ls -la "$SM/data/.captain-shared.md.inherited" 2>/dev/null | sed "s#$SANDBOX#<sandbox>#g" || printf '(no receipt)\n'
printf 'not-a-digest\n' > "$SM/data/.captain-shared.md.inherited" 2>/dev/null || true
captain_shared "preference set v6"
run_push
show_secondmate

step "8. captain deletes the authoritative source entirely"
rm -f "$HOME_DIR/data/captain-shared.md"
run_push
show_secondmate

printf '\nsandbox: %s\n' "$SANDBOX"
