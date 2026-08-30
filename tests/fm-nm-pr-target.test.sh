#!/usr/bin/env bash
# Behavior tests for the pull-request target guard - bin/fm-nm-pr-target.sh and
# bin/fm-nm-pr-target-lib.sh.
#
# WHAT THIS GUARDS. A fork-topology home registers the validation pipeline with
# two targets: branches push to the personal fork, while the registration's own
# remote stays the pull-request base. Nothing checked that base against where the
# home's work is meant to go, and on 2026-08-28 two large pull requests landed on
# OFFICIAL UPSTREAM from work that was never meant to leave the fork. The guard's
# rule is that the pipeline may open a pull request only against the repository
# this home already pushes to.
#
# WHY THE CENTRAL CASE PUSHES FOR REAL. The bar is that the wrong target must be
# UNREACHABLE, not reported after the fact, so the assertion that matters is
# end-to-end: with the targets disagreeing, a real `git push` into a real gate
# repository must FAIL and the gate must NOT receive the branch. That is the
# operation `no-mistakes axi run` performs to enter the pipeline, and a refused
# entry starts no run at all - so review, push, and PR are never reached.
# Asserting the refusal message alone would pass just as happily against a guard
# that printed a warning and let the push through, which is exactly the shape
# that was rejected.
#
# Cases:
#   (a) gate push REFUSED when the PR base and the push target disagree, and the
#       gate receives nothing                                  <- the red/green case
#   (b) gate push allowed when they agree
#   (c) an ordinary non-gate push is never refused, even while (a) holds
#   (d) a renamed gate remote is still recognized by its path
#   (e) equivalent URL spellings (scp vs https, redacted userinfo, port, .git,
#       host case) are the same target and must NOT refuse
#   (f) fail-closed: unreadable configured push target
#   (g) fail-closed: unreadable registration (tool absent, tool fails, empty base)
#   (h) fail-closed: unparseable URL on either side
#   (i) install is idempotent, repairs its own stale copy, and refuses to clobber
#       a foreign pre-push hook
#   (j) the installed hook carries its own guard payload, refuses when that
#       payload is missing, and repairs it without reading another checkout
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-nm-pr-target.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-pr-target)
fm_git_identity fmtest fmtest@example.invalid

REFUSE_EXIT=4

