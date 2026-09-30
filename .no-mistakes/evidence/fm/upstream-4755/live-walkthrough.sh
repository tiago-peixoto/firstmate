#!/usr/bin/env bash
# Live walkthrough of issue #4755 against a disposable lab FM_HOME.
# Drives the real entrypoints: fm-pending-reply-remind.sh, fm-bearings-snapshot.sh,
# fm-send.sh --resolve-key, fm-wake-drain.sh, and the watcher's fm_pending_reply_tick.
set -u
ROOT=$1
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_PENDING_REPLY_SESSION
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); rmdir "$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
export FM_HOME=$LAB
S=$LAB/state
say() { printf '\n=== %s\n' "$*"; }
rows() { FM_HOME=$LAB "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-"))]'; }
qrows() { local n; n=$(grep -c $'\tcheck\tpending-reply-escalated\t' "$S/.wake-queue" 2>/dev/null); echo "${n:-0}"; }
# A live harness-named process holds the session lock (as a real primary would).
( exec -a "$LAB/agent-bin/claude" bash -c 'trap "kill \$!; exit 0" TERM; sleep 600 & wait' ) </dev/null >/dev/null 2>&1 &
HOLDER=$!
trap 'kill $HOLDER 2>/dev/null; rm -rf "$LAB"' EXIT
printf '%s\n' "$HOLDER" > "$S/.lock"; printf 'session-one\n' > "$S/.lock-session"
# Fake tmux on PATH only so fm-send never touches any real tmux server.
FB=$LAB/fakebin; mkdir -p "$FB"
printf '#!/usr/bin/env bash\ncase "$1" in display-message) for a; do case "$a" in *cursor_y*) echo 1; exit 0;; esac; done; echo fakepane;; capture-pane) printf "x\\n";; esac\nexit 0\n' > "$FB/tmux"; chmod +x "$FB/tmux"
printf 'window=sess:fm-mate\nkind=ship\n' > "$S/mate.meta"

