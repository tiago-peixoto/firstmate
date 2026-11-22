#!/usr/bin/env bash
# Live driver: runs the real bin/fm-captain-hold.sh and the real tasks-axi
# against disposable homes. Usage: drive.sh <worktree> <base-bin-root>
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-answer-words.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REAL_TASKS_AXI=$(command -v tasks-axi)
export FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z
FAILS=0

make_home() {  # <name> [config flags...]
  local home="$TMP/$1" tool
  shift
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  for tool in tmux treehouse no-mistakes gh gh-axi; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$home/fakebin/$tool"; chmod +x "$home/fakebin/$tool"
  done
  for tool in "$@"; do touch "$home/config/$tool"; done
  printf '%s\n' "$home"
}

cap() {  # <root> <home> <args...>
  local root=$1 home=$2
  shift 2
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$REAL_TASKS_AXI" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$root/bin/fm-captain-hold.sh" "$@"
}

show() { (cd "$1" && tasks-axi show "$2" --full); }

step() {  # <description> <command...>; prints the command, its output and exit
  local desc=$1 rc=0
  shift
  printf '\n$ %s\n' "$desc"
  "$@" 2>&1 || rc=$?
  printf '[exit %s]\n' "$rc"
  return "$rc"
}

expect() {  # <label> <0|1 actual-ok>
  if [ "$2" -eq 0 ]; then printf 'CHECK ok: %s\n' "$1"; else printf 'CHECK FAILED: %s\n' "$1"; FAILS=$((FAILS + 1)); fi
}

has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

hold() {  # <root> <home> <id>
  cap "$1" "$2" hold "$3" --title "Choose the start state" \
    --reason "Should the feature start enabled? A: Off until checks pass. B: On now." --repo sample >/dev/null
}

# The same inputs through every answer path; used for the parity scenarios.
default_paths() {  # <root> <home>
  local root=$1 home=$2 id
  for id in direct release bare labelled blank free multi; do hold "$root" "$home" "s-$id"; done
  printf 'A\n' > "$home/a.txt"
  printf 'From chat:\nAnswer: Off until checks pass.\nBecause the gate is flaky.\n' > "$home/multi.txt"
  step "answer s-direct --decision-file <A>" cap "$root" "$home" answer s-direct --decision-file "$home/a.txt"
  step "answer s-release --decision-file <A> --release" cap "$root" "$home" answer s-release --decision-file "$home/a.txt" --release
  step "answer s-multi --decision-file <multi-line>" cap "$root" "$home" answer s-multi --decision-file "$home/multi.txt"
  printf 's-bare\tA\t\ns-labelled\tA\tOff until checks pass.\ns-blank\tA\t \ns-free\tKeep it off for now\t\n' > "$home/rows.tsv"
  step "answers --source fixture < rows (bare A, labelled A, blank-label A, free text)" \
    sh -c 'exec "$@" < "$0"' "$home/rows.tsv" env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$REAL_TASKS_AXI" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$root/bin/fm-captain-hold.sh" answers --source fixture
}

parity() {  # <scenario name> [config flags...]
  local name=$1 h b ho bo
  shift
  printf '\n===== %s: target commit vs base commit, config: %s =====\n' "$name" "${*:-(none)}"
  h=$(make_home "$name-head" "$@"); b=$(make_home "$name-base" "$@")
  ho=$(default_paths "$HEAD_ROOT" "$h"); bo=$(default_paths "$BASE_ROOT" "$b")
  printf -- '--- target commit transcript ---\n%s\n' "$ho"
  expect "$name: command output identical to base commit" "$([ "$ho" = "$bo" ]; echo $?)"
  if diff -r "$b/data" "$h/data" > "$TMP/diff.out" 2>&1; then
    expect "$name: task records (data/) byte-identical to base commit" 0
  else
    cat "$TMP/diff.out"; expect "$name: task records (data/) byte-identical to base commit" 1
  fi
  ! grep -rq 'Selected answer:' "$h/data"; expect "$name: no 'Selected answer:' line in any record" $?
  [ "$(grep -c 'Resolution mode: answered' "$h/data/backlog.md")" -eq 6 ]
  expect "$name: all six closing answers recorded (bare options accepted)" $?
  printf -- '--- target commit record for s-direct ---\n'; show "$h" s-direct
}

parity unconfigured
parity existing-settings hold-pr-settle park-on-review auto-land

printf '\n===== opt-in: config/hold-answer-words present (target commit) =====\n'
H=$(make_home optin hold-answer-words)
n=0
for shape in A b 7 '(c)' 'D.' 'e)' ' A ' 'A)  '; do
  n=$((n + 1)); hold "$HEAD_ROOT" "$H" "o-$n"
  printf '%s\n' "$shape" > "$H/d.txt"
  out=$(step "answer o-$n --decision-file <'$shape'>" cap "$HEAD_ROOT" "$H" answer "o-$n" --decision-file "$H/d.txt"); rc=$?
  printf '%s\n' "$out"
  [ "$rc" -ne 0 ] && has "$out" "include the displayed option words"; expect "direct '$shape' refused with the reason" $?
  out=$(printf 'o-%s\t%s\t\n' "$n" "$shape" | cap "$HEAD_ROOT" "$H" answers --source fixture 2>&1); rc=$?
  printf '$ answers < "o-%s<TAB>%s<TAB>"\n%s\n[exit %s]\n' "$n" "$shape" "$out" "$rc"
  [ "$rc" -ne 0 ] && has "$out" "skipped: o-$n"; expect "keyed '$shape' without label skipped, non-zero exit" $?
  s=$(show "$H" "o-$n")
  has "$s" "held: yes" && has "$s" "state: queued" && ! has "$s" "Resolution recorded"
  expect "o-$n still held, nothing recorded" $?
