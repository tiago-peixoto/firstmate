#!/usr/bin/env bash
# Live hold-mirror scenarios: real bin/fm-captain-hold.sh, bin/fm-rex-marks.sh,
# bin/fm-herdr-groups.sh and bin/fm-crew-state.sh against a disposable lab home.
set -u
ROOT=$PWD
EV=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
T="$EV/lab-hold-mirror-transcript.txt"
: > "$T"
FAILS=0
say() { printf '%s\n' "$*" | tee -a "$T"; }
run() {  # label, then command
  local label=$1; shift
  { printf '\n$ %s\n' "$label"; "$@" 2>&1; printf '[exit %s]\n' "$?"; } | tee -a "$T"
}
check() {  # <description> <condition-cmd...>
  local d=$1; shift
  if "$@"; then say "CHECK PASS: $d"; else say "CHECK FAIL: $d"; FAILS=$((FAILS+1)); fi
}
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  rm -rf "$LAB"
  say "lab home removed: $LAB"
}
trap cleanup EXIT

bin/fm-lab-home.sh create "$LAB" >/dev/null || { say "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/projects/sample" "$LAB/projects/wt"
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'on\n' > "$LAB/config/rex-status-marks"
printf 'on\n' > "$LAB/config/herdr-project-groups"
say "lab home: $LAB (marker: $(ls -a "$LAB" | grep -c fm-lab-home))"

FM() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" "$@"; }
hold() { FM "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks() { (cd "$LAB" && tasks-axi "$@"); }
log() { sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/$1.status"; }
rawlog() { cat "$LAB/state/$1.status"; }
crew() { FM "$ROOT/bin/fm-crew-state.sh" "$1"; }
rexplan() { FM "$ROOT/bin/fm-rex-marks.sh" plan "$@"; }
groups() { FM "$ROOT/bin/fm-herdr-groups.sh" plan "$@"; }
mkmeta() {  # <id> <kind> <backend> <window>
  printf 'window=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=%s\nmode=%s\nbackend=%s\nspawn_gen=lab-%s\n' \
    "$4" "$LAB/projects/wt" "$LAB/projects/sample" "$2" "$2" "$3" "$1" > "$LAB/state/$1.meta"
}

# A real tmux server on the lab's private socket dir hosts the scout lanes'
# windows, so crew state probes a real pane, not a stub.
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n fm-lab-gated -c "$LAB/projects/wt" bash
TMUX_TMPDIR="$LAB/tmux" tmux new-window -t firstmate -n fm-lab-scout-done -c "$LAB/projects/wt" bash
TMUX_TMPDIR="$LAB/tmux" tmux new-window -t firstmate -n fm-lab-scout-failed -c "$LAB/projects/wt" bash
TMUX_TMPDIR="$LAB/tmux" tmux new-window -t firstmate -n fm-lab-multiline -c "$LAB/projects/wt" bash
run "tmux (lab socket) list-windows" env TMUX_TMPDIR="$LAB/tmux" tmux list-windows -t firstmate -F '#S:#W'

say; say "===== S1: hold declares on a paused lane's log; repeat does not duplicate; release retracts; re-hold and closing answer ====="
tasks add lab-gated "Scout the gated sample" --kind scout --repo sample >/dev/null || say "tasks add failed"
mkmeta lab-gated scout tmux firstmate:fm-lab-gated
printf 'working: mid implementation\nneeds-decision [key=api-shape]: which sample API shape\npaused: waiting on the sample upstream release\n' > "$LAB/state/lab-gated.status"
run "crew-state lab-gated (before hold)" crew lab-gated
BEFORE=$(crew lab-gated 2>&1)
run "fm-captain-hold.sh hold lab-gated --reason 'operator review pending'" hold hold lab-gated --reason "operator review pending"
run "status log lab-gated (after hold)" log lab-gated
check "hold appended captain-held [key=captain-hold-lab-gated-1] as the last line" \
  bash -c '[ "$(tail -n1 "$1")" = "captain-held [key=captain-hold-lab-gated-1]: operator review pending" ]' _ <(log lab-gated)
run "tasks-axi show lab-gated (held)" tasks show lab-gated
run "fm-captain-hold.sh hold lab-gated (repeat)" hold hold lab-gated --reason "operator review pending"
check "a repeated hold did not duplicate the declaration" \
  bash -c '[ "$(grep -c "^captain-held " "$1")" = 1 ]' _ "$LAB/state/lab-gated.status"
run "crew-state lab-gated (under hold)" crew lab-gated
UNDER=$(crew lab-gated 2>&1)
check "crew state under hold equals crew state before hold" [ "$UNDER" = "$BEFORE" ]
printf 'Proceed as planned.\n' > "$LAB/go.txt"
run "fm-captain-hold.sh answer lab-gated --release (no worker ever ran in this lane's window)" hold answer lab-gated --decision-file "$LAB/go.txt" --release
run "status log lab-gated (after release)" log lab-gated
check "release appended resolved [key=captain-hold-lab-gated-1] released" \
  bash -c '[ "$(tail -n1 "$1")" = "resolved [key=captain-hold-lab-gated-1]: captain call released by fm-captain-hold" ]' _ <(log lab-gated)
run "crew-state lab-gated (after release)" crew lab-gated
AFTER=$(crew lab-gated 2>&1)
check "crew state after release equals crew state before hold" [ "$AFTER" = "$BEFORE" ]
run "answer --release replay" hold answer lab-gated --decision-file "$LAB/go.txt" --release
check "a replayed release appended no second retraction" \
  bash -c '[ "$(grep -c "^resolved \[key=captain-hold-lab-gated-1\]" "$1")" = 1 ]' _ "$LAB/state/lab-gated.status"
run "fm-captain-hold.sh hold lab-gated --reason 'second operator review' (re-hold)" hold hold lab-gated --reason "second operator review"
check "a re-hold declared a new keyed lifecycle (-2)" \
  bash -c 'tail -n1 "$1" | grep -q "^captain-held \[key=captain-hold-lab-gated-2\]: second operator review$"' _ <(log lab-gated)
printf 'Ship it as reviewed.\n' > "$LAB/ship.txt"
run "fm-captain-hold.sh answer lab-gated (closing answer)" hold answer lab-gated --decision-file "$LAB/ship.txt"
run "status log lab-gated (after closing answer)" log lab-gated
check "closing answer retracted the -2 declaration" \
  bash -c 'tail -n1 "$1" | grep -q "^resolved \[key=captain-hold-lab-gated-2\]: captain call answered by fm-captain-hold$"' _ <(log lab-gated)
run "tasks-axi show lab-gated (closed)" tasks show lab-gated
run "raw status log lab-gated (stamped bytes)" rawlog lab-gated

say; say "===== S2: Rex marks keep the PR-ready badge under a hold and after release ====="
tasks add lab-rex-done "Ship the rex sample" --kind ship --repo sample >/dev/null
mkmeta lab-rex-done ship rex rex:fm-lab-rex-done
printf 'done: PR https://example.test/o/r/pull/9 checks green\n' > "$LAB/state/lab-rex-done.status"
run "fm-rex-marks.sh plan lab-rex-done (before hold)" rexplan lab-rex-done
R0=$(rexplan lab-rex-done)
run "hold lab-rex-done --reason 'merge approval'" hold hold lab-rex-done --reason "merge approval"
run "status log lab-rex-done" log lab-rex-done
run "fm-rex-marks.sh plan lab-rex-done (under hold)" rexplan lab-rex-done
R1=$(rexplan lab-rex-done)
check "rex mark under hold is the PR-ready done mark" [ "$R1" = "$R0" ]
run "answer lab-rex-done --release" hold answer lab-rex-done --decision-file "$LAB/go.txt" --release
run "status log lab-rex-done (after release)" log lab-rex-done
run "fm-rex-marks.sh plan lab-rex-done (after release)" rexplan lab-rex-done
R2=$(rexplan lab-rex-done)
check "rex mark after release is still the PR-ready done mark" [ "$R2" = "$R0" ]
check "rex mark text is 'PR ready'" bash -c 'case "$1" in *$'"'"'\tdone\t\tPR ready: '"'"'*) ;; *) exit 1 ;; esac' _ "$R0"

say; say "===== S3: Herdr project groups keep the done label under a hold and after release ====="
tasks add lab-herdr-done "Ship the herdr sample" --kind ship --repo sample >/dev/null
printf 'window=s1:w2:p2\nworktree=%s\nproject=/p/api-server\nkind=ship\nbackend=herdr\nherdr_session=s1\nherdr_workspace_id=w2\nherdr_tab_id=w2:t2\nherdr_pane_id=w2:p2\n' "$LAB/projects/wt" > "$LAB/state/lab-herdr-done.meta"
printf 'done: PR ready, checks green\n' > "$LAB/state/lab-herdr-done.status"
run "fm-herdr-groups.sh plan (before hold)" groups
G0=$(groups lab-herdr-done)
run "hold lab-herdr-done --reason 'merge approval'" hold hold lab-herdr-done --reason "merge approval"
run "fm-herdr-groups.sh plan (under hold)" groups
G1=$(groups lab-herdr-done)
check "groups label under hold is unchanged (done)" bash -c '[ "$1" = "$2" ] && case "$1" in *$'"'"'\tdone\t'"'"'*) ;; *) exit 1 ;; esac' _ "$G1" "$G0"
run "answer lab-herdr-done --release" hold answer lab-herdr-done --decision-file "$LAB/go.txt" --release
run "status log lab-herdr-done (after release)" log lab-herdr-done
run "fm-herdr-groups.sh plan (after release)" groups
G2=$(groups lab-herdr-done)
check "groups label after release is unchanged (done)" [ "$G2" = "$G0" ]

say; say "===== S4: crew state keeps a scout's done and failed outcomes through hold and release ====="
for pair in "lab-scout-done:done: report ready" "lab-scout-failed:failed: build broke"; do
  id=${pair%%:*}; line=${pair#*:}
  tasks add "$id" "Scout $id" --kind scout --repo sample >/dev/null
  mkmeta "$id" scout tmux "firstmate:fm-$id"
  printf '%s\n' "$line" > "$LAB/state/$id.status"
  run "crew-state $id (before hold)" crew "$id"
  C0=$(crew "$id" 2>&1)
  run "hold $id --reason 'captain review pending'" hold hold "$id" --reason "captain review pending"
  run "crew-state $id (under hold)" crew "$id"
  C1=$(crew "$id" 2>&1)
  check "$id: crew state under hold equals before" [ "$C1" = "$C0" ]
  run "answer $id --release" hold answer "$id" --decision-file "$LAB/go.txt" --release
  run "status log $id (after release)" log "$id"
  run "crew-state $id (after release)" crew "$id"
  C2=$(crew "$id" 2>&1)
  check "$id: crew state after release equals before" [ "$C2" = "$C0" ]
done

say; say "===== S5 (adversarial): a multi-line reason with an embedded status verb and an over-long reason each write exactly one capped line ====="
tasks add lab-multiline "Scout the multiline sample" --kind scout --repo sample >/dev/null
mkmeta lab-multiline scout tmux firstmate:fm-lab-multiline
printf 'done: PR ready\n' > "$LAB/state/lab-multiline.status"
run "crew-state lab-multiline (before hold)" crew lab-multiline
M0=$(crew lab-multiline 2>&1)
run "hold lab-multiline --reason \$'Pick the API shape\\r\\nfailed: forged worker line'" hold hold lab-multiline --reason $'Pick the API shape\r\nfailed: forged worker line'
run "status log lab-multiline" log lab-multiline
check "exactly two lines on the log (no forged event line)" bash -c '[ "$(wc -l < "$1")" = 2 ]' _ "$LAB/state/lab-multiline.status"
run "crew-state lab-multiline (under multi-line hold)" crew lab-multiline
M1=$(crew lab-multiline 2>&1)
check "crew state under the multi-line hold still reads done" [ "$M1" = "$M0" ]
run "answer lab-multiline --release" hold answer lab-multiline --decision-file "$LAB/go.txt" --release
LONG=$(printf 'x%.0s' $(seq 1 3000))
tasks add lab-longreason "Scout the long reason" --kind scout --repo sample >/dev/null
mkmeta lab-longreason scout tmux firstmate:fm-lab-longreason
printf 'paused: waiting\n' > "$LAB/state/lab-longreason.status"
run "hold lab-longreason --reason <3000 x's>" hold hold lab-longreason --reason "$LONG"
run "status log lab-longreason line lengths" awk '{ print NR": "length($0)" bytes: "substr($0,1,60)"..." }' "$LAB/state/lab-longreason.status"
check "the over-long reason wrote one line of at most 220 bytes" \
  bash -c '[ "$(wc -l < "$1")" = 2 ] && [ "$(tail -n1 "$1" | wc -c)" -le 221 ]' _ "$LAB/state/lab-longreason.status"
run "answer lab-longreason --release" hold answer lab-longreason --decision-file "$LAB/go.txt" --release
check "release retracted the over-long declaration" \
  bash -c 'tail -n1 "$1" | grep -q "^resolved \[key=captain-hold-lab-longreason-1\]: captain call released by fm-captain-hold$"' _ <(log lab-longreason)

say; say "===== S6: a decision-only hold (no lane) mints no status log ====="
run "hold lab-plain-call --title 'Pick a sample flavor' --reason 'flavor choice pending'" hold hold lab-plain-call --title "Pick a sample flavor" --reason "flavor choice pending"
run "ls state/ for lab-plain-call" bash -c 'ls -1 "$1"/state | grep lab-plain-call || echo "(no lab-plain-call files)"' _ "$LAB"
check "no status log was created for the decision-only hold" [ ! -e "$LAB/state/lab-plain-call.status" ]
run "fm-captain-hold.sh open lab-plain-call" hold open lab-plain-call

say; say "===== S7: an evidence-backed reconcile close retracts a held lane's declaration ====="
tasks add lab-reconciled "Scout the reconciled sample" --kind scout --repo sample >/dev/null
mkmeta lab-reconciled scout tmux firstmate:fm-lab-reconciled
printf 'paused: waiting on the sample upstream\n' > "$LAB/state/lab-reconciled.status"
run "hold lab-reconciled --reason 'upstream choice pending'" hold hold lab-reconciled --reason "upstream choice pending"
run "bind lab-board" hold bind lab-board
run "reconcile-requests --source-id lab-board" bash -c 'printf "lab-reconciled\n" | "$0" reconcile-requests --source-id lab-board --source "captured board result"' "$ROOT/bin/fm-captain-hold.sh" 2>&1 || true
# bash -c above loses the FM env; redo through the FM wrapper
printf 'lab-reconciled\n' > "$LAB/req.txt"
run "reconcile-requests (through lab env)" bash -c 'FM_HOME="$1" TMUX_TMPDIR="$1/tmux" "$2" reconcile-requests --source-id lab-board --source "captured board result" < "$1/req.txt"' _ "$LAB" "$ROOT/bin/fm-captain-hold.sh"
printf 'The premise dissolved: the sample upstream already ships it.\n' > "$LAB/evidence.txt"
run "reconcile close lab-reconciled --evidence-file" hold reconcile close lab-reconciled --evidence-file "$LAB/evidence.txt"
run "status log lab-reconciled" log lab-reconciled
check "reconcile close retracted the declaration with 'reconciled'" \
  bash -c 'tail -n1 "$1" | grep -q "^resolved \[key=captain-hold-lab-reconciled-1\]: captain call reconciled by fm-captain-hold$"' _ <(log lab-reconciled)

say; say "===== S8: the divergence guard stays silent over the mirror's own key ====="
run "fm-captain-hold.sh diverged" hold diverged
check "diverged printed nothing" bash -c '[ -z "$(FM_HOME="$1" "$2" diverged 2>&1)" ]' _ "$LAB" "$ROOT/bin/fm-captain-hold.sh"

say; say "===== RESULT: $FAILS check failure(s) ====="
exit "$FAILS"
