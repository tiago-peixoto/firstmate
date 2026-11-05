
## Scenario: head movement on an open owned PR wakes exactly once

$ fm-pr-check.sh delivery https://github.com/o/r/pull/8   (registers pr= and arms the contribution observer)
armed: state/delivery.check.sh
OK   fm-pr-check armed state/contributions.check.sh

$ bash state/contributions.check.sh   (baseline poll, unchanged PR)
<no output: no wake>
OK   no wake queued for an unchanged PR (queue: 0)

$ forge: head -> bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

$ bash state/contributions.check.sh
contribution-wake: check: contributions delivery ea92d2fdcd819936c05a18447eca992d9aff76db615713b3dcfb7659bfc68755

$ fm-contributions.sh pending
[{"token":"head:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb:2026-09-16T08:00:00Z","type":"head","source":"https://github.com/o/r/pull/8","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","body":"head moved from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","task":"delivery","url":"https://github.com/o/r/pull/8"}]
OK   exactly one pending signal of type head with body 'head moved from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
OK   exactly one durable check wake queued (queue: 1)

$ state/.wake-queue
1793886570	1	check	contribution-ea92d2fdcd819936c05a18447eca992d9aff76db615713b3dcfb7659bfc68755	check: contributions delivery ea92d2fdcd819936c05a18447eca992d9aff76db615713b3dcfb7659bfc68755

$ bash state/contributions.check.sh   (unchanged re-poll)
<no output: no wake>
OK   unchanged re-poll adds no wake and no signal

## Scenario: ready movement on an open owned PR wakes exactly once

$ fm-pr-check.sh delivery https://github.com/o/r/pull/8   (registers pr= and arms the contribution observer)
armed: state/delivery.check.sh
OK   fm-pr-check armed state/contributions.check.sh

$ bash state/contributions.check.sh   (baseline poll, unchanged PR)
<no output: no wake>
OK   no wake queued for an unchanged PR (queue: 0)

$ forge: draft=true, poll (adversarial: converting TO draft must not wake)
<no output: no wake>
OK   converting to draft queued no wake (queue: 0)

$ forge: draft=false

$ bash state/contributions.check.sh
contribution-wake: check: contributions delivery ae8dba7e52a9c9f5d024526ed4c5816cea03c35b6113bba8293b3ea81d1e0e8c

