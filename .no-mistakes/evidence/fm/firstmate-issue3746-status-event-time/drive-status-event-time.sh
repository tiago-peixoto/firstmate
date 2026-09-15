#!/usr/bin/env bash
# Live driver: real firstmate CLIs against an isolated FM home.
set -u
ROOT=${ROOT:?}
T=$(mktemp -d /tmp/fm-evtime.XXXXXX)
export TMUX_TMPDIR=$T/tmux; mkdir -p "$TMUX_TMPDIR"   # isolated tmux server, never the user's
H=$T/home; SM=$H/secondmate-home
mkdir -p "$H/state" "$H/data" "$H/projects" "$H/config" "$SM/state" "$SM/data"
printf 'window=firstmate:fm-secondmate-task\nworktree=%s\nproject=%s\nharness=codex\nkind=secondmate\nmode=secondmate\nhome=%s\nprojects=alpha\n' "$SM" "$SM" "$SM" > "$H/state/secondmate-task.meta"
printf 'secondmate-task\n' > "$SM/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$H" > "$SM/.fm-secondmate-parent"
STATUS=$H/state/secondmate-task.status
snap() { FM_HOME="$H" FM_SNAPSHOT_NOW_EPOCH=$1 "$ROOT/bin/fm-fleet-snapshot.sh" --json; }
show() { jq '{last_event:(.tasks[]|select(.id=="secondmate-task")|.paths.status_log.last_event), open_decisions:(.tasks[]|select(.id=="secondmate-task")|.hints.open_decisions), secondmate_fallback:(.secondmate_current.records[]|select(.id=="secondmate-task")|{current_state:.current.state, parent_event:{raw:.parent_event.raw,emitted_at_epoch:.parent_event.emitted_at_epoch,age_seconds:.parent_event.age_seconds}, freshness_age:.freshness.age_seconds})}'; }

echo "=== S1: real fm-secondmate-report.sh emits a stamped parent status event ==="
before=$(date +%s)
( cd "$SM" && FM_HOME="$SM" "$ROOT/bin/fm-secondmate-report.sh" done 0123456789abcdef 'audit complete' ); rc=$?
after=$(date +%s)
echo "exit=$rc before=$before after=$after"
echo "--- $STATUS:"; cat "$STATUS"
line=$(tail -1 "$STATUS")
. "$ROOT/bin/fm-classify-lib.sh"
ep=$(status_line_at_epoch "$line") && [ "$ep" -ge "$before" ] && [ "$ep" -le "$after" ] && echo "RESULT S1: PASS (at=$ep within emission window)" || echo "RESULT S1: FAIL"

echo; echo "=== S2: fleet snapshot exposes emission time and age for the stamped event ==="
touch -t 202001010000 "$STATUS"   # file mtime deliberately unrelated
out=$(snap $((ep + 42))); printf '%s' "$out" | show
printf '%s' "$out" | jq -e --argjson ep "$ep" '.tasks[]|select(.id=="secondmate-task")|.paths.status_log.last_event|.emitted_at_epoch==$ep and .age_seconds==42' >/dev/null && echo "RESULT S2: PASS" || echo "RESULT S2: FAIL"

echo; echo "=== S3: legacy / malformed / duplicate / future tags keep an unknown age (no mtime fallback) ==="
s3=PASS
for l in 'working: legacy unstamped line' 'working [at=oops]: malformed' 'working [at=0123]: leading zero' 'working [at=1700000000] [at=1700000001]: duplicate' 'working [at=1700000200]: future event'; do
  printf '%s\n' "$l" > "$STATUS"; touch -t 202001010000 "$STATUS"
  o=$(snap 1700000100)
  r=$(printf '%s' "$o" | jq -c '.tasks[]|select(.id=="secondmate-task")|.paths.status_log.last_event|{raw,state,emitted_at_epoch,age_seconds}')
  echo "$r"
  case "$l" in
    *future*) printf '%s' "$r" | jq -e '.emitted_at_epoch==1700000200 and .age_seconds==null' >/dev/null || s3=FAIL ;;
    *) printf '%s' "$r" | jq -e '.emitted_at_epoch==null and .age_seconds==null' >/dev/null || s3=FAIL ;;
  esac