# A fake `no-mistakes` whose `status` output mirrors the real command's shape:
# aligned "remote:" and "fork:" labels. FM_FAKE_NM_REMOTE / FM_FAKE_NM_FORK drive
# it; FM_FAKE_NM_FAIL makes the command itself fail, and FM_FAKE_NM_NO_REMOTE
# omits the base line entirely.
make_fakebin() { # <dir> -> echoes fakebin path
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" != status ]; then exit 0; fi
if [ -n "${FM_FAKE_NM_FAIL:-}" ]; then
  echo "no gate registered for this repository" >&2
  exit 1
fi
printf '    repo:  %s\n' "$PWD"
if [ -z "${FM_FAKE_NM_NO_REMOTE:-}" ]; then
  printf '  remote:  %s\n' "${FM_FAKE_NM_REMOTE:-}"
fi
printf '    fork:  %s\n' "${FM_FAKE_NM_FORK:-}"
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# A working clone with an `origin` push target plus a bare gate repository whose
# path matches the real gate layout (~/.no-mistakes/repos/<id>.git), wired as the
# `no-mistakes` remote exactly as `no-mistakes init` wires it.
make_sandbox() { # <name> <origin-push-url> -> echoes repo path
  local name=$1 origin_url=$2 dir repo gate
  # Separate statements: bash expands every word of one `local` before it
  # assigns any of them, so a later item cannot read an earlier one.
  dir="$TMP_ROOT/$name"
  repo="$dir/work"
  gate="$dir/home/.no-mistakes/repos/abcdef123456.git"
  mkdir -p "$(dirname "$gate")"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin "$origin_url"
  git init -q --bare "$gate"
  git -C "$repo" remote add no-mistakes "$gate"
  git -C "$repo" checkout -q -b topic
  printf 'change\n' > "$repo/change.txt"
  git -C "$repo" add change.txt
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm 'topic change'
  printf '%s\n' "$dir"
}

gate_of()  { printf '%s/home/.no-mistakes/repos/abcdef123456.git\n' "$1"; }
work_of()  { printf '%s/work\n' "$1"; }

# Did the gate actually receive the branch? This is the fact that decides whether
# a pipeline run could start, independent of what the push printed.
gate_has_topic() { # <gate>
  git -C "$1" rev-parse --verify --quiet refs/heads/topic >/dev/null 2>&1
}

FORK_SSH='git@github.com:tiago-peixoto/firstmate.git'
UPSTREAM_SSH='git@github.com:kunchenguid/firstmate.git'

FB=$(make_fakebin "$TMP_ROOT")
export PATH="$FB:$PATH"

# --- (a) the red/green case: a disagreeing target cannot enter the pipeline ---

sandbox=$(make_sandbox mismatch "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")

# The guard must be installed for the refusal to exist at all. Installation is
# deliberately tolerated as a soft step here so that running this file against a
# tree WITHOUT the guard still reaches the assertion below and fails on the real
# defect - an accepted gate push - rather than on a missing file.
"$GUARD" install "$work" >/dev/null 2>&1 || true

export FM_FAKE_NM_REMOTE="$UPSTREAM_SSH" FM_FAKE_NM_FORK="$FORK_SSH"
push_out=$(git -C "$work" push no-mistakes HEAD:refs/heads/topic 2>&1) && push_rc=0 || push_rc=$?

[ "$push_rc" -ne 0 ] \
  || fail "(a) gate push was ACCEPTED while the pipeline's PR base ($UPSTREAM_SSH) differs from the push target ($FORK_SSH); a run could start and open the wrong pull request"
gate_has_topic "$gate" \
  && fail "(a) the gate received refs/heads/topic despite the target mismatch; the pipeline can still be entered"
case "$push_out" in
  *REFUSED*) ;;
  *) fail "(a) push failed without the guard's refusal; got: $push_out" ;;
esac
case "$push_out" in
  *kunchenguid*) ;;
  *) fail "(a) refusal did not name the wrong pull-request base; got: $push_out" ;;
esac
pass "(a) a gate push is refused and the gate stays empty when the PR base is not the push target"

# The read-only verdict agrees with the enforced one, and uses the distinct code.
"$GUARD" check "$work" >/dev/null 2>&1 && fail "(a) check reported ok on a mismatched target"
"$GUARD" check "$work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq "$REFUSE_EXIT" ] || fail "(a) check exit was $rc, expected $REFUSE_EXIT"
pass "(a) check refuses the same mismatch with exit $REFUSE_EXIT"

# --- (b) agreement lets the pipeline be entered -------------------------------

sandbox=$(make_sandbox match "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")
"$GUARD" install "$work" >/dev/null || fail "(b) install failed"

export FM_FAKE_NM_REMOTE="$FORK_SSH" FM_FAKE_NM_FORK=''
git -C "$work" push --quiet no-mistakes HEAD:refs/heads/topic 2>&1 \
  || fail "(b) gate push was refused although the PR base IS the push target"
gate_has_topic "$gate" || fail "(b) gate did not receive the branch on an allowed push"
"$GUARD" check "$work" >/dev/null || fail "(b) check refused a matching target"
pass "(b) a gate push proceeds when the PR base is the push target"

# --- (c) ordinary pushes are none of the guard's business ---------------------

sandbox=$(make_sandbox ordinary "$FORK_SSH")
work=$(work_of "$sandbox")
other="$TMP_ROOT/ordinary/other.git"
git init -q --bare "$other"
git -C "$work" remote add elsewhere "$other"
"$GUARD" install "$work" >/dev/null || fail "(c) install failed"

