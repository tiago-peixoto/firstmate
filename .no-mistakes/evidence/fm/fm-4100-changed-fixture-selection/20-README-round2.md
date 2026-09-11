# Live validation — issue #4100, changed top-level `tests/*-fixture.sh` selection

(Round 2 evidence. Files `00-`..`11-` are from round 1, before the nested-fixture ordering fix landed as `a05d0eb`.)

Product driven: `bin/fm-test-run.sh --changed` (and `--list --changed`), run from a
real repository checkout the way CI and the local validation path run it.

Three mapper versions were driven so every result is a before/after, not an assertion:

| commit | what it is |
| --- | --- |
| `9074f9d` | base, before any fix |
| `880a9de` | first fix commit |
| `a05d0eb` | target (adds the nested-fixture ordering fix) |

## Files

- `21-round2-repro-at-base.txt` — the reported bug reproduced on the real repo at base:
  a touched `tests/remote-herdr-fixture.sh` aborts with
  `no changed-test mapping for source path` and exit 2, so zero tests run.
- `22-round2-real-repo-fixed.txt` — the same real-repo edit at target: exit 0 and all
  four in-tree readers of that fixture are selected.
- `23-round2-mapper-matrix-3-versions.txt` — five changed-path shapes × three mapper versions, in an
  isolated repo: shared fixture with readers, fixture nobody reads, plain unmapped
  `tests/` path, nested `tests/fixtures/<dir>/` fixture, and `tests/*-helpers.sh`.
- `24-round2-changed-run-actually-executes.txt` — a real `--changed` run (no `--list`): the two
  reader suites actually execute, `FM_TEST_SUMMARY total=2 failed=0`.
- `25-round2-no-regression-identical-selection.txt` — `tests/herdr-client-pair-fixture.sh`, `tests/fixtures.sh`
  and `tests/lib.sh` select byte-identical sets before and after the change.
- `26-round2-new-test-fails-before-passes-after.txt` — the new case in `tests/fm-test-run.test.sh`,
  run alone: exit 1 at base, exit 2 at `880a9de`, exit 0 at target.
- `27-round2-branch-own-selection.txt` — this branch's own `--changed` selection from its base.
- `28-round2-contract-suite.txt` — `bin/fm-test-run.sh tests/fm-test-run.test.sh` at target.
