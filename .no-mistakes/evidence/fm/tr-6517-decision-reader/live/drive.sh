#!/usr/bin/env bash
# Live driver: runs the real bin/fm-wake-drain.sh over disposable state dirs and
# records transcripts under $EV/live. Each scenario prints RESULT lines.
set -u
ROOT={run-worktree}
EV=~/.no-mistakes/evidence/01M6KGX813GQYW06PXJ3Z4DWC5/live
DRAIN=$ROOT/bin/fm-wake-drain.sh
LIB=$ROOT/bin/fm-wake-lib.sh
T=$(mktemp -d /tmp/fm-live-drain.XXXXXX)
export FM_ROOT_OVERRIDE="$T/tangle-root"; mkdir -p "$FM_ROOT_OVERRIDE"
export FM_WEDGE_ALARM_EXEC
FM_WEDGE_ALARM_EXEC=$(command -v true)
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_HOME
cd "$ROOT" || exit 1
FAILS=0
ok()   { printf 'RESULT ok   %s\n' "$*"; }
bad()  { printf 'RESULT FAIL %s\n' "$*"; FAILS=$((FAILS+1)); }
check(){ if "$@" >/dev/null 2>&1; then return 0; else return 1; fi; }
drain(){ local state=$1; shift; FM_STATE_OVERRIDE="$state" "$DRAIN" "$@"; }
append_wake() { local state=$1 kind=$2 key=$3 payload=$4
  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$LIB" "$kind" "$key" "$payload"; }
ack_args() { sed -n 's/^WAKE_ACK_REQUIRED:.* run bin\/fm-wake-drain.sh //p' "$1" | tail -1; }
sorted_eq() { LC_ALL=C sort "$1" > "$1.sorted"; LC_ALL=C sort "$2" > "$2.sorted"; cmp -s "$1.sorted" "$2.sorted"; }

echo "=== S1 full reader uncapped, non-consuming, survives presentation and acknowledgement ==="
S=$T/s1; mkdir -p "$S/state"; st=$S/state; O=$EV/s1; mkdir -p "$O"
printf 'kind=secondmate\n' > "$st/many.meta"
for i in $(seq 1 96); do
  note="Question $i? $(printf 'Context %.0s' {1..40})END-$i"
  printf 'needs-decision [key=call-%s]: %s\n' "$i" "$note" >> "$st/many.status"
  printf 'many [key=call-%s] needs-decision: %s\n' "$i" "$note" >> "$O/expected.txt"
done
printf 'note: Context that still needs presentation.\n' >> "$st/many.status"
append_wake "$st" check fixture 'Handle this separately.' || bad "s1 queue fixture"
cp "$st/.wake-queue" "$S/queue-before"
drain "$st" --open-decisions > "$O/full-before-drain.out" 2> "$O/full-before-drain.err"; rc=$?
echo "s1 full reader rc=$rc lines=$(wc -l < "$O/full-before-drain.out") bytes=$(wc -c < "$O/full-before-drain.out")"
[ $rc -eq 0 ] && ok "s1 full reader exit 0" || bad "s1 full reader rc=$rc"
[ "$(wc -l < "$O/full-before-drain.out" | tr -d ' ')" = 96 ] && ok "s1 full reader printed 96 rows" || bad "s1 full reader rows != 96"
sorted_eq "$O/expected.txt" "$O/full-before-drain.out" && ok "s1 full reader rows byte-identical to the 96 written decisions (keys + complete notes)" || bad "s1 full reader content differs from expected"
cmp -s "$S/queue-before" "$st/.wake-queue" && ok "s1 full reader left .wake-queue unchanged" || bad "s1 full reader mutated .wake-queue"
[ ! -e "$st/.main-eligible-rows" ] && ok "s1 full reader did not claim rows" || bad "s1 full reader claimed rows"
drain "$st" > "$O/drain.out" 2> "$O/drain.err"; rc=$?
echo "s1 normal drain rc=$rc preview-rows=$(grep -c '^many \[key=' "$O/drain.out") stdout-bytes=$(wc -c < "$O/drain.out")"
grep -E '^OPEN DECISIONS: [0-9]+ more omitted \(byte cap\)\. Read and reconcile the full set: bin/fm-wake-drain.sh --open-decisions$' "$O/drain.out" && ok "s1 omission notice names the full reader" || bad "s1 omission notice missing/unnamed"
grep -F 'many note: Context that still needs presentation.' "$O/drain.out" >/dev/null && ok "s1 unread note still presented after the full reader ran" || bad "s1 unread note was consumed"
grep -E '^WAKE_ACK_REQUIRED: open-decisions=96 \(full reader: bin/fm-wake-drain.sh --open-decisions\)\. .*--ack-through 1 --recovery-generation ' "$O/drain.err" && ok "s1 ack line carries open-decisions=96" || bad "s1 ack line count wrong: $(grep WAKE_ACK "$O/drain.err")"
preview=$(grep -c '^many \[key=' "$O/drain.out"); [ "$preview" -gt 0 ] && [ "$preview" -lt 96 ] && ok "s1 preview still bounded ($preview of 96 rows)" || bad "s1 preview rows=$preview"
drain "$st" --open-decisions > "$O/full-after-drain.out" 2>&1
sorted_eq "$O/expected.txt" "$O/full-after-drain.out" && ok "s1 full reader still returns all 96 after the presentation cursor advanced" || bad "s1 full reader filtered after presentation"
ack=$(ack_args "$O/drain.err"); echo "s1 ack command: $ack"
# shellcheck disable=SC2086
drain "$st" $ack > "$O/ack.out" 2> "$O/ack.err"; rc=$?; echo "s1 ack rc=$rc"
[ $rc -eq 0 ] && ok "s1 acknowledgement accepted" || bad "s1 acknowledgement rc=$rc $(cat "$O/ack.err")"
drain "$st" --open-decisions > "$O/full-after-ack.out" 2>&1
sorted_eq "$O/expected.txt" "$O/full-after-ack.out" && ok "s1 full reader still returns all 96 after acknowledgement (post-compaction recovery read)" || bad "s1 full reader lost rows after ack"
drain "$st" > "$O/drain-2.out" 2> "$O/drain-2.err"
grep -c '^many \[key=' "$O/drain-2.out" | sed 's/^/s1 second drain preview rows: /'

echo "=== S2 empty-queue recovery acknowledgement carries the full count ==="
S=$T/s2; mkdir -p "$S/state"; st=$S/state; O=$EV/s2; mkdir -p "$O"
for i in $(seq 1 96); do printf 'needs-decision [key=call-%s]: Choose option %s.\n' "$i" "$i" >> "$st/many.status"; done
FM_STATE_OVERRIDE="$st" bash -c '. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' _ "$LIB" || bad "s2 publish recovery"
drain "$st" > "$O/drain.out" 2> "$O/drain.err"; rc=$?; echo "s2 drain rc=$rc"
grep -E '^WAKE_ACK_REQUIRED: open-decisions=96 .*--ack-through 0 --recovery-generation ' "$O/drain.err" && ok "s2 empty-queue recovery ack says open-decisions=96" || bad "s2 ack: $(grep WAKE_ACK "$O/drain.err")"
grep -E '^OPEN DECISIONS: [0-9]+ more omitted' "$O/drain.out" | sed 's/^/s2 preview: /'
drain "$st" --open-decisions > "$O/full.out" 2>&1
[ "$(wc -l < "$O/full.out" | tr -d ' ')" = 96 ] && ok "s2 full reader lists 96" || bad "s2 full reader rows"
ack=$(ack_args "$O/drain.err"); echo "s2 ack command: $ack"
# shellcheck disable=SC2086
drain "$st" $ack > "$O/ack.out" 2> "$O/ack.err" && ok "s2 recovery acknowledged" || bad "s2 ack failed: $(cat "$O/ack.err")"
drain "$st" --open-decisions > "$O/full-after-ack.out" 2>&1
[ "$(wc -l < "$O/full-after-ack.out" | tr -d ' ')" = 96 ] && ok "s2 full reader still 96 after ack" || bad "s2 full reader after ack"

echo "=== S3 per-item content truncation names the full reader; full reader keeps the whole note ==="
S=$T/s3; mkdir -p "$S/state"; st=$S/state; O=$EV/s3; mkdir -p "$O"
longnote="Choose between $(printf 'option-%d ' $(seq 1 60))and say why. END-MARKER"
printf 'needs-decision [key=long-call]: %s\n' "$longnote" > "$st/task.status"
drain "$st" > "$O/drain.out" 2> "$O/drain.err"
grep -Fx 'OPEN DECISIONS: content truncated. Read and reconcile the full set: bin/fm-wake-drain.sh --open-decisions' "$O/drain.out" && ok "s3 truncation notice names the full reader" || bad "s3 truncation notice missing"
pl=$(grep '^task \[key=long-call\]' "$O/drain.out"); echo "s3 preview item length=${#pl}"
[ "${#pl}" -le 219 ] && ! grep -F 'END-MARKER' <<<"$pl" >/dev/null && ok "s3 preview item capped (END-MARKER cut)" || bad "s3 preview not capped"
drain "$st" --open-decisions > "$O/full.out" 2>&1
grep -Fx "task [key=long-call] needs-decision: $longnote" "$O/full.out" && ok "s3 full reader returns the complete ${#longnote}-char note" || bad "s3 full reader note incomplete"

echo "=== S4 count distinguishes empty, unreadable, and resolved ==="
S=$T/s4; mkdir -p "$S/state"; st=$S/state; O=$EV/s4; mkdir -p "$O"
append_wake "$st" check fixture 'Handle this separately.'
drain "$st" > "$O/drain-empty.out" 2> "$O/drain-empty.err"
grep -E '^WAKE_ACK_REQUIRED: open-decisions=0 ' "$O/drain-empty.err" && ok "s4 no decisions -> open-decisions=0" || bad "s4 empty: $(grep WAKE_ACK "$O/drain-empty.err")"
printf 'needs-decision [key=route-check]: Choose the route.\n' > "$st/task.status"
printf '#!/usr/bin/env bash\nexit 1\n' > "$S/identity-reader"; chmod +x "$S/identity-reader"
cp "$st/.wake-queue" "$S/queue-before"
FM_STATUS_IDENTITY_READER="$S/identity-reader" drain "$st" > "$O/drain-unreadable.out" 2> "$O/drain-unreadable.err"; rc=$?; echo "s4 unreadable drain rc=$rc"
grep -E '^WAKE_ACK_REQUIRED: open-decisions=unknown ' "$O/drain-unreadable.err" && ok "s4 failed read -> open-decisions=unknown (not 0)" || bad "s4 unreadable: $(grep WAKE_ACK "$O/drain-unreadable.err")"
cmp -s "$S/queue-before" "$st/.wake-queue" && ok "s4 wake preserved across failed presentation" || bad "s4 wake consumed"
! grep -F 'OPEN DECISIONS' "$O/drain-unreadable.out" >/dev/null && ok "s4 failed read printed no misleading open section" || echo "s4 note: open section printed under failing reader"
FM_STATUS_IDENTITY_READER="$S/identity-reader" drain "$st" --open-decisions > "$O/full-unreadable.out" 2> "$O/full-unreadable.err"; rc=$?; echo "s4 unreadable full reader rc=$rc stdout-bytes=$(wc -c < "$O/full-unreadable.out")"
[ $rc -ne 0 ] && [ ! -s "$O/full-unreadable.out" ] && ok "s4 full reader fails loudly (rc=$rc, empty stdout) instead of printing an empty set" || bad "s4 full reader under failing reader rc=$rc"
drain "$st" --open-decisions > "$O/full.out" 2>&1
grep -Fx 'task [key=route-check] needs-decision: Choose the route.' "$O/full.out" && ok "s4 full reader lists route-check once readable" || bad "s4 full reader after recovery"
printf 'resolved [key=route-check]: Take the north route.\n' >> "$st/task.status"
drain "$st" --open-decisions > "$O/full-resolved.out" 2>&1; rc=$?
[ $rc -eq 0 ] && [ ! -s "$O/full-resolved.out" ] && ok "s4 resolved key leaves the full reader empty with exit 0" || bad "s4 resolved rc=$rc out=$(cat "$O/full-resolved.out")"

echo "=== S5 argument grammar and branch actor ==="
S=$T/s5; mkdir -p "$S/state"; st=$S/state; O=$EV/s5; mkdir -p "$O"
printf 'needs-decision [key=k1]: pick one\n' > "$st/t.status"
{ drain "$st" --open-decisions extra; echo "rc=$?"; } > "$O/extra-arg.txt" 2>&1
grep -q 'rc=2' "$O/extra-arg.txt" && grep -q 'takes no arguments' "$O/extra-arg.txt" && ok "s5 --open-decisions rejects extra args (rc=2)" || bad "s5 extra arg: $(cat "$O/extra-arg.txt")"
{ drain "$st" --bogus; echo "rc=$?"; } > "$O/bogus.txt" 2>&1
grep -q 'rc=2' "$O/bogus.txt" && grep -q 'usage: fm-wake-drain.sh \[--open-decisions | --ack-through' "$O/bogus.txt" && ok "s5 usage line names --open-decisions" || bad "s5 usage: $(cat "$O/bogus.txt")"
{ drain "$st" --help; echo "rc=$?"; } > "$O/help.txt" 2>&1
grep -q 'rc=2' "$O/help.txt" && ok "s5 --help is not a separate grammar (usage error rc=2, per recorded decision)" || bad "s5 help: $(cat "$O/help.txt")"
{ FM_SUPERVISION_ACTOR=branch drain "$st"; echo "rc=$?"; } > "$O/branch-plain.txt" 2>&1
grep -q 'rc=1' "$O/branch-plain.txt" && grep -q 'no branch-eligible row snapshot' "$O/branch-plain.txt" && ok "s5 plain branch drain still refuses without eligible rows" || bad "s5 branch plain: $(cat "$O/branch-plain.txt")"
{ FM_SUPERVISION_ACTOR=branch drain "$st" --open-decisions; echo "rc=$?"; } > "$O/branch-full.txt" 2>&1
grep -q 'rc=0' "$O/branch-full.txt" && grep -Fxq 't [key=k1] needs-decision: pick one' "$O/branch-full.txt" && ok "s5 branch actor can read the full set without a row grant" || bad "s5 branch full: $(cat "$O/branch-full.txt")"
[ ! -e "$st/.wake-queue" ] || [ ! -s "$st/.wake-queue" ]; ls -A "$st" > "$O/state-listing-after.txt"

echo "=== S6 full reader and preview share the canonical fold (independent oracle: documented fold rules) ==="
S=$T/s6; mkdir -p "$S/state"; st=$S/state; O=$EV/s6; mkdir -p "$O"
# ship task a: a1 opens then resolved; a2 blocked stays open; later unrelated lines do not touch it
printf 'needs-decision [key=a1]: pick REST or RPC\nworking: still going\nblocked [key=a2]: infra outage\nresolved [key=a1]: went with REST\nworking: more\n' > "$st/a.status"
# scout task b: done: for ship/scout kind clears every open decision
printf 'kind=scout\n' > "$st/b.meta"
printf 'needs-decision [key=b1]: scout question\ndone: report written\n' > "$st/b.status"
# secondmate task c: done: does not clear a secondmate decision
printf 'kind=secondmate\n' > "$st/c.meta"
printf 'needs-decision [key=c1]: mate question\ndone: finished a turn\n' > "$st/c.status"
# task d: captain-held closes d1 (ownership transfer); d2 reopened after resolve; colonless key form on d3
printf 'needs-decision [key=d1]: first call\ncaptain-held [key=d1]: moved to backlog\nneeds-decision [key=d2]: second call\nresolved [key=d2]: answered\nneeds-decision [key=d2]: second call again\nneeds-decision [key=d3] colonless form call\n' > "$st/d.status"
# reserved pending-reply namespace: foreign writer cannot take over or close it
printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it\nresolved [key=pending-reply-abcdef0123456789]: all good now\n' > "$st/e.status"
cat > "$O/expected.txt" <<'EXP'
a [key=a2] blocked: infra outage
c [key=c1] needs-decision: mate question
d [key=d2] needs-decision: second call again
d [key=d3] needs-decision: needs-decision [key=d3] colonless form call
e [key=pending-reply-abcdef0123456789] blocked: pending-reply-missed: task=ios pending-reply-id=abcdef0123456789 request=ship it
EXP
drain "$st" --open-decisions > "$O/full.out" 2> "$O/full.err"; rc=$?; echo "s6 full rc=$rc"
cmp -s "$O/expected.txt" "$O/full.out" && ok "s6 full reader output equals the rule-derived expected set, in file order" || { bad "s6 full reader differs"; diff "$O/expected.txt" "$O/full.out"; }
drain "$st" > "$O/drain.out" 2> "$O/drain.err"
grep '\[key=' "$O/drain.out" | grep -v '^OPEN DECISIONS' | grep -v 'close one by answering' > "$O/preview-rows.txt"
sorted_eq "$O/expected.txt" "$O/preview-rows.txt" && ok "s6 bounded preview lists exactly the same set as the full reader" || { bad "s6 preview differs"; cat "$O/preview-rows.txt"; }
grep -E '^WAKE_ACK_REQUIRED' "$O/drain.err" | sed 's/^/s6 (no recovery, no ack line expected): /'

echo "=== cleanup ==="
for d in "$T"/s*/state; do
  if [ -f "$d/.watch.lock/pid" ]; then p=$(cat "$d/.watch.lock/pid"); echo "killing stray watcher $p"; kill "$p" 2>/dev/null; fi
done
rm -rf "$T"
echo "FAILS=$FAILS"