export FM_FAKE_NM_REMOTE="$UPSTREAM_SSH" FM_FAKE_NM_FORK="$FORK_SSH"
git -C "$work" push --quiet elsewhere HEAD:refs/heads/topic 2>&1 \
  || fail "(c) an ordinary push was refused; the guard must only gate pipeline entry"
git -C "$other" rev-parse --verify --quiet refs/heads/topic >/dev/null \
  || fail "(c) the ordinary push did not deliver the branch"
pass "(c) an ordinary push is untouched even while the pipeline target is wrong"

# --- (d) a renamed gate remote is still recognized ----------------------------

sandbox=$(make_sandbox renamed "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")
git -C "$work" remote rename no-mistakes validator
"$GUARD" install "$work" >/dev/null || fail "(d) install failed"

export FM_FAKE_NM_REMOTE="$UPSTREAM_SSH" FM_FAKE_NM_FORK="$FORK_SSH"
git -C "$work" push --quiet validator HEAD:refs/heads/topic >/dev/null 2>&1 \
  && fail "(d) a renamed gate remote bypassed the guard"
gate_has_topic "$gate" && fail "(d) the renamed gate still received the branch"
pass "(d) a renamed gate remote is recognized by its path and still refused"

# --- (e) equivalent spellings of the same repository must not refuse ----------

for spelling in \
  'https://github.com/tiago-peixoto/firstmate.git' \
  'https://github.com/tiago-peixoto/firstmate' \
  'https://redacted@github.com/tiago-peixoto/firstmate.git' \
  'ssh://git@github.com:22/tiago-peixoto/firstmate.git' \
  'git@GitHub.com:tiago-peixoto/firstmate'
do
  sandbox=$(make_sandbox "spell$RANDOM$RANDOM" "$FORK_SSH")
  work=$(work_of "$sandbox")
  export FM_FAKE_NM_REMOTE="$spelling" FM_FAKE_NM_FORK=''
  "$GUARD" check "$work" >/dev/null \
    || fail "(e) refused '$spelling', which is the same repository as $FORK_SSH"
done
pass "(e) equivalent URL spellings of one repository are treated as the same target"

# A genuinely different repository on the same host still refuses.
sandbox=$(make_sandbox otherowner "$FORK_SSH")
work=$(work_of "$sandbox")
export FM_FAKE_NM_REMOTE='https://github.com/kunchenguid/firstmate.git' FM_FAKE_NM_FORK=''
"$GUARD" check "$work" >/dev/null 2>&1 \
  && fail "(e) a different owner on the same host was accepted as the same target"
pass "(e) a different owner on the same host is still refused"

# --- (f) fail closed: the configured push target cannot be read ---------------

sandbox=$(make_sandbox noorigin "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")
git -C "$work" remote remove origin
"$GUARD" install "$work" >/dev/null || fail "(f) install failed"
export FM_FAKE_NM_REMOTE="$FORK_SSH" FM_FAKE_NM_FORK=''

out=$("$GUARD" check "$work" 2>&1) && fail "(f) check passed with no configured push target"
case "$out" in
  *'configured push target'*) ;;
  *) fail "(f) refusal did not name the unreadable push target; got: $out" ;;
esac
git -C "$work" push --quiet no-mistakes HEAD:refs/heads/topic >/dev/null 2>&1 \
  && fail "(f) an unreadable push target fell back to allowing the pipeline in"
gate_has_topic "$gate" && fail "(f) the gate received the branch with no readable push target"
pass "(f) an absent configured push target refuses instead of falling back"

# Several push URLs on origin are ambiguous, not a pick-the-first situation.
sandbox=$(make_sandbox twopush "$FORK_SSH")
work=$(work_of "$sandbox")
git -C "$work" config --add remote.origin.pushurl "$FORK_SSH"
git -C "$work" config --add remote.origin.pushurl "$UPSTREAM_SSH"
export FM_FAKE_NM_REMOTE="$FORK_SSH" FM_FAKE_NM_FORK=''
out=$("$GUARD" check "$work" 2>&1) && fail "(f) two push URLs were accepted"
case "$out" in
  *ambiguous*) ;;
  *) fail "(f) two push URLs did not refuse as ambiguous; got: $out" ;;
