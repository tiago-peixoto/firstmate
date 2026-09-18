#!/usr/bin/env bash
# Drive the remote-route receiver bin/fm-remote-inherit.sh inside a scratch
# secondmate home, under an empty environment like the remote job worker.
# Usage: drive-remote-receiver.sh <firstmate-bin-dir>
set -u
BIN=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-issue3745-remote.XXXXXX"); W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT
home="$W/home"; mkdir -p "$home/data" "$home/config"
dest="$home/data/captain-shared.md"
write_shared() {
  cat > "$1" <<HDR
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
HDR
  printf '%s\n' "$2" >> "$1"
}
put() { # <home> <generation> <body> <label>
  local h=$1 gen=$2 payload="$W/payload" bytes hash rc
  write_shared "$payload" "$3"
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(shasum -a 256 "$payload" | awk '{print $1}')
  [ -z "${4:-}" ] || { echo; echo "\$ fm-remote-inherit.sh put data/captain-shared.md $bytes <sha256> $gen    # $4"; }
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$W" FM_HOME="$h" \
    "$BIN/fm-remote-inherit.sh" put data/captain-shared.md "$bytes" "$hash" "$gen" < "$payload" 2>&1 | sed "s#$W#<scratch>#g"
  rc=${PIPESTATUS[0]}
  [ -z "${4:-}" ] || echo "[exit $rc]"
}
absent() {
  local empty; empty=$(printf '' | shasum -a 256 | awk '{print $1}')
  echo; echo "\$ fm-remote-inherit.sh absent data/captain-shared.md 0 <empty-sha256> $1    # $2"
  env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$W" FM_HOME="$home" \
    "$BIN/fm-remote-inherit.sh" absent data/captain-shared.md 0 "$empty" "$1" < /dev/null 2>&1 | sed "s#$W#<scratch>#g"
  echo "[exit ${PIPESTATUS[0]}]"
}
show() {
  echo "-- remote home data/:"
  ( cd "$home/data" && for f in captain-shared.md captain-shared.md.remote-quarantine-*; do
      [ -e "$f" ] || continue
      printf '   %-58s mode=%s last-line=%s\n' "$f" "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" "$(tail -n1 "$f")"
    done )
}
echo "=== remote receiver (bin: $BIN) ==="
put "$home" 1 "shared v1" "first copy"; show
put "$home" 2 "shared v1" "unchanged re-push"
put "$home" 3 "shared v2" "source-only edit, remote copy untouched"; show
chmod u+w "$dest"; write_shared "$dest" "REMOTE LOCAL EDIT"; chmod 444 "$dest"
put "$home" 4 "shared v3" "remote copy edited locally, then source edited"; show
put "$home" 5 "shared v4" "later source-only edit"; show
# Crash state: generation 6 (v5) committed its record but the publish never landed.
rm -rf "$W/shadow"; cp -Rp "$home" "$W/shadow"
put "$W/shadow" 6 "shared v5" >/dev/null
cp -p "$W/shadow/data/.fm-inherit-captain-shared.md.generation" "$home/data/"
echo; echo "-- simulated crash: generation 6 record committed (v5) but destination still holds: $(tail -n1 "$dest")"
put "$home" 7 "shared v6" "source advanced after interrupted publication"; show
absent 8 "primary deleted its shared file"; show
put "$home" 9 "shared v7 re-added" "primary re-added the shared file"; show
