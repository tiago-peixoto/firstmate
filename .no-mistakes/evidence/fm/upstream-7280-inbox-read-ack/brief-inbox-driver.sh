#!/usr/bin/env bash
# Generates every crewmate scaffold with the real bin/fm-brief.sh in a throwaway
# FM_HOME, prints the emitted "Firstmate instruction inbox" section, then runs the
# emitted receipt command and the file-tool fallback paths exactly as written.
set -u
ROOT=$PWD
H=$(mktemp -d /tmp/fm-lab.XXXXXX)
trap 'rm -rf "$H"' EXIT
ST=0
for kind in no-mistakes direct-PR local-only scout; do
  if [ "$kind" = scout ]; then
    FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --scout >/dev/null || { echo "FAIL: $kind scaffold"; ST=1; }
  else
    FM_HOME="$H" "$ROOT/bin/fm-brief.sh" "$kind" arbitrary-project-name --mode "$kind" >/dev/null || { echo "FAIL: $kind scaffold"; ST=1; }
  fi
done
FM_HOME="$H" FM_SECONDMATE_CHARTER='Supervise assigned work.' "$ROOT/bin/fm-brief.sh" supervisor --secondmate --no-projects >/dev/null || { echo "FAIL: secondmate scaffold"; ST=1; }
for kind in no-mistakes direct-PR local-only scout supervisor; do
  b="$H/data/$kind/brief.md"
  echo "=================== $kind: generated inbox section of $b"
  awk '/^# Firstmate instruction inbox/{p=1;print;next} p&&/^# /{p=0} p' "$b"
  grep -q "use your file tools to create $H/state/$kind.inbox/.read/ if needed, then create the empty receipt $H/state/$kind.inbox/.read/NNN.msg" "$b" \
    && echo "PASS: $kind file-tool fallback names the unquoted receipt path" || { echo "FAIL: $kind fallback path"; ST=1; }
  grep -q "use your file tools to create '" "$b" && { echo "FAIL: $kind fallback is shell-quoted"; ST=1; } || echo "PASS: $kind fallback carries no shell quotes"
  grep -q "mv '$H/state/$kind.inbox'/NNN.msg '$H/state/$kind.inbox'/handled/" "$b" && echo "PASS: $kind keeps the quoted handled/ move" || { echo "FAIL: $kind handled move"; ST=1; }
  cmd=$(sed -n 's/^Immediately after reading each message.*: `\(.*\)`\.$/\1/p' "$b")
  echo "emitted receipt command: $cmd"
  rec=$(FM_STATE_OVERRIDE="$H/state" bash -c '. "$1"; fm_task_inbox_write "$2" "$3" "steer for $3"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$H/state" "$kind") || { echo "FAIL: steer write"; ST=1; }
  if bash -c "${cmd//NNN/001}" && [ -f "$H/state/$kind.inbox/.read/001.msg" ] && [ -f "$rec" ]; then
    echo "PASS: $kind emitted receipt command, run as a shell command, created .read/001.msg and left 001.msg pending"
  else echo "FAIL: $kind emitted command"; ST=1; fi
  rm -rf "$H/state/$kind.inbox/.read"
  fb=$(sed -n 's/^If the command fails or cannot run, use your file tools to create \(.*\) if needed, then create the empty receipt \(.*\) for the message you just read\.$/\1 \2/p' "$b")
  set -- $fb
  echo "fallback dir as printed: $1"; echo "fallback receipt as printed: $2"
  if mkdir -p "$1" && : > "${2//NNN/001}" && [ -f "$H/state/$kind.inbox/.read/001.msg" ]; then
    echo "PASS: $kind fallback paths, used literally as a file tool would, create the same receipt"
  else echo "FAIL: $kind fallback literal path"; ST=1; fi
  act=$(FM_STATE_OVERRIDE="$H/state" FM_TASK_INBOX_GRACE_SECS=0 bash -c '. "$1"; fm_task_inbox_due_action "$2" "$3"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$H/state" "$kind")
  [ "$act" = quiet ] && echo "PASS: $kind ladder quiet after the file-tool receipt (due action: $act)" || { echo "FAIL: due action $act"; ST=1; }
done
echo "=================== polytoken system prompt (rendered by bin/fm-polytoken-lib.sh)"
grep -n '^fm_polytoken_[a-z_]*() *{' "$ROOT/bin/fm-polytoken-lib.sh" | head -30
echo "RESULT: $([ $ST = 0 ] && echo ALL PASS || echo FAILURES)"
exit $ST
