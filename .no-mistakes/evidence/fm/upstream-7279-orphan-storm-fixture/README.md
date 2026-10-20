# Test evidence for the orphan-storm fixture repair (upstream issue 7279)

All scenario runs drive the real `bin/fm-procevent.sh` of the run worktree (target commit 129a0ef9).
`orphan-storm-fixture.sh` is the orphan-storm case extracted verbatim from `tests/fm-procevent.test.sh`.
It sources the worktree's `tests/lib.sh`, so the repo's own temp-root and procevent-home cleanup apply.
`MODE=base` runs the fixture body from the base commit 45dd50a5 and `MODE=fixed` runs the target-commit body.
`SOURCE_DELAY` injects a sleep before each launch's timestamp to simulate slow source scheduling.
`STAMP_MULT` makes one launch record several timestamps to fake a launch storm.

- `s1-fixed-unloaded.log`: fixed fixture, no load. Three launches over 2.1 s, no process left after retire.
- `s2-base-delayed-source.log`: base fixture with a 12 s source delay reproduces the issue text "launched only 2 times within its observation window".
- `s3-fixed-delayed-source.log`: fixed fixture with the same 12 s delay passes with three samples spanning 26 s.
- `s4-fixed-storm-detected.log`: fixed fixture with a source that stamps three times per launch still fails with "launched 3 times in only 0.012s", so the storm guard is not weakened.
- `s5-loaded-*.log` and `s5-loaded-summary.log`: eight fixed-fixture runs pinned to CPU 0 beside two busy loops under nice 10, all pass.
- `full-fm-procevent-test.log` and `full-fm-procevent-test-rerun.log`: `bin/fm-test-run.sh tests/fm-procevent.test.sh` in the worktree. The changed case passes. Both runs stop in the later "accidentally orphaned runner" section, which asserts a detached listener's parent pid is 1. On this host the test runs under `systemd --user` (pid 5856), a child subreaper, so orphans reparent there instead. That assertion is unchanged from the base commit.
- `full-run-copy-subreaper-relaxation.diff` and `full-fm-procevent-test-copy-subreaper-relaxed.log`: the full script in a disposable `git archive` copy of the target commit where only that parent-pid check also accepts pid 5856.
