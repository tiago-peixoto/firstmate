#!/usr/bin/env bash
# Live driver for issue #8048: raw-epoch status lines are reported with file:line
# while earlier open decisions stay open and legacy lines stay readable.
# Runs the REAL bin/fm-classify-lib.sh fold and the REAL bin/fm-captain-hold.sh
# CLI against a disposable home. Usage: drive-raw-epoch-scenarios.sh <repo-root>
set -u
ROOT_ARG=$1
cd "$ROOT_ARG" || exit 2
# shellcheck source=tests/lib.sh
. "$ROOT_ARG/tests/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT_ARG/bin/fm-classify-lib.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-8048-live.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
FAILS=0
check() {  # <label> <condition-exit>
  if [ "$2" -eq 0 ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILS=$((FAILS + 1)); fi
}
show() { printf '%s\n' "--- $1 ---"; printf '%s\n' "$2"; printf '%s\n' "--- end $1 ---"; }

echo "=================== Scenario A: issue #8048 reproduction, exact script ==================="
cd "$WORK"
printf '%s\n' '1793378273 blocked [key=example] An implementation decision needs an answer.' > malformed.status
echo "\$ status_line_verb \"\$(<malformed.status)\""
status_line_verb "$(<malformed.status)"; echo
echo "\$ status_open_decisions malformed.status ship   (stdout -> A.out, stderr -> A.err)"
status_open_decisions malformed.status ship > A.out 2> A.err
show "A.out (open set, stdout)" "$(cat A.out)"
show "A.err (report, stderr)" "$(cat A.err)"
[ -z "$(cat A.out)" ]; check "A1 raw-epoch line folds as nothing on stdout (no fake open key)" $?
[ "$(cat A.err)" = 'malformed.status:1: malformed status line; repair the timestamp to [at=<epoch>] after the verb: 1793378273 blocked [key=example] An implementation decision needs an answer.' ]
check "A2 stderr names file:line and the repair (move epoch to [at=<epoch>] after the verb)" $?
cd "$ROOT_ARG"

echo
echo "=================== Scenario B: earlier open blocker survives a later raw-epoch line ==================="
f="$WORK/later.status"
printf '%s\n' \
  'blocked [at=1793378273] [key=example]: An earlier blocker remains open.' \
  '1793378273 blocked [key=broken] A malformed later event.' > "$f"
full=$(status_open_decisions "$f" 2> "$WORK/B.err"); incr=$(status_open_decisions_incremental "$f" 2>/dev/null)
show "B stdout (full fold)" "$full"; show "B stderr" "$(cat "$WORK/B.err")"
[ "$full" = "$(printf 'example\tblocked\tAn earlier blocker remains open.')" ]; check "B1 earlier canonical blocker stays open" $?
[ "$incr" = "$full" ]; check "B2 incremental fold agrees with the full fold on the open set" $?
[ "$(cat "$WORK/B.err")" = "$f:2: malformed status line; repair the timestamp to [at=<epoch>] after the verb: 1793378273 blocked [key=broken] A malformed later event." ]
check "B3 line 2 reported with its real line number" $?

echo
echo "=================== Scenario C: valid legacy lines stay readable, no false reports ==================="
f="$WORK/legacy.status"
printf '%s\n' \
  'working: started' \
  'blocked: legacy keyless blocker with no tags' \
  'needs-decision [key=route]: choose route north or south' \
  'needs-decision: [key=access] colon-first stated key' \
  'Reason: 2026 is the year; 10:30 standup; see https://example.test/1793378273' \
  '2026 release notes: nothing malformed here.' \
  '1793378273 parked [key=x] unknown verb after an epoch is not the raw-epoch class' \
  '1793378273' \
  '1793378273blocked [key=glued] no separator' \
  'resolved [key=route]: north' > "$f"
full=$(status_open_decisions "$f" 2> "$WORK/C.err"); incr=$(status_open_decisions_incremental "$f" 2>/dev/null)
show "C stdout" "$full"; show "C stderr" "$(cat "$WORK/C.err")"
expected=$(printf 'default\tblocked\tlegacy keyless blocker with no tags\naccess\tneeds-decision\tcolon-first stated key')
[ "$full" = "$expected" ]; check "C1 legacy keyless blocker and both key positions fold; resolved closes route" $?
[ "$incr" = "$full" ]; check "C2 incremental fold agrees" $?
[ ! -s "$WORK/C.err" ]; check "C3 no report for prose, numbers, clock times, unknown verbs, or glued tokens" $?

echo
echo "=================== Scenario D: adversarial shapes, verb overrides, channel separation ==================="
f="$WORK/shapes.status"
printf '%s\n' \
  '1793378273 blocked: [key=colon] colon-first raw epoch BEFORE any valid line' \
  '   1793378273 needs-decision [key=indent] indented raw epoch' \
  '1793378273 captain-held [key=held] raw epoch transfer verb' \
  '1793378273 answered [key=ans] raw epoch with overridden resolve verb' \
  '1793378273 napping [key=nap] raw epoch with overridden paused verb' \
  '1793378273 resolved [key=notverb] default resolve verb is NOT recognized while overridden' \
  '00001793378273 done [key=zeros]: leading zeros still digits' \
  'needs-decision [key=valid]: a valid line AFTER the malformed ones still opens' > "$f"
FM_CLASSIFY_RESOLVE_VERB=answered FM_CLASSIFY_PAUSED_VERB=napping status_open_decisions "$f" > "$WORK/D.out" 2> "$WORK/D.err"
show "D stdout" "$(cat "$WORK/D.out")"; show "D stderr" "$(cat "$WORK/D.err")"
[ "$(cat "$WORK/D.out")" = "$(printf 'valid\tneeds-decision\ta valid line AFTER the malformed ones still opens')" ]
check "D1 stdout carries only the open-set TSV; the later valid decision opens" $?
rep='malformed status line; repair the timestamp to [at=<epoch>] after the verb'
expected="$f:1: $rep: 1793378273 blocked: [key=colon] colon-first raw epoch BEFORE any valid line
$f:2: $rep:    1793378273 needs-decision [key=indent] indented raw epoch
$f:3: $rep: 1793378273 captain-held [key=held] raw epoch transfer verb
$f:4: $rep: 1793378273 answered [key=ans] raw epoch with overridden resolve verb
$f:5: $rep: 1793378273 napping [key=nap] raw epoch with overridden paused verb
$f:7: $rep: 00001793378273 done [key=zeros]: leading zeros still digits"
[ "$(cat "$WORK/D.err")" = "$expected" ]
check "D2 colon-first, indented, captain-held, overridden resolve/paused verbs reported; non-overridden 'resolved' (line 6) not reported" $?
case "$(cat "$WORK/D.out")" in *"malformed status line"*) r=1 ;; *) r=0 ;; esac
check "D3 report never leaks into stdout consumed by callers" $r

