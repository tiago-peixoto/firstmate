# Upstream merge behavior resolutions

This report records the construct decision, causal evidence, red-to-green proof, and minimal resolution for each merge-owned failure.

The post-fix mutation campaign made all ten target tests go red against a deliberate break of the behavior each one protects. No mutation-proof gap was found.

## Harness adapter routing artifact

- Test: `tests/fm-harness-adapter-references.test.sh`.
- Construct: the `harness-adapter-routing-v1` operation-to-reference matrix in `.agents/skills/harness-adapters/SKILL.md`.
- Verdict: competing concept.
  Upstream replaced the monolithic routing mechanism with a split router whose matrix selects common and harness-specific references.
  The fork has no separate behavior to layer over that mechanism.
- Cause: the merge kept upstream's split-router prose and reference files but omitted the matrix carried by upstream parent `4ad8cbaeafc109a17c1af3911867b7fe9e04e801`, leaving the structural reader with an empty artifact.
- Resolution: restore upstream's matrix verbatim beneath the detection section.
- Red proof: the unfixed branch reports `not ok - harness adapter routing artifact is not a normalized operation and harness map`.
- Mutation proof: changing the artifact fence from `harness-adapter-routing-v1` to an unrecognized marker made the focused test exit 1 with that same normalized-map failure.
- Green proof: the restored matrix reports `ok - harness adapter routing artifact is normalized and every target is readable`, and its JSON block is byte-identical to the upstream parent's block.

## Bearings board order proof

- Test: `tests/fm-bearings-board.test.sh`.
- Construct: the owner-private `state/` precondition of `fm_procevent_claim_state_root_identity`, exercised while `fm-bearings-board.sh build` binds an immediately completing Lavish source before arming it.
- Verdict: competing concept. Upstream replaced permissive process-event capture with identity-bound extension capture rooted in an owner-private state directory; weakening that invariant would restore an obsolete assumption, not fork behavior.
- Cause: the behavior fixture created `state/` under the ambient `022` umask and passed macOS's noncanonical `/var/...` alias rather than its `/private/var/...` identity, so the upstream runner rejected the state root before recording a claim.
- Resolution: keep upstream's claim mechanism and make the fixture model a real Firstmate state root: canonical absolute identity and mode `0700`.
- Red proof: the unfixed branch reports `not ok - the order-proof board build failed` after `cannot claim source`.
- Mutation proof: replacing the `fm-captain-hold.sh bind` call with a no-op made the focused test exit 1 with `not ok - the board source is not bound any-origin`.
- Green proof: the same immediate-result order proof passes after correcting the fixture mode.

## Pi branch outcomes rendering

- Test: `tests/fm-pi-branch-extension.test.sh`.
- Construct: the `fm_branch_outcomes` stock-rendering capability probe and `renderResult` color scoping in `.pi/extensions/fm-branch-supervision.ts`.
- Verdict: addition. Upstream's custom renderer is the required mechanism for hiding outcome rows in Calm mode, and its stock preview probe is the right seam; the fork behavior to layer onto it is compatibility with every installed Pi stock renderer rather than only Pi 0.84.4's line-scoped colors.
- Cause: upstream's renderer always reset `toolOutput` color per line. Pi 0.83.0 stock rendering holds one foreground scope across multiline output, so Calm-off output differed byte-for-byte even though the content was the same.
- Resolution: extend the existing stock capability probe to detect foreground-reset scope and use either stock-style whole-output coloring or stock-style per-line coloring. Keep upstream's preview and expansion mechanism unchanged.
- Red proof: the unfixed branch reports `Calm-off ToolExecutionComponent rendering differs from Pi stock` against installed Pi 0.83.0.
- Mutation proof: forcing `renderResult` down the line-scoped color branch instead of following the stock-renderer capability probe made the focused test exit 1 with `Calm-off ToolExecutionComponent rendering differs from Pi stock`.
- Green proof: the focused suite compares collapsed, expanded, live-toggle, and HTML-export consumers against the installed Pi 0.83.0 stock renderer and passes for its whole-output color scope; its capability-conditional assertions retain the collapsed-preview contract used by newer Pi renderers.

