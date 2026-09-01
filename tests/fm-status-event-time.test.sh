#!/usr/bin/env bash
# tests/fm-status-event-time.test.sh - the "[at=...]" event-time tag on status
# lines (bin/fm-classify-lib.sh).
#
# A status log is an append-only event log, and any latency read off it needs
# the instant each event HAPPENED. The appender stamps its own line, so the
# tag has to be invisible to everything that already reads these lines, and
# every existing log stays unstamped forever - nothing is backfilled. The
# mixed file is therefore the real case, not the edge case: a live log gains
# stamped lines below its unstamped history.
#
# These tests drive the REAL parsers, folds and reader executables over crafted
# status files and assert their behavior, never the library's own source text:
#   1. The stamp round-trips: written, read back, and converted to an epoch
#      that the platform's own date agrees with.
#   2. A malformed or misplaced stamp reads as NO time, never as a wrong one.
#   3. Stamping is idempotent, and refuses rather than damaging a line whose
#      shape it cannot stamp.
#   4. Every reader gives the SAME answer for the unstamped, stamped and mixed
#      forms of one identical event sequence - the fold, the captain-relevant
#      and pause classifiers, the unread surface, the open-activities fold, the
#      fleet scan, and the wake drain and crew-state executables.
#   5. A two-event latency computes from a stamped pair, and a pair with one
#      unstamped endpoint reports WHICH endpoint has no time instead of
#      inventing one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-event-time)

case_dir() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  printf '%s' "$d"
}

# One event sequence, written three ways. The events - their verbs, keys and
# notes - are byte-identical across the three files; only the presence of the
# time tag differs, so any reader that disagrees between them is reading the
# tag when it should not.
#
# The sequence is a real supervision shape: a keyed decision opens, unrelated
# work continues, the decision is answered and closed, a declared wait starts,
# and an informational note lands.
EVENTS_UNSTAMPED=(
  'needs-decision [key=api-shape]: pick REST or RPC'
  'working: kept busy on an unrelated stream'
  'resolved [key=api-shape]: answered: go with REST'
  'paused: awaiting the vendor rate-limit reset'
  'note [key=pending-reply-abcdef0123456789]: report mirrored'
)
STAMPS=(
  20260829T120000Z
  20260829T121500Z
  20260829T133000Z
  20260829T140000Z
  20260829T141000Z
)

write_variants() {  # <dir> -> writes unstamped.status stamped.status mixed.status
  local dir=$1 i line
  : > "$dir/unstamped.status"
  : > "$dir/stamped.status"
  : > "$dir/mixed.status"
  i=0
  while [ "$i" -lt "${#EVENTS_UNSTAMPED[@]}" ]; do
    line=${EVENTS_UNSTAMPED[$i]}
    printf '%s\n' "$line" >> "$dir/unstamped.status"
    printf '%s\n' "$(status_stamp_line "$line" "${STAMPS[$i]}")" >> "$dir/stamped.status"
    # The mixed file is a log that predates stamping and then gains it: the
    # first two events carry no time, the rest do.
    if [ "$i" -lt 2 ]; then
      printf '%s\n' "$line" >> "$dir/mixed.status"
    else
      printf '%s\n' "$(status_stamp_line "$line" "${STAMPS[$i]}")" >> "$dir/mixed.status"
    fi
    i=$((i + 1))
  done
}

