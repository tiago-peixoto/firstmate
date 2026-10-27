#!/usr/bin/env bash
# Live driver: scout brief write boundary vs completion gate (issue #7862).
set -u
ROOT=/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5ZQQC4YV0S05NH2P34PW476
EV=/home/firstmate/.no-mistakes/evidence/01M5ZQQC4YV0S05NH2P34PW476
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
cd "$ROOT" || exit 1

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
mkdir -p "$LAB/fakebin"
for t in tmux treehouse no-mistakes gh gh-axi; do printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/fakebin/$t"; chmod +x "$LAB/fakebin/$t"; done

# Every product call runs the way a scout or firstmate would: plain FM_HOME, no
# fleet-path overrides inherited from this gate session.
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
          PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" "$@"; }
lab_tasks() { (cd "$LAB" && tasks-axi "$@"); }

seed_task() {  # <id> <status-body>
  local id=$1
  lab_tasks add "$id" "Investigate $id" --kind scout --repo sample --start >/dev/null || { echo "tasks-axi add $id failed"; exit 1; }
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$LAB/projects/missing-$id" "project=$LAB/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id" > "$LAB/state/$id.meta"
  printf '%s\n' "$2" > "$LAB/state/$id.status"
  printf '# Report for %s\n\nWhat I did, what I found, evidence, recommendation.\n' "$id" > "$LAB/data/$id/report.md"
}

brief_command() {  # <brief.md> -> the exact completion command the brief gives the scout
  sed -n 's/^Only when the reviewed inventory is empty, run `\(.*\)`\.$/\1/p' "$1"
}

echo "################ SCENARIO 1: scaffold scout brief; rule 2 and Definition of done side by side"
run "$ROOT/bin/fm-brief.sh" scout-empty sample --scout >/dev/null || { echo "scaffold failed"; exit 1; }
BRIEF="$LAB/data/scout-empty/brief.md"
{
  echo "## Rule 2 (write boundary), from $BRIEF"
  grep -n '^2\. ' "$BRIEF"
  echo
  echo "## Definition of done excerpt (completion step), from $BRIEF"
  grep -n 'captain-hold-lifecycle/SKILL.md\|Only when the reviewed inventory is empty\|This exception permits only\|If any captain call remains\|If the command refuses' "$BRIEF"
  echo
  echo "## Command the brief hands the scout (verbatim)"
  brief_command "$BRIEF"
} | sed "s#$LAB#\$LAB#g" | tee "$EV/scenario1-brief-rule2-vs-dod.txt"
CMD=$(brief_command "$BRIEF")
[ -n "$CMD" ] || { echo "FAIL: brief carries no completion command"; exit 1; }

echo; echo "################ SCENARIO 2: empty-inventory scout runs the brief's command verbatim, then verify and teardown accept"
seed_task scout-empty $'working [at=1]: report drafted\ndone [at=2]: nothing waits on the captain'
{
  echo "\$ cat state/scout-empty.meta   (before)"; cat "$LAB/state/scout-empty.meta"
  echo; echo "\$ $CMD"
  run bash -c "$CMD"; echo "exit=$?"
  echo; echo "\$ cat state/scout-empty.meta   (after)"; cat "$LAB/state/scout-empty.meta"
  echo; echo "\$ fm-captain-hold.sh verify scout-empty"
  run bash "$ROOT/bin/fm-captain-hold.sh" verify scout-empty; echo "exit=$?"
  echo; echo "\$ fm-teardown.sh scout-empty   (scout teardown gate)"
  run "$ROOT/bin/fm-teardown.sh" scout-empty 2>&1; echo "exit=$?"
  echo; echo "\$ backlog row after teardown:"; grep -n 'scout-empty' "$LAB/data/backlog.md"
} 2>&1 | sed "s#$LAB#\$LAB#g; s#$ROOT#\$ROOT#g" | tee "$EV/scenario2-empty-inventory-complete-verify-teardown.txt"

echo; echo "################ SCENARIO 3 (adversarial): open keyed decision; the same brief command is refused, verify and teardown refuse"
run "$ROOT/bin/fm-brief.sh" scout-open sample --scout >/dev/null || { echo "scaffold failed"; exit 1; }
CMD_OPEN=$(brief_command "$LAB/data/scout-open/brief.md")
seed_task scout-open $'working [at=1]: report drafted\nneeds-decision [key=route]: choose route north or route south'
{
  echo "\$ cat state/scout-open.status"; cat "$LAB/state/scout-open.status"
  echo; echo "\$ $CMD_OPEN"
  run bash -c "$CMD_OPEN"; echo "exit=$?"
  echo; echo "\$ grep decisions_reviewed state/scout-open.meta"; grep -c 'decisions_reviewed' "$LAB/state/scout-open.meta"
  echo; echo "\$ fm-captain-hold.sh verify scout-open"
  run bash "$ROOT/bin/fm-captain-hold.sh" verify scout-open; echo "exit=$?"
  echo; echo "\$ fm-teardown.sh scout-open"
  run "$ROOT/bin/fm-teardown.sh" scout-open 2>&1; echo "exit=$?"
  echo; echo "\$ ls state/scout-open.meta (must survive the refused teardown)"; ls "$LAB/state/scout-open.meta"
} 2>&1 | sed "s#$LAB#\$LAB#g; s#$ROOT#\$ROOT#g" | tee "$EV/scenario3-open-decision-refused.txt"

echo; echo "################ SCENARIO 4 (adversarial): the exception is scout-only and names one command"
run "$ROOT/bin/fm-brief.sh" ship-x sample --mode no-mistakes >/dev/null || { echo "ship scaffold failed"; exit 1; }
FM_SECONDMATE_CHARTER='Supervise sample.' run "$ROOT/bin/fm-brief.sh" sm-x --secondmate sample >/dev/null || { echo "secondmate scaffold failed"; exit 1; }
{
  for b in scout-empty ship-x sm-x; do
    f="$LAB/data/$b/brief.md"
    printf '%-12s attestation-exception lines: %s   complete-command lines: %s   other fm-captain-hold.sh subcommands offered: %s\n' \
      "$b" "$(grep -c 'empty-inventory attestation' "$f")" "$(grep -c 'fm-captain-hold.sh.* complete ' "$f")" \
      "$(grep -o 'fm-captain-hold.sh[^`]* \(hold\|answer\|reconcile\|bind\|unbind\)' "$f" | wc -l)"
  done
  echo; echo "scout brief: every fm-captain-hold.sh invocation it offers:"; grep -o 'fm-captain-hold.sh[^`]*' "$LAB/data/scout-empty/brief.md" | sed "s#$LAB#\$LAB#g"
  echo; echo "ship brief rule 2:"; grep -n '^2\. ' "$LAB/data/ship-x/brief.md"
} 2>&1 | tee "$EV/scenario4-exception-scope.txt"
