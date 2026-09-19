#!/usr/bin/env bash
# End-to-end driver for issue 4767 (supervisor's own status close must not wake
# the same home; worker lines still must). Runs the REAL product scripts from
# <root>: bin/fm-watch.sh (watcher), bin/fm-wake-drain.sh (drain / OPEN
# DECISIONS), bin/fm-send.sh --resolve-key (answer + close), and
# bin/fm-captain-hold.sh complete (captain-held transfer). Only tmux and
# fm-crew-state are stubbed, because there is no live tmux session / crew pane.
#
# usage: e2e-4767.sh <root> <label> [case...]
# fm-send/fm-captain-hold run with FM_GATE_REFUSE_BYPASS=1 (the documented
# test-harness escape hatch) because every home here is a throwaway temp dir.
set -u
ROOT=$1; LABEL=$2; shift 2
CASES=${*:-"fold_single watcher_loop fold_multi late_worker folded_working sm_failed sm_paused sm_selfresolved hold_transfer append_fail"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm4767-$LABEL.XXXXXX")
say() { printf '%s\n' "$*"; }
hr() { printf -- '---- %s\n' "$*"; }

make_fakebins() {  # <dir>
  local d=$1
  mkdir -p "$d/sendbin" "$d/watchbin"
  # fm-send: accept typed input, report an empty composer so submit confirms.
  cat > "$d/sendbin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0 ;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1 fm-mate fm-origin; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/sendbin/sleep"
  # watcher: the crew pane is actively working (its output keeps changing), so
  # the pane-stale path never fires and only status signals can wake.
  cat > "$d/watchbin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
[ "${1:-}" = capture-pane ] && { printf 'compiling step %s\n' "$RANDOM$RANDOM"; exit 0; }
exit 1
SH
  cat > "$d/watchbin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · idle worker}"
SH
  chmod +x "$d"/sendbin/* "$d"/watchbin/*
}

new_home() {  # <name> -> sets HOME_DIR STATE_DIR BIN
  HOME_DIR="$WORK/$1"; STATE_DIR="$HOME_DIR/state"; BIN="$HOME_DIR"
  mkdir -p "$STATE_DIR" "$HOME_DIR/data" "$HOME_DIR/config"
  make_fakebins "$HOME_DIR"
}

ship_meta() { printf 'window=sess:fm-%s\nkind=ship\n' "$1" > "$STATE_DIR/$1.meta"; }
mate_meta() {
  printf '%s\n' "window=sess:fm-$1" "endpoint_task_id=$1" "worktree=$HOME_DIR" "project=$HOME_DIR" \
    "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" "home=$HOME_DIR" "projects=alpha" \
    > "$STATE_DIR/$1.meta"
}

drain() {  # supervisor drains; acks any presented wake rows like the real loop
  local out err seq gen
  out=$(FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-wake-drain.sh" 2>"$HOME_DIR/drain.err")
  printf '%s\n' "$out" | sed 's/^/  drain| /'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$HOME_DIR/drain.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$HOME_DIR/drain.err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_STATE_OVERRIDE="$STATE_DIR" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    say "  drain| (acked through $seq)"
  fi
}

send() {  # fm-send.sh <args...>; then the worker reads the answer (the
  # documented worker contract: mv each handled record into <id>.inbox/handled/)
  local rc=0 d
  env FM_GATE_REFUSE_BYPASS=1 PATH="$HOME_DIR/sendbin:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    FM_SEND_LOG=/dev/null FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$@" || rc=$?
  for d in "$STATE_DIR"/*.inbox; do
    [ -d "$d" ] || continue
    mkdir -p "$d/handled"; mv "$d"/*.msg "$d/handled/" 2>/dev/null || true
  done
  return "$rc"
}

WPID=
watch_start() {
  : > "$HOME_DIR/watch.out"
  PATH="$HOME_DIR/watchbin:$PATH" FM_STATE_OVERRIDE="$STATE_DIR" \
    FM_CREW_STATE_BIN="$HOME_DIR/watchbin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$HOME_DIR/watch.out" 2>"$HOME_DIR/watch.err" &
  WPID=$!
}
beat() { stat -f %m "$STATE_DIR/.last-watcher-beat" 2>/dev/null; }
# Watch for <cycles> full poll cycles. Prints QUIET (alive, no output, empty queue)
# or WOKE: <output> (watcher exited with a wake).
watch_verdict() {  # <cycles>
  local want=${1:-3} seen=0 last='' now i=0
  rm -f "$STATE_DIR/.last-watcher-beat"
  while [ "$i" -lt 250 ]; do
    if ! kill -0 "$WPID" 2>/dev/null; then
      wait "$WPID" 2>/dev/null
      say "  watch| WOKE: $(tr '\n' ' ' < "$HOME_DIR/watch.out")"; WPID=
      say "  (supervisor drains the wake it was handed)"; drain; return 1
    fi
    now=$(beat)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then seen=$((seen + 1)); last=$now; fi
    [ "$seen" -gt "$want" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ -s "$HOME_DIR/watch.out" ] || [ -s "$STATE_DIR/.wake-queue" ]; then
    say "  watch| WOKE(queued): $(tr '\n' ' ' < "$HOME_DIR/watch.out")"
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=; return 1
  fi
  say "  watch| QUIET after $want full poll cycles (no output, empty wake queue)"
  return 0
}
watch_stop() { [ -n "$WPID" ] && { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }; WPID=; }
watch_wait_wake() {  # watcher must exit with a wake within ~15s
  local i=0
  while [ "$i" -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$WPID" 2>/dev/null; then say "  watch| NO WAKE within 15s"; watch_stop; return 1; fi
  wait "$WPID" 2>/dev/null; WPID=
  say "  watch| WOKE: $(tr '\n' ' ' < "$HOME_DIR/watch.out")"
  say "  (supervisor drains the wake it was handed)"; drain
}
worker() { printf '%s\n' "$2" >> "$STATE_DIR/$1.status"; say "  worker($1)| $2"; }
showfile() { sed 's/^/  file| /' "$STATE_DIR/$1.status"; }
# Let the real watcher surface the current file once, then drain+ack it, so the
# watcher's seen marker covers everything so far (the normal supervision loop).
announce_via_watcher() {
  say "  (watcher up: it surfaces the decision; supervisor drains and acks)"
  watch_start
  watch_wait_wake
}

case_fold_single() {
  hr "fold_single: session-start drain lists the decision, supervisor answers with --resolve-key, watcher starts"
  new_home fold_single; ship_meta t1
  worker t1 'needs-decision [key=api-shape]: pick REST or RPC'
  drain
  send t1 --resolve-key api-shape "go with REST"; say "  send| rc=$?"
  showfile t1
  watch_start
  if watch_verdict 3; then
    worker t1 'blocked: need staging credentials'
    watch_wait_wake
  fi
}

case_watcher_loop() {
  hr "watcher_loop: watcher surfaces the decision, supervisor drains, answers, restarts watcher"
  new_home watcher_loop; ship_meta t1
  worker t1 'needs-decision [key=db]: postgres or sqlite?'
  announce_via_watcher
  send t1 --resolve-key db "postgres"; say "  send| rc=$?"
  watch_start
  if watch_verdict 3; then
    worker t1 'blocked: migration needs a superuser'
    watch_wait_wake
  fi
}

case_fold_multi() {
  hr "fold_multi: drain lists two decisions, ONE answer closes both keys"
  new_home fold_multi; ship_meta t1
  worker t1 'needs-decision [key=budget]: approve spend?'
  worker t1 'needs-decision [key=vendor]: pick a vendor'
  drain
  send t1 --resolve-key budget --resolve-key vendor "approve spend, pick acme"; say "  send| rc=$?"
  showfile t1
  watch_start
  watch_verdict 3 && { watch_stop; drain; }
}

case_late_worker() {
  hr "late_worker (adversarial): worker appends after the drain, before the supervisor's close"
  new_home late_worker; ship_meta t1
  worker t1 'needs-decision [key=region]: us-east or eu-west?'
  drain
  worker t1 'blocked: vendor portal is down'
  send t1 --resolve-key region "eu-west"; say "  send| rc=$?"
  watch_start
  watch_verdict 3 || true
}

case_folded_working() {
  hr "folded_working (adversarial): ship worker changes course while watcher is down; drain folds past it; supervisor closes"
  new_home folded_working; ship_meta t1
  : > "$STATE_DIR/t1.status"
  worker t1 'needs-decision [key=budget]: approve spend?'
  announce_via_watcher
  worker t1 'working: abandoned the migration, rewriting the schema by hand'
  drain
  send t1 --resolve-key budget "approved"; say "  send| rc=$?"
  watch_start
  watch_verdict 3 || true
}

case_sm_common() {  # <lagging lines...>
  new_home "$CASE_NAME"; mate_meta mate
  : > "$STATE_DIR/mate.status"
  worker mate 'needs-decision [key=budget]: approve spend?'
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy' announce_via_watcher
  local l; for l in "$@"; do worker mate "$l"; done
  drain
  send fm-mate --resolve-key budget "approved"; say "  send| rc=$?"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_start
  watch_verdict 3 || true
  unset FM_FAKE_CREW_STATE
}
case_sm_failed() {
  hr "sm_failed (adversarial): secondmate relays a crew failure while watcher is down; drain folds; supervisor closes"
  CASE_NAME=sm_failed case_sm_common 'failed: crew c3 hit an unrecoverable migration error' \
    'working: retrying c3 in a fresh worktree'
}
case_sm_paused() {
  hr "sm_paused (adversarial): secondmate pauses while watcher is down; drain folds; supervisor closes"
  CASE_NAME=sm_paused case_sm_common 'paused: waiting on vendor quote'
}
case_sm_selfresolved() {
  hr "sm_selfresolved (adversarial): secondmate raises and self-resolves a decision while watcher is down"
  CASE_NAME=sm_selfresolved case_sm_common 'needs-decision [key=vendor]: vendor A or B?' \
    'resolved [key=vendor]: picked vendor B myself, cheaper'
}

case_hold_transfer() {
  hr "hold_transfer: investigation with two open decisions; drain folds; captain-hold complete transfers both"
  command -v tasks-axi >/dev/null || { say "  SKIP: tasks-axi missing"; return; }
  new_home hold_transfer
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  local id=sample-review hold_env
  (cd "$HOME_DIR" && tasks-axi add "$id" "Investigate sample" --kind scout --repo sample --start >/dev/null)
  printf 'window=sess:fm-origin\nkind=scout\n' > "$STATE_DIR/$id.meta"
  mkdir -p "$HOME_DIR/data/$id"; printf '# report\n' > "$HOME_DIR/data/$id/report.md"
  worker "$id" 'needs-decision [key=route]: route north or south'
  worker "$id" 'needs-decision [key=access]: open or restricted access'
  drain
  hold() {
    FM_GATE_REFUSE_BYPASS=1 PATH="$HOME_DIR/sendbin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$STATE_DIR" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      "$ROOT/bin/fm-captain-hold.sh" "$@"
  }
  hold hold route-call --title "Choose route and access" --reason "captain choices pending" \
    --repo sample --origin "$id" >/dev/null 2>&1; say "  hold| hold rc=$?"
  hold complete "$id" route-call 2>&1 | sed 's/^/  hold| /'
  showfile "$id"
  watch_start
  watch_verdict 3 || true
}

case_append_fail() {
  hr "append_fail (adversarial): the status file cannot be appended; two-key answer must fail loudly with a usable manual close"
  new_home append_fail; ship_meta t1
  worker t1 'needs-decision [key=budget]: approve spend?'
  worker t1 'needs-decision [key=vendor]: pick a vendor'
  drain >/dev/null
  chmod 444 "$STATE_DIR/t1.status"
  send t1 --resolve-key budget --resolve-key vendor "approve spend, pick acme" 2>"$HOME_DIR/send.err"
  say "  send| rc=$?"; sed 's/^/  send.err| /' "$HOME_DIR/send.err"
  chmod 644 "$STATE_DIR/t1.status"
  local cmd; cmd=$(perl -0ne 'print $1 if /Close it manually with: (.*) - do not resend the answer\./s' "$HOME_DIR/send.err")
  say "  operator runs: $cmd"
  eval "$cmd"
  showfile t1
  drain
}

say "== ROOT=$ROOT ($LABEL) commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo base-archive)"
for c in $CASES; do "case_$c"; watch_stop; done
rm -rf "$WORK"
