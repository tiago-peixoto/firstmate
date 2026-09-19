# Live validation: issue 4766 (captain hold and release reach the worker status log)

Every scenario ran against the real product in an isolated firstmate home.
That means a private tmux server (`tmux -L`), the real `tasks-axi` backlog, `bin/fm-captain-hold.sh`, the watcher armed through `bin/fm-watch-arm.sh` and drained through `bin/fm-wake-drain.sh`, `bin/fm-supervise-daemon.sh`, `bin/fm-crew-state.sh`, and `bin/fm-afk-return.sh`.
Only the forge and pipeline CLIs (`gh`, `gh-axi`, `no-mistakes`, `treehouse`) were stubbed.
`live-harness.sh` and `live-scenarios.sh` are the exact scripts that produced the transcripts.
Where a `*.base.txt` exists, the same scenario was run against base commit 1bb72cc for comparison.

A stopped worker is a pane holding a bare shell.
A live worker is a pane whose foreground process is `/bin/sleep` exec'd under the harness name, which the tmux liveness probe reports as `alive`.
Recheck cadences are shortened with `FM_PAUSE_RESURFACE_SECS=5` (production default: 4h) so the recheck loop is visible in seconds.

| Scenario | Base 1bb72cc | Branch 8328434 |
| --- | --- | --- |
| s1: held `paused:` lane, captain away (watcher-owned away posture), 30s | 5 "paused, awaiting external" rechecks | 0 wakes; triage log: "captain-held, never rechecked while the away-posture record exists" |
| s8: same lane under `fm-supervise-daemon.sh` (state/.afk), 30s | 5 recheck escalations buffered for the captain | escalation buffer empty |
| s2: held `paused:` lane, always-on, then `answer --release` with the worker stopped | held phase called it an external wait | held phase names the captain; after release the log gets a keyed `resolved` line and reads `paused:` again, with 0 "answer the held decision" wakes |
| s3: `hold` + `complete` transfer on a stopped scout, then `answer` | the transfer line stays; 3 "answer the held decision" wakes after the answer | the transfer is retracted and read past; 0 such wakes after the answer |
| s4: hold and release while the watcher is armed, including a lane with no status log yet | - | watcher stays armed through both; a real worker append to the same log wakes it (control) |
| s5: delivered `done:` lane (live agent) held for merge, then released, `FM_STALE_ESCALATE_SECS=3` | - | one first-sight `stale:` before the hold; 0 wakes and 0 possible-wedge escalations in the 20s after the release |
| s6: `fm-crew-state.sh` on a `done:` scout before, during, and after a hold | `done · source: status-log` | `done · source: status-log` in all three phases |
| s7: repeated hold, decision-only hold, worker writes after the hold, replayed answer, `diverged` | - | 1 declaration; no status log created; no retraction written over the worker's newer line; 1 retraction; divergence guard silent |
| s9: away return brief after a `failed:` lane is held and released | failed lane listed | failed lane listed |

The `check: rearm-resurface` lines in some transcripts come from the harness: it stops the watcher between phases, and the next arm reports that downtime.
They are not caused by the change.
