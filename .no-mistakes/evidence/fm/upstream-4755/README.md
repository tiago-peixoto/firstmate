# Live validation of fm/upstream-4755 (escalated pending-reply re-surfacing)

Disposable lab home minted with bin/fm-lab-home.sh under /tmp (removed after the run).
The mate pane backend is a fake tmux in the lab's fakebin that logs typed text.
Escalations are driven through the product library (escalate.sh); sessions are the real session lock token
(bin/fm-lock.sh anchored on this harness) or a re-keyed state/.lock-session id, the same /clear re-key the watcher sees.

| File | Scenario | Result |
| --- | --- | --- |
| s1-default-off-escalate.txt, s1-default-off-later-session.txt, s1-session-start-full.txt | Flag absent: real bin/fm-session-start.sh in a later session enqueues no reminder; Bearings has no row | pass |
| s2-opt-in-later-session.txt, s2-session-start-full.txt | Flag present: a later real session start presents exactly one `check pending-reply-escalated` wake; Bearings row carries a string `question`; no second status line | pass |
| s3-same-session-no-rearm.txt | After ack, the same session's second start, three watcher ticks, and a direct remind add nothing | pass |
| s4-unkeyed-resolved-new-session.txt | An unkeyed `resolved:` line does not dismiss; a new session is reminded once across three ticks | pass |
| s5-keyed-close-clean.txt | `bin/fm-send.sh mate2 --resolve-key pending-reply-<corr>` dismisses only that escalation: no reminder in two later sessions, Bearings drops it, the sibling escalation is still reminded | pass |
| s5-s6-s7-keyed-close-reply-limit.txt (S6 part), s5-s6-keyed-close-and-reply.txt (S6 part) | A correlated `done [corr=...]` reply resolves the record: no reminder, no Bearings row | pass |
| s5-s7-keyed-close-final.txt (S7 part) | FM_BEARINGS_DECISIONS=1 with two open escalations lists both (exempt from the limit) | pass |
| targeted-tests.log | tests/fm-pending-reply.test.sh and tests/fm-bearings-snapshot.test.sh under the heavy-slot wrapper | not run: heavy slot never freed |

The fm-send attempts in s5-s6-keyed-close-and-reply.txt and s5-s7-keyed-close-final.txt were refused by the gate guard
(NO_MISTAKES_GATE still set, then FM_ROOT_OVERRIDE pointing at the lab) or found the key already folded closed by the mate's
terminal `done` line on task mate; those are fixture mistakes, corrected in s5-keyed-close-clean.txt.
