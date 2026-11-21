#!/usr/bin/env bash
# Drives the real fm-pr-check.sh, its registered contribution check, and
# fm-contributions.sh pending in disposable homes against a local gh emulator
# (the fixture functions are lifted unchanged from tests/fm-contributions.test.sh).
set -u
WT=$1 TMP_ROOT=$2 BASE=$3
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
fail() { printf 'FIXTURE FAIL: %s\n' "$*"; exit 1; }
for f in new_home record forge_home with_home registered_checks queued_wakes; do
  eval "$(awk -v f="$f" '$0 ~ "^"f"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$WT/tests/fm-contributions.test.sh")"
done
show() { # home label
  printf -- '--- %s\n' "$2"
  printf 'pending: '; with_home "$1" "$ROOT/bin/fm-contributions.sh" pending | jq -c '.[] | {type,body,head}'
  printf 'queued check wakes: %s\n' "$(queued_wakes "$1")"
}
setup() { # name on|off
  local home; home=$(new_home "$1"); forge_home "$home" >&2
  [ "$2" = off ] || touch "$home/config/contribution-pr-movement"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null || fail register
  registered_checks "$home" >/dev/null
  printf '%s\n' "$home"
}
move_all() { # home: head replaced, draft->ready, reviewer and team requested
  printf 'true\n' > "$1/forge/draft"; registered_checks "$1" >/dev/null
  printf 'false\n' > "$1/forge/draft"
  printf '%s\n' "$HEAD_B" > "$1/forge/head"
  printf '[{"login":"reviewer"}]\n' > "$1/forge/requested.json"
  printf '[{"slug":"core","name":"Core"}]\n' > "$1/forge/teams.json"
  registered_checks "$1" >/dev/null
}
maintainer_comment() {
  jq -n '[{id:12,user:{login:"maintainer"},author_association:"OWNER",body:"Please clarify the contract",
    html_url:"https://github.com/o/r/pull/8#issuecomment-12",updated_at:"2026-09-16T08:01:00Z",submitted_at:"2026-09-16T08:01:00Z"}]' \
    > "$1/forge/comments.json"
  registered_checks "$1" >/dev/null
}

ROOT=$WT
echo "===== S1: UNCONFIGURED home (no config/contribution-pr-movement), branch code"
h=$(setup s1-off off); ls "$h/config"; show "$h" "after first poll, nothing moved"
move_all "$h"; show "$h" "after head replaced + left draft + reviewer + team requested"
jq -c '.records[0].observation | {head,draft,review_requests}' "$h/data/delivery/contributions.json"
maintainer_comment "$h"; show "$h" "after a maintainer comment (existing trigger must still wake)"
S1_PENDING=$(with_home "$h" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[]|{type,body,head,token}]'); S1_WAKES=$(queued_wakes "$h")
S1_VIEW=$(with_home "$h" "$ROOT/bin/fm-contributions.sh" pending | jq -S .)

echo; echo "===== S2: ENABLE after the fact - no replay; then new movement wakes"
touch "$h/config/contribution-pr-movement"; registered_checks "$h" >/dev/null
show "$h" "file created, re-polled, forge unchanged (only the maintainer comment may be pending)"
printf '[{"login":"reviewer"},{"login":"second"}]\n' > "$h/forge/requested.json"; registered_checks "$h" >/dev/null
show "$h" "a second reviewer requested while enabled"

echo; echo "===== S3: CONFIGURED home, each trigger wakes exactly once"
h=$(setup s3-on on); show "$h" "after first poll, nothing moved"
move_all "$h"; show "$h" "after head replaced + left draft + reviewer + team requested (one wake per signal)"
registered_checks "$h" >/dev/null; registered_checks "$h" >/dev/null
show "$h" "two unchanged re-polls"

echo; echo "===== S4: REMOVE the file - new movement silent, pending kept"
rm "$h/config/contribution-pr-movement"
printf '%s\n' "$HEAD_A" > "$h/forge/head"; printf '[{"login":"reviewer"},{"login":"third"}]\n' > "$h/forge/requested.json"
registered_checks "$h" >/dev/null; show "$h" "file removed, head replaced again, third reviewer requested"

echo; echo "===== S5: ADVERSARIAL - directory at the config path, and merged PR while enabled"
h=$(setup s5-dir off); mkdir "$h/config/contribution-pr-movement"
printf '%s\n' "$HEAD_B" > "$h/forge/head"; registered_checks "$h" >/dev/null
show "$h" "config/contribution-pr-movement is a directory, head replaced"
h=$(setup s5-merged on); printf 'merged\n' > "$h/forge/state"; printf '%s\n' "$HEAD_B" > "$h/forge/head"
printf '[{"login":"reviewer"}]\n' > "$h/forge/requested.json"; registered_checks "$h" >/dev/null
show "$h" "enabled, PR merged with a different head and a reviewer"

echo; echo "===== S6: UNCONFIGURED home on base 427056c4 (main) - same steps as S1"
ROOT=$BASE
h=$(setup s6-base off); move_all "$h"; maintainer_comment "$h"; show "$h" "main: after all movement + maintainer comment"
B_PENDING=$(with_home "$h" "$ROOT/bin/fm-contributions.sh" pending | jq -c '[.[]|{type,body,head,token}]'); B_WAKES=$(queued_wakes "$h")
B_VIEW=$(with_home "$h" "$ROOT/bin/fm-contributions.sh" pending | jq -S .)
[ "$S1_PENDING" = "$B_PENDING" ] && [ "$S1_WAKES" = "$B_WAKES" ] && [ "$S1_VIEW" = "$B_VIEW" ] \
  && echo "RESULT: unconfigured branch home == main (pending view byte-identical, wakes $S1_WAKES == $B_WAKES)" \
  || { echo "RESULT: DIFFERS from main"; diff <(printf '%s\n' "$S1_VIEW") <(printf '%s\n' "$B_VIEW"); }