test_stamp_round_trips_through_the_grammar() {
  local line at epoch
  line=$(status_stamp_line 'working: pushed 39594f22a4' 20260829T134516Z)
  [ "$line" = 'working [at=20260829T134516Z]: pushed 39594f22a4' ] \
    || fail "the stamp landed somewhere unexpected: $line"

  at=$(status_line_at "$line") || fail "a stamped line reported no event time"
  [ "$at" = 20260829T134516Z ] || fail "read back the wrong stamp: $at"

  [ "$(status_line_verb "$line")" = working ] \
    || fail "the stamp broke the leading verb: $(status_line_verb "$line")"
  [ "$(status_line_note "$line")" = 'pushed 39594f22a4' ] \
    || fail "the stamp leaked into the note: $(status_line_note "$line")"

  line=$(status_stamp_line 'resolved [key=api-shape]: answered: use REST' 20260829T134516Z)
  [ "$(_fm_decision_key "$line")" = api-shape ] \
    || fail "the stamp displaced the stated key: $(_fm_decision_key "$line")"
  [ "$(status_line_note "$line")" = 'answered: use REST' ] \
    || fail "the stamp displaced the note of a keyed line: $(status_line_note "$line")"

  # The colon-first key position keeps working: the tag goes before the colon,
  # so a note-head key is still exactly where the fold looks for it.
  line=$(status_stamp_line 'working: [key=api-shape] still on it' 20260829T134516Z)
  [ "$(_fm_decision_key "$line")" = api-shape ] \
    || fail "the stamp broke the colon-first key: $line"
  [ "$(status_line_note "$line")" = 'still on it' ] \
    || fail "the stamp broke the colon-first note: $(status_line_note "$line")"

  epoch=$(status_line_at_epoch "$line") || fail "a stamped line reported no epoch"
  case "$epoch" in ''|*[!0-9]*) fail "the epoch is not a number: $epoch" ;; esac

  pass "the event-time tag round-trips and displaces neither the verb, the key, nor the note"
}

test_epoch_conversion_matches_the_platform_clock() {
  local stamp want got checked=0
  # Cross-check the library's pure integer conversion against whatever this
  # platform's own date can parse, so the arithmetic cannot drift on either
  # BSD or GNU userland. The instants span a leap year, a month boundary, and
  # the epoch itself.
  for stamp in 19700101T000000Z 20000229T123456Z 20260101T000000Z \
               20260228T235959Z 20260829T134516Z 20991231T235959Z; do
    got=$(status_stamp_to_epoch "$stamp") \
      || fail "the library refused a well-formed stamp: $stamp"
    want=$(date -u -j -f '%Y%m%dT%H%M%SZ' "$stamp" +%s 2>/dev/null \
      || date -u -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2}T${stamp:9:2}:${stamp:11:2}:${stamp:13:2}Z" +%s 2>/dev/null) \
      || continue
    [ "$got" = "$want" ] \
      || fail "epoch mismatch for $stamp: library said $got, date said $want"
    checked=$((checked + 1))
  done
  [ "$checked" -ge 4 ] \
    || fail "the platform date parsed too few instants to prove the conversion ($checked)"
  pass "the pure-arithmetic epoch conversion agrees with the platform clock"
}

test_a_bad_or_misplaced_stamp_reads_as_no_time() {
  local line
  # A malformed stamp is rejected rather than repaired: the line then carries
  # no time, which is a missing measurement instead of a wrong one.
  for line in \
    'working [at=]: x' \
    'working [at=2026-08-29T13:45:16Z]: x' \
    'working [at=20260829T134516]: x' \
    'working [at=20261329T134516Z]: x' \
    'working [at=20260832T134516Z]: x' \
    'working [at=20260829T254516Z]: x' \
    'working [at=20260829T136016Z]: x' \
    'working [at=20260829T134560Z]: x' \
    'working [at=notatime]: x'; do
    if status_line_at "$line" >/dev/null 2>&1; then
      fail "a malformed stamp was accepted as an event time: $line"
    fi
    [ "$(status_line_verb "$line")" = working ] \
      || fail "a malformed stamp broke the verb: $line"
  done

  # A tag after the colon is note prose, not a stated time: the same rule the
  # fold applies to a key mentioned deeper inside a note.
  line='working: rolled back [at=20260829T134516Z] as prose'
  if status_line_at "$line" >/dev/null 2>&1; then
    fail "an after-the-colon tag was read as this line's event time: $line"
  fi

  pass "a malformed or misplaced stamp reads as no time, never as a wrong one"
}

test_stamping_is_idempotent_and_refuses_what_it_cannot_stamp() {
  local first second bare rc
  first=$(status_stamp_line 'done: PR up' 20260829T120000Z)
  second=$(status_stamp_line "$first" 20260829T180000Z)
  [ "$second" = "$first" ] \
    || fail "re-stamping overwrote the time first recorded: $second"

  # A legacy colon-free line has no verb/note boundary to insert a tag before,
  # so stamping refuses and hands the line back untouched rather than pushing
  # metadata into what readers treat as the note.
  bare='merged'
  rc=0
  second=$(status_stamp_line "$bare" 20260829T120000Z) || rc=$?
  [ "$rc" = 1 ] || fail "stamping a colon-free line should report that it could not stamp"
  [ "$second" = "$bare" ] || fail "a line that cannot be stamped was modified: $second"

  # An unusable clock is the same case: the event is still appendable.
  rc=0
  second=$(FM_CLASSIFY_NOW=nonsense status_stamp_line 'working: x') || rc=$?
  [ "$rc" = 1 ] || fail "an invalid clock should report that it could not stamp"
  [ "$second" = 'working: x' ] || fail "an invalid clock damaged the line: $second"

  pass "stamping is idempotent and refuses rather than damaging a line it cannot stamp"
}

