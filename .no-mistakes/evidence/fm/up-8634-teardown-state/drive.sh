#!/usr/bin/env bash
# Usage: drive.sh <tree> - drives the real bin/fm-teardown.sh and bin/fm-procevent.sh
# from <tree> against disposable homes, with the parent's FM_STATE_OVERRIDE exported.
set -u
TREE=$1
. "$TREE/tests/secondmate-helpers.sh"
T=$(fm_test_tmproot fm-8634-live)
fmode() { stat -c %a "$1"; }
show() { echo "--- $1"; (cd "$2" 2>/dev/null && find . -path ./bin -prune -o -type f -print | sort | grep -v '^./AGENTS.md' ) || echo "(gone)"; }
verdict=0
check() { if eval "$2"; then echo "OK   $1"; else echo "FAIL $1"; verdict=1; fi; }

setup() { # $1=tag $2=mode ; sets home subhome control claims before
  home="$T/$1-parent"; subhome="$T/$1-child"; control="$home/state/parent-route"
  claims="$T/$1-claims"; before="$T/$1.source.before"
  mkdir -p "$control/procevent" "$home/data"
  chmod "$2" "$control"
}
register() {
  mkdir -p "$subhome/state"; chmod 700 "$subhome/state"
  printf 'domain\n' > "$subhome/.fm-secondmate-home"
  cp -R "$ROOT/bin/." "$subhome/bin/"
  FM_HOME="$subhome" FM_STATE_OVERRIDE="$subhome/state" FM_PROCEVENT_CLAIM_ROOT="$claims" \
    "$subhome/bin/fm-procevent.sh" register lavish source -- "$(command -v true)" >/dev/null || { echo "setup: register failed"; exit 3; }
  cp "$subhome/state/procevent/source.source" "$before"
  cp "$before" "$control/procevent/source.source"   # parent holds a same-named registration
  printf '%s\n' '- domain - design domain (home: '"$subhome"'; scope: design domain; projects: alpha; added 2026-06-22)' > "$home/data/secondmates.md"
}

for mode in 775 700; do
  echo; echo "===== S1 teardown, parent state mode $mode, parent FM_STATE_OVERRIDE exported ====="
  setup "s1-$mode" "$mode"; mark_firstmate_home "$subhome"; register
  fm_write_secondmate_meta "$control/domain.meta" "$subhome"
  fakebin=$(make_fake_tmux "$T/s1-$mode-fake")
  show "parent state before" "$control"; show "child home before" "$subhome"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$control" FM_PROCEVENT_CLAIM_ROOT="$claims" \
    FM_FAKE_TMUX_LOG="$T/s1-$mode-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$T/s1-$mode-fake/pane.txt" \
    "$ROOT/bin/fm-teardown.sh" domain 2>&1); rc=$?
  echo "\$ FM_HOME=<parent> FM_STATE_OVERRIDE=<parent>/state/parent-route bin/fm-teardown.sh domain  -> rc=$rc"
  printf '%s\n' "$out" | sed "s#$T#<tmp>#g; s/^/  | /"
  show "parent state after" "$control"; show "child home after" "$subhome"
  check "teardown exits 0" '[ $rc -eq 0 ]'
  check "sweep reports the child registration (attempted=1)" 'printf "%s" "$out" | grep -qF "swept: attempted=1"'
  check "child home removed" '[ ! -d "$subhome" ]'
  check "parent source.source byte-identical" 'cmp -s "$before" "$control/procevent/source.source"'
  check "parent state dir mode still $mode (now $(fmode "$control"))" '[ "$(fmode "$control")" = "$mode" ]'
done

echo; echo "===== S2 failed home return -> restore + reconcile, parent FM_STATE_OVERRIDE exported ====="
setup s2 775; fmroot="$T/s2-fmroot"
make_firstmate_git_root "$fmroot"
git -C "$fmroot" worktree add --quiet --detach "$subhome" HEAD
register
cat > "$control/domain.meta" <<META
window=firstmate:fm-domain
worktree=$subhome
project=$subhome
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$subhome
projects=alpha
META
fakebin=$(make_fake_tmux "$T/s2-fake")
show "parent state before" "$control"; show "child state before" "$subhome/state"
out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fmroot" FM_HOME="$home" FM_STATE_OVERRIDE="$control" FM_PROCEVENT_CLAIM_ROOT="$claims" \
  FM_FAKE_TMUX_LOG="$T/s2-fake/tmux.log" FM_FAKE_TMUX_CAPTURE="$T/s2-fake/pane.txt" FM_FAKE_TREEHOUSE_RETURN_FAIL=1 \
  "$ROOT/bin/fm-teardown.sh" domain 2>&1); rc=$?
echo "\$ ... FM_FAKE_TREEHOUSE_RETURN_FAIL=1 bin/fm-teardown.sh domain  -> rc=$rc"
printf '%s\n' "$out" | sed "s#$T#<tmp>#g; s/^/  | /"
sleep 2
show "parent state after" "$control"; show "child state after" "$subhome/state"
check "teardown refuses (rc != 0)" '[ $rc -ne 0 ]'
check "refusal is the failed home return" 'printf "%s" "$out" | grep -qF "treehouse return failed"'
check "child home retained" '[ -d "$subhome" ]'
check "child registration restored" '[ -f "$subhome/state/procevent/source.source" ]'
check "parent procevent dir holds only its original source" '[ "$(cd "$control/procevent" && ls -A | tr "\n" " ")" = "source.source " ]'
check "parent source.source byte-identical" 'cmp -s "$before" "$control/procevent/source.source"'
check "parent state dir mode still 775 (now $(fmode "$control"))" '[ "$(fmode "$control")" = 775 ]'
FM_HOME="$subhome" FM_STATE_OVERRIDE="$subhome/state" FM_PROCEVENT_CLAIM_ROOT="$claims" "$subhome/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true

echo; echo "===== S3 documented manual recovery command, run from a shell that exports the parent FM_STATE_OVERRIDE ====="
setup s3 775; mark_firstmate_home "$subhome"; register
export FM_STATE_OVERRIDE="$control"
out=$(FM_PROCEVENT_CLAIM_ROOT="$claims" FM_HOME="$subhome" FM_STATE_OVERRIDE="$subhome/state" "$subhome/bin/fm-procevent.sh" sweep-home 2>&1); rc=$?
unset FM_STATE_OVERRIDE
echo "\$ FM_HOME=<home> FM_STATE_OVERRIDE=<home>/state <home>/bin/fm-procevent.sh sweep-home  -> rc=$rc"
printf '%s\n' "$out" | sed "s#$T#<tmp>#g; s/^/  | /"
check "sweep exits 0 and retires the child registration" '[ $rc -eq 0 ] && [ ! -e "$subhome/state/procevent/source.source" ]'
check "parent source.source byte-identical" 'cmp -s "$before" "$control/procevent/source.source"'
check "parent state dir mode still 775" '[ "$(fmode "$control")" = 775 ]'

pgrep -af "$T" && echo "WARN: leftover processes" 
rm -rf "$T"
echo; echo "RESULT: $([ $verdict -eq 0 ] && echo ALL-OK || echo HAS-FAILURES)"
exit $verdict