done

out=$(printf 'o-1\tA\t \n' | cap "$HEAD_ROOT" "$H" answers --source fixture 2>&1); rc=$?
printf '$ answers < "o-1<TAB>A<TAB><blank label>"\n%s\n[exit %s]\n' "$out" "$rc"
[ "$rc" -ne 0 ] && has "$out" "skipped: o-1"; expect "blank label does not count as displayed words" $?

out=$(printf 'o-1\tA\tOff until checks pass.\no-2\tKeep it off for now\t\no-3\tKeep it off for now\t \n' \
  | cap "$HEAD_ROOT" "$H" answers --source fixture 2>&1); rc=$?
printf '$ answers < labelled A, free text, free text with blank label\n%s\n[exit %s]\n' "$out" "$rc"
expect "labelled and free-text rows accepted" "$rc"
s=$(show "$H" o-1); printf -- '--- record o-1 ---\n%s\n' "$s"
has "$s" "state: done" && has "$s" "Answer: A" && has "$s" "Answer as shown to the captain: Off until checks pass." \
  && has "$s" "Selected answer: Off until checks pass."; expect "labelled A closes and records the displayed words as Selected answer" $?
s=$(show "$H" o-2); has "$s" "Selected answer: Keep it off for now"; expect "free text recorded as Selected answer" $?
s=$(show "$H" o-3); printf -- '--- record o-3 ---\n%s\n' "$s"
has "$s" "Selected answer: Keep it off for now" && ! has "$s" "Answer as shown to the captain:"
expect "blank label omitted from the record" $?

printf 'Off until checks pass.\n' > "$H/words.txt"
step "answer o-4 --decision-file <'Off until checks pass.'> --release" cap "$HEAD_ROOT" "$H" answer o-4 --decision-file "$H/words.txt" --release
s=$(show "$H" o-4); printf -- '--- record o-4 ---\n%s\n' "$s"
has "$s" "Resolution mode: released" && has "$s" "held: no" && has "$s" "Selected answer: Off until checks pass."
expect "release with words lifts the hold and records Selected answer" $?

printf 'From chat:\nAnswer: Off until checks pass.\nBecause the gate is flaky.\n' > "$H/multi.txt"
cap "$HEAD_ROOT" "$H" answer o-5 --decision-file "$H/multi.txt" >/dev/null 2>&1
s=$(show "$H" o-5); printf -- '--- record o-5 ---\n%s\n' "$s"
# tasks-axi show prints the body as one escaped line, so the field must close it.
[ "$(printf '%s\n' "$s" | grep -o 'Selected answer:' | wc -l)" -eq 1 ] \
  && has "$s" 'Because the gate is flaky.\nSelected answer: Off until checks pass."' 
expect "multi-line decision yields exactly one single-line Selected answer" $?

printf 'First thought.\nSecond thought.\n' > "$H/nomarker.txt"
cap "$HEAD_ROOT" "$H" answer o-6 --decision-file "$H/nomarker.txt" >/dev/null 2>&1
s=$(show "$H" o-6); has "$s" "state: done" && ! has "$s" "Selected answer:"
expect "multi-line decision without an Answer marker closes with no Selected answer line" $?

printf '\n===== toggle: removing the flag restores the default on the next command =====\n'
rm "$H/config/hold-answer-words"
printf 'A\n' > "$H/a.txt"
step "answer o-7 --decision-file <A> (flag removed)" cap "$HEAD_ROOT" "$H" answer o-7 --decision-file "$H/a.txt"
s=$(show "$H" o-7); has "$s" "state: done" && ! has "$s" "Selected answer:"
expect "bare A accepted again, no Selected answer line" $?
s=$(show "$H" o-1); has "$s" "Selected answer: Off until checks pass."
expect "earlier opt-in record left untouched" $?

printf '\n===== adversarial: a directory or a differently named file is not the flag =====\n'
G=$(make_home lookalike hold-answer-word hold-answer-words.bak)
mkdir "$G/config/hold-answer-words.d"
hold "$HEAD_ROOT" "$G" g-1
step "answer g-1 --decision-file <A> (lookalike names only)" cap "$HEAD_ROOT" "$G" answer g-1 --decision-file "$H/a.txt"
s=$(show "$G" g-1); has "$s" "state: done" && ! has "$s" "Selected answer:"
expect "lookalike config names do not enable the behavior" $?

printf '\nFAILED CHECKS: %s\n' "$FAILS"
[ "$FAILS" -eq 0 ]
