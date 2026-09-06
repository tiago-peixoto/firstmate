#!/usr/bin/env bash
# Manual end-to-end repro of kunchenguid/firstmate#3808: a launch from a
# Firstmate home whose project is itself a LINKED worktree of a repository.
# `treehouse get` reports the repository PRIMARY checkout as its own cwd while
# it is still preparing the pooled slot, so the task pane reads the primary for
# the first seconds before settling into the isolated slot treehouse created.
set -u
LABEL=${1:?label}
WORKTREE=${2:?worktree root}
KIND=${3:-ship}          # ship (crewmate) | scout
STALE=${4:-3}            # pane reads that still report the primary checkout
. "$WORKTREE/tests/fixtures.sh"

root=$(fm_test_tmproot fm3808-"$LABEL")
home="$root/firstmate-home"
primary="$root/acme"          # repository primary checkout
mate="$root/acme-mate"        # the home's project: a LINKED worktree of acme
slot="$root/acme-slot-7"      # the isolated worktree treehouse get creates
id=demo-$KIND-a1

fm_test_spawn_home "$home" codex
fm_git_worktree "$primary" "$mate" mate >/dev/null 2>&1
git -C "$primary" worktree add --quiet -b slot-7 "$slot"
fm_test_spawn_brief "$home" "$id" "Demonstrate launching from a linked-worktree home."

fake=$(fm_fakebin "$root/fake")
fm_fake_exit0 "$fake" treehouse
cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    n=0; [ -f "$FM_FAKE_PANE_COUNTFILE" ] && n=$(cat "$FM_FAKE_PANE_COUNTFILE")
    n=$((n + 1)); printf '%s\n' "$n" > "$FM_FAKE_PANE_COUNTFILE"
    # treehouse get is still fetching/checking the slot out for these reads.
    if [ "$n" -le "$FM_FAKE_PANE_STALE_READS" ]; then printf '%s\n' "$FM_FAKE_PANE_STALE"
    else printf '%s\n' "$FM_FAKE_PANE_PATH"; fi
    exit 0 ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
chmod +x "$fake/tmux"

args=("$id" "$mate")
if [ "$KIND" = scout ]; then args+=(--scout); else args+=(--mode no-mistakes --yolo off); fi

echo "### $LABEL"
echo
echo "repository primary checkout  : \$R/acme"
echo "firstmate home's project     : \$R/acme-mate     (linked worktree of acme)"
echo "isolated slot treehouse gets : \$R/acme-slot-7   (linked worktree of acme)"
echo "pane reads reporting primary : $STALE"
echo
echo "\$ bin/fm-spawn.sh ${args[*]//$root/\$R}"
set +e
FM_ROOT_OVERRIDE='' FM_HOME="$home" \
  FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
  FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
  FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
  FM_FAKE_PANE_PATH="$slot" FM_FAKE_PANE_STALE="$primary" \
  FM_FAKE_PANE_STALE_READS="$STALE" \
  FM_FAKE_PANE_COUNTFILE="$root/pane-reads" \
  PATH="$fake:$PATH" \
  "$WORKTREE/bin/fm-spawn.sh" "${args[@]}" 2>&1 \
  | grep -v '^warning: .*records no delivery contract line' | sed "s#$root#\$R#g"
rc=${PIPESTATUS[0]}
set -e
echo
echo "exit status: $rc"
echo
echo "\$ cat \$FM_HOME/state/$id.meta   # recorded task worktree"
if [ -e "$home/state/$id.meta" ]; then
  grep -E '^(worktree|project|kind)=' "$home/state/$id.meta" | sed "s#$root#\$R#g"
else
  echo "(no metadata written - launch refused)"
fi
echo
