#!/usr/bin/env bash
# Remote-route drive for firstmate issue 3745.
# Usage: drive-remote-inherit.sh <label> <pusher-bin> <receiver-root> <scenario>
# Runs the real bin/fm-remote-inherit-push.sh -> bin/fm-on.sh from <pusher-bin>.
# FM_SSH_BIN points at a loopback shim that stands in for ssh + the remote job
# worker: it decodes fm-on.sh's argv exactly as fm-remote-entrypoint.sh would
# and runs <receiver-root>/bin/<command> locally under an empty environment
# with FM_HOME set to the "remote" home. Everything except the transport is real.
set -u
LABEL=$1
PBIN=$2
RROOT=$3
SCENARIO=$4
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3745-remote-$SCENARIO.XXXXXX")
W=$(cd "$W" && pwd -P)
P="$W/primary"; R="$W/remote-home"; SRC="$P/data/captain-shared.md"; DEST="$R/data/captain-shared.md"
mkdir -p "$P/data" "$P/config" "$P/state" "$R/data" "$R/config" "$R/state" "$W/fakebin"
printf -- '- rsm - remote test route (host: loop-host; root: %s; home: %s; scope: test; projects: none; added 2026-09-18)\n' \
  "$RROOT" "$R" > "$P/data/secondmates.md"
cat > "$W/fakebin/loop-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift  # --
_host=$1 _entry=$2 _proto=$3
root=$(printf '%s' "$4" | base64 -D)
home=$(printf '%s' "$5" | base64 -D)
args=()
while IFS= read -r -d '' a; do args+=("$a"); done < <(printf '%s' "$6" | base64 -D)
cmd=${args[0]}
exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" FM_HOME="$home" "$root/bin/$cmd" "${args[@]:1}"
SH
chmod +x "$W/fakebin/loop-ssh"

shared() {
  cat <<EOF
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
$1
EOF
}
GEN=0
say() { printf '\n### %s\n' "$*"; }
push() {
  GEN=$((GEN + 1))
  printf '$ fm-remote-inherit-push.sh rsm %s   [%s]\n' "$GEN" "$LABEL"
  FM_HOME="$P" FM_ROOT_OVERRIDE="${WT_ROOT}" FM_SSH_BIN="$W/fakebin/loop-ssh" FM_CONFIG_INHERIT_LIVE=1 \
    "$PBIN/fm-remote-inherit-push.sh" rsm "$GEN" 2>&1 | grep -E 'captain-shared|error' | sed "s|$W|<world>|g; s/^/    /"
  printf '    (exit %s)\n' "${PIPESTATUS[0]}"
}
state() {
  printf '    remote copy: mode=%s last-line=%s matches-primary=%s remote-quarantine-files=%s\n' \
    "$(stat -f %Lp "$DEST" 2>/dev/null || echo absent)" \
    "$(tail -n1 "$DEST" 2>/dev/null | tr ' ' '_')" \
    "$(cmp -s "$SRC" "$DEST" && echo yes || echo no)" \
    "$(find "$R/data" -name 'captain-shared.md.remote-quarantine-*' | wc -l | tr -d ' ')"
}
show_quarantines() {
  local f
  for f in "$R"/data/captain-shared.md.remote-quarantine-*; do
    [ -f "$f" ] || continue
    printf '    recovery copy %s ends with: %s\n' "${f##*/data/}" "$(tail -n1 "$f")"
  done
}
remote_edit() { chmod u+w "$DEST"; printf '%s\n' "$1" >> "$DEST"; chmod 444 "$DEST"; }

printf '## %s: remote scenario %s\n' "$LABEL" "$SCENARIO"
case "$SCENARIO" in
  source-only)
    say "first put"; shared "shared v1" > "$SRC"; push; state
    say "unchanged rerun"; push; state
    say "edit ONLY the primary source (remote copy untouched)"; shared "shared v2" > "$SRC"; push; state; show_quarantines
    ;;
  guards)
    say "first put"; shared "shared v1" > "$SRC"; push; state
    say "source-only edit"; shared "shared v2" > "$SRC"; push; state
    say "remote copy edited locally; primary unchanged"; remote_edit "REMOTE EDIT A"; push; state; show_quarantines
    say "remote copy edited locally AND primary advances"; remote_edit "REMOTE EDIT B"; shared "shared v3" > "$SRC"; push; state; show_quarantines
    say "simulate interrupted publication: generation record committed for v4 but the destination swap never happened"
    shared "shared v4" > "$SRC"; GEN=$((GEN + 1))
    printf '%s\n%s\n%s\n%s\n' "$GEN" "$(wc -c < "$SRC" | tr -d ' ')" "$(shasum -a 256 "$SRC" | awk '{print $1}')" put \
      > "$R/data/.fm-inherit-captain-shared.md.generation"
    printf '    (record now names v4 at generation %s; remote copy still holds v3)\n' "$GEN"
    shared "shared v5" > "$SRC"; push; state; show_quarantines
    say "primary removes shared file"; rm -f "$SRC"; push; state
    say "primary recreates shared file, then source-only edit"; shared "shared v6" > "$SRC"; push; shared "shared v7" > "$SRC"; push; state
    ;;
esac
chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"
