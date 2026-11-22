#!/usr/bin/env bash
# Drives the real helper (which calls the real bin/fm-crew-state.sh), the real
# pending-reply library, and the real charter generator of <root> in disposable
# parent + secondmate homes, with config/reply-child-state toggled per scenario.
# The only stand-in is a tmux shim that lists the fixture children's windows.
set -u
umask 022
ROOT=$1
for v in $(env | sed -n 's/^\(FM_[A-Z_]*\)=.*/\1/p') NO_MISTAKES_GATE; do unset "$v"; done
export FM_PENDING_REPLY_GRACE_SECS=0 FM_PENDING_REPLY_NOW=9300
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
. "$ROOT/bin/fm-pending-reply-lib.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
T=$(mktemp -d /tmp/fm-8047-optin.XXXXXX); trap 'rm -rf "$T"' EXIT
FB=$T/fakebin; mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_STATE_OVERRIDE:-${FM_HOME:?}/state}"/*.meta 2>/dev/null ;;
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
chmod +x "$FB/tmux"; export PATH="$FB:$PATH"
norm() { sed -E "s#$T#<T>#g; s#$ROOT#<ROOT>#g; s/ \[at=[0-9]+\]//; s/[0-9a-f]{16}/<CORR>/g"; }
run() { printf '$ %s\n' "$*" | norm; "$@" 2>&1 | norm; printf '[exit %s]\n' "${PIPESTATUS[0]}"; }
pair() {  # <name> -> sets home mate state
  home=$T/$1-parent mate=$T/$1-mate state=$home/state
  mkdir -p "$home/state" "$home/data" "$home/config" "$mate/state" "$mate/config"
  printf 'kid\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$mate/.fm-secondmate-parent"
}
child() {  # <id> <kind> <busy|idle> <log-line>
  local id=$1 kind=$2 busy=$3 log=$4 wt=$mate/wt-$1 gen
  mkdir -p "$wt"
  if [ "$kind" = ship ]; then
    git -C "$wt" init -q; git -C "$wt" commit -q --allow-empty -m init
    git -C "$wt" update-ref refs/remotes/origin/main "$(git -C "$wt" rev-parse HEAD)"
  fi
  printf 'window=fm:fm-%s\nworktree=%s\nkind=%s\nmode=direct-PR\nharness=claude\n' "$id" "$wt" "$kind" > "$mate/state/$id.meta"
  printf '%s\n' "$log" > "$mate/state/$id.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$mate/state" "$id")
  if [ "$busy" = busy ]; then
    "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$id" busy --gen "$gen" --source claude-hook --event user-prompt-submit
  else
    "$ROOT/bin/fm-busy-event.sh" apply "$mate/state" "$id" idle --gen "$gen" --source claude-hook --event stop
  fi
}
ask() { corr=$(fm_pending_reply_create "$home" "$state" kid "$1"); fm_pending_reply_mark_delivered "$state" "$corr"; }
settle() {  # resolve and print what the parent recorded
  fm_pending_reply_try_resolve "$state" "$corr"; printf '[resolve exit %s]\n' $?
  printf 'mate reply line : %s\n' "$(grep -F "corr=$corr" "$state/kid.status" | tail -1 | norm)"
  printf 'parent record   : phase=%s resolved_via=%s %s\n' "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" phase)" \
    "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" \
    "$(grep -E '^reply_(child_id|child_state|overall)=' "$(fm_pending_reply_path "$state" "$corr")" | tr '\n' ' ')"
  [ -n "$(grep -E '^reply_' "$(fm_pending_reply_path "$state" "$corr")")" ] || echo 'parent record   : (no reply_child_* / reply_overall fields)'
}

