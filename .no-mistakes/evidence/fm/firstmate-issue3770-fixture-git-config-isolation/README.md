# Issue 3770 — fixture Git config isolation: live test evidence

Change: 527aa7c (base) → 1246f09 (head), branch `fm/firstmate-issue3770-fixture-git-config-isolation`.

"Signing host layer" = scratch `GIT_CONFIG_GLOBAL` with `commit.gpgsign=true`, `gpg.program=gpg`,
plus an empty `GNUPGHOME`, i.e. the issue's condition: no secret key matches the fixture identities.
The developer's real `~/.gitconfig` sets signing but has an include that turns it off under temp
paths, so it could not reproduce the failure (logs 01–04). It was only read, never written (log 16).

| Log | What it shows |
|-----|---------------|
| 00-host-condition-reproduced.log | A bare fixture-identity commit under the signing layer fails with `gpg: skipped "…": No secret key` |
| 01–04 | Real `~/.gitconfig`: base and head both pass (the host's nosign include masks the bug) |
| 05-base-direct-signing-host.log | BEFORE: base `tests/fm-project-origin.test.sh` fails with the issue signature |
| 06-head-direct-signing-host.log | AFTER: same suite, invoked directly, passes on head |
| 07-base-runner-signing-host.log | BEFORE: `bin/fm-test-run.sh` on base, `fm-project-origin` and `fm-spawn-worktree-settle` fail with `No secret key` (its `fm-gitignore-config` failure comes from the base tree not being a git repo; not counted) |
| 08-head-runner-signing-host.log | AFTER: the same three suites pass through the runner on head |
| 09-head-runner-bash32-signing-host.log | Runner under stock macOS bash 3.2.57 passes (the scoped export of the local variable works) |
| 10-head-fm-test-fixtures.log | Regression suite passes: every entry point, the runner (jobs 1/2 × timeout 0/30), explicit config kept, outside commits still sign |
| 11-mutation-runner-isolation-removed.log | Adversarial test: deleting the runner's isolation line makes the regression suite fail (`runner inherited global config`) |
| 12-mutation-libsh-isolation-removed.log | Adversarial test: deleting lib.sh's isolation line makes the regression suite fail, and a real suite fails again with `No secret key` |
| 13-changed-file-selection.log | `--changed`: a runner edit selects `fm-test-fixtures`, an isolation-proof edit does not, a git-config-helpers edit selects lib.sh and herdr-test-safety dependents |
| 14-system-layer-signing.log | Signing armed on the system layer only: base fails, head passes directly and through the runner |
| 15-head-fm-test-run-suite.log | The changed runner contract suite (new selection assertions, linked-worktree fixture) passes |
| 16-after-state-outside-commits-still-sign.log | `~/.gitconfig` hash unchanged, a commit outside any fixture still attempts signing, worktree clean |