esac
pass "(f) several push URLs on origin refuse as ambiguous"

# --- (g) fail closed: the registration cannot be read -------------------------

sandbox=$(make_sandbox noreg "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")
"$GUARD" install "$work" >/dev/null || fail "(g) install failed"

# The tool itself fails.
export FM_FAKE_NM_REMOTE="$FORK_SSH" FM_FAKE_NM_FORK='' FM_FAKE_NM_FAIL=1
out=$("$GUARD" check "$work" 2>&1) && fail "(g) check passed when the registration could not be read"
case "$out" in
  *'pipeline registration'*) ;;
  *) fail "(g) refusal did not name the unreadable registration; got: $out" ;;
esac
git -C "$work" push --quiet no-mistakes HEAD:refs/heads/topic >/dev/null 2>&1 \
  && fail "(g) an unreadable registration let the pipeline be entered"
gate_has_topic "$gate" && fail "(g) the gate received the branch with an unreadable registration"
pass "(g) a failing registration read refuses instead of falling back"
unset FM_FAKE_NM_FAIL

# The registration reports no pull-request base at all.
export FM_FAKE_NM_NO_REMOTE=1
out=$("$GUARD" check "$work" 2>&1) && fail "(g) check passed with no recorded PR base"
case "$out" in
  *'pull-request base'*) ;;
  *) fail "(g) refusal did not name the missing PR base; got: $out" ;;
esac
pass "(g) a registration with no recorded pull-request base refuses"
unset FM_FAKE_NM_NO_REMOTE

# The tool is not installed at all.
export FM_FAKE_NM_REMOTE="$FORK_SSH"
out=$(PATH="/usr/bin:/bin" "$GUARD" check "$work" 2>&1) \
  && fail "(g) check passed with no-mistakes absent from PATH"
case "$out" in
  *'not installed'*) ;;
  *) fail "(g) refusal did not name the absent tool; got: $out" ;;
esac
pass "(g) an absent no-mistakes binary refuses instead of falling back"

# --- (h) fail closed: an unparseable URL on either side -----------------------

sandbox=$(make_sandbox badbase "$FORK_SSH")
work=$(work_of "$sandbox")
export FM_FAKE_NM_REMOTE='not-a-url' FM_FAKE_NM_FORK=''
out=$("$GUARD" check "$work" 2>&1) && fail "(h) an unparseable PR base was accepted"
case "$out" in
  *'cannot parse'*) ;;
  *) fail "(h) refusal did not name the unparseable base; got: $out" ;;
esac
pass "(h) an unparseable pull-request base refuses"

sandbox=$(make_sandbox badpush 'not-a-url')
work=$(work_of "$sandbox")
export FM_FAKE_NM_REMOTE='not-a-url' FM_FAKE_NM_FORK=''
out=$("$GUARD" check "$work" 2>&1) && fail "(h) an unparseable push target was accepted"
case "$out" in
  *'cannot parse'*) ;;
  *) fail "(h) refusal did not name the unparseable push target; got: $out" ;;
esac
pass "(h) an unparseable configured push target refuses even when both sides read alike"

# --- (i) install behavior -----------------------------------------------------

sandbox=$(make_sandbox installer "$FORK_SSH")
work=$(work_of "$sandbox")
hook="$(git -C "$work" rev-parse --path-format=absolute --git-common-dir)/hooks/pre-push"

out=$("$GUARD" install "$work") || fail "(i) first install failed"
case "$out" in *installed*) ;; *) fail "(i) first install did not report installing; got: $out" ;; esac
[ -x "$hook" ] || fail "(i) hook is not executable at $hook"

out=$("$GUARD" install "$work") || fail "(i) second install failed"
case "$out" in *current*) ;; *) fail "(i) second install was not a no-op; got: $out" ;; esac
"$GUARD" installed "$work" >/dev/null || fail "(i) installed did not report the current guard"
pass "(i) install is idempotent and reports the guard current on a repeat run"

