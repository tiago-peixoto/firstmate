#!/usr/bin/env bash
# Drives the real fm-config-push.sh and fm-remote-inherit.sh CLIs against disposable homes.
# Usage: drive.sh <bin-dir-root>   (a checkout root containing bin/)
set -u
R=$1; W=$(mktemp -d "${TMPDIR:-/tmp}/fm-sc-drive.XXXXXX"); trap 'chmod -R u+w "$W"; rm -rf "$W"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e.invalid
hdr(){ printf '# Shared captain preferences\n\nThis file is main-authoritative in the main firstmate home.\nIn secondmate homes it is read-only in secondmate homes and must not be edited there.\nRoute new captain-preference discoveries to the main firstmate through marked status or a document pointer.\n%s\n' "$2" > "$1"; }
root=$W/root home=$W/home sm=$W/sm od=$W/primary-data
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$od"; touch "$home/state/.last-watcher-beat"
git init -q -b main "$root"; printf '.fm-secondmate-home\ndata/\nstate/\nconfig/\nprojects/\n' > "$root/.gitignore"; echo x > "$root/AGENTS.md"; mkdir -p "$root/bin" "$root/.agents/skills"; echo "echo spawn" > "$root/bin/fm-spawn.sh"; echo s > "$root/.agents/skills/e.md"
git -C "$root" add -A; git -C "$root" commit -qm i; git -C "$root" worktree add -q --detach "$sm" HEAD
echo sm > "$sm/.fm-secondmate-home"; mkdir -p "$sm/data" "$sm/state" "$sm/config" "$sm/projects"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s\n' "$sm" > "$home/state/sm.meta"
push(){ env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS PATH=/usr/bin:/bin FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_DATA_OVERRIDE="$od" "$R/bin/fm-config-push.sh" 2>&1 | head -30; }
q(){ find "$1" -name '*captain-shared.md*quarantine*' | wc -l; }
echo "=== LOCAL (fm-config-push.sh) ==="
echo "--- S1 first inherit"; hdr "$od/captain-shared.md" "shared v1"; push; echo "quarantines=$(q "$sm/data")"
echo "--- S2 re-push unchanged"; push; echo "quarantines=$(q "$sm/data")"
echo "--- S3 primary-only edit (v2)"; hdr "$od/captain-shared.md" "shared v2"; push; echo "quarantines=$(q "$sm/data")"; cmp -s "$od/captain-shared.md" "$sm/data/captain-shared.md" && echo "converged=yes"; stat -c 'mode=%a' "$sm/data/captain-shared.md"
echo "--- S4 secondmate local edit + primary v3 (real divergence)"; chmod u+w "$sm/data/captain-shared.md"; hdr "$sm/data/captain-shared.md" "SECONDMATE LOCAL EDIT"; chmod 444 "$sm/data/captain-shared.md"; hdr "$od/captain-shared.md" "shared v3"; push; echo "quarantines=$(q "$sm/data")"; grep -l "SECONDMATE LOCAL EDIT" "$sm"/data/.captain-shared.md.quarantine.* >/dev/null && echo "recovery-copy-has-local-edit=yes"; cmp -s "$od/captain-shared.md" "$sm/data/captain-shared.md" && echo "converged=yes"
echo "--- S5 interrupted publication: receipt lost, dest holds partial/other bytes, primary v4"; rm -f "$sm/data/.captain-shared.md.inherited"; chmod u+w "$sm/data/captain-shared.md"; printf 'partial write' > "$sm/data/captain-shared.md"; chmod 444 "$sm/data/captain-shared.md"; hdr "$od/captain-shared.md" "shared v4"; push; echo "quarantines=$(q "$sm/data")"; grep -l "partial write" "$sm"/data/.captain-shared.md.quarantine.* >/dev/null && echo "recovery-copy-has-partial=yes"
echo "--- S6 corrupt receipt + untouched dest, primary v5 (no usable receipt => still refused quietly? expect quarantine)"; [ -e "$sm/data/.captain-shared.md.inherited" ] && { chmod u+w "$sm/data/.captain-shared.md.inherited"; echo garbage > "$sm/data/.captain-shared.md.inherited"; }; hdr "$od/captain-shared.md" "shared v5"; push; echo "quarantines=$(q "$sm/data")"
echo "=== REMOTE (fm-remote-inherit.sh) ==="
rh=$W/rhome; mkdir -p "$rh/data" "$rh/config"; src=$W/rsrc.md
rput(){ local b h; b=$(wc -c < "$src" | tr -d ' '); h=$(sha256sum "$src" | awk '{print $1}'); PATH=/usr/bin:/bin FM_HOME="$rh" "$R/bin/fm-remote-inherit.sh" put data/captain-shared.md "$b" "$h" "$1" < "$src" 2>&1; }
echo "--- R1 first put"; hdr "$src" "r v1"; rput 1; echo "quarantines=$(q "$rh/data")"
echo "--- R2 source-only edit"; hdr "$src" "r v2"; rput 2; echo "quarantines=$(q "$rh/data")"
echo "--- R3 remote local edit + v3"; chmod u+w "$rh/data/captain-shared.md"; hdr "$rh/data/captain-shared.md" "REMOTE LOCAL EDIT"; chmod 444 "$rh/data/captain-shared.md"; hdr "$src" "r v3"; rput 3; echo "quarantines=$(q "$rh/data")"; grep -l "REMOTE LOCAL EDIT" "$rh"/data/*remote-quarantine* >/dev/null && echo "recovery-copy-has-local-edit=yes"
echo "--- R4 stale generation replay (gen 2) refused"; hdr "$src" "r stale"; rput 2; echo "rc=$?"; grep -c "r v3" "$rh/data/captain-shared.md" | sed 's/^/dest-still-v3=/'
