# Issue 4767 live validation (base 45b5b221, HEAD 8ee49513)

The driver `e2e-issue4767.sh` runs the real `fm-wake-drain.sh`, `fm-send.sh`, `fm-captain-hold.sh` and `fm-watch.sh` against a throwaway firstmate home.
Only the tmux pane transport and the `fm-crew-state.sh` verdict are stubbed.
"own-close" rows expect the watcher to stay quiet after the supervisor's own close.
All other rows expect a `signal:` wake for a line a worker wrote.

scenario | base 45b5b221 | HEAD 8ee49513
--- | --- | ---
single/own-close | FAIL (wakes) | PASS (quiet)
single/next-worker-line | PASS | PASS
multi/own-closes | FAIL (wakes) | PASS (quiet)
multi/next-worker-line | PASS | PASS
livecycle/worker-decision | PASS | PASS
livecycle/own-close | PASS | PASS
livecycle/next-worker-line | PASS | PASS
captain_hold/own-transfers | FAIL (wakes) | PASS (quiet)
captain_hold/next-worker-line | PASS | PASS
folded_failure/unlisted-worker-lines-still-wake | PASS | PASS
ship_paused/unlisted-worker-lines-still-wake | PASS | PASS
mate_paused/unlisted-worker-lines-still-wake | PASS | PASS
mate_self_resolved/unlisted-worker-lines-still-wake | PASS | PASS
race_after_drain/unread-worker-line-still-wakes | PASS | PASS

On the base commit, the drain the supervisor runs after the unwanted wake shows its own sentence as the wake's reason, as the issue reports:

```
wake annotation: latest wake-EVENT observed at drain, not current state: t1.status: resolved [key=api-shape]: answered: go with REST
```

`e2e-multikey-failed-close.sh` covers the new batched close failure path on HEAD.
One answer closes two keys while the status file is read-only.
`fm-send` exits nonzero, and running the manual close command it prints closes both keys; answer text containing shell metacharacters is written as data and never runs.

Full transcripts: `e2e-base-45b5b221.txt`, `e2e-head-8ee49513.txt`, `e2e-multikey-failed-close-head-8ee49513.txt`.