printf '#!/bin/sh\n# fm-nm-pr-target guard v0 - older shim\nexit 0\n' > "$hook"
chmod +x "$hook"
"$GUARD" installed "$work" >/dev/null 2>&1 && fail "(i) a stale shim was reported current"
out=$("$GUARD" install "$work") || fail "(i) repair failed"
case "$out" in *repaired*) ;; *) fail "(i) a stale shim was not repaired; got: $out" ;; esac
"$GUARD" installed "$work" >/dev/null || fail "(i) repaired shim is not current"
pass "(i) install repairs its own stale shim"

printf '#!/bin/sh\necho someone elses hook\nexit 0\n' > "$hook"
chmod +x "$hook"
"$GUARD" install "$work" >/dev/null 2>&1 && fail "(i) install clobbered a foreign pre-push hook"
"$GUARD" install "$work" >/dev/null 2>&1; rc=$?
[ "$rc" -eq "$REFUSE_EXIT" ] || fail "(i) foreign-hook refusal exit was $rc, expected $REFUSE_EXIT"
grep -q 'someone elses hook' "$hook" || fail "(i) the foreign hook was overwritten"
pass "(i) install refuses to replace a pre-push hook it did not write"

# --- (j) the hook carries a clone-local guard payload --------------------------
#
# A disposable linked worktree must not execute the guard out of the primary
# checkout. The common hook directory belongs to the clone and is shared by all
# of its worktrees, so installation puts the executable guard there as well as
# the pre-push entrypoint.

sandbox=$(make_sandbox brokenshim "$FORK_SSH")
work=$(work_of "$sandbox"); gate=$(gate_of "$sandbox")
FM_ROOT_OVERRIDE="$TMP_ROOT/gone" "$GUARD" install "$work" >/dev/null \
  || fail "(j) install with a relocated root failed"
export FM_FAKE_NM_REMOTE="$FORK_SSH" FM_FAKE_NM_FORK=''

# Targets agree, and the tracked checkout recorded at install time is absent.
# Success therefore proves the hook executed its clone-local payload.
git -C "$work" push --quiet no-mistakes HEAD:refs/heads/topic \
  || fail "(j) the installed hook still depended on the checkout that installed it"
gate_has_topic "$gate" || fail "(j) the clone-local guard did not let the matching branch reach the gate"
pass "(j) the installed hook runs from clone-local Git metadata"

# Losing that payload is a refusal, not an unguarded pass. Repair restores it
# from the command's current trusted copy and the next push succeeds.
hook=$(git -C "$work" rev-parse --path-format=absolute --git-path hooks/pre-push)
payload="$(dirname "$hook")/.fm-nm-pr-target.sh"
rm -f "$payload"
printf 'second change\n' >> "$work/change.txt"
git -C "$work" add change.txt
git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -qm 'second topic change'
prior=$(git -C "$gate" rev-parse refs/heads/topic)
push_out=$(git -C "$work" push no-mistakes HEAD:refs/heads/topic 2>&1) \
  && fail "(j) a missing clone-local guard payload let the push through"
[ "$(git -C "$gate" rev-parse refs/heads/topic)" = "$prior" ] \
  || fail "(j) the gate advanced while the clone-local guard payload was missing"
case "$push_out" in
  *REFUSED*) ;;
  *) fail "(j) a missing clone-local guard failed silently instead of saying why; got: $push_out" ;;
esac
"$GUARD" install "$work" >/dev/null || fail "(j) clone-local guard repair failed"
git -C "$work" push --quiet no-mistakes HEAD:refs/heads/topic \
  || fail "(j) repaired clone-local guard still refused the matching push"
[ "$(git -C "$gate" rev-parse refs/heads/topic)" = "$(git -C "$work" rev-parse HEAD)" ] \
  || fail "(j) repaired clone-local guard did not deliver the new head"
pass "(j) a missing clone-local guard refuses and is repairable"
