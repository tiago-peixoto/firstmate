# Live validation evidence - firstmate #4885 (branch fm/fm4885)

Everything here was produced by driving the real product in a throwaway `FM_HOME`
under `/tmp`: the real `bin/fm-watch.sh` watcher process, the real
`bin/fm-send.sh --resolve-key` answer path, and the real `bin/fm-wake-drain.sh`
captain-facing presentation.
No live fleet, no real `FM_HOME`, no Herdr session was touched.

The only stand-ins are the two seams the product already exposes for this:
a `tmux` stub on `PATH` and the `FM_CREW_STATE_BIN` crew-state reader.
`FM_FAKE_CREW_SLEEP` makes that reader take real time, which is how the real
watcher behaves (it makes a bounded no-mistakes call there) and what opens the
window in which the supervisor's answers land between the watcher's
classification and its seen-marker commit.
That window is the state the issue describes.

## Files

| file | what it shows |
| --- | --- |
| `live-e2e-before-fix-base-commit.log` | the bug, on base commit `a09090d`: scenario S3 FAILS - the two `--resolve-key` answers alone re-wake the supervisor |
| `live-e2e-after-fix.log` | the same driver on the branch head `0992f93`: S3 passes, S4 (worker line still wakes) and S5 (answers still presented) pass |
| `live-adversarial.log` | three attempts to make the ledger swallow something it must not: an interleaved worker line, a rotated status log, an unreadable status log |
| `regression-test-fails-on-base.log` | the branch's own `test_separate_resolve_key_answers_do_not_rewake` run against the base commit: `not ok` |
| `driver-live-e2e.sh`, `driver-live-adversarial.sh` | the drivers, so a reviewer can re-run them: `./driver-live-e2e.sh <repo-root> <workdir>` |

## The one-line difference

Same driver, same throwaway home, same six steps.

```
base  a09090d : S3  FAIL  the answers woke the watcher (it exited): signal: <STATE>/t1.status
branch 0992f93: S3  PASS  a full watcher poll cycle passed with no wake over this home's own answers
```

In both runs the answers are still printed to the captain by the drain
(`wake annotation: ... resolved [key=k1]: answered: go with REST`), which is the
"do not hide owned ranges from presentation" constraint holding.
