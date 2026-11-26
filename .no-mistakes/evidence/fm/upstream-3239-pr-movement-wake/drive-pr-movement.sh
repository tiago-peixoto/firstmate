#!/usr/bin/env bash
# Drives the real bin/fm-contributions.sh + fm-pr-check.sh registered check against
# a disposable home and the test suite's local fake `gh` forge (synthetic PR o/r#8).
# usage: drive-pr-movement.sh <worktree> <base-bin-root>
set -u
WT=$1; BASE=$2
. "$WT/tests/lib.sh"; source <(sed -e "/^failures=0\$/,\$d" -e "/^\. .*lib\.sh\"\$/d" "$WT/tests/fm-contributions.test.sh")
show() { # home label
  printf '  %-46s wakes=%s pending=%s\n' "$2" "$(queued_wakes "$1")" \
    "$(with_home "$1" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[] | {type,body}]')"
}
setup() { # name flag(on|off|dir)
  local home; home=$(new_home "$1"); forge_home "$home" >/dev/null
  case "$2" in on) touch "$home/config/contribution-pr-movement" ;; dir) mkdir "$home/config/contribution-pr-movement" ;; esac
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null || echo REGISTER-FAILED >&2
  registered_checks "$home" >/dev/null
  printf '%s\n' "$home"
}
moves() { # home
  local home=$1
  show "$home" 'baseline poll'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"; registered_checks "$home" >/dev/null; show "$home" 'head A -> B'
  printf 'true\n' > "$home/forge/draft"; registered_checks "$home" >/dev/null; show "$home" 'converted to draft'
  printf 'false\n' > "$home/forge/draft"; registered_checks "$home" >/dev/null; show "$home" 'left draft'
  printf '[{"login":"reviewer"}]\n' > "$home/forge/requested.json"; registered_checks "$home" >/dev/null; show "$home" 'reviewer requested'
  printf '[{"slug":"core","name":"Core"}]\n' > "$home/forge/teams.json"; registered_checks "$home" >/dev/null; show "$home" 'team requested'
  registered_checks "$home" >/dev/null; show "$home" 'unchanged re-poll'
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
    html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z"}]' > "$home/forge/comments.json"
  registered_checks "$home" >/dev/null; show "$home" 'maintainer comment'
}
HEADROOT=$ROOT
echo "== S1a unconfigured home, this change ($(git -C "$WT" rev-parse --short HEAD))"
moves "$(setup unconf-head off)" | tee "$TMP_ROOT/head.txt"
echo "== S1b unconfigured home, base commit scripts (427056c4)"
ROOT=$BASE; moves "$(setup unconf-base off)" | tee "$TMP_ROOT/base.txt"; ROOT=$HEADROOT
if diff "$TMP_ROOT/base.txt" "$TMP_ROOT/head.txt" >/dev/null; then echo "== S1 RESULT: identical to base"; else echo "== S1 RESULT: DIFFERS"; diff "$TMP_ROOT/base.txt" "$TMP_ROOT/head.txt"; fi
echo "== S2 opted-in home (config/contribution-pr-movement present)"
moves "$(setup optin on)"
echo "== S3 enable after the movement was already observed, then remove"
h=$(setup late off)
printf '%s\n' "$HEAD_B" > "$h/forge/head"; registered_checks "$h" >/dev/null; show "$h" 'head A -> B while disabled'
touch "$h/config/contribution-pr-movement"; registered_checks "$h" >/dev/null; show "$h" 'flag created, re-poll'
printf '%s\n' "$HEAD_A" > "$h/forge/head"; registered_checks "$h" >/dev/null; show "$h" 'head B -> A while enabled'
rm "$h/config/contribution-pr-movement"
printf '%s\n' "$HEAD_B" > "$h/forge/head"; registered_checks "$h" >/dev/null; show "$h" 'flag removed, head A -> B'
echo "== S4 adversarial: flag path is a directory, not a regular file"
h=$(setup dirflag dir)
printf '%s\n' "$HEAD_B" > "$h/forge/head"; printf '[{"login":"reviewer"}]\n' > "$h/forge/requested.json"
registered_checks "$h" >/dev/null; show "$h" 'head moved + reviewer requested'
echo "== S5 adversarial: opted in, PR merges with a different head"
h=$(setup merged on)
printf '%s\n' "$HEAD_B" > "$h/forge/head"; printf 'merged\n' > "$h/forge/state"
registered_checks "$h" >/dev/null; show "$h" 'merged on head B'
echo "   stored state=$(jq -r '.records[0].observation.state' "$h/data/delivery/contributions.json")"