## Deterministic condition-to-action process events

- Test: `tests/fm-procevent-when.test.sh`.
- Construct: the canonical owner-private state-root precondition used by the upstream process-event claim mechanism when `reconcile` starts the winning concurrent `when` registration.
- Verdict: competing concept. Upstream's trusted extension capture supersedes permissive claims from noncanonical or group/world-writable state roots; the `when` adapter itself is unchanged and must not weaken that boundary.
- Cause: the suite passed macOS's `/var/...` alias and `0755` state fixtures into the merged claim mechanism, so the winning registration could be published but its runner could not acquire a claim or produce an outcome.
- Resolution: retain upstream's claim mechanism, canonicalize the suite temp root, and create every fixture state directory at mode `0700`.
- Red proof: the unfixed suite reports `not ok - the winning concurrent arm did not produce an outcome`.
- Mutation proof: making `cmd_run` execute `COND_ARGV` where it must execute `ACT_ARGV` made the focused test exit 1 because the winning concurrent registration recorded zero action invocations instead of one.
- Green proof: the same concurrent-arm outcome and the complete `when` behavior suite pass with production code unchanged.

## Generic process-event runner

- Test: `tests/fm-procevent.test.sh`.
- Construct: `fm_procevent_claim_acquire_locked`'s state-root identity validation, first exercised when `reconcile` starts `src-one`.
- Verdict: competing concept. Upstream's trusted extension runner intentionally refuses noncanonical or non-private state roots; the fork's generic runner behavior belongs on top of that safety boundary, not through a permissive duplicate path.
- Cause: the generic suite's homes inherited a `0755` mode and macOS's `/var/...` alias, so registration succeeded but the detached runner never acquired `src-one`'s claim.
- Resolution: preserve upstream's runner and make the suite's shared home constructor produce canonical roots with `0700` state directories.
- Red proof: the unfixed suite reports `not ok - reconcile never claimed the registered source`.
- Mutation proof: suppressing `publish_result`'s `fm_wake_append` call made the focused test exit 1 with `not ok - no event was published after the source completed`.
- Green proof: the complete generic process-event behavior suite passes with production code unchanged.

## Status event-time mixed-fleet scan

- Test: `tests/fm-status-event-time.test.sh`.
- Construct: the removed `scan_captain_relevant_statuses` last-line fleet scan, superseded upstream by `status_span_first_actionable_record` and caller-owned classified offsets.
- Verdict: competing concept. Upstream deliberately replaced last-line scanning because a later routine append can hide an earlier actionable event; restoring the fork helper would reintroduce the defective read model and duplicate the span mechanism.
- Cause: the fork-only event-time test still invoked the removed helper even though every production consumer had migrated to span classification.
- Resolution: keep upstream's span classifier and retarget the mixed stamped/unstamped fleet proof to call it from offset zero for each fixture log. No production construct is restored.
- Red proof: the unfixed suite reports `scan_captain_relevant_statuses: command not found` and then fails its mixed-fleet assertion.
- Mutation proof: making `status_span_first_actionable_record` skip every captain-relevant line made the focused test exit 1 with `not ok - the captain-relevant span scan disagreed on a mixed fleet` and an empty result.
- Green proof: the full status event-time suite passes, including the mixed fleet, wake-drain, crew-state, and latency cases.

## Turn-end guard queued-wake reason

- Test: `tests/fm-turnend-guard.test.sh`.
- Construct: the queue-only branches in `block_stop` and the terminal attended-failure `NEED_DESC` selection.
- Verdict: addition. Upstream's Stop-owned recovery and bounded block mechanism remains authoritative; the fork's shared supervision predicate adds durable queued wakes as a fourth reason supervision is needed, so its two user-facing reason selectors must name that state instead of falling through to X-mode.
- Cause: the merge kept the fork's `FM_SUP_QUEUE_PENDING` supervision input but adopted upstream's three-way guard message selection for tasks, sources, and X-mode, mislabelling an undelivered wake as Relay polling.
- Resolution: layer the two queue-only reason branches onto upstream's guard without changing its recovery mechanism.
- Red proof: the unfixed suite reports that the block reason is missing `queued wake delivery pending` and shows the incorrect X-mode reason.
- Mutation proof: disabling `block_stop`'s queue-only reason branch made the focused test exit 1 with the same missing `queued wake delivery pending` assertion and the incorrect `X-mode relay polling` banner.

