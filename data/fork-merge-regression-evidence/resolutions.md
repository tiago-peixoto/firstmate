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
