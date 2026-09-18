# Live validation: a waiting worker spends no turns until it is answered

Branch `fm/firstmate-issue4228-wait-turn-spend`, target commit `86ba891`.

## Setup

Every scenario ran against the real firstmate scripts from this worktree (`bin/fm-send.sh`, `bin/fm-watch.sh` via `bin/fm-watch-arm.sh`, `bin/fm-wake-drain.sh`, `bin/fm-config-push.sh`, `bin/fm-secondmate-reconcile.sh`, `bin/fm-bootstrap.sh`, `bin/fm-brief.sh`).
They ran against a real tmux 3.7c server on a private socket (`tmux -L fm-live-4228`), reached through a PATH shim, so the host's own sessions were never touched.
Each worker pane runs `harness-stand-in-agent.py` through a symlink named `claude`.
firstmate's own backend classifies that pane as a live Claude agent, and its composer reads as `empty` or `pending` from the real screen.
Every submitted line is logged as a "TURN", which stands for one full-context model turn.
With `BUSY_SECS`, the stand-in shows Claude's `esc to interrupt` busy line for a few seconds after each turn.
Homes and state live under `/tmp/fm-live-4228`.
`FM_GATE_REFUSE_BYPASS=1` is the repo's documented test-harness hatch for an isolated sandbox fleet.
The watcher ran with `FM_POLL=1` and short inbox grace so waits fit in seconds.
Firstmate's cycle of arm, wake, drain with ack, and re-arm is reproduced by `harness-common.sh`.

## Scenario transcripts

- `s3-automatic-send-defers-then-answer-wakes.txt`: `fm-send --automatic` exits 4 with `deferred:` while the worker's own decision is open, writes no record, and the pane gets no turn. The deliberate `--resolve-key` answer still wakes it, and automatic sends then resume.
- `s5-automatic-send-adversarial.txt`: parent-raised keys (`pending-reply-*`, `captain-hold-*`, `remote-reply-continuity-*`) do not hold an automatic send. The worker's own keyless `blocked:` does. `--automatic` is refused with an explicit backend target, with `--resolve-key`, and with `--key`.
- `s6-fire-and-forget-retry-rings-once.txt`: a pending composer skips a fire-and-forget doorbell, and fm-send says "the watcher will ring it once more". The real watcher rings exactly once, spends the mark, never enters the ladder, never wakes firstmate, and does not ring again over 25 s.
- `s7-retry-held-while-own-decision-open.txt`: the owed retry is held for about 25 s while the mate's own decision is open (the mark is kept and there is no turn). It then rings exactly once after the decision closes.
- `s8-reconcile-ask-waits-for-decision.txt`: `process-requests` reports `waiting: 1`, exits 0, sends nothing, and does not start the cooldown while the mate decides. It delivers the fire-and-forget ask once the decision closes.
- `s9-config-reread-deferred-then-delivered-by-watcher.txt`: `fm-config-push.sh` pushes the file but defers the reread (exit 0, flag kept, no turn). The watcher's `--retry-deferred` delivers the `CONFIG_REREAD` pointer about 3 s after the decision closes.
- `s10-pending-reply-recovery-waits-for-decision.txt`: a marked request's turn completes without a report while the mate has its own decision open. The one `REPOST REQUIRED` recovery stays unattempted for about 25 s and is sent about 2 s after the decision closes.
- `s11-bootstrap-nudge-deferred-despite-guard-banner.txt`: the primary checkout is on a feature branch, so the guard's WORKTREE TANGLE banner prints ahead of `deferred:`. Bootstrap still reports `NUDGE_SECONDMATES: ... deferred: ...`, not "send failed", and keeps the retry marker. The next session start after the decision closes delivers the nudge.

## Worker brief (generated prompt delivered to workers)

- `brief-ship-generated.md`, `brief-scout-generated.md`, `brief-secondmate-generated.md` are real `bin/fm-brief.sh` output.
- `brief-ship-base-vs-branch.diff` compares the ship brief from base `daaffdb` with this branch, both generated at the same home path.
  It adds the Waiting section, drops the "natural checkpoint" inbox habit, reattaches a timed-out `respond` with `axi run`, and drives no-mistakes with one foreground call instead of background-and-poll.