$ fm-contributions.sh pending
[{"token":"ready-for-review:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:2026-09-16T08:00:00Z","type":"ready-for-review","source":"https://github.com/o/r/pull/8","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"pull request left draft","task":"delivery","url":"https://github.com/o/r/pull/8"}]
OK   exactly one pending signal of type ready-for-review with body 'pull request left draft'
OK   exactly one durable check wake queued (queue: 1)

$ state/.wake-queue
1793886579	1	check	contribution-ae8dba7e52a9c9f5d024526ed4c5816cea03c35b6113bba8293b3ea81d1e0e8c	check: contributions delivery ae8dba7e52a9c9f5d024526ed4c5816cea03c35b6113bba8293b3ea81d1e0e8c

$ bash state/contributions.check.sh   (unchanged re-poll)
<no output: no wake>
OK   unchanged re-poll adds no wake and no signal

## Scenario: reviewer movement on an open owned PR wakes exactly once

$ fm-pr-check.sh delivery https://github.com/o/r/pull/8   (registers pr= and arms the contribution observer)
armed: state/delivery.check.sh
OK   fm-pr-check armed state/contributions.check.sh

$ bash state/contributions.check.sh   (baseline poll, unchanged PR)
<no output: no wake>
OK   no wake queued for an unchanged PR (queue: 0)

$ forge: requested_reviewers=[reviewer]

$ bash state/contributions.check.sh
contribution-wake: check: contributions delivery 9258c1fbd22feba6773f7dd8e51870eb96b4ca634404b12072e60a7dc4404678

$ fm-contributions.sh pending
[{"token":"review-requested:reviewer:2026-09-16T08:00:00Z","type":"review-requested","source":"https://github.com/o/r/pull/8","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"review requested from reviewer","task":"delivery","url":"https://github.com/o/r/pull/8"}]
OK   exactly one pending signal of type review-requested with body 'review requested from reviewer'
OK   exactly one durable check wake queued (queue: 1)

$ state/.wake-queue
1793886585	1	check	contribution-9258c1fbd22feba6773f7dd8e51870eb96b4ca634404b12072e60a7dc4404678	check: contributions delivery 9258c1fbd22feba6773f7dd8e51870eb96b4ca634404b12072e60a7dc4404678

$ bash state/contributions.check.sh   (unchanged re-poll)
<no output: no wake>
OK   unchanged re-poll adds no wake and no signal

## Scenario: team movement on an open owned PR wakes exactly once

$ fm-pr-check.sh delivery https://github.com/o/r/pull/8   (registers pr= and arms the contribution observer)
armed: state/delivery.check.sh
OK   fm-pr-check armed state/contributions.check.sh

$ bash state/contributions.check.sh   (baseline poll, unchanged PR)
<no output: no wake>
OK   no wake queued for an unchanged PR (queue: 0)

$ forge: requested_teams=[core]

$ bash state/contributions.check.sh
contribution-wake: check: contributions delivery 1fb56c40893df6ca7d04536d8275c3be3094514d502d04626d668546dbf2036d

$ fm-contributions.sh pending
[{"token":"review-requested:team:core:2026-09-16T08:00:00Z","type":"review-requested","source":"https://github.com/o/r/pull/8","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","body":"review requested from team:core","task":"delivery","url":"https://github.com/o/r/pull/8"}]
OK   exactly one pending signal of type review-requested with body 'review requested from team:core'
OK   exactly one durable check wake queued (queue: 1)

$ state/.wake-queue
1793886588	1	check	contribution-1fb56c40893df6ca7d04536d8275c3be3094514d502d04626d668546dbf2036d	check: contributions delivery 1fb56c40893df6ca7d04536d8275c3be3094514d502d04626d668546dbf2036d

$ bash state/contributions.check.sh   (unchanged re-poll)
<no output: no wake>
OK   unchanged re-poll adds no wake and no signal

## Adversarial: review requests already present at the FIRST observation are a baseline, not movement

$ poll twice
<no output: no wake>
<no output: no wake>

$ fm-contributions.sh pending
[]

$ recorded observation.review_requests
["reviewer","team:core"]
OK   no pending signal and no wake
OK   baseline records the current reviewers

## Adversarial: a LEGACY stored observation (no review_requests field) gains reviewers without movement

$ stored observation has review_requests?
false
<no output: no wake>
<no output: no wake>
OK   legacy record: no pending signal and no wake
OK   legacy record now carries the baseline

## Adversarial: a head change observed as merged/closed settles without a movement wake

$ fm-contributions.sh poll   (stored head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, forge now merged at bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
<no output: no wake>
{"state":"merged","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","pending":[],"error":null}
OK   merged: no wake output and empty queue
OK   merged: settled at the new head with no pending signal

$ fm-contributions.sh poll   (stored head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, forge now closed at bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)
<no output: no wake>
{"state":"closed","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","pending":[],"error":null}
OK   closed: no wake output and empty queue
OK   closed: settled at the new head with no pending signal

## Real forge: poll https://github.com/kunchenguid/firstmate/pull/5341 through the real gh login (read-only)

$ gh pr view 5341 --json headRefOid,isDraft,reviewRequests,state
{"headRefOid":"7c5f2560f088782f91033a620d26bac494bd2671","isDraft":false,"reviewRequests":[],"state":"OPEN"}

$ fm-contributions.sh poll   (first observation: the PR already carries maintainer comments, which are expected pre-existing comment wakes)
rc=0
contribution-wake: check: contributions upstream 6dddb009c469ccab66a9a51a32094b2feec9c8b2df81a2c0c1b7f5a6a0923198
contribution-wake: check: contributions upstream 0fe82c8502c944538d9d577d39dc8e1718b6b7026aa5ded1cc9d536b003dc864
contribution-wake: check: contributions upstream f93d157dbc090edb882a3344ad39d80e576aa768f590ec9716dab92e2ed15397
contribution-wake: check: contributions upstream 30d8fc1ae7afdf4f5b2532f162e38a6979a3e1854ada34fd838b081191215afc
contribution-wake: check: contributions upstream ff9ccf184a767914bac824fba4eee281bdba774835b71ebfcc1f6f0b683b1d27
{"url":"https://github.com/kunchenguid/firstmate/pull/5341","error":null,"observation":{"head":"7c5f2560f088782f91033a620d26bac494bd2671","state":"open","draft":false,"review_requests":[]}}

$ fm-contributions.sh pending   (type/author/source only)
{"type":"comment","author":"kunchenguid","source":"https://github.com/kunchenguid/firstmate/pull/5341#issuecomment-6040131519"}
{"type":"comment","author":"kunchenguid","source":"https://github.com/kunchenguid/firstmate/pull/5341#issuecomment-6126622858"}
{"type":"comment","author":"kunchenguid","source":"https://github.com/kunchenguid/firstmate/pull/5341#issuecomment-6230578430"}
{"type":"comment","author":"kunchenguid","source":"https://github.com/kunchenguid/firstmate/pull/5341#issuecomment-6352542339"}
{"type":"comment","author":"kunchenguid","source":"https://github.com/kunchenguid/firstmate/pull/5341#issuecomment-6378693617"}
OK   first observation recorded the real head and a review_requests array, no error
OK   first observation produced no movement signal: every pending signal is a pre-existing maintainer comment (5 comments, 5 wakes)

$ synthetic prior state: stored head -> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, stored draft -> true (as if the PR were previously a draft at another head)

$ fm-contributions.sh poll   (second observation against the real forge)
rc=0
contribution-wake: check: contributions upstream 1691c8fccf48ce7fd19d378cbc31d2dd8b7bc25a3177c09f40ac050c343901d2
contribution-wake: check: contributions upstream e4110e1da613ae8da073314c26b0394ebf1239fd10ecb6f4a2eef4a291dcb880

$ fm-contributions.sh pending   (non-comment signals)
{"type":"head","source":"https://github.com/kunchenguid/firstmate/pull/5341","head":"7c5f2560f088782f91033a620d26bac494bd2671","body":"head moved from aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa to 7c5f2560f088782f91033a620d26bac494bd2671"}
{"type":"ready-for-review","source":"https://github.com/kunchenguid/firstmate/pull/5341","head":"7c5f2560f088782f91033a620d26bac494bd2671","body":"pull request left draft"}
OK   pending gained exactly one head signal naming the real head and one ready-for-review signal
OK   exactly two more durable wakes and two more signals (queue: 7, pending: 7)

$ fm-contributions.sh poll   (third observation, unchanged)
<no output: no wake>
OK   unchanged real re-poll adds no wake and no signal (queue: 7, pending: 7)

== 0 check failures ==
exit=0
