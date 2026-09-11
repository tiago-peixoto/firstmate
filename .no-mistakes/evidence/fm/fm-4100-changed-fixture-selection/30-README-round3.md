Live validation of fm/fm-4100-changed-fixture-selection (issue #4100)
base 7d14fc1 vs target 0f647e2, both driven as real `bin/fm-test-run.sh` invocations
in throwaway clones of this repository.

30-1-top-level-fixture-before-after.txt
  Editing the real tests/remote-herdr-fixture.sh: base aborts with exit 2 and zero
  selection; target lists the 51 suites of the families that read it.
30-2-curated-and-existing-arms-unchanged.txt
  tests/herdr-client-pair-fixture.sh (curated herdr arm), tests/lib.sh, *-helpers.sh,
  tests/fixtures.sh, tests/git-config-helpers.sh, a .test.sh and a bin/ script all keep
  byte-identical selection on base and target.
30-3-loud-refusal-still-stands.txt
  A reader-less tests/*-fixture.sh, one referenced only from bin/, and an unrelated
  tests/ file all still exit 2 with the named refusal; adding one reader flips it to
  selection.
30-4-nested-fixture-directory-scan.txt
  A nested tests/fixtures/<dir>/<name>-fixture.sh whose suite names only the directory
  still selects through the directory scan, identically to base.
30-5-changed-run-actually-executes-suites.txt
  Full `--changed` run (no --list): base runs zero suites and exits 2; target really
  executes both reader suites and exits 0, without widening to the unrelated suite.
30-6-regression-test-fails-before-passes-after.txt
  The new case in tests/fm-test-run.test.sh passes on target and fails against the base
  runner.
30-7-retirement-parity-with-base.txt
  Deleting the fixture plus its references refuses identically on base and target: no
  new abort introduced (known pre-existing gap, routed separately by the maintainer).
