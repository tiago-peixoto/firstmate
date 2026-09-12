# shared setup for the live drive
set -u
REPO=/Users/tiago/.no-mistakes/worktrees/5dfc3e2f8f7a/01M2ARDSRMF6ERN620H5JMC1B6
BIN="$REPO/bin"
umask 022

make_fakebin() { # <dir>
  local fb=$1/fakebin
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta 2>/dev/null ;;
esac
exit 0
SH
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none}"
SH
  chmod +x "$fb"/*
  printf '%s\n' "$fb"
}

write_meta() { # <file> <kv>...
  local f=$1; shift; : > "$f"; local kv
  for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}

hr() { printf '\n=== %s ===\n' "$*"; }

# The suite-level bypass firstmate uses for its own tests: this drive runs FROM a
# no-mistakes gate worktree, which fm-gate-refuse-lib.sh otherwise refuses.
export FM_GATE_REFUSE_BYPASS=1
unset FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND 2>/dev/null || true
