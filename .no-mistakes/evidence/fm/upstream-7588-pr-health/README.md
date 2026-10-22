# Test-step evidence for fm/upstream-7588-pr-health (target a986889b)

All live runs used a disposable lab home made by bin/fm-lab-home.sh under /tmp and removed afterwards.
GitHub was only read: every forwarded gh call was a REST GET of one pull request or a GraphQL query (live/observations.json, live/responses/*.cmd).
No PR, branch, check, review or comment was changed.

- live/transcript.txt: flag absent (poll silent, arm refuses, zero gh calls, state untouched); flag on + enroll PR 7208 (19 reported contexts, none required, two failing) -> one "has failing checks" line, second poll silent; enroll conflicting PR 7612 -> one conflict line, PR 7208 silent, next poll silent.
- live/observations.json: latest commit, isRequired values, failing contexts and mergeable per PR, extracted from the logged real GitHub responses.
- live/pr-health-after-7612.json: the fingerprint file after the runs.
- before-after/transcript.txt: the pre-fix script (3bc134e6) polling PR 7208 prints nothing; the target script in the same home then prints the fallback line once.
- watcher/transcript.txt: the real watcher (fm-watch-checkpoint.sh) turns the conflict on PR 7612 into one wake-queue row; a second run finds no new wake.
- focused-tests.log: bin/fm-test-run.sh tests/fm-pr-health.test.sh tests/fm-pr-state.test.sh (fake forge, all 23 monitor cases).
- bootstrap-tests.log: bin/fm-test-run.sh tests/fm-bootstrap.test.sh (bootstrap arms the monitor only with the flag).
