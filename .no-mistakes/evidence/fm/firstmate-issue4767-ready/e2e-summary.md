# Issue 4767 live validation

The driver `e2e-issue4767.sh` runs the real `fm-wake-drain.sh`, `fm-send.sh`, `fm-captain-hold.sh` and `fm-watch.sh` against a throwaway firstmate home.
Only the tmux pane transport and the `fm-crew-state.sh` verdict are stubbed.
"own-close" rows expect the watcher to stay quiet after the supervisor's own close.
All other rows expect a `signal:` wake for a worker-authored line.

scenario | base befcf9a6 | branch 00002948
--- | --- | ---
single/own-close | FAIL | PASS
single/next-worker-line | PASS | PASS
multi/own-closes | FAIL | PASS
multi/next-worker-line | PASS | PASS
livecycle/worker-decision | PASS | PASS
livecycle/own-close | PASS | PASS
livecycle/next-worker-line | PASS | PASS
captain_hold/own-transfers | FAIL | PASS
captain_hold/next-worker-line | PASS | PASS
folded_failure/worker-decision | PASS | PASS
folded_failure/unlisted-worker-lines-still-wake | PASS | PASS
ship_paused/worker-decision | PASS | PASS
ship_paused/unlisted-worker-lines-still-wake | PASS | PASS
mate_paused/worker-decision | PASS | PASS
mate_paused/unlisted-worker-lines-still-wake | PASS | PASS
mate_self_resolved/worker-decision | PASS | PASS
mate_self_resolved/unlisted-worker-lines-still-wake | PASS | PASS
race_after_drain/unread-worker-line-still-wakes | PASS | PASS

On the base commit, the supervisor's drain after the unwanted wake reads its own sentence, as the issue reports:

```
wake annotation: latest wake-EVENT observed at drain, not current state: t1.status: resolved [key=api-shape]: answered: go with REST
```

The adversarial rows were also run against the earlier commits on this branch (`e2e-adversarial-earlier-commits.txt`).
Each hole found in review rounds 1 to 3 shows up there as a live failure, and HEAD passes them all.

Full transcripts: `e2e-base-befcf9a6.txt`, `e2e-branch-00002948.txt`.