# --- the mixed-log bar ------------------------------------------------------

# Compare one reader's verdict across the three variants of the same events.
assert_same_across_variants() {  # <dir> <label> <fn>
  local dir=$1 label=$2 fn=$3 u s m
  u=$("$fn" "$dir/unstamped.status")
  s=$("$fn" "$dir/stamped.status")
  m=$("$fn" "$dir/mixed.status")
  [ "$u" = "$s" ] \
    || fail "$label differs once lines carry a time: unstamped '$u' vs stamped '$s'"
  [ "$u" = "$m" ] \
    || fail "$label differs on a mixed log: unstamped '$u' vs mixed '$m'"
}

read_fold() { status_open_decisions "$1"; }
read_fold_incremental() { status_open_decisions_incremental "$1"; }
read_closing_verb() { status_key_closing_verb "$1" api-shape; }
read_activities() { status_open_activities "$1"; }
read_last_verb() { status_line_verb "$(last_status_line "$1")"; }
read_last_note() { status_line_note "$(last_status_line "$1")"; }
read_last_key() { _fm_decision_key "$(last_status_line "$1")" || printf 'REJECTED'; }
read_captain_relevant() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if status_is_captain_relevant "$line"; then printf 'y'; else printf 'n'; fi
  done < "$1"
}
read_pause_class() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if status_is_paused "$line"; then printf 'P'
    elif status_is_captain_held "$line"; then printf 'H'
    elif status_is_terminal_verb "$line"; then printf 'T'
    else printf '.'; fi
  done < "$1"
}
read_unread_surface() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if status_line_is_unread_surface "$line"; then printf 'u'; else printf '.'; fi
  done < "$1"
}
read_events_without_time() {
  # The parsed event stream with the time columns dropped: what every reader
  # above ultimately consumes.
  status_timed_events "$1" | cut -f3-
}

test_every_reader_agrees_across_unstamped_stamped_and_mixed() {
  local dir
  dir=$(case_dir readers)
  write_variants "$dir"

  # Sanity: the three files really do differ, so an all-passing comparison
  # cannot be vacuous.
  cmp -s "$dir/unstamped.status" "$dir/stamped.status" \
    && fail "the stamped variant is byte-identical to the unstamped one"
  cmp -s "$dir/unstamped.status" "$dir/mixed.status" \
    && fail "the mixed variant is byte-identical to the unstamped one"
  cmp -s "$dir/stamped.status" "$dir/mixed.status" \
    && fail "the mixed variant is byte-identical to the stamped one"
  grep -q '\[at=' "$dir/mixed.status" || fail "the mixed variant carries no stamped line"
  grep -qv '\[at=' "$dir/mixed.status" || fail "the mixed variant carries no unstamped line"

  assert_same_across_variants "$dir" "the open-decisions fold" read_fold
  assert_same_across_variants "$dir" "the incremental fold" read_fold_incremental
  assert_same_across_variants "$dir" "the key's closing verb" read_closing_verb
  assert_same_across_variants "$dir" "the open-activities fold" read_activities
  assert_same_across_variants "$dir" "the last line's verb" read_last_verb
  assert_same_across_variants "$dir" "the last line's note" read_last_note
  assert_same_across_variants "$dir" "the last line's key" read_last_key
  assert_same_across_variants "$dir" "the captain-relevant classification" read_captain_relevant
  assert_same_across_variants "$dir" "the pause/hold/terminal classification" read_pause_class
  assert_same_across_variants "$dir" "the unread-surface classification" read_unread_surface
  assert_same_across_variants "$dir" "the parsed event stream" read_events_without_time

  # The comparisons above would also pass if every reader returned nothing, so
  # pin the substance once: this sequence answers its keyed decision and then
  # declares a wait.
  [ -z "$(read_fold "$dir/mixed.status")" ] \
    || fail "the answered decision should be closed: $(read_fold "$dir/mixed.status")"
  [ "$(read_closing_verb "$dir/mixed.status")" = resolved ] \
    || fail "the key should read as closed by a resolution: $(read_closing_verb "$dir/mixed.status")"
  [ "$(read_pause_class "$dir/mixed.status")" = 'T..P.' ] \
    || fail "unexpected classification of the sequence: $(read_pause_class "$dir/mixed.status")"
  # Only the informational note surfaces here: a `resolved` line surfaces just
  # under a reserved key prefix, and api-shape is an ordinary decision key.
  [ "$(read_unread_surface "$dir/mixed.status")" = '....u' ] \
    || fail "unexpected unread surface: $(read_unread_surface "$dir/mixed.status")"

  pass "every status reader gives the same answer for unstamped, stamped and mixed logs"
}