done
echo "RESULT S3: $s3"

echo; echo "=== S4 (adversarial): out-of-order timestamps never decide current state or decision closure ==="
cat > "$STATUS" <<'L'
needs-decision [key=api-shape] [at=1700000900]: choose REST or GraphQL
working [at=1700000950]: waiting on answer
resolved [key=api-shape] [at=1700000001]: answered: use REST
working [at=1600000000]: implementing REST
L
cat "$STATUS"
o=$(snap 1700001000); printf '%s' "$o" | show
printf '%s' "$o" | jq -e '(.tasks[]|select(.id=="secondmate-task")) as $t | $t.paths.status_log.last_event.note=="implementing REST" and $t.paths.status_log.last_event.state=="working" and ($t.hints.open_decisions|length)==0' >/dev/null && s4a=PASS || s4a=FAIL
echo "latest-line-wins despite older stamp, resolved closes despite older stamp: $s4a"
# Converse: a stamped close for a DIFFERENT key must not close, even with a newer time
cat > "$STATUS" <<'L'
needs-decision [key=api-shape] [at=1700000001]: choose REST or GraphQL
resolved [key=other] [at=1700000999]: unrelated
done [at=1700000999]: PR https://github.com/example/repo/pull/1
L
o=$(snap 1700001000); printf '%s' "$o" | jq -c '.tasks[]|select(.id=="secondmate-task")|{last_state:.paths.status_log.last_event.state, open_decisions:.hints.open_decisions}'
printf '%s' "$o" | jq -e '(.tasks[]|select(.id=="secondmate-task")) as $t | $t.paths.status_log.last_event.state=="done" and ($t.hints.open_decisions|length)==1' >/dev/null && s4b=PASS || s4b=FAIL
echo "later done/newer-stamp does not close keyed decision: $s4b"
[ $s4a = PASS ] && [ $s4b = PASS ] && echo "RESULT S4: PASS" || echo "RESULT S4: FAIL"

echo; echo "=== S5: classifier treats stamped terminal lines like unstamped ones ==="
s5=PASS
for l in 'done [at=1700000000]: PR https://x/pull/1' 'failed [at=1700000000]: agy never showed its folder-trust dialog' 'needs-decision [key=k] [at=1700000000]: pick'; do
  status_is_captain_relevant "$l" && echo "captain-relevant: $l" || { echo "NOT relevant: $l"; s5=FAIL; }
done
printf 'working [corr=abc] [at=1700000000]: x\n' > "$T/dedup.status"
status_event_recorded "$T/dedup.status" 'working [corr=abc]: x' && echo "retry dedup ignores time tag: yes" || s5=FAIL
status_event_recorded "$T/dedup.status" 'working [corr=abd]: x' && s5=FAIL || echo "different corr still distinct: yes"
echo "RESULT S5: $s5"

echo; echo "=== S6: generated worker brief instructs stamped status lines, and executing it yields a known-time event ==="
mkdir -p "$H/projects/alpha"; git -C "$H/projects/alpha" init -q 2>/dev/null
b=$(cd "$ROOT" && FM_HOME="$H" "$ROOT/bin/fm-brief.sh" demo-task alpha --mode direct-PR 2>&1); echo "$b" | tail -2
brief=$(ls "$H"/data/demo-task/brief.md 2>/dev/null || find "$H" -name 'brief*.md' | head -1)
grep -n 'at=\$(date +%s)' "$brief" | head -3
cmd=$(grep -o '`echo "{state} \[at=$(date +%s)\]: {one short line}" >> [^`]*`' "$brief" | head -1 | tr -d '`')
cmd=${cmd//\{state\}/done}; cmd=${cmd//\{one short line\}/PR https:\/\/github.com\/example\/repo\/pull\/2}
echo "executing brief instruction: $cmd"; b0=$(date +%s); eval "$cmd"; b1=$(date +%s)
sf=$(printf '%s' "$cmd" | sed -E "s/.*>> //; s/'//g"); tail -1 "$sf"
e=$(status_line_at_epoch "$(tail -1 "$sf")") && [ "$e" -ge "$b0" ] && [ "$e" -le "$b1" ] && echo "RESULT S6: PASS" || echo "RESULT S6: FAIL"
rm -rf "$T"
