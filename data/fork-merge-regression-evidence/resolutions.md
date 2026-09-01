# Upstream merge behavior resolutions

This report records the construct decision, causal evidence, red-to-green proof, and minimal resolution for each merge-owned failure.

## Harness adapter routing artifact

- Test: `tests/fm-harness-adapter-references.test.sh`.
- Construct: the `harness-adapter-routing-v1` operation-to-reference matrix in `.agents/skills/harness-adapters/SKILL.md`.
- Verdict: competing concept.
  Upstream replaced the monolithic routing mechanism with a split router whose matrix selects common and harness-specific references.
  The fork has no separate behavior to layer over that mechanism.
- Cause: the merge kept upstream's split-router prose and reference files but omitted the matrix carried by upstream parent `4ad8cbaeafc109a17c1af3911867b7fe9e04e801`, leaving the structural reader with an empty artifact.
- Resolution: restore upstream's matrix verbatim beneath the detection section.
- Red proof: the unfixed branch reports `not ok - harness adapter routing artifact is not a normalized operation and harness map`.
- Green proof: the restored matrix reports `ok - harness adapter routing artifact is normalized and every target is readable`, and its JSON block is byte-identical to the upstream parent's block.

## Bearings board order proof

- Test: `tests/fm-bearings-board.test.sh`.
- Construct: the owner-private `state/` precondition of `fm_procevent_claim_state_root_identity`, exercised while `fm-bearings-board.sh build` binds an immediately completing Lavish source before arming it.
- Verdict: competing concept. Upstream replaced permissive process-event capture with identity-bound extension capture rooted in an owner-private state directory; weakening that invariant would restore an obsolete assumption, not fork behavior.
- Cause: the behavior fixture created `state/` under the ambient `022` umask and passed macOS's noncanonical `/var/...` alias rather than its `/private/var/...` identity, so the upstream runner rejected the state root before recording a claim.
- Resolution: keep upstream's claim mechanism and make the fixture model a real Firstmate state root: canonical absolute identity and mode `0700`.
- Red proof: the unfixed branch reports `not ok - the order-proof board build failed` after `cannot claim source`.
- Green proof: the same immediate-result order proof passes after correcting the fixture mode.

## Pi branch outcomes rendering

- Test: `tests/fm-pi-branch-extension.test.sh`.
- Construct: the `fm_branch_outcomes` stock-rendering capability probe and `renderResult` color scoping in `.pi/extensions/fm-branch-supervision.ts`.
- Verdict: addition. Upstream's custom renderer is the required mechanism for hiding outcome rows in Calm mode, and its stock preview probe is the right seam; the fork behavior to layer onto it is compatibility with every installed Pi stock renderer rather than only Pi 0.84.4's line-scoped colors.
- Cause: upstream's renderer always reset `toolOutput` color per line. Pi 0.83.0 stock rendering holds one foreground scope across multiline output, so Calm-off output differed byte-for-byte even though the content was the same.
- Resolution: extend the existing stock capability probe to detect foreground-reset scope and use either stock-style whole-output coloring or stock-style per-line coloring. Keep upstream's preview and expansion mechanism unchanged.
- Red proof: the unfixed branch reports `Calm-off ToolExecutionComponent rendering differs from Pi stock` against installed Pi 0.83.0.
- Green proof: the focused suite compares collapsed, expanded, live-toggle, and HTML-export consumers against the installed Pi 0.83.0 stock renderer and passes for its whole-output color scope; its capability-conditional assertions retain the collapsed-preview contract used by newer Pi renderers.

## Deterministic condition-to-action process events

- Test: `tests/fm-procevent-when.test.sh`.
- Construct: the canonical owner-private state-root precondition used by the upstream process-event claim mechanism when `reconcile` starts the winning concurrent `when` registration.
- Verdict: competing concept. Upstream's trusted extension capture supersedes permissive claims from noncanonical or group/world-writable state roots; the `when` adapter itself is unchanged and must not weaken that boundary.
- Cause: the suite passed macOS's `/var/...` alias and `0755` state fixtures into the merged claim mechanism, so the winning registration could be published but its runner could not acquire a claim or produce an outcome.
- Resolution: retain upstream's claim mechanism, canonicalize the suite temp root, and create every fixture state directory at mode `0700`.
- Red proof: the unfixed suite reports `not ok - the winning concurrent arm did not produce an outcome`.
- Green proof: the same concurrent-arm outcome and the complete `when` behavior suite pass with production code unchanged.

## Generic process-event runner

- Test: `tests/fm-procevent.test.sh`.
- Construct: `fm_procevent_claim_acquire_locked`'s state-root identity validation, first exercised when `reconcile` starts `src-one`.
- Verdict: competing concept. Upstream's trusted extension runner intentionally refuses noncanonical or non-private state roots; the fork's generic runner behavior belongs on top of that safety boundary, not through a permissive duplicate path.
- Cause: the generic suite's homes inherited a `0755` mode and macOS's `/var/...` alias, so registration succeeded but the detached runner never acquired `src-one`'s claim.
- Resolution: preserve upstream's runner and make the suite's shared home constructor produce canonical roots with `0700` state directories.
- Red proof: the unfixed suite reports `not ok - reconcile never claimed the registered source`.
- Green proof: the complete generic process-event behavior suite passes with production code unchanged.