test_fleet_scan_and_reader_executables_read_a_mixed_log() {
  local dir home out task_row bare stamped status_file task rc
  dir=$(case_dir executables)
  write_variants "$dir"

  # The fleet scan finds a still-open decision whichever way its line is
  # written. A log whose open decision is unstamped and one whose open
  # decision is stamped must both surface.
  home="$dir/home"
  mkdir -p "$home/state"
  printf '%s\n' "${EVENTS_UNSTAMPED[0]}" > "$home/state/old.status"
  printf '%s\n' "$(status_stamp_line "${EVENTS_UNSTAMPED[0]}" "${STAMPS[0]}")" \
    > "$home/state/new.status"
  # A third task mixes both inside one file: an unstamped open decision under
  # one key, a stamped open decision under another.
  printf '%s\n' 'blocked [key=creds]: need the deploy token' > "$home/state/both.status"
  printf '%s\n' "$(status_stamp_line 'needs-decision [key=rollout]: staged or all at once' \
    20260829T150000Z)" >> "$home/state/both.status"

  out=$(scan_open_decisions "$home/state")
  for task_row in 'old	api-shape' 'new	api-shape' 'both	creds' 'both	rollout'; do
    printf '%s' "$out" | grep -F "$task_row" >/dev/null \
      || fail "the fleet scan lost an open decision ($task_row): $out"
  done

  out=''
  for status_file in "$home/state"/*.status; do
    status_span_first_actionable_record "$status_file" 0 >/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || continue
    task=${status_file##*/}; task=${task%.status}
    out="${out}${task}"$'\n'
  done
  out=$(printf '%s' "$out" | sort | tr '\n' ' ')
  [ "$out" = 'both new old ' ] \
    || fail "the captain-relevant span scan disagreed on a mixed fleet: $out"

  # The wake drain is the reader an agent actually sees. It must present every
  # open decision from the same mixed fleet.
  out=$(FM_STATE_OVERRIDE="$home/state" "$DRAIN" 2>/dev/null)
  for task_row in api-shape creds rollout; do
    printf '%s' "$out" | grep -F "[key=$task_row]" >/dev/null \
      || fail "the wake drain did not present the open decision $task_row: $out"
  done

  # fm-crew-state.sh reads the same log for its current-state verdict, and it
  # must read a stamped pause exactly as it reads an unstamped one: same state,
  # same reason, with the tag left out of the verdict it prints. Routed through
  # the remote-secondmate arm over a stubbed transport, because that is the path
  # whose verdict comes from the status log itself.
  mkdir -p "$home/data" "$home/fakebin"
  fm_write_meta "$home/state/rsm.meta" \
    "window=remote:rsm" "endpoint_task_id=rsm" \
    "worktree=/remote/home/never-locally-present" \
    "harness=claude" "kind=secondmate" "mode=secondmate" \
    "remote_host=remote-mac" "remote_root=/remote/root" \
    "remote_backend=herdr" "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
  cat > "$home/data/secondmates.md" <<'REG'
- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)
REG
  cat > "$home/fakebin/fake-ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf 'alive\n'
