#!/usr/bin/env bash
# Disposable live driver for #8154: drives the REAL bin/fm-teardown.sh,
# bin/fm-bootstrap.sh, bin/fm-captain-hold.sh and bin/fm-bearings-snapshot.sh
# of the checkout given as $1 against throwaway homes built by the atomicity
# suite's own fixture helpers. Prints a transcript; asserts nothing.
REPO=$1; shift
set -u
# Reuse the suite's fixture helpers (make_home, add_item, run_teardown, ...)
# without running its test list: source only the preamble before "--- dispatch".
preamble=$(mktemp)
sed -n '1,/^# --- dispatch/p' "$REPO/tests/fm-backlog-atomicity.test.sh" \
  | sed -e "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$REPO/tests|" > "$preamble"
. "$preamble"
rm -f "$preamble"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"
echo "=== checkout: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo base-archive))"

show_row() { tasks-axi show "$2" --file "$(backlog_of "$1")" --full; }
bearings_landed() {  # <case-dir>
  PATH="$1/fakebin:$PATH" FM_HOME="$(home_of "$1")" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json 2>/dev/null | jq -c '[.landed[] | {id, what, artifact}]'
}
run_captain() {  # <case-dir> <args...>
  local case_dir=$1; shift
  PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$(home_of "$case_dir")" \
    "$CAPTAIN" "$@"
}

scenario() { printf '\n##### %s\n' "$*"; }

for report in missing partial; do
  scenario "S1-$report: forced teardown of an unheld scout with a $report report"
  id="scout-forced-$report"
  c=$(make_home "forced-$report")
  add_item "$c" "$id" scout; start_item "$c" "$id"
  write_task_meta "$c" "$id" scout '' "spawn_gen=spawn-forced-$report"
  if [ "$report" = partial ]; then
    mkdir -p "$(home_of "$c")/data/$id"; printf 'unfinished findings\n' > "$(home_of "$c")/data/$id/report.md"
  fi
  echo "\$ fm-teardown.sh $id --force"; run_teardown "$c" "$id" --force; echo "exit=$?"
  echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"
  echo "\$ fm-bearings-snapshot.sh --json | .landed"; bearings_landed "$c"
done

scenario "S2: forced teardown of an unheld scout WITHOUT --force is still refused when the report is missing"
id=scout-unforced-missing; c=$(make_home unforced-missing)
add_item "$c" "$id" scout; start_item "$c" "$id"
write_task_meta "$c" "$id" scout '' "spawn_gen=spawn-unforced"
echo "\$ fm-teardown.sh $id"; run_teardown "$c" "$id"; echo "exit=$?"
echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"

scenario "S3: ordinary scout completion with its report (no --force) still records the report path"
id=scout-reported; c=$(make_home reported)
add_item "$c" "$id" scout; start_item "$c" "$id"
write_task_meta "$c" "$id" scout '' "spawn_gen=spawn-reported"
mkdir -p "$(home_of "$c")/data/$id"; printf 'findings\n' > "$(home_of "$c")/data/$id/report.md"
run_captain "$c" complete "$id" --none >/dev/null || echo "captain complete failed"
echo "\$ fm-teardown.sh $id"; run_teardown "$c" "$id"; echo "exit=$?"
echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"
echo "\$ fm-bearings-snapshot.sh --json | .landed"; bearings_landed "$c"

for report in present absent; do
  scenario "S4-$report: forced teardown of a CAPTAIN-HELD scout whose report is $report"
  id="scout-held-$report"; c=$(make_home "held-$report")
  add_item "$c" "$id" scout; start_item "$c" "$id"
  write_task_meta "$c" "$id" scout '' "spawn_gen=spawn-held-$report"
  if [ "$report" = present ]; then
    mkdir -p "$(home_of "$c")/data/$id"; printf 'one captain choice remains\n' > "$(home_of "$c")/data/$id/report.md"
  fi
  run_captain "$c" hold "$id" --reason "captain must choose" >/dev/null || echo "captain hold failed"
  echo "\$ fm-teardown.sh $id --force"; run_teardown "$c" "$id" --force; echo "exit=$?"
  echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"
  echo "\$ fm-bearings-snapshot.sh --json | .landed"; bearings_landed "$c"
done

scenario "S5: session start replays a recorded 'discarded' close marker as the note 'discarded'"
id=scout-replay-forced; c=$(make_home replay-forced)
add_item "$c" "$id" scout; start_item "$c" "$id"
printf 'id=%s\ndata=%s\nspawn_gen=spawn-replay\narg=--note\narg=discarded\n' "$id" "$(home_of "$c")/data" \
  > "$(home_of "$c")/state/$id.backlog-close"
echo "\$ cat state/$id.backlog-close"; cat "$(home_of "$c")/state/$id.backlog-close"
echo "\$ fm-bootstrap.sh"; run_bootstrap "$c" | grep -i "$id\|close\|replay" || true
echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"
echo "marker remains? $([ -e "$(home_of "$c")/state/$id.backlog-close" ] && echo yes || echo no)"

scenario "S6: session start still decodes a recorded 'local%20main' close marker to the note 'local main'"
id=ship-replay-local; c=$(make_home replay-local)
add_item "$c" "$id"; start_item "$c" "$id"
printf 'id=%s\ndata=%s\nspawn_gen=spawn-replay-local\narg=--note\narg=local%%20main\n' "$id" "$(home_of "$c")/data" \
  > "$(home_of "$c")/state/$id.backlog-close"
echo "\$ fm-bootstrap.sh"; run_bootstrap "$c" | grep -i "$id\|close\|replay" || true
echo "\$ tasks-axi show $id --full"; show_row "$c" "$id"

scenario "S7 (adversarial): a close marker with a note other than local%20main or discarded is rejected"
for bad in 'evil' 'discarded%20x' 'Discarded' 'local main'; do
  id=ship-replay-bad; c=$(make_home "replay-bad-$RANDOM")
  add_item "$c" "$id"; start_item "$c" "$id"
  printf 'id=%s\ndata=%s\nspawn_gen=spawn-replay-bad\narg=--note\narg=%s\n' "$id" "$(home_of "$c")/data" "$bad" \
    > "$(home_of "$c")/state/$id.backlog-close"
  echo "--- note value: '$bad'"
  echo "\$ fm-bootstrap.sh"; run_bootstrap "$c" | grep -i "$id\|close\|replay\|refus\|invalid" || true
  echo "row state: $(row_state "$c" "$id"); marker remains? $([ -e "$(home_of "$c")/state/$id.backlog-close" ] && echo yes || echo no)"
done
echo "=== driver done"
