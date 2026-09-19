#!/usr/bin/env bash
# End-to-end driver for firstmate issue 4767: does the supervisor's own status
# append (an fm-send --resolve-key close, a captain-held transfer) wake that same
# supervisor through the real watcher, and do worker lines still wake it?
#
# Usage: e2e-issue4767.sh <firstmate-checkout> [scenario...]
# Drives the real bin/fm-wake-drain.sh, bin/fm-send.sh, bin/fm-captain-hold.sh
# and bin/fm-watch.sh against a throwaway home. Only tmux (the pane transport)
# and fm-crew-state.sh (the crew verdict) are stubbed.
set -u
ROOT=$(cd "$1" && pwd); shift
SCEN=("$@")
[ "${#SCEN[@]}" -gt 0 ] || SCEN=(single multi livecycle captain_hold folded_failure ship_paused mate_paused mate_self_resolved race_after_drain)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm4767-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export FM_WEDGE_ALARM_EXEC=/usr/bin/true
# Every command below targets the throwaway home only, so use the gate-refusal
# bypass firstmate's own test harness uses (bin/fm-gate-refuse-lib.sh).
export FM_GATE_REFUSE_BYPASS=1

say() { printf '%s\n' "$*"; }
show_status() { say "  --- $1 ---"; sed 's/^/  | /' "$1"; }