SH
  chmod +x "$home/fakebin/fake-ssh"

  printf '%s\n' 'paused: awaiting the vendor rate-limit reset' > "$home/state/rsm.status"
  bare=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$home/fakebin/fake-ssh" "$CREW_STATE" rsm 2>/dev/null || true)
  printf '%s\n' "$(status_stamp_line 'paused: awaiting the vendor rate-limit reset' \
    20260829T140000Z)" > "$home/state/rsm.status"
  stamped=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SSH_BIN="$home/fakebin/fake-ssh" "$CREW_STATE" rsm 2>/dev/null || true)
  assert_contains "$bare" 'awaiting the vendor rate-limit reset' \
    "precondition: the crew-state verdict should come from the status log"
  [ "$stamped" = "$bare" ] \
    || fail "the crew-state verdict changed once the pause carried a time: '$bare' vs '$stamped'"
  case "$stamped" in
    *'[at='*) fail "the crew-state reader leaked the raw event tag into its verdict: $stamped" ;;
  esac

  pass "the fleet scans, the wake drain and the crew-state reader all read a mixed fleet"
}

# --- what the times are for -------------------------------------------------

# Seconds between the first event matching <from-verb>/<from-key> and the next
# one matching <to-verb>/<to-key>. Prints the latency, or "no-time:<which>"
# naming the endpoint that carries no event time.
latency_between() {  # <status-file> <from-verb> <from-key> <to-verb> <to-key>
  local f=$1 fv=$2 fk=$3 tv=$4 tk=$5 epoch stamp verb key note from=''
  while IFS=$'\t' read -r epoch stamp verb key note; do
    if [ -z "$from" ] && [ "$verb" = "$fv" ] && [ "$key" = "$fk" ]; then
      [ "$epoch" != - ] || { printf 'no-time:from'; return 0; }
      from=$epoch
      continue
    fi
    if [ -n "$from" ] && [ "$verb" = "$tv" ] && [ "$key" = "$tk" ]; then
      [ "$epoch" != - ] || { printf 'no-time:to'; return 0; }
      printf '%s' $((epoch - from))
      return 0
    fi
  done <<EOF
$(status_timed_events "$f")
EOF
  printf 'no-pair'
}

test_a_latency_computes_and_names_a_missing_endpoint() {
  local dir got
  dir=$(case_dir latency)
  write_variants "$dir"

  # Registered-to-answered for the keyed decision: 12:00:00Z to 13:30:00Z.
  got=$(latency_between "$dir/stamped.status" needs-decision api-shape resolved api-shape)
  [ "$got" = 5400 ] \
    || fail "the decision latency did not compute from a stamped log: $got"

  # The same pair on the mixed log: the decision was registered before
  # stamping existed, so the measurement is refused with the endpoint named
  # rather than guessed from the answer's time alone.
  got=$(latency_between "$dir/mixed.status" needs-decision api-shape resolved api-shape)
  [ "$got" = 'no-time:from' ] \
    || fail "a half-timed pair should name its missing endpoint, got: $got"

  # And the whole-log view says exactly how much of the history can be
  # measured, so a gap is visible instead of silent.
  got=$(status_timed_events "$dir/mixed.status" | cut -f1 | grep -c '^[0-9]')
  [ "$got" = 3 ] || fail "expected 3 timed events in the mixed log, counted $got"
  got=$(status_timed_events "$dir/mixed.status" | cut -f1 | grep -c '^-$')
  [ "$got" = 2 ] || fail "expected 2 untimed events in the mixed log, counted $got"

  # The absence marker is what makes the row readable field-by-field: an empty
  # leading field would be folded away by IFS-tab reading and shift the verb
  # into the epoch column.
  got=$(latency_between "$dir/unstamped.status" needs-decision api-shape resolved api-shape)
  [ "$got" = 'no-time:from' ] \
    || fail "an entirely untimed log should still parse into readable rows, got: $got"

  pass "a latency computes from timed events and names the endpoint that has none"
}

test_stamp_round_trips_through_the_grammar
test_epoch_conversion_matches_the_platform_clock
test_a_bad_or_misplaced_stamp_reads_as_no_time
test_stamping_is_idempotent_and_refuses_what_it_cannot_stamp
test_every_reader_agrees_across_unstamped_stamped_and_mixed
test_fleet_scan_and_reader_executables_read_a_mixed_log
test_a_latency_computes_and_names_a_missing_endpoint
