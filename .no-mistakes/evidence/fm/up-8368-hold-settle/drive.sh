#!/usr/bin/env bash
# Live drive: real bin/fm-captain-hold.sh, bin/fm-contributions.sh, bin/fm-tasks-axi.sh and
# bin/fm-afk-contract.sh against disposable homes; only `gh` (the forge) is a local emulator.
set -u
ROOT=$PWD
T=$ROOT/tests/fm-contributions.test.sh
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-hold-settle.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
NOW=2026-09-16T08:00:00Z HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
fail() { printf 'FIXTURE FAIL: %s\n' "$*"; exit 1; }
# Fixture builders (home layout + forge emulator) reused from the repository test file.
eval "$(sed -n '11,19p;27,41p;107,159p' "$T")"
PR=https://github.com/o/r/pull/8
FAILS=0
h() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; with_home "$HOME_" "$@" 2>&1; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }
hold() { run "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks() { run "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
poll() { printf '$ fm-contributions.sh poll\n'; POLL=$(with_home "$HOME_" "$ROOT/bin/fm-contributions.sh" poll 2>&1); printf '%s\n[exit %s] [poll output bytes: %s]\n' "$POLL" "$?" "${#POLL}"; }
forge() { printf '(forge emulator: PR 8 is now %s)\n' "$1"; printf '%s\n' "$1" > "$HOME_/forge/state"; }
is_open() { with_home "$HOME_" "$ROOT/bin/fm-captain-hold.sh" open "$1" >/dev/null 2>&1; }
state() { with_home "$HOME_" "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full | sed -n 's/^  state: //p'; }
body() { with_home "$HOME_" "$ROOT/bin/fm-tasks-axi.sh" show "$1" --full; }
check() { if eval "$2"; then printf 'CHECK PASS: %s\n' "$1"; else printf 'CHECK FAIL: %s\n' "$1"; FAILS=$((FAILS+1)); fi; }
home() { HOME_=$(new_home "$1"); forge_home "$HOME_"; rm "$HOME_/state/delivery.meta"; }
closed_tasks() { with_home "$HOME_" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[] | select(.type == "closed") | .task] | sort'; }

h 'S1 merged PR settles declared holds (close and release); undeclared hold on unrelated work stays open'
home s1; touch "$HOME_/config/hold-pr-settle"
tasks add q-close 'Approve this PR?' --pr $PR >/dev/null; hold hold q-close --reason 'Approve this PR?'
hold pr-policy q-close $PR merged close
tasks add q-release 'Wait for PR before continuing work' --pr $PR >/dev/null; hold hold q-release --reason 'Wait for the PR'
hold pr-policy q-release $PR merged release
hold hold delivery --reason 'Unrelated unfinished work'
printf 'policy record: '; cat "$HOME_/data/q-close/hold-pr-policy.json"; echo
run "$ROOT/bin/fm-contributions.sh" arm >/dev/null
forge merged
printf '$ bash state/contributions.check.sh   (the shim the watcher runs)\n'
OUT=$(with_home "$HOME_" bash "$HOME_/state/contributions.check.sh" 2>&1); printf '%s\n[exit %s] [check output bytes: %s]\n' "$OUT" "$?" "${#OUT}"
check 'watcher check printed nothing, so no wake / model turn' '[ -z "$OUT" ]'
check 'no wake queued' '[ ! -s "$HOME_/state/.wake-queue" ]'
check 'q-close hold settled' '! is_open q-close'
check 'q-close task is done' '[ "$(state q-close)" = done ]'
check 'q-release hold released' '! is_open q-release'
check 'q-release work NOT completed' '[ "$(state q-release)" != done ]'
check 'unrelated delivery hold still open' 'is_open delivery'
check 'forge event recorded as evidence' 'body q-close | grep -qF "Forge PR merged: $PR"'
check 'no captain answer invented' '! body q-close | grep -qF "Captain decision:"'
check 'policy files retired' '[ ! -e "$HOME_/data/q-close/hold-pr-policy.json" ] && [ ! -e "$HOME_/data/q-release/hold-pr-policy.json" ]'
printf -- '--- q-close task after settlement ---\n'; body q-close
cp "$HOME_/data/backlog.md" "$HOME_/before.md"; poll
check 'repeat poll is silent and changes nothing' '[ -z "$POLL" ] && cmp -s "$HOME_/data/backlog.md" "$HOME_/before.md"'

h 'S2 PR closed without merging: terminal policy settles; held task without policy is told; unheld task is not'
home s2; touch "$HOME_/config/hold-pr-settle"
tasks add q-term 'Decide this PR' --pr $PR >/dev/null; hold hold q-term --reason 'Decide this PR' >/dev/null
hold pr-policy q-term $PR terminal close
hold hold delivery --reason 'Rework or drop?' >/dev/null
tasks add bystander 'Work without a captain hold' --pr $PR >/dev/null
forge closed; poll
check 'q-term settled and done with closed evidence' '! is_open q-term && [ "$(state q-term)" = done ] && body q-term | grep -qF "Forge PR closed: $PR"'
check 'held-without-policy task still open' 'is_open delivery'
printf 'pending closed events: %s\n' "$(closed_tasks)"
check 'closed event reported to exactly the still-held task' '[ "$(closed_tasks)" = "[\"delivery\"]" ]'
check 'closure queued a wake' '[ -s "$HOME_/state/.wake-queue" ]'
printf 'wake queue: '; cat "$HOME_/state/.wake-queue"
N=$(wc -l < "$HOME_/state/.wake-queue"); poll
check 'closure reported once (repeat poll silent, no new wake)' '[ -z "$POLL" ] && [ "$(wc -l < "$HOME_/state/.wake-queue")" = "$N" ]'

h 'S3 opt-in: flag absent -> declaration refused, nothing settles; creating the flag applies the retained observation'
home s3
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged close; RC=$?
check 'pr-policy refused without config/hold-pr-settle' '[ "$RC" -ne 0 ]'
touch "$HOME_/config/hold-pr-settle"; hold pr-policy delivery $PR merged close; rm "$HOME_/config/hold-pr-settle"
forge merged; poll
check 'flag absent: hold untouched and poll silent' 'is_open delivery && [ -z "$POLL" ]'
touch "$HOME_/config/hold-pr-settle"; poll
check 'flag created: retained merged observation settles the hold' '! is_open delivery'

h 'S4 adversarial: policy says merged, PR closed unmerged -> not settled, policy dropped with a diagnostic, closure reported'
home s4; touch "$HOME_/config/hold-pr-settle"
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged close >/dev/null
forge closed; poll
check 'hold stays open' 'is_open delivery && [ "$(state delivery)" != done ]'
check 'diagnostic names the dropped policy' 'printf %s "$POLL" | grep -qF "PR hold settlement failed for delivery $PR"'
check 'closed event raised for the still-held task' '[ "$(closed_tasks)" = "[\"delivery\"]" ]'
poll; check 'diagnostic is not repeated' '[ -z "$POLL" ]'

h 'S5 adversarial: question changed (re-held) after the declaration -> merged PR must not settle the new question'
home s5; touch "$HOME_/config/hold-pr-settle"
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged close >/dev/null
hold hold delivery --reason 'A different question about this work'
forge merged; poll
check 'new question stays open and unfinished' 'is_open delivery && [ "$(state delivery)" != done ]'

h 'S6 follow-up PR link and retained report link do not invalidate the declaration'
home s6; touch "$HOME_/config/hold-pr-settle"
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged close >/dev/null
mkdir -p "$HOME_/data/delivery"; echo report > "$HOME_/data/delivery/report.md"
tasks update delivery --pr https://github.com/o/r/pull/10 --report data/delivery/report.md
forge merged; poll
check 'hold settled despite added links' '! is_open delivery && [ -z "$POLL" ]'

h 'S7 away home: release deferred silently, applied on the first attended poll; close action unaffected'
home s7; touch "$HOME_/config/hold-pr-settle"
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged release >/dev/null
run "$ROOT/bin/fm-afk-contract.sh" enter --words 'watch the fleet' >/dev/null
forge merged; poll
check 'away: hold stays, poll silent, policy kept' 'is_open delivery && [ -z "$POLL" ] && [ -f "$HOME_/data/delivery/hold-pr-policy.json" ]'
run "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null; poll
check 'attended: hold released, work not completed' '! is_open delivery && [ "$(state delivery)" != done ]'

h 'S8 busy away-record lock: poll returns promptly and defers, then applies'
home s8; touch "$HOME_/config/hold-pr-settle"
hold hold delivery --reason 'Merge this PR?' >/dev/null
hold pr-policy delivery $PR merged release >/dev/null
FM_STATE_OVERRIDE="$HOME_/state" bash -c '. "$1"; fm_lock_acquire_wait "$2" || exit 10; echo ready > "$3"; while [ ! -e "$4" ]; do sleep 0.05; done; fm_lock_release "$2"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$HOME_/state/.afk-contract.lock" "$HOME_/ready" "$HOME_/release" &
HP=$!; for i in $(seq 100); do [ -s "$HOME_/ready" ] && break; sleep 0.05; done
forge merged; S=$SECONDS; poll; D=$((SECONDS-S)); printf 'poll took %ss under a held away-record lock (no timeout override)\n' "$D"
touch "$HOME_/release"; wait $HP
check 'locked: deferred silently within 10s' 'is_open delivery && [ -z "$POLL" ] && [ "$D" -lt 10 ]'
poll; check 'unlocked: released' '! is_open delivery'

printf '\n===== RESULT: %s failed checks =====\n' "$FAILS"
exit $((FAILS > 0))
