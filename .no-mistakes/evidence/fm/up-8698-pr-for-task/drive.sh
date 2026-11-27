#!/usr/bin/env bash
# Drives the real bin/fm-inactive-reconcile.sh `scan` of the tree in $1 against a
# throwaway secondmate home, and prints the lines it relayed on the parent channel.
# $2 = "scan-opt-in" creates config/pr-register-scan in that home.
set -u
TREE=$1; OPT=${2:-}
. "$TREE/tests/lib.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-8698.XXXXXX"); trap 'rm -rf "$W"' EXIT
MAIN=$W/main; MATE=$W/mate
mkdir -p "$W/root" "$W/fakebin" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
: > "$MATE/AGENTS.md"; : > "$W/forge.log"
for t in gh gh-axi curl; do printf '#!/usr/bin/env bash\necho "$(basename "$0")" >> "%s"\nexit 97\n' "$W/forge.log" > "$W/fakebin/$t"; done
printf '#!/usr/bin/env bash\necho "state: unknown · source: fake"\n' > "$W/fakebin/fm-crew-state.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/fakebin/tmux"
chmod +x "$W/fakebin"/*
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$MATE/.fm-secondmate-parent"
[ "$OPT" != scan-opt-in ] || : > "$MATE/config/pr-register-scan"
A=https://github.com/acme/widgets/pull/101   # PR A: recorded in meta pr=
B=https://github.com/acme/widgets/pull/202   # PR B: named by a ready line
child() { # <id> <kind> <recorded-pr-or-empty> <status-log>
  local id=$1 kind=$2 pr=$3 status=$4 sha p="$MATE/projects/$1"
  mkdir -p "$p"; git -C "$p" init -q
  git -C "$p" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  sha=$(git -C "$p" rev-parse HEAD); git -C "$p" update-ref refs/remotes/origin/main "$sha"
  fm_write_meta "$MATE/state/$id.meta" "window=firstmate:fm-$id" "worktree=$p" "project=$p" \
    harness=codex "kind=$kind" mode=no-mistakes yolo=off "spawn_gen=s1.$id" ${pr:+"pr=$pr"} "pr_head=$sha"
  printf '%s\n' "$status" > "$MATE/state/$id.status"; : > "$MATE/state/$id.turn-ended"
  touch -d '2 minutes ago' "$MATE/state/$id".{meta,status,turn-ended}
}
child a-registered-b-reported ship "$A" "done: PR $B checks green"
child a-then-b-in-log        ship "$A" "$(printf 'done: PR %s checks green\nworking: reopening\ndone: PR %s' "$A" "$B")"
child b-reported-stamped     ship "$A" "done [at=1788576000]: PR $B checks green"
child one-pr                 ship "$A" "done: PR $A checks green"
child one-pr-plain-done      ship "$A" "done: cleanup finished"
child prose-mentions-b       ship "$A" "done: fixed, context in $B"
child ready-shape-with-tail  ship "$A" "done: PR $B checks green and more words"
child failed-names-b         ship "$A" "failed: PR $B checks red"
child no-recorded-pr         ship ""   "done: PR $B checks green"
child scout-names-b          scout "$A" "done: PR $B checks green"
PATH="$W/fakebin:$PATH" FM_ROOT_OVERRIDE="$W/root" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" \
  FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" FM_INACTIVE_RECONCILE_SECS=60 \
  FM_INACTIVE_CREW_STATE_BIN="$W/fakebin/fm-crew-state.sh" FM_FORGE_LOG="$W/forge.log" \
  "$TREE/bin/fm-inactive-reconcile.sh" scan
echo "scan exit=$?" >&2
sed -E 's/ \[at=[0-9]+\]//; s/ \[key=[^]]*\]//' "$MAIN/state/mate.status" | sort
[ ! -s "$W/forge.log" ] || { echo "FORGE CALLED:" >&2; cat "$W/forge.log" >&2; }