echo "=== A. both homes opted in"
pair both; touch "$home/config/reply-child-state" "$mate/config/reply-child-state"
child repack scout busy 'done: spinner fix done; broader repacking work remains unfinished'
child scoutdone scout idle 'done: report written'
child shipready ship idle 'done: ready for merge'
child nopr ship idle 'done: spinner fix done'; git -C "$mate/wt-nopr" commit -q --allow-empty -m 'unpublished work'
for c in repack scoutdone shipready nopr; do run env FM_HOME="$mate" "$ROOT/bin/fm-crew-state.sh" "$c"; done
run env FM_HOME="$mate" "$REPORT"
echo "--- A1 unfinished (working) child, verb done"; ask q1; run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" "narrow fix done"; settle
echo "--- A2 finished scout"; ask q2; run env FM_HOME="$mate" "$REPORT" --task scoutdone "done" "$corr" "report written"; settle
echo "--- A3 finished ship through the document form"; ask q3; run env FM_HOME="$mate" "$REPORT" --task shipready --doc "done" "$corr" data/x/report.md "see report"; settle
echo "--- A4 ship with an undelivered commit"; ask q4; run env FM_HOME="$mate" "$REPORT" --task nopr "done" "$corr" "narrow fix done"; settle
echo "--- A5 no --task"; ask q5; run env FM_HOME="$mate" "$REPORT" "done" "$corr" "narrow fix done"; settle
echo "--- A6 unknown child id"; ask q6; run env FM_HOME="$mate" "$REPORT" --task no-such-child "done" "$corr" "narrow fix done"; settle
echo "--- A7 path-shaped child id pointing at the finished scout"; ask q7; run env FM_HOME="$mate" "$REPORT" --task ./scoutdone "done" "$corr" "narrow fix done"; settle
echo "--- A8 --task after the verb (wrong order)"; ask q8; run env FM_HOME="$mate" "$REPORT" "done" --task scoutdone "$corr" "x"
echo "--- A9 --task with no value"; run env FM_HOME="$mate" "$REPORT" --task
echo "--- A10 note that quotes a finished marker, sent with no --task"; ask q10; run env FM_HOME="$mate" "$REPORT" "done" "$corr" "all good (via-helper child=scoutdone child-state=done"; settle
echo "--- A11 note that quotes a finished marker, sent for the working child"; ask q11; run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" "all good (via-helper child=scoutdone child-state=done)"; settle
echo "--- A12 hand-written line (no helper) that quotes a finished marker"; ask q12; printf 'done [corr=%s]: all finished (child=x child-state=done)\n' "$corr" >> "$state/kid.status"; settle
echo "--- A13 hand-written no-child marker with a done verdict"; ask q13; printf 'done [corr=%s]: all finished (via-helper child=- child-state=done)\n' "$corr" >> "$state/kid.status"; settle
echo "--- A14 routine resolutions appended nothing: parent channel holds only the mate's own lines"
norm < "$state/kid.status"
echo "--- A15 missed twice -> escalation; late helper reply for the working child closes it with the result"
before=$(wc -l < "$state/kid.status")
ask "how far is the repacking"
fm_pending_reply_mark_turn_completed "$state" "$corr" request
FM_PENDING_REPLY_SEND_HOOK=true fm_pending_reply_send_recovery "$state" "$corr"; echo "[recovery exit $?]"
fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
fm_pending_reply_maybe_escalate "$state" "$corr"; echo "[escalate exit $?]"
run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" "narrow fix done"; settle
tail -n +$((before+1)) "$state/kid.status" | norm
echo "--- A16 opt-out again: remove the flag from both homes; earlier results stay, new replies record nothing"
old=$corr; rm "$home/config/reply-child-state" "$mate/config/reply-child-state"
ask q16; run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" "x"; run env FM_HOME="$mate" "$REPORT" "done" "$corr" "answered"; settle
printf 'earlier record  : %s\n' "$(grep -E '^reply_' "$(fm_pending_reply_path "$state" "$old")" | tr '\n' ' ')"

echo; echo "=== B. only the secondmate opted in (parent has no flag)"
pair mateonly; touch "$mate/config/reply-child-state"; child repack scout busy 'working: repacking'
ask q; run env FM_HOME="$mate" "$REPORT" --task repack "done" "$corr" "narrow fix done"; settle

echo; echo "=== C. only the parent opted in (secondmate has no flag)"
pair parentonly; touch "$home/config/reply-child-state"; child scoutdone scout idle 'done: report written'
ask q; run env FM_HOME="$mate" "$REPORT" --task scoutdone "done" "$corr" "report written"; run env FM_HOME="$mate" "$REPORT" "done" "$corr" "report written"; settle

echo; echo "=== D. FM_CONFIG_OVERRIDE selects the effective config directory"
pair override; mkdir -p "$T/ovr-on" "$T/ovr-off"; touch "$T/ovr-on/reply-child-state"; child scoutdone scout idle 'done: report written'
echo "--- D1 flag only in the override dir -> enabled"
export FM_CONFIG_OVERRIDE=$T/ovr-on
ask q; run env FM_HOME="$mate" "$REPORT" --task scoutdone "done" "$corr" "report written"; settle
echo "--- D2 flag only in home/config, override dir empty -> disabled"
touch "$home/config/reply-child-state" "$mate/config/reply-child-state"; export FM_CONFIG_OVERRIDE=$T/ovr-off
ask q; run env FM_HOME="$mate" "$REPORT" --task scoutdone "done" "$corr" "report written"; run env FM_HOME="$mate" "$REPORT" "done" "$corr" "report written"; settle
unset FM_CONFIG_OVERRIDE

echo; echo "=== E. charter generated by the parent"
pair charter
run env FM_HOME="$home" FM_SECONDMATE_CHARTER='Handle routed domain work.' "$ROOT/bin/fm-brief.sh" kid --secondmate --no-projects
cp "$home/data/kid/brief.md" "$T/charter-off.md"; rm -rf "$home/data/kid"
touch "$home/config/reply-child-state"
run env FM_HOME="$home" FM_SECONDMATE_CHARTER='Handle routed domain work.' "$ROOT/bin/fm-brief.sh" kid --secondmate --no-projects
echo "--- diff of the two generated charters (flag absent -> flag present)"
diff "$T/charter-off.md" "$home/data/kid/brief.md" | norm
