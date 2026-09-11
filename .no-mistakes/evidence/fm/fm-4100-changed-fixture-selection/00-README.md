# Live validation: `bin/fm-test-run.sh --changed` and a changed top-level `tests/*-fixture.sh`

Base `9074f9d` (before) vs target `880a9de` (after), both driven as the real CLI
against real copies of the repository.

| file | what it shows |
| --- | --- |
| `01-base-remote-herdr-fixture-abort.txt` | BEFORE: touching `tests/remote-herdr-fixture.sh` aborts `--changed` with exit 2 |
| `02-fixed-remote-herdr-fixture-selects-readers.txt` | AFTER: the same change selects 51 suites instead of aborting |
| `09-real-fixture-reader-coverage.txt` | all four suites that actually read the fixture are in that selection; the real-Herdr lane is not |
| `07-end-to-end-changed-run.txt` | full `--changed` RUN (not `--list`): base runs zero tests and exits 2; target runs the one consuming suite green |
| `03-guard-still-refuses.txt` | the loud refusal survives: an unmapped `tests/` path and a reader-less `tests/*-fixture.sh` both still exit 2 |
| `04-curated-fixture-arm-not-shadowed.txt` | the curated `tests/herdr-client-pair-fixture.sh` mapping is byte-identical before and after |
| `05-nested-fixtures-dir-shadow-check.txt` | REGRESSION: `tests/fixtures/<dir>/<x>-fixture.sh` that a suite references by directory selected its suite on base, aborts on target |
| `06-nested-fixture-shadow-bounds.txt` | bounds that regression to directory-only references of nested `*-fixture.sh` files |
| `10-candidate-fix-probe.txt` | moving the `tests/fixtures/*/*` arm above the new one restores it without losing anything |
| `11-scratch-copy-artifact-not-a-regression.txt` | the one red script seen in a wide scratch fan-out is red on base too and green in the real worktree |
| `08-fm-test-run-regression-suite.txt` | the author's own suite, `bin/fm-test-run.sh tests/fm-test-run.test.sh` |
