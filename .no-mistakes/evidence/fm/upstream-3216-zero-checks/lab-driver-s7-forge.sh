#!/usr/bin/env bash
# Drives the real bin/fm-crew-state.sh (base vs target) inside a disposable lab
# home against a disposable no-mistakes stand-in that serves recorded-shape
# `axi status` and ci-step log text. Real tmux on a private socket hosts the
# crew window. Everything is removed at exit.
set -u
WT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5HZG22CJQZTWBMHWD4WEHCP
EV=/home/firstmate/.no-mistakes/evidence/01M5HZG22CJQZTWBMHWD4WEHCP
BASE=9fe25bca01b70207409315cc9540af587ef2c5da
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
BASEBIN=$(mktemp -d "${TMPDIR:-/tmp}/fm-basebin.XXXXXX")
cleanup() {
  env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null
  rm -rf "$LAB" "$BASEBIN"
}
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fixture" "$LAB/fakebin"
git -C "$WT" archive "$BASE" bin | tar -x -C "$BASEBIN"
ID=feat-zero
BR=fm/feat-zero
mkdir -p "$LAB/wt"
git -C "$LAB/wt" init -q
git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$LAB/wt" checkout -q -b "$BR"
git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
HEAD=$(git -C "$LAB/wt" rev-parse HEAD)
printf 'window=fm:fm-%s\nworktree=%s\nkind=ship\n' "$ID" "$LAB/wt" > "$LAB/state/$ID.meta"
# Disposable stand-in for the no-mistakes CLI surface the helper reads.
cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
F=${LAB_FIXTURE:?}
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      ""|status) cat "$F/axi-status" ;;
      logs) cat "$F/ci.log" ;;
    esac ;;
  runs) : ;;
  daemon) printf '  ● daemon running (pid 4242)\n' ;;
esac
exit 0
SH
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf 'state=OPEN\nmerged=false\n'
SH
chmod +x "$LAB/fakebin/"*
# Real tmux on the lab's private socket hosts the crew window the meta names.
env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s fm -n "fm-$ID" -c "$LAB/wt" bash
env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t fm -F '#{session_name}:#{window_name}' | sed 's/^/lab tmux window: /'

ci_monitoring() {
cat > "$LAB/fixture/axi-status" <<EOF
run:
  id: "01RUN"
  branch: $BR
  status: running
  head: "$HEAD"
  pr: "https://github.com/o/r/pull/2"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
}
ci_failed_orphan() {
cat > "$LAB/fixture/axi-status" <<EOF
run:
  id: "01RUN"
  branch: $BR
  status: failed
  head: "$HEAD"
  pr: "https://github.com/o/r/pull/203"
  findings: none
outcome: failed
steps[9]{step,status,findings,duration_ms}:
  intent,completed,0,0
  rebase,completed,0,0
  review,completed,0,0
  test,completed,0,0
  document,completed,0,0
  lint,completed,0,0
  push,completed,0,0
  pr,completed,0,0
  ci,failed,0,76127890
EOF
}

run_state() {  # <base|target>
  local bin
  case "$1" in base) bin="$BASEBIN/bin" ;; *) bin="$WT/bin" ;; esac
  env -u TMUX -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" LAB_FIXTURE="$LAB/fixture" \
    PATH="$LAB/fakebin:$PATH" "$bin/fm-crew-state.sh" "$ID"
}
scenario() {  # <title>
  printf '\n=== %s ===\n' "$1"
  printf -- '--- ci log tail (as served by `axi logs --step ci --full`):\n'
  tail -2 "$LAB/fixture/ci.log" | sed 's/^/    /'
  [ -s "$LAB/state/$ID.status" ] && printf -- '--- status log: %s\n' "$(tail -1 "$LAB/state/$ID.status")"
  [ -e "$LAB/config/ci-no-checks-not-green" ] && printf -- '--- old opt-in flag present: config/ci-no-checks-not-green\n'
  printf -- '--- base   %s: %s\n' "${BASE:0:8}" "$(run_state base)"
  printf -- '--- target 7afb2912: %s\n' "$(run_state target)"
}


ci_failed_orphan
printf '[10:05:01] no CI checks reported - still monitoring until merged or closed\n' > "$LAB/fixture/ci.log"
scenario "S7 terminal failed run, only the ci monitor failed, zero-checks marker"
printf '[10:05:01] all CI checks passed - still monitoring until merged or closed\n' > "$LAB/fixture/ci.log"
scenario "S7b same terminal run with a checks-passed marker (held-green guard unchanged)"