### Read-only session ownership

- Construct: the foreign-live-session owner exemption before the Claude recovery predicate.
- Verdict: addition. Upstream's generation-claim recovery remains authoritative for the session that may mutate the home; this check covers a distinct scope where the current session is provably read-only and its matching auto-arm already defers to the live owner.
- Cause: adopting upstream's guard verbatim dropped the fork's narrow session-lock alignment, so the read-only session was blocked for failing to start recovery it was forbidden to own.
- Resolution: source the existing session-lock owner and add the pre-predicate foreign-live-owner exemption; do not restore the fork's superseded lock-held auto-arm claim or escalation machinery.
- Red proof: after the queue reason was restored, the suite reports that the read-only session returned exit 2 instead of 0.

### Auto-arm entry trace

- Construct: the `.claude-autoarm-entry-trace` assertion for `event=gate-live-session-owner`.
- Verdict: competing concept. The trace names decision points from the fork's retired lock-held-claim design and does not participate in the read-only-session guarantee.
- Resolution: keep upstream's generation-claim design and drop the trace assertion while preserving the end-to-end checks that both auto-arm and guard defer without displacing the live owner.
- Red proof: once behavior was restored, the suite failed only because the deliberately retired trace file was absent.

### Separate identical-block escalation

- Construct: `terminal_unclaimed_escalation`, its `UNCLAIMED_BLOCK_BUDGET`, evidence signatures, `reblocks=` ledger field, and `.turnend-claude-escalated` marker.
- Verdict: competing concept. Upstream replaces this second escalation path with generation-claim ownership plus `FM_CLAUDE_TURNEND_BLOCK_BUDGET`, `terminal_fail_open`, and fresh exhausted-failure epochs.
- Resolution: retain upstream's single recovery progression and delete the fork-only tests and marker assertions. The source-retirement test still proves the additive queued wake remains guarded, and the existing upstream-aligned tests continue to prove bounded failure progression and recovery reset.
- Red proof: the upstream-shaped guard correctly returned another block on the second unchanged stop, while the obsolete fork test expected its separate captain escalation.

### Post-wait supervision refresh

- Construct: the second `fm_supervision_status` read after the bounded auto-arm claim wait and before upstream's failure-budget accounting.
- Verdict: addition. It does not change generation claims or failure progression; it refreshes the shared predicate after a wait during which the supervised identity can retire and leave a durable queued wake.
- Cause: the initial snapshot still named the process-event source after it had retired, so the queue stayed guarded but the banner reported the stale source instead of the now-authoritative undelivered wake.
- Resolution: refresh the predicate at the end of the wait, exit if supervision genuinely ended, then continue through upstream's budget mechanism with current task/source/queue facts.
- Red proof: the source-retirement case remained blocked as required but incorrectly named one registered source instead of `queued wake delivery pending`.
- Green proof: the complete turn-end guard suite passes with upstream's generation-claim and bounded failure-epoch tests intact, the read-only owner and queued-wake additions covered end to end, and the superseded trace and separate escalation tests removed.
- Divergence effect: net reduced. The production guard is upstream plus 21 additive lines, while deleting the retired fork recovery tests reduces the two-file diff against upstream from 211 changed lines to 154.

## Watcher process-event delivery fixture