say "Session one: two requests to secondmate 'mate' go unanswered through recovery and escalate"
CORRS=$(bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  export FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_SEND_HOOK=true
  for summary in "ship the report" "answer the api question"; do
    c=$(fm_pending_reply_create "$2" "$2/state" mate "$summary")
    fm_pending_reply_mark_delivered "$2/state" "$c"
    fm_pending_reply_mark_turn_completed "$2/state" "$c" request
    fm_pending_reply_send_recovery "$2/state" "$c" >/dev/null
    fm_pending_reply_mark_turn_completed "$2/state" "$c" recovery
    fm_pending_reply_maybe_escalate "$2/state" "$c"
    echo "$c"
  done' _ "$ROOT" "$LAB")
A=$(echo "$CORRS" | sed -n 1p); B=$(echo "$CORRS" | sed -n 2p)
RA=$S/pending-replies/$A; [ -f "$RA" ] || RA=$(ls -d "$S"/*pending*/"$A")
RB=$(dirname "$RA")/$B
echo "corr A=$A phase=$(grep ^phase= "$RA") $(grep ^surfaced_session= "$RA")"
echo "corr B=$B phase=$(grep ^phase= "$RB") $(grep ^surfaced_session= "$RB")"
echo "parent status log (mate.status):"; sed 's/^/  | /' "$S/mate.status"

say "Session one: Bearings snapshot lists both unresolved escalations in decisions_open"
before=$(cat "$RA")
rows | jq .
[ "$before" = "$(cat "$RA")" ] && echo "record A unchanged by Bearings (read-only): yes" || echo "record A unchanged by Bearings: NO"

say "Session one: reminder runs again (same session token) -> no new wake"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S"; echo "reminder rows in wake queue: $(qrows)"

say "Session two (new session id): reminder enqueues exactly one check wake naming both"
printf 'session-two\n' > "$S/.lock-session"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S"; echo "reminder rows in wake queue: $(qrows)"
grep pending-reply-escalated "$S/.wake-queue" | cut -f2- | sed 's/^/  queue: /'
echo "A $(grep ^surfaced_session= "$RA")"
say "Session two: watcher polls repeatedly -> still one reminder, no extra status lines"
bash -c '. "$1/bin/fm-pending-reply-lib.sh"; for i in 1 2 3; do fm_pending_reply_tick "$2"; done' _ "$ROOT" "$S" 2>/dev/null
echo "reminder rows in wake queue: $(qrows)"; echo "blocked lines for A in mate.status: $(grep -Fc "blocked [key=pending-reply-$A]" "$S/mate.status")"
say "Session two: the primary drains its wake queue (fm-wake-drain.sh)"
DRAIN=$(FM_HOME=$LAB "$ROOT/bin/fm-wake-drain.sh" 2>&1); printf '%s\n' "$DRAIN" | grep -v '^●' | sed 's/^/  drain| /'
ACK=$(printf '%s\n' "$DRAIN" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through .*\)$/\1/p')
# shellcheck disable=SC2086
FM_HOME=$LAB "$ROOT/bin/fm-wake-drain.sh" $ACK >/dev/null 2>&1; echo "acked the drain ($ACK); reminder rows now: $(qrows)"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S"; echo "after drain + re-run in same session, reminder rows: $(qrows)"

say "Operator dismisses escalation A with fm-send --resolve-key pending-reply-$A"
PATH="$FB:$PATH" FM_SEND_SETTLE=0 FM_PENDING_REPLY_GRACE_SECS=0 "$ROOT/bin/fm-send.sh" mate --resolve-key "pending-reply-$A" "ack, handled out of band" >/dev/null 2>&1; echo "fm-send exit=$?"
tail -1 "$S/mate.status" | sed 's/^/  | /'
say "Bearings after dismissal: only B remains"
rows | jq -c '.[] | {key,verb,owner}'

say "Session three: reminder names only B; A gets escalation_dismissed_epoch"
printf 'session-three\n' > "$S/.lock-session"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S"
grep pending-reply-escalated "$S/.wake-queue" | tail -1 | cut -f2- | sed 's/^/  queue: /'
echo "A $(grep ^escalation_dismissed_epoch= "$RA")"

say "Adversarial: another process holds B's record lock while Bearings and the reminder run"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2" && : > "$3"; exec sleep 60' _ "$ROOT" "$S/.pending-reply-$B.lock" "$LAB/held" &
H2=$!; for _ in $(seq 50); do [ -e "$LAB/held" ] && break; sleep 0.1; done
printf 'progress: unrelated line\n' >> "$S/mate.status"   # changes the log signature -> cache miss
beforeB=$(cat "$RB")
start=$(date +%s); rows >/dev/null; echo "Bearings returned in $(( $(date +%s)-start ))s while lock held; record B unchanged: $([ "$beforeB" = "$(cat "$RB")" ] && echo yes || echo NO)"
printf 'session-four\n' > "$S/.lock-session"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S" & RP=$!; sleep 1.5
echo "while lock held, reminder wrote B's scan cache: $([ "$beforeB" = "$(cat "$RB")" ] && echo no || echo YES)"
kill $H2; wait $H2 2>/dev/null; rm -rf "$S/.pending-reply-$B.lock"; wait $RP; echo "reminder exit after lock release=$?"
echo "B $(grep ^escalation_dismiss_scan= "$RB")"

say "Secondmate finally reports with corr=$B; watcher tick resolves it"
printf 'done [corr=%s]: answered the api question\n' "$B" >> "$S/mate.status"
bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_tick "$2"' _ "$ROOT" "$S" 2>/dev/null
echo "B $(grep ^phase= "$RB")"
: > "$S/.wake-queue"; printf 'session-five\n' > "$S/.lock-session"
"$ROOT/bin/fm-pending-reply-remind.sh" "$S"
echo "session five reminder rows: $(qrows)"; echo "Bearings pending-reply rows: $(rows)"
