#!/usr/bin/env bash
# Drive the captain-facing convergence CLI (bin/fm-config-push.sh) against a
# REMOTE secondmate route, through the issue-3745 story.
#
# Usage: drive-remote-route.sh <firstmate-repo-root> <label>
#
# The SSH hop is replaced at firstmate's own FM_SSH_BIN process seam: the shim
# decodes fm-on.sh's base64 argv and runs the REAL bin/fm-remote-inherit.sh
# receiver from the same source revision against a real remote-home directory.
# Everything the change touches - sender, receiver, generation record,
# quarantine, destination bytes - is the product's own code on a real filesystem.
set -u

FM_SRC=$(cd "$1" && pwd -P)
LABEL=$2
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/fm3745r-$LABEL.XXXXXX")
SANDBOX=$(cd "$SANDBOX" && pwd -P)
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HOME_DIR="$SANDBOX/captain-home"
RHOME="$SANDBOX/remote-secondmate-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects" "$RHOME/data" "$RHOME/state"
touch "$HOME_DIR/state/.last-watcher-beat"

cat > "$HOME_DIR/data/secondmates.md" <<EOF
- rsm - remote lane (host: remote-mac; root: $FM_SRC; home: $RHOME; scope: relay work; projects: firstmate; added 2026-08-02)
EOF
{
  printf 'window=fm-remote:rsm\n'
  printf 'kind=secondmate\n'
  printf 'remote_host=remote-mac\n'
  printf 'home=%s\n' "$RHOME"
} > "$HOME_DIR/state/rsm.meta"

FAKEBIN="$SANDBOX/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = remote-mac ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
home_b64=$3
argv_b64=$4
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$argv_b64")
cmd=${rargs[0]}
env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" \
  FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/$cmd" "${rargs[@]:1}"
SH
chmod +x "$FAKEBIN/fake-ssh"

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
  printf '$ FM_HOME=<captain-home> fm-config-push.sh   # remote route rsm\n'
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$FM_SRC" \
    FM_SSH_BIN="$FAKEBIN/fake-ssh" FM_REMOTE_CODE_ROOT="$FM_SRC" \
    "$FM_SRC/bin/fm-config-push.sh" 2>&1 \
    | grep -Ev 'WATCHER DOWN|watcher still down|^●|crew-dispatch|crew-harness|backlog-backend|^  backend:|herdr-presentation|startup-memory|trace-context|launch-env|claude-permission' \
    | sed -e "s#$SANDBOX#<sandbox>#g" -e "s#$FM_SRC#<firstmate-root>#g"
}
show_remote() {
  printf -- '--- remote home data/ ---\n'
  ls -la "$RHOME/data" | sed -e '/^total/d' | awk '{ $3=""; $4=""; print }' | sed 's/  */ /g'
  printf -- '--- remote data/captain-shared.md body line ---\n'
  tail -n 1 "$RHOME/data/captain-shared.md" 2>/dev/null || printf '(absent)\n'
  for q in "$RHOME"/data/captain-shared.md.remote-quarantine-*; do
    [ -e "$q" ] || continue
    printf -- '--- recovery copy %s body line ---\n' "$(basename "$q")"
    tail -n 1 "$q"
  done
}

printf 'firstmate source under test: %s\n' "$FM_SRC"
printf 'revision: %s\n' "$(git -C "$FM_SRC" rev-parse --short HEAD 2>/dev/null || echo 'archived copy')"

step "1. captain publishes the first shared-preferences copy to the remote mate"
captain_shared "preference set v1"
run_push
show_remote

step "2. captain converges again with nothing changed"
run_push
show_remote

step "3. captain edits ONLY the authoritative source (issue 3745 case)"
captain_shared "preference set v2"
run_push
show_remote

step "4. remote mate hand-edits its copy, then the captain edits the source"
chmod u+w "$RHOME/data/captain-shared.md"
printf 'remote local edit\n' >> "$RHOME/data/captain-shared.md"
chmod 444 "$RHOME/data/captain-shared.md"
captain_shared "preference set v3"
run_push
show_remote

step "5. captain edits the source again right after that quarantine"
captain_shared "preference set v4"
run_push
show_remote

step "5a. adversarial: remote copy is unreadable when the source advances"
chmod 000 "$RHOME/data/captain-shared.md"
captain_shared "preference set v5"
run_push
chmod 444 "$RHOME/data/captain-shared.md"
show_remote

step "5b. captain converges again after that failed (interrupted) publication"
printf -- '--- remote generation record before (gen / bytes / sha256 / command) ---\n'
cat "$RHOME/data/.fm-inherit-captain-shared.md.generation"
printf 'sha256 of the bytes actually on disk: %s\n' "$(shasum -a 256 "$RHOME/data/captain-shared.md" | awk '{print $1}')"
captain_shared "preference set v7"
run_push
show_remote

step "6. captain deletes the authoritative source entirely"
rm -f "$HOME_DIR/data/captain-shared.md"
run_push
show_remote

printf '\nsandbox: %s\n' "$SANDBOX"
