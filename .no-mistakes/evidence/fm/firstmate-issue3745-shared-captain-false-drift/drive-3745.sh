#!/usr/bin/env bash
# Drive real fm-config-push.sh / fm-remote-inherit.sh at a given commit in a disposable world.
set -u
SRC=$1 COMMIT=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-3745.XXXXXX")
git clone -q "$SRC" "$W/root" && git -C "$W/root" checkout -q "$COMMIT"
git -C "$W/root" config user.email t@e.invalid; git -C "$W/root" config user.name t
LAB="$W/lab"; "$W/root/bin/fm-lab-home.sh" create "$LAB" >/dev/null
git -C "$W/root" worktree add -q --detach "$W/sm" HEAD
echo sm > "$W/sm/.fm-secondmate-home"; mkdir -p "$W/sm/data" "$W/sm/state" "$W/sm/config" "$W/sm/projects"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$W/sm" > "$LAB/state/sm.meta"
hdr='# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.'
put(){ printf '%s\n%s\n' "$hdr" "$2" > "$1"; }
push(){ env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$W/root/bin/fm-config-push.sh" 2>&1 | grep -E 'captain-shared|SECONDMATE_SYNC|error' ; }
q(){ find "$W/sm/data" -name '.captain-shared.md.quarantine.*' | wc -l; }
show(){ echo "   dest: $(tail -1 "$W/sm/data/captain-shared.md")  mode=$(stat -c %a "$W/sm/data/captain-shared.md")  quarantine-copies=$(q)"; }
echo "=== commit $(git -C "$W/root" rev-parse --short HEAD) ==="
echo "--- S1: first inheritance (primary v1)"; put "$LAB/data/captain-shared.md" "pref v1"; push; show
echo "--- S2: captain edits ONLY the primary source (v2) and pushes"; put "$LAB/data/captain-shared.md" "pref v2"; push; show
echo "--- S3: secondmate edits its copy locally, primary moves to v3"; chmod u+w "$W/sm/data/captain-shared.md"; put "$W/sm/data/captain-shared.md" "LOCAL secondmate edit"; chmod 444 "$W/sm/data/captain-shared.md"; put "$LAB/data/captain-shared.md" "pref v3"; push; show
for f in "$W/sm/data"/.captain-shared.md.quarantine.*; do [ -e "$f" ] && echo "   recovery copy $(basename "$f"): $(tail -1 "$f")"; done
echo "--- S4: interrupted publication: receipt says v3 but dest bytes are a torn/partial write, primary v4"
chmod u+w "$W/sm/data/captain-shared.md"; printf '# Shared captain pref (torn write' > "$W/sm/data/captain-shared.md"; chmod 444 "$W/sm/data/captain-shared.md"; put "$LAB/data/captain-shared.md" "pref v4"; push; show
echo "--- S5: receipt deleted (no usable receipt), dest untouched v4, primary v5"
rm -f "$W/sm/data/.captain-shared.md.inherited"; put "$LAB/data/captain-shared.md" "pref v5"; push; show
echo "--- S6: forged receipt (garbage), dest v5, primary v6"
printf 'not-a-digest\n' > "$W/sm/data/.captain-shared.md.inherited"; put "$LAB/data/captain-shared.md" "pref v6"; push; show
echo "--- S7: primary removes shared file -> absence mirrored after quarantine"
rm -f "$LAB/data/captain-shared.md"; push; echo "   dest exists? $([ -e "$W/sm/data/captain-shared.md" ] && echo yes || echo no) receipt exists? $([ -e "$W/sm/data/.captain-shared.md.inherited" ] && echo yes || echo no) quarantine-copies=$(q)"

echo "=== remote receiver (fm-remote-inherit.sh) ==="
RH="$W/rhome"; mkdir -p "$RH/data" "$RH/config"; P="$W/payload"
rput(){ local b h; b=$(wc -c < "$P" | tr -d ' '); h=$(sha256sum "$P" | awk '{print $1}'); env -u NO_MISTAKES_GATE FM_HOME="$RH" "$W/root/bin/fm-remote-inherit.sh" put data/captain-shared.md "$b" "$h" "$1" < "$P" 2>&1; }
rq(){ find "$RH/data" -name 'captain-shared.md.remote-quarantine-*' | wc -l; }
echo "--- R1: first put v1"; put "$P" "remote v1"; rput 1; echo "   quarantine-copies=$(rq)"
echo "--- R2: source-only edit v2"; put "$P" "remote v2"; rput 2; echo "   dest: $(tail -1 "$RH/data/captain-shared.md") quarantine-copies=$(rq)"
echo "--- R3: local remote edit, then v3"; chmod u+w "$RH/data/captain-shared.md"; put "$RH/data/captain-shared.md" "REMOTE local edit"; chmod 444 "$RH/data/captain-shared.md"; put "$P" "remote v3"; rput 3; echo "   dest: $(tail -1 "$RH/data/captain-shared.md") quarantine-copies=$(rq)"
for f in "$RH/data"/captain-shared.md.remote-quarantine-*; do [ -e "$f" ] && echo "   recovery copy: $(tail -1 "$f")"; done
git -C "$W/root" worktree remove --force "$W/sm" 2>/dev/null; rm -rf "$W"