new_home() {  # <name> -> sets HOME_DIR STATE SENDBIN WATCHBIN
  HOME_DIR="$WORK/$1"; STATE="$HOME_DIR/state"
  SENDBIN="$HOME_DIR/sendbin"; WATCHBIN="$HOME_DIR/watchbin"
  mkdir -p "$STATE" "$SENDBIN" "$WATCHBIN" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
  # fm-send's pane transport: accept typed text, report an empty composer.
  cat > "$SENDBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0 ;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1 fm-t2 fm-mate fm-scout; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SENDBIN/sleep"
  # Watcher side: no live panes to scan; crew verdict is canned (idle unless set).
  printf '#!/usr/bin/env bash\n[ "${1:-}" = list-windows ] && exit 0\nexit 1\n' > "$WATCHBIN/tmux"
  cat > "$WATCHBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · idle worker}"
SH
  chmod +x "$SENDBIN"/* "$WATCHBIN"/*
}

drain() {  # session-start / post-wake drain as the supervisor runs it
  local err="$HOME_DIR/drain.err" seq gen out
  out=$(FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" 2>"$err")
  if [ "${DRAIN_FULL:-0}" = 1 ]; then
    printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | sed 's/^/  wake-drain> /'
  else
    printf '%s\n' "$out" | sed -n '/OPEN DECISIONS/,/^$/p;/UNREAD STATUS/,/^$/p;/^signal:/p' | sed 's/^/  drain> /'
  fi
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  if [ -n "$seq" ] && [ -n "$gen" ]; then
    FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" \
      --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
    say "  drain> (acked wake queue through $seq)"
  fi
}

send() {  # supervisor answers: fm-send <target> --resolve-key ... <answer>
  local rc=0
  say "  \$ fm-send.sh $*"
  env PATH="$SENDBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$@" >"$HOME_DIR/send.out" 2>"$HOME_DIR/send.err" || rc=$?
  say "  fm-send rc=$rc"
  [ "$rc" -eq 0 ] || sed 's/^/  send-err> /' "$HOME_DIR/send.err"
}

WPID=''
watch_start() {
  : > "$HOME_DIR/watch.out"
  PATH="$WATCHBIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_CREW_STATE_BIN="$WATCHBIN/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >"$HOME_DIR/watch.out" 2>"$HOME_DIR/watch.err" &
  WPID=$!
}
mtime() { stat -f %m "$1" 2>/dev/null; }
# Wait for three watcher poll beats. Echo "quiet" if the watcher stayed alive
# with no output, else "woke: <reason>".
watch_observe() {
  local beat="$STATE/.last-watcher-beat" last='' n=0 i=0 now
  rm -f "$beat"
  while [ "$i" -lt 200 ] && [ "$n" -lt 3 ]; do
    kill -0 "$WPID" 2>/dev/null || break
    now=$(mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$last" ]; then n=$((n + 1)); last=$now; fi
    sleep 0.1; i=$((i + 1))
  done
  if kill -0 "$WPID" 2>/dev/null && [ ! -s "$HOME_DIR/watch.out" ]; then
    say "quiet (watcher alive after $n poll beats, no wake printed)"
  else
    wait "$WPID" 2>/dev/null; WPID=''
    say "woke: $(tr '\n' ' ' < "$HOME_DIR/watch.out")"
  fi
}
watch_until_exit() {
  local i=0
  while [ "$i" -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  if kill -0 "$WPID" 2>/dev/null; then
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=''
    say "quiet (watcher still blocking after 15s, no wake)"
  else
    wait "$WPID" 2>/dev/null; WPID=''
    say "woke: $(tr '\n' ' ' < "$HOME_DIR/watch.out")"
  fi
}
watch_stop() { [ -z "$WPID" ] || { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; WPID=''; }; }

result() {  # <label> <observed> <expected-prefix>
  case "$2" in
    "$3"*) say "  RESULT[$1]: PASS - expected $3, observed: $2" ;;
    *) say "  RESULT[$1]: FAIL - expected $3, observed: $2" ;;
  esac
}

# The supervisor's own close must leave the watcher quiet. If it wakes, show
# what the supervisor would then read from its drain (the wake's annotation).
own_close_check() {  # <label>
  local obs
  obs=$(watch_observe)
  result "$1" "$obs" quiet
  case "$obs" in woke*)
    DRAIN_FULL=1 drain
    watch_start ;;
  esac
}

meta_ship() { printf 'window=sess:fm-%s\nkind=ship\n' "$1" > "$STATE/$1.meta"; }
meta_mate() {
  printf 'window=sess:fm-mate\nendpoint_task_id=mate\nworktree=%s\nproject=%s\nharness=echo\nkind=secondmate\nmode=secondmate\nyolo=off\nhome=%s\nprojects=alpha\n' \
    "$HOME_DIR" "$HOME_DIR" "$HOME_DIR" > "$STATE/mate.meta"
}

# 1. Issue 4767 as reported: the supervisor's session-start drain lists the open
#    decision (no watcher seen marker exists yet), the supervisor answers it,
#    then the watcher is armed. The watcher must not wake on the close; the
#    worker's next line must.
sc_single() {
  say "== single: one --resolve-key close after a session-start OPEN DECISIONS drain"
  new_home single; meta_ship t1
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$STATE/t1.status"
  drain
  send t1 --resolve-key api-shape "go with REST"
  show_status "$STATE/t1.status"
  watch_start
  own_close_check "single/own-close"
  say "  worker appends: blocked: need prod DB credentials to continue"
  printf 'blocked: need prod DB credentials to continue\n' >> "$STATE/t1.status"
  result "single/next-worker-line" "$(watch_until_exit)" "woke: signal: $STATE/t1.status"
  watch_stop
}

# 2. One answer closing two listed decisions (repeatable --resolve-key).
sc_multi() {
  say "== multi: one fm-send closing two keys after an OPEN DECISIONS drain"
  new_home multi; meta_ship t2
  printf 'needs-decision [key=budget]: approve spend?\nneeds-decision [key=vendor]: pick a vendor\n' > "$STATE/t2.status"
  drain
  send t2 --resolve-key budget --resolve-key vendor "approve spend, pick acme"
  show_status "$STATE/t2.status"
  watch_start
  own_close_check "multi/own-closes"
  say "  worker appends: failed: vendor API rejected the order"
  printf 'failed: vendor API rejected the order\n' >> "$STATE/t2.status"
  result "multi/next-worker-line" "$(watch_until_exit)" "woke: signal: $STATE/t2.status"
  watch_stop
}

# 3. The ordinary live cycle: the watcher surfaces the worker's decision, the
#    supervisor drains and answers, the watcher is re-armed.
sc_livecycle() {
  say "== livecycle: watcher surfaces the decision, supervisor answers, watcher re-armed"
  new_home livecycle; meta_ship t1
  printf 'working: scaffolding the service\n' > "$STATE/t1.status"
  FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATE/t1.status"
  watch_start
  sleep 1.5
  say "  worker appends: needs-decision [key=db]: postgres or sqlite?"
  printf 'needs-decision [key=db]: postgres or sqlite?\n' >> "$STATE/t1.status"
  result "livecycle/worker-decision" "$(watch_until_exit)" "woke: signal: $STATE/t1.status"
  drain
  send t1 --resolve-key db "postgres"
  show_status "$STATE/t1.status"
  watch_start
  own_close_check "livecycle/own-close"
  say "  worker appends: blocked: postgres container will not start"
  printf 'blocked: postgres container will not start\n' >> "$STATE/t1.status"
  result "livecycle/next-worker-line" "$(watch_until_exit)" "woke: signal: $STATE/t1.status"
  watch_stop
}

# Shared shape for the adversarial cases: the watcher surfaces a decision and
# exits; while it is down the worker appends <lagging> lines; the supervisor's
# drain folds through them; the supervisor answers the decision. The worker's
# lagging lines were never listed, so the watcher must still wake.
lagging_case() {  # <name> <id> <target> <lagging-text>
  local name=$1 id=$2 target=$3 lagging=$4
  printf 'needs-decision [key=budget]: approve spend?\n' > "$STATE/$id.status"
  watch_start
  result "$name/worker-decision" "$(watch_until_exit)" "woke: signal: $STATE/$id.status"
  drain
  say "  while the watcher is down the worker appends:"; printf '%s\n' "$lagging" | sed 's/^/    + /'
  printf '%s\n' "$lagging" >> "$STATE/$id.status"
  drain
  send "$target" --resolve-key budget "approved"
  show_status "$STATE/$id.status"
  watch_start
  result "$name/unlisted-worker-lines-still-wake" "$(watch_until_exit)" "woke: signal: $STATE/$id.status"
  watch_stop
}

# A ship/scout failed: closes every open decision (bin/fm-classify-lib.sh), so
# fm-send would refuse the key there; a secondmate's failed: does not.
sc_folded_failure() {
  say "== folded_failure: a secondmate failed: line inside the folded span"
  new_home folded_failure; meta_mate
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  lagging_case folded_failure mate fm-mate $'failed: crew c3 hit an unrecoverable migration error\nworking: retrying c3 in a fresh worktree'
  unset FM_FAKE_CREW_STATE
}

sc_ship_paused() {
  say "== ship_paused: a ship worker's paused: line inside the folded span"
  new_home ship_paused; meta_ship t1
  lagging_case ship_paused t1 t1 'paused: waiting on upstream API quota reset'
}

# The worker writes between the supervisor's drain and its close: those bytes
# were never read by anyone, so the close must not cover them.
sc_race_after_drain() {
  say "== race_after_drain: a worker line lands after the drain but before the close"
  new_home race_after_drain; meta_ship t1
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$STATE/t1.status"
  drain
  say "  worker appends (after the drain, before the answer): paused: waiting on design review"
  printf 'paused: waiting on design review\n' >> "$STATE/t1.status"
  send t1 --resolve-key api-shape "go with REST"
  show_status "$STATE/t1.status"
  watch_start
  result "race_after_drain/unread-worker-line-still-wakes" "$(watch_until_exit)" "woke: signal: $STATE/t1.status"
  watch_stop
}

sc_mate_paused() {
  say "== mate_paused: a secondmate paused: line inside the folded span"
  new_home mate_paused; meta_mate
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  lagging_case mate_paused mate fm-mate 'paused: waiting on vendor quote'
  unset FM_FAKE_CREW_STATE
}

sc_mate_self_resolved() {
  say "== mate_self_resolved: the secondmate raised and closed its own decision inside the folded span"
  new_home mate_self_resolved; meta_mate
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  lagging_case mate_self_resolved mate fm-mate $'needs-decision [key=vendor]: vendor A or B?\nresolved [key=vendor]: picked vendor B myself, cheaper'
  unset FM_FAKE_CREW_STATE
}

# 7. Captain-hold completion transfers two still-open decisions to the
#    captain-held inventory in one command after a session-start drain.
sc_captain_hold() {
  local id=scout rc=0
  say "== captain_hold: fm-captain-hold.sh complete transfers two open keys after an OPEN DECISIONS drain"
  command -v tasks-axi >/dev/null || { say "  RESULT[captain_hold]: SKIP - tasks-axi missing"; return; }
  new_home captain_hold
  cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SENDBIN/treehouse"; chmod +x "$SENDBIN/treehouse"
  (cd "$HOME_DIR" && tasks-axi add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null)
  mkdir -p "$HOME_DIR/data/$id"
  printf 'endpoint_task_id=%s\nworktree=%s/projects/missing\nproject=%s/projects/sample\nharness=codex\nkind=scout\nmode=scout\nspawn_gen=fixture\n' \
    "$id" "$HOME_DIR" "$HOME_DIR" > "$STATE/$id.meta"
  printf 'needs-decision [key=route]: north or south?\nneeds-decision [key=access]: open or restricted?\n' > "$STATE/$id.status"
  cap() { PATH="$SENDBIN:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"; }
  cap hold sample-route-call --title "Choose route and access" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null 2>"$HOME_DIR/hold.err" || { say "  hold failed: $(cat "$HOME_DIR/hold.err")"; return; }
  drain
  say "  \$ fm-captain-hold.sh complete $id sample-route-call"
  cap complete "$id" sample-route-call 2>"$HOME_DIR/complete.err" | sed 's/^/  /' ; rc=${PIPESTATUS[0]}
  say "  complete rc=$rc"; [ "$rc" -eq 0 ] || sed 's/^/  err> /' "$HOME_DIR/complete.err"
  show_status "$STATE/$id.status"
  watch_start
  own_close_check "captain_hold/own-transfers"
  say "  worker appends: blocked: sample repo access revoked"
  printf 'blocked: sample repo access revoked\n' >> "$STATE/$id.status"
  result "captain_hold/next-worker-line" "$(watch_until_exit)" "woke: signal: $STATE/$id.status"
  watch_stop
}

say "firstmate checkout: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo archive))"
for s in "${SCEN[@]}"; do "sc_$s"; say; done
