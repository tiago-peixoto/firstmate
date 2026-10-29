# Live validation of opt-in pending-reply re-surfacing (fm/upstream-4755 at 1df9b1ee)

All drives ran the real scripts from the run worktree against a disposable lab home
minted with bin/fm-lab-home.sh (removed afterwards).
The lab session lock was held through this agent's real Claude harness ancestry,
and "later session" means a re-keyed CLAUDE_CODE_SESSION_ID, so the session token
(bin/fm-pending-reply-remind.sh --token = <claude pid>:<session id>) changed each time.
The escalated records were produced by driving the pending-reply library through
delivery, a missed turn, a missed recovery (recovery delivery stubbed), and escalation.

| # | Scenario | Evidence | Result |
|---|----------|----------|--------|
| S8 | flag created in the session that already received the escalation: no second wake | 02-s8-midsession-optin-sidA.log, 02-s8-summary.txt | pass |
| S1 | flag absent, later session: no reminder wake, Bearings decisions_open [] | 03-s1-default-off-sidB.log, 03-s1-bearings-decisions-flag-absent.json | pass |
| S2 | flag present, later session: one `check pending-reply-escalated` wake in the WAKE QUEUE digest; surfaced_session re-stamped | 04-s2-optin-later-session-sidB.log, 04-s2-summary.txt | pass |
| S2b | same session starts again: still exactly one queued reminder | 05-s2b-same-session-again-sidB.log | pass |
| S3 | Bearings lists the escalation (verb blocked, key pending-reply-<corr>, owner "(main)") in JSON and TOON | 06-s3-bearings-decisions-flag-present.json, 06-s3-bearings-toon-flag-present.txt | pass |
| S4 | after ack, a third session is reminded once more | 07-s4-third-session-sidC.log | pass |
| S7 | unkeyed `resolved:`, other-key `resolved [key=api-shape]`, and `done:` lines do not dismiss: still reminded and listed | 08-s7-*.txt, 08-s7-other-closes-sidD.log, 08-s7-bearings-decisions.json | pass |
| S5 | mate reports `done [corr=..]` via bin/fm-secondmate-report.sh; one real bin/fm-watch.sh pass resolves it; next session has no reminder; Bearings [] | 09-s5-*.txt, 09-s5-watcher.log, 09-s5-after-resolve-sidE.log, 09-s5-bearings-after-resolve.json | pass |
| S6 | operator closes one of two escalations with bin/fm-send.sh --resolve-key: closed one gets escalation_dismissed_epoch, is neither reminded nor listed; the open one still is, across two later sessions | 10-s6-*.txt, 10-s6-after-operator-close-sidF.log, 10-s6-bearings-after-close.json, 11-s6b-dismissal-sticks-sidG.log | pass |
| S9 | fresh interactive `claude` primary in the lab tmux runs the SessionStart hook and presents the reminder | 12-s9-claude-primary-pane.txt | untested: the worktree cwd has no trust acceptance in ~/.claude.json, so the project hook in .claude/settings.json did not run |

Baseline: tests/fm-pending-reply.test.sh and tests/fm-bearings-snapshot.test.sh both pass
(baseline-*.log).
