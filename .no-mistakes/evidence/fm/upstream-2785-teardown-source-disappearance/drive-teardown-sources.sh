#!/usr/bin/env bash
# Live driver: runs the real bin/fm-teardown.sh (extracted from a git revision)
# against isolated fixtures with one required source removed or unreadable.
# Usage: drive-teardown-sources.sh <repo> <rev> <label>
set -u
REPO=$1 REV=$2 LABEL=$3
WORK=$(mktemp -d /tmp/fm-live-td.XXXXXX)
TESTS_DIR="$REPO/tests"
. "$TESTS_DIR/lib.sh" >/dev/null 2>&1 || true
# Pull fixture helpers from the test file without running its tests.
eval "$(awk '/^(make_case|write_meta|configure_secondmate_with_herdr_child)\(\) *\{/{p=1} p{print} p&&/^\}/{p=0}' "$TESTS_DIR/fm-teardown.test.sh")"
TMP_ROOT=$WORK

build_tree() {  # <case-dir>
  mkdir -p "$1/root"
  git -C "$REPO" archive "$REV" bin lib 2>/dev/null | tar -x -C "$1/root" 2>/dev/null \
    || git -C "$REPO" archive "$REV" bin | tar -x -C "$1/root"
  printf 'manual\n' > "$1/config/backlog-backend"
  cat > "$1/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/treehouse.log"
SH
  cat > "$1/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/tmux.log"
SH
  chmod +x "$1/fakebin/treehouse" "$1/fakebin/tmux"
  : > "$1/treehouse.log"; : > "$1/tmux.log"; : > "$1/state/task-x1.status"
}

run() {  # <case-dir> <title> args...
  local c=$1 title=$2 rc=0; shift 2
  echo "=================================================================="
  echo "[$LABEL @ ${REV:0:7}] $title"
  echo "\$ bin/fm-teardown.sh task-x1 $*"
  FM_ROOT_OVERRIDE="$c/root" FM_STATE_OVERRIDE="$c/state" FM_DATA_OVERRIDE="$c/data" \
  FM_CONFIG_OVERRIDE="$c/config" FM_FAKE_HERDR_LOG="$c/herdr.log" FM_FAKE_HERDR_CLOSED="$c/closed" \
  PATH="$c/fakebin:$PATH" bash "$c/root/bin/fm-teardown.sh" task-x1 "$@" >"$c/stdout" 2>"$c/stderr" || rc=$?
  echo "--- exit status: $rc"
  echo "--- stdout (tail):"; tail -n 5 "$c/stdout" | sed 's/^/    /'
  echo "--- stderr (tail):"; tail -n 6 "$c/stderr" | sed "s#$c#<case>#g; s/^/    /"
  echo "--- state after:"
  for f in "$c/state/task-x1.meta" "$c/state/task-x1.status" ${EXTRA:-}; do
    [ -e "$f" ] && echo "    present: ${f#$c/}" || echo "    GONE:    ${f#$c/}"
  done
  echo "    treehouse return calls: $(wc -l < "$c/treehouse.log")"
  echo "    tmux kill calls: $(grep -c kill "$c/tmux.log")"
  [ -f "$c/herdr.log" ] && echo "    herdr close calls: $(grep -c 'pane close' "$c/herdr.log")"
  return 0
}

# 1. missing startup source (the issue's narrow repro)
c=$(make_case s1); write_meta "$c" local-only ship; build_tree "$c"
rm -f "$c/root/bin/fm-nm-run-lib.sh"
run "$c" "fm-nm-run-lib.sh deleted (issue repro)" --force

# 2. missing fm-operational-input.sh (review F2)
c=$(make_case s2); write_meta "$c" local-only ship; build_tree "$c"
rm -f "$c/root/bin/fm-operational-input.sh"
run "$c" "fm-operational-input.sh deleted" --force

# 3. unreadable startup source
c=$(make_case s3); write_meta "$c" local-only ship; build_tree "$c"
chmod 000 "$c/root/bin/fm-nm-run-lib.sh"
run "$c" "fm-nm-run-lib.sh mode 000" --force
chmod 644 "$c/root/bin/fm-nm-run-lib.sh"

# 4. recorded tmux backend: adapter sibling missing
c=$(make_case s4); write_meta "$c" local-only ship; build_tree "$c"
rm -f "$c/root/bin/fm-session-lock-lib.sh"
run "$c" "tmux task, adapter sibling fm-session-lock-lib.sh deleted" --force

# 5. recorded tmux backend: adapter itself missing
c=$(make_case s5); write_meta "$c" local-only ship; build_tree "$c"
rm -f "$c/root/bin/backends/tmux.sh"
run "$c" "tmux task, adapter backends/tmux.sh deleted" --force

# 6. forced secondmate with herdr child, child adapter sibling missing
c=$(make_case s6); write_meta "$c" local-only secondmate; configure_secondmate_with_herdr_child "$c"; build_tree "$c"
: > "$c/herdr.log"
rm -f "$c/root/bin/fm-transition-lib.sh"
EXTRA="$c/secondmate-home/state/child-herdr.meta $c/secondmate-home/state/child-herdr.status $c/secondmate-home" \
  run "$c" "secondmate + herdr child, fm-transition-lib.sh deleted" --force

# 7. forced zellij secondmate with tmux child, own adapter sibling missing (review F1)
c=$(make_case s7); build_tree "$c"
fm_write_meta "$c/state/task-x1.meta" window=zs:3 endpoint_task_id=task-x1 "worktree=$c/wt" "project=$c/project" \
  kind=secondmate mode=local-only backend=zellij zellij_session=zs zellij_tab_id=1 zellij_pane_id=3 spawn_gen=live-task-x1
h="$c/secondmate-home"; mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"
printf '%s\n' task-x1 > "$h/.fm-secondmate-home"; printf '%s\n' "home=$h" >> "$c/state/task-x1.meta"
fm_write_meta "$h/state/child-tmux.meta" window=childsession:fm-child-tmux endpoint_task_id=child-tmux \
  "worktree=$c/wt" "project=$c/project" kind=ship mode=local-only
: > "$h/state/child-tmux.status"
rm -f "$c/root/bin/fm-backend-hometag-lib.sh"
EXTRA="$h/state/child-tmux.meta $h/state/child-tmux.status $h" \
  run "$c" "zellij secondmate + tmux child, fm-backend-hometag-lib.sh deleted" --force

# 8. control: nothing missing, ordinary forced teardown completes
c=$(make_case s8); write_meta "$c" local-only ship; build_tree "$c"
run "$c" "control: all sources present" --force
rm -rf "$WORK"
