# Issue 4768 live before/after

The same driver (`live-driver.sh`) ran against the base commit `daaffdb` and the target commit `e4eebad`.
It uses real git remotes, real linked worker worktrees, a private tmux server, and the real firstmate scripts.
Only `gh` (the forge API) and `no-mistakes` (no run attributed) are stubbed.
Full transcripts: `live-transcript-base-daaffdb.txt` (before) and `live-transcript.txt` (after).

| Scenario | Worker's git state | Base `daaffdb` | Target `e4eebad` |
| --- | --- | --- | --- |
| S1 direct-PR, never pushed | fix only in the worktree | crew-state `done`; `fm-pr-check` arms the poll | crew-state `blocked · named head <sha> is unreachable outside the worker copy`; `fm-pr-check` exits 1 with the same reason, no `pr=` |
| S2 direct-PR, branch pushed, later fix unpushed | forge head = older pushed tip | `done`; PR registered | `blocked` naming the unpushed fix; `fm-pr-check` refuses |
| S2b same worker pushes the fix | fix on `origin/fm/b` | `done` | `done`; `pr=` and `pr_head=` recorded |
| S3 remote branch moved to main, note cites a pushed SHA | fix on no remote ref | `done` | `blocked` naming HEAD, not the SHA quoted in the note |
| S4 no-mistakes handoff `done: {summary}` | unpushed (pipeline owns push) | `done` | `done` (not gated) |
| S4 no-mistakes CI-ready done, HEAD unpushed | nothing pushed | `done` | `blocked` |
| S4b pipeline pushed HEAD to its gate remote | on `refs/remotes/no-mistakes/fm/d` | `done` | `done` |
| S4c worker commits after the run | new commit unpushed | `done` | `blocked` |
| S4d pipeline-created forge head the worker never fetched | forge head not in the worker clone | `done` | `blocked` before registration; `fm-pr-check` registers the forge head; then `done` |
| S5 local-only on shared branch `fm/f` | on the project's `refs/heads/fm/f` | `done` | `done` |
| S5 local-only detached-HEAD commit | on no branch | `done` | `blocked` |
| S6 direct-PR squash-merged, branch pruned | fix on no ref after prune | `done` | `blocked` until the real watcher's PR poll records the merge, then `done` |
| S6 done naming a different PR than recorded | same | `done` | `blocked` (no merge credit) |
| S7 secondmate child, unpushed done | fix only in the worktree | published upstream on the first scan | not published, no receipt; published once, with a `.reported` receipt, after push |
| S8 fleet snapshot (captured meta) | all of the above | every crew `done` | matches crew-state; merged `g` reads `done` |
