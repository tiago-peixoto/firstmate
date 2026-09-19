# Issue 4768 live drive: base 1bb72cc vs branch eee422f

Driver: `drive-4768.sh` (isolated FM_HOME, real bare origin, project clone, linked worker worktrees, isolated tmux server, real busy records).
Full transcripts: `transcript.txt` (branch) and `transcript-base-1bb72cc.txt` (base).

| Scenario | Base 1bb72cc | Branch eee422f |
| --- | --- | --- |
| S1 direct-PR, pushed branch is a merge of main, fix only in copy | crew-state `done`, fm-pr-check registers and arms poll | crew-state `blocked · named head <fix> is unreachable outside the worker copy`, fm-pr-check exits 1, no `pr=`, no poll |
| S2 direct-PR after pushing the fix | done, registers | done, registers |
| S3 local-only, commit on detached HEAD in Treehouse worktree | `done` | `blocked`, then `done` once on `fm/lo` |
| S4 local-only, commit only in a standalone clone | `done` | `blocked` |
| S5 no-mistakes pre-validation `done: {summary}` | done | done (handoff not gated) |
| S6 no-mistakes CI-ready, commit made after the run, forge has no head | crew-state `done`, fm-pr-check registers | crew-state `blocked`, fm-pr-check exits 1 |
| S7 no-mistakes CI-ready, forge reports the pipeline head | done before and after registration | blocked before registration; fm-pr-check records `pr_head=` from GitHub; done after |
| S8 keyed `done [key=fix]:` with fix unpushed | `done` | `blocked` |
| S9 secondmate child CI-ready done, unpushed | published upstream | not published; child reads `blocked` |
| S10 secondmate child after push | published once | published once |
| S11 pending delivery after teardown removed worktree | delivered by `report` | delivered by `report` |
