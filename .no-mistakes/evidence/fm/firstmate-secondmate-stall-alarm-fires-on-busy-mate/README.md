# Test evidence: secondmate wake-loop stall alarm no longer fires on a busy mate

Branch `fm/firstmate-secondmate-stall-alarm-fires-on-busy-mate`, base `261eae8`, target `7164674`.

Every `*.watch*.out` file below is the literal stdout of `bin/fm-watch-checkpoint.sh --seconds 2`, which is exactly what the parent supervising harness reads on each checkpoint.
A quiet checkpoint prints `checkpoint: no actionable wake within 2s`; a stall alarm prints `check: secondmate wake-loop stalled: mate=<id> row=<seq> age=<n>s` and appends the same row to the parent's `state/.wake-queue` (copied here as `*.state_.wake-queue`).

## target/ (commit 7164674, the fix)

- `secondmate-busy-turn.watch.out`: a claude-hook `busy` record plus a 20000s-old foreign row stays quiet.
- `secondmate-idle-turn.watch.out`: the same 100s-old row under an `idle` record settled 10s ago fires once with `age=11s`, measured from the turn end, not row arrival.
- `secondmate-idle-turn.watch-second.out` and `.state_.wake-queue`: after drain and ack the second checkpoint is quiet and the parent queue is empty, so the row fired exactly once.
- `secondmate-turn-end-clock.watch-before.out` / `watch-after.out`: a 120s-old row is quiet while the idle record is fresh, then fires at `age=61s` once the settled time is 61s old.
- `secondmate-cursor-turn.watch-busy.out` / `watch-settled.out` / `watch-after.out`: the fake Cursor transcript path. Mid-turn transcript is quiet; after `turn_ended` lands the row is still quiet until the transcript settled time is past the threshold, then fires at `age=62s`. (`check: rearm-resurface` in the settled transcript is an unrelated pre-existing watcher wake, not the stall alarm.)
- `secondmate-unknown-turn.watch-before.out` / `watch-after.out`: no busy record at all stays quiet at 600s and fires at `age=14401s`, the fixed four-hour long-turn threshold.
- `secondmate-grok-idle.watch-before.out` / `watch-after.out`: a grok-regex `idle` verdict, which has no settled time, stays quiet at 600s and fires only at `age=14401s`.
- `secondmate-unverified-endpoint.watch.out`: a zellij-backed mate (endpoint state `unverified`) with a settled idle record still fires at the normal threshold, `age=61s`.
- `secondmate-foreign-stall.*`, `secondmate-stall-marker-symlink.*`, `secondmate-stall-crash.*`, `secondmate-prefix-receipt.*`: the four pre-existing marker and receipt convergence cases, still green.

## base-red/ (commit 261eae8, before the fix, same test code)

- `secondmate-busy-turn.watch.out`: the false alarm reproduced, `age=20000s` fires on a mate that is provably busy, and `secondmate-busy-turn.state_.wake-queue` shows the parent handling turn it would have consumed.
- `secondmate-cursor-turn.watch-busy.out`: the same false alarm mid Cursor turn.
- `secondmate-idle-turn.watch.out`: the alarm ages from row arrival (`age=100s`) instead of turn end.

## round1-red/ (commit 1f5473e, after review round 1, before round 2)

- `secondmate-unverified-endpoint.watch.out`: quiet where it should fire, the alive-only gate discarding the idle record.
- `secondmate-grok-idle.watch-before.out`: grok idle fired at the short threshold.

## Logs

- `target-subset.log`: the eleven secondmate stall cases at the target, all green.
- `base-red-subset.log`: the same cases at the base, six red, five green (the four pre-existing convergence cases plus the unverified-endpoint case that only the round-1 commit regressed).
- `round1-red-subset.log`: the two round-2 cases red at the round-1 commit.
- `full-fm-wake-queue-test.log`: `bash tests/fm-wake-queue.test.sh` at the target aborts on its first case, the wake-lib self-held-lock test, under this machine's stock bash 3.2. That case fails identically at the base commit and is unrelated to this change; CI runs the suite on Ubuntu bash.
- `full-fm-wake-queue-test-minus-bash32-lock-case.log`: every other case in the changed test file, run at the target.