echo
echo "=================== Scenario E: real CLI - fm-captain-hold.sh complete <origin> --none ==================="
command -v tasks-axi >/dev/null 2>&1 || { echo "FAIL: tasks-axi missing"; FAILS=$((FAILS+1)); exit 1; }
HOME_DIR="$WORK/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
fakebin=$(fm_fakebin "$HOME_DIR")
fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
id=sample-epoch-review
mkdir -p "$HOME_DIR/data/$id"
(cd "$HOME_DIR" && tasks-axi add "$id" "Investigate epoch status" --kind scout --repo sample --start >/dev/null) || echo "WARN: tasks-axi add failed"
fm_write_meta "$HOME_DIR/state/$id.meta" "window=firstmate:fm-$id" "worktree=$HOME_DIR/projects/missing-$id" \
  "project=$HOME_DIR/projects/sample" "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
printf '%s\n' \
  'working: report drafted' \
  'blocked [at=1793378273] [key=example]: An earlier blocker remains open.' \
  '1793378273 blocked [key=broken] An implementation decision needs an answer.' > "$HOME_DIR/state/$id.status"
printf '# Epoch review\n\nOne blocker remains.\n' > "$HOME_DIR/data/$id/report.md"
echo "\$ FM_HOME=<lab> bin/fm-captain-hold.sh complete $id --none"
set +e
PATH="$fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT_ARG/bin/fm-captain-hold.sh" complete "$id" --none > "$WORK/E.out" 2> "$WORK/E.err"
rc=$?
set -e; set +e
echo "exit=$rc"
show "E stdout" "$(cat "$WORK/E.out")"; show "E stderr" "$(cat "$WORK/E.err")"
[ "$rc" -ne 0 ]; check "E1 complete --none is refused: the earlier blocker is still open" $?
grep -q "still has open captain decisions" "$WORK/E.err"; check "E2 refusal names the open captain decision" $?
grep -qF "$HOME_DIR/state/$id.status:3: malformed status line; repair the timestamp to [at=<epoch>] after the verb: 1793378273 blocked [key=broken]" "$WORK/E.err"
check "E3 the CLI surfaces the malformed line 3 with file:line on stderr" $?
! grep -q 'decisions_reviewed=1' "$HOME_DIR/state/$id.meta"; check "E4 no false completion attestation written" $?

echo
echo "TOTAL FAILS: $FAILS"
exit "$FAILS"