- Test: `tests/fm-watch-triage.test.sh`.
- Construct: the `pe_case` fixture's state-root identity passed to `fm_procevent_claim_acquire_locked` while `seed_captured_procevent_result` creates the queued result used by the watcher delivery proofs.
- Verdict: competing concept. Upstream replaced permissive process-event claims with claims bound to a canonical, owner-private state root; restoring the old acceptance rule would weaken the trusted extension mechanism for the sake of a test alias.
- Cause: the fixture passed macOS's `/var/...` alias while upstream canonicalized it to `/private/var/...` for identity verification, so the runner refused the claim and the fixture produced no queued result.
- Resolution: keep upstream's claim mechanism and canonicalize only the fixture case directory before registering, reconciling, or retiring its source.
- Red proof: the unfixed suite reports `error: cannot claim source: delivery-src` followed by `not ok - the fixture captured no process-event result`.
- Mutation proof: returning from `procevent_surface_queued` before inspecting the durable queue made the focused test exit 1 because the actionable reason was only `check: rearm-resurface` and did not name the queued process-event result.
- Green proof: the complete watcher triage suite passes, including proactive delivery, interrupted-handler replay, marker identity, serialization, crash-boundary replay, and acknowledgement behavior.
- Divergence effect: one test-fixture line added; production remains exactly upstream-shaped for this construct.

## Session-start comparison timeout

- Test: `tests/fm-session-start.test.sh`.
- Construct: upstream's locked-start `fm-home-summary-refresh.sh --best-effort` publication and its corresponding ledger assertion; the reported failure itself came from the comparison invocation's external `--per-script-timeout-secs 300` boundary, not from a failed session-start branch.
- Verdict: addition retained upstream. The structured per-home summary is new upstream behavior and no fork mechanism competes with it; removing, stubbing, or weakening it would manufacture divergence merely to satisfy a non-project timing ceiling.
- Cause: the comparative merged run was externally terminated at 301.387 seconds immediately before the watchdog assertion, while the same merged script completed every assertion in a direct run. The repository runner defaults this explicit bound to disabled for `--all` and uses 900 seconds for bounded `--changed`; 300 seconds was imposed only by the comparison harness.
- Resolution: restore no construct. Keep upstream's synchronous best-effort publication and run the final comparison with the repository's authoritative timeout behavior rather than the ad hoc 300-second ceiling.
- Red proof: the comparison log reports `not ok - tests/fm-session-start.test.sh exceeded the per-script bound of 300s and was terminated` after all assertions through Pi marker rejection had passed.
- Mutation proof: replacing the locked-start `fm-home-summary-refresh.sh --best-effort` call with a no-op made the focused test exit 1 with `not ok - a locked session start did not publish the home summary ledger`.
- Green proof: the current merged head completes the entire script, including watchdog, runtime-bound, re-emit, baseline, and ownership assertions, in a direct run with exit 0; the earlier isolated merged run also completed in 213.480 seconds.
- Divergence effect: none. Production and tests remain upstream-shaped for this construct.

## Watcher re-arm recovery timing

- Test: `tests/fm-watch-arm.test.sh`.
- Construct: the fixed `sleep 0.25` branch in `test_rearm_resurfaces_durable_queue_and_remote_open_decision`, which declared a live re-arm failed before observing its bounded lifecycle result.
- Verdict: competing concept. Upstream's watcher now performs richer recovery startup and v2 status-signature work before surfacing durable downtime state; the fixture must observe that mechanism's result rather than reinstate a quarter-second startup assumption.
- Cause: under the full merged-suite load, the re-arm was still legitimately starting after 250 milliseconds, so the fixture injected a cleanup status and reported a false failure. The same recovery completed normally when allowed to reach its existing bounded outcome.
- Resolution: keep upstream's recovery implementation and replace the fixed sleep/liveness guess with the shared `wait_for_exit` helper and its eight-second fixture bound, matching the surrounding recovery assertions.
- Red proof: the comparative merged log reports `not ok - re-arm stayed live instead of surfacing durable wakes and the still-open remote decision`; the control happened to finish inside the fixed quarter-second window.
- Mutation proof: making `resurface_after_downtime` return instead of emitting `check: rearm-resurface` made the focused test exit 1 with `not ok - re-arm stayed live instead of surfacing durable wakes and the still-open remote decision`.
- Green proof: the complete watcher-arm suite passes, including durable queue replay, open-decision refolding, interrupted handling, stale-lock recovery, generation acknowledgements, and symlink safety.
- Divergence effect: the upstream file needed no fork diff before this repair; the bounded-wait fixture adds 11 changed lines (`+3/-8`) and shortens the file by five lines. Production remains upstream-shaped.
