#!/usr/bin/env bash
# usage: drive.sh <repo-root> ; drives the real fm-captain-hold.sh + real tasks-axi in a throwaway home
set -u
ROOT=$1
H=$(mktemp -d /tmp/fm-8152-home.XXXXXX)
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$H/fakebin/$t"; chmod +x "$H/fakebin/$t"; done
cap() { PATH="$H/fakebin:$PATH" REAL_TASKS_AXI="$(command -v tasks-axi)" FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
show() { (cd "$H" && tasks-axi show "$1" --full); }
step() { printf '\n===== %s =====\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
hold() { cap hold "$1" --title "Choose the start state" --reason "Should the feature start enabled? A: Off until checks pass. B: On now." --repo sample >/dev/null || echo "HOLD FAILED $1"; }
feed() { printf '$ printf %q | fm-captain-hold.sh answers --source "interview"\n' "$1"; printf "$1" | cap answers --source "interview"; printf '[exit %s]\n' "$?"; }
state() { show "$1" | grep -E '^ *(state|held):|Answer|Selected answer|Captain decision|Resolution mode' ; }

step "S1 keyed option letter, no label (issue #8152 repro)"
hold q1; feed 'q1\tA\t\n'; state q1
step "S2 keyed option letter WITH displayed label"
feed 'q1\tA\tOff until checks pass.\n'; state q1
run cap open q1
step "S3 direct answer, decision file holding only 'A'"
hold q2; printf 'A\n' > "$H/a.txt"; run cap answer q2 --decision-file "$H/a.txt"; state q2
step "S4 adversarial option shapes without meaning"
i=0; for s in b 7 '(c)' 'D.' 'e)' 'A ' ' b'; do i=$((i+1)); hold "adv$i"; feed "adv$i\t$s\t\n"; state "adv$i"; done
hold adv8; feed 'adv8\tA\t \n'; state adv8
hold adv9; printf ' (B) \n' > "$H/b.txt"; run cap answer adv9 --decision-file "$H/b.txt"; state adv9
step "S5 free text unchanged (keyed, no label; keyed, blank label; direct file)"
hold f1; feed 'f1\tKeep it off for now\t\n'; state f1
hold f2; feed 'f2\tKeep it off for now\t \n'; state f2
hold f3; printf 'Keep it off until the checks pass.\n' > "$H/f.txt"; run cap answer f3 --decision-file "$H/f.txt"; state f3
step "S6 selected-answer field shapes on direct answer"
hold m1; printf 'From chat:\nAnswer: Off until checks pass.\nBecause the gate is flaky.\n' > "$H/m1.txt"; run cap answer m1 --decision-file "$H/m1.txt"; show m1 | grep -n -A1 'Selected answer'
hold m2; printf 'Answer: Off until checks pass.\nBecause the gate is flaky.\n' > "$H/m2.txt"; run cap answer m2 --decision-file "$H/m2.txt"; show m2 | grep -n -A1 'Selected answer'
hold m3; printf 'Go with the guard.\nBecause CI is flaky.\n' > "$H/m3.txt"; run cap answer m3 --decision-file "$H/m3.txt"; echo "Selected answer lines: $(show m3 | grep -c 'Selected answer')"
step "S7 interview flow: register, feed keyed answers, verify closure + Bearings"
hold iv1; hold iv2
feed 'iv1\tB\tOn now.\niv2\tA\tOff until checks pass.\n'
state iv1; state iv2
run cap open iv1; run cap open iv2
PATH="$H/fakebin:$PATH" FM_HOME="$H" "$ROOT/bin/fm-bearings-snapshot.sh" --json > "$H/bearings.json" 2>"$H/bearings.err"; echo "[bearings exit $?]"
echo "decisions_open ids in Bearings: $(jq -c "[.decisions_open[].id]" "$H/bearings.json")"
step "full durable record of q1"
show q1
rm -rf "$H"
