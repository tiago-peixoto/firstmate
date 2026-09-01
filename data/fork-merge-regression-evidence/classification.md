# Upstream merge result-set classification

Classification only; no additional fixes were made during this phase.
The counts were reissued after `7a9ca327d461d197d2a48052dc6c70deef8eb013` landed on main and three previously undetermined failures received verified baseline causes.

## Accounting

- Merged candidate: 179 scripts, 26 raw failures, 24 expected gate skips.
- Pre-merge control: 165 scripts, 19 raw failures, 23 expected gate skips.
- Every merged-candidate script has exactly one verdict below:
  - 114 passed on both sides.
  - 23 were expected-gate-skipped on both sides, so their behavior could not be determined by these runs.
  - 3 failed on the control and passed on the merged candidate (upstream improvement, not a regression).
  - 9 passed on the control and failed on the merged candidate (merge-candidate regressions under the full-suite conditions).
  - 16 failed on both sides: 4 environmental, 6 known-broken baseline, and 6 undetermined.
  - 14 exist only on the merged candidate: 12 passed, 1 was expected-gate-skipped, and 1 exposed a merge defect by direct change inspection.

The 26 merged-candidate failures therefore sit in exactly three sets: 9 control-pass/merged-fail, 16 fail-both, and 1 merged-only failure.
Ten are merge-owned: the 9 control-pass/merged-fail results plus the confirmed merged-only router-artifact defect.

**Unresolved-mechanism warning:** `tests/fm-session-start.test.sh` and `tests/fm-watch-arm.test.sh` pass in isolation but fail only in the full merged suite.
Their order- or timing-dependent mechanism remains unresolved, so the isolated passes do not clear them.

## Control-pass / merged-fail: 9 merge-candidate regressions

All nine are owned by the merge comparison because the same full-suite run passed them on the control. An isolated merged rerun reproduced seven; two passed in isolation and remain full-suite/order-dependent regressions whose mechanism is not yet determined.

| Script | Isolated merged verdict | Exact observed failure |
|---|---|---|
| `tests/fm-bearings-board.test.sh` | Reproduced | The order-proof board build failed. |
| `tests/fm-pi-branch-extension.test.sh` | Reproduced | Pi outcomes-rendering consumers did not preserve stock behavior. |
| `tests/fm-procevent-when.test.sh` | Reproduced | The winning concurrent arm did not produce an outcome. |
| `tests/fm-procevent.test.sh` | Reproduced | Reconcile never claimed the registered source. |
| `tests/fm-session-start.test.sh` | Full-suite-only / mechanism undetermined | Full run exceeded 300 seconds; isolated run passed in 213.480 seconds. |
| `tests/fm-status-event-time.test.sh` | Reproduced | The captain-relevant fleet scan disagreed on a mixed fleet. |
| `tests/fm-turnend-guard.test.sh` | Reproduced | The block reason omitted `queued wake delivery pending`. |
| `tests/fm-watch-arm.test.sh` | Full-suite-only / mechanism undetermined | Full run said re-arm stayed live instead of surfacing durable wakes and the still-open remote decision; isolated run passed in 62.202 seconds. |
| `tests/fm-watch-triage.test.sh` | Reproduced | The fixture captured no process-event result (308.502-second isolated run). |

## Fail-both: 16

### Environmental: 4

The installed terminal manager reports `herdr 0.8.2`. Each of these four produced the same concrete `treehouse get did not enter a worktree within 60s` failure on both sides, with closely matched durations:

| Script | Merged | Control |
|---|---:|---:|
| `tests/fm-backend-autodetect-smoke.test.sh` | 66.336 s | 65.885 s |
| `tests/fm-backend-herdr-launcher-workspace-e2e.test.sh` | 67.561 s | 66.697 s |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | 71.934 s | 69.283 s |
| `tests/fm-backend-herdr-workspace-per-home-e2e.test.sh` | 69.125 s | 66.145 s |

### Known-broken pre-merge baseline: 6

Commit `7a9ca327d461d197d2a48052dc6c70deef8eb013` (`test: repair stale portable CI fixtures`) is now main itself, and main CI is all green after that repair.
The commit changes and captured failures confirm these five as repaired stale portable-CI fixtures, fully clearing them of the merge:

- `tests/fm-gotmp.test.sh` - both logs report that teardown left the task-temp directory behind; the repair supplies the fixture's missing session-lock library and orphan-reaper stub.
- `tests/fm-kimi-harness.test.sh`
- `tests/fm-on.test.sh` - both logs report that the read-only doctor missed the stopped worker; the repair supplies the remote fixture's missing runtime libraries and correct worker-tree cleanup.
- `tests/fm-secondmate-safety.test.sh`
- `tests/fm-teardown.test.sh`

`tests/fm-muse-harness.test.sh` is a separate confirmed baseline defect tracked as `firstmate-muse-detection-unknown-macos`.
Both logs match that filed cause exactly: a `muse-bin-0.1.0-R708.1` process ancestor is expected to classify as `muse` but produces no verdict (`unknown`).

### Undetermined: 6

Both result sets are red, but there is neither the concrete Herdr 0.8.2 worktree-entry signature nor a named known-baseline repair. A fail-both result cannot clear or convict the merge for these:

- `tests/fm-backend-herdr.test.sh` (both runs timed out at about 300 seconds after the same final unit assertion; unlike the four environmental cases, neither log identifies a worktree-entry timeout)
- `tests/fm-composer-lib.test.sh`
- `tests/fm-gitignore-config.test.sh`
- `tests/fm-pending-reply.test.sh`
- `tests/fm-pr-check-security.test.sh`
- `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`

## Confirmed merged-only defect: dropped harness routing artifact

`tests/fm-harness-adapter-references.test.sh` exposed a standalone merge defect.
The merged router kept the split-router prose while dropping the machine-readable `harness-adapter-routing-v1` operation matrix.
The upstream second parent `4ad8cbaeafc109a17c1af3911867b7fe9e04e801` carries that matrix, introduced by `c731c36c`, while the merge result does not.
The matching prose hid the absent artifact: a construct present in upstream is not behavior running in the merge result.

## Merged-only corpus: 14 direct-change verdicts

These scripts do not exist on the control, so none is called control-pass or control-fail. Their verdicts come from the introduced construct and the merged run itself.

| Script | Introduced construct | Verdict |
|---|---|---|
| `tests/fm-backlog-atomicity.test.sh` | Backlog/record pairing invariant from `1260adce`. | Integrated and passed. |
| `tests/fm-bearings-board-render.test.sh` | Shipped board-render behavior from `60bedde5`. | Integrated and passed. |
| `tests/fm-check-unregister.test.sh` | Safe named custom-check retirement from `0866a770`. | Integrated and passed. |
| `tests/fm-classify-corr-token.test.sh` | Correlation-token-transparent status classification from `9ce69acf`. | Integrated and passed. |
| `tests/fm-extension-binding.test.sh` | Trusted process-event extension bindings from `1fbc7bb1`. | Integrated and passed. |
| `tests/fm-harness-adapter-instructions-live-e2e.test.sh` | Model evaluation of the split harness-router instructions from `c731c36c`. | Could not determine: the declared opt-in environment gate skipped it. |
| `tests/fm-harness-adapter-references.test.sh` | Machine-readable `harness-adapter-routing-v1` operation/harness map from `c731c36c`. | Confirmed merge defect: see the standalone defect section above. |
| `tests/fm-home-summary-refresh.test.sh` | Per-home summary ledger publication from `a3906593`. | Integrated and passed. |
| `tests/fm-no-mistakes-required.test.sh` | PR-head-bound no-mistakes attestation from `3e5577b2`. | Integrated and passed. |
| `tests/fm-procevent-quota.test.sh` | Extracted mid-task quota polling from `4ad8cbae`. | Integrated and passed. |
| `tests/fm-quota-choose.test.sh` | Extracted quota candidate selection from `4ad8cbae`. | Integrated and passed. |
| `tests/fm-remote-transport-lanes.test.sh` | Concurrent bounded per-home transport lanes from `1fd7ea28`. | Integrated and passed. |
| `tests/fm-secondmate-reconcile.test.sh` | Cooldown-limited secondmate reconciliation request from `60bedde5`. | Integrated and passed. |
| `tests/fm-test-fixtures.test.sh` | Central shared shell-fixture builders from `0ace60ab`. | Integrated and passed. |

## Control failures removed on the merged candidate: 3

These are upstream improvements relative to the frozen pre-merge control result, not regressions:

- `tests/fm-backend-orca.test.sh`
- `tests/fm-bootstrap-network-parallel.test.sh`
- `tests/fm-public-followup.test.sh`

## Expected-gate-skipped on both sides: 23

These are not passes or failures; their configured opt-in/optional gates did not exercise the behavior in either run:

- `tests/fm-afk-pi-herdr-return-e2e.test.sh`
- `tests/fm-backend-cmux-smoke.test.sh`
- `tests/fm-backend-zellij-smoke.test.sh`
- `tests/fm-claude-stop-autoarm-live-e2e.test.sh`
- `tests/fm-cmux-claude-composer-live-e2e.test.sh`
- `tests/fm-codex-continuity-live-e2e.test.sh`
- `tests/fm-composer-matrix-live-e2e.test.sh`
- `tests/fm-cursor-primary-live-e2e.test.sh`
- `tests/fm-grok-continuity-live-e2e.test.sh`
- `tests/fm-grok-stop-live-e2e.test.sh`
- `tests/fm-harness-liveness-drift-live-e2e.test.sh`
- `tests/fm-herdr-submit-confirm-live-e2e.test.sh`
- `tests/fm-herdr-version-floor-live-e2e.test.sh`
- `tests/fm-muse-signals-live-e2e.test.sh`
- `tests/fm-opencode-primary-live-e2e.test.sh`
- `tests/fm-pi-branch-live-e2e.test.sh`
- `tests/fm-pi-primary-live-e2e.test.sh`
- `tests/fm-pi-primary-types.test.sh`
- `tests/fm-quota-array-dispatch-live-e2e.test.sh`
- `tests/fm-send-inbox-doorbell-live-e2e.test.sh`
- `tests/fm-send-secondmate-marker-herdr-e2e.test.sh`
- `tests/fm-sessionstart-hook-live-e2e.test.sh`
- `tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh`

## Passed on both sides: 114

- `tests/fm-afk-inject-e2e.test.sh`
- `tests/fm-afk-inject-herdr-e2e.test.sh`
- `tests/fm-afk-launch.test.sh`
- `tests/fm-afk-return.test.sh`
- `tests/fm-arm-pretool-check.test.sh`
- `tests/fm-ask-user-authority.test.sh`
- `tests/fm-backend-cmux.test.sh`
- `tests/fm-backend-herdr-eventwait-smoke.test.sh`
- `tests/fm-backend-herdr-focus-flash-e2e.test.sh`
- `tests/fm-backend-herdr-prune-safety-e2e.test.sh`
- `tests/fm-backend-herdr-respawn-idem-e2e.test.sh`
- `tests/fm-backend-herdr-smoke.test.sh`
- `tests/fm-backend-tmux-smoke.test.sh`
- `tests/fm-backend-zellij.test.sh`
- `tests/fm-backend.test.sh`
- `tests/fm-backlog-handoff.test.sh`
- `tests/fm-bearings-snapshot.test.sh`
- `tests/fm-bootstrap.test.sh`
- `tests/fm-branch-supervision.test.sh`
- `tests/fm-brief.test.sh`
- `tests/fm-busy-adapter-wiring.test.sh`
- `tests/fm-busy-state.test.sh`
- `tests/fm-calm-pi-extension.test.sh`
- `tests/fm-captain-hold-lifecycle.test.sh`
- `tests/fm-cd-pretool-check.test.sh`
- `tests/fm-classify-decision-key.test.sh`
- `tests/fm-claude-stop-autoarm.test.sh`
- `tests/fm-composer-ghost.test.sh`
- `tests/fm-control-herdr-smoke.test.sh`
- `tests/fm-control-relaunch.test.sh`
- `tests/fm-control.test.sh`
- `tests/fm-crew-state.test.sh`
- `tests/fm-cursor-harness.test.sh`
- `tests/fm-cursor-primary.test.sh`
- `tests/fm-daemon.test.sh`
- `tests/fm-documentation-audiences.test.sh`
- `tests/fm-ensure-agents-md.test.sh`
- `tests/fm-fleet-snapshot-view.test.sh`
- `tests/fm-fleet-sync.test.sh`
- `tests/fm-fork-main.test.sh`
- `tests/fm-gate-refuse.test.sh`
- `tests/fm-grok-harness.test.sh`
- `tests/fm-guard-stale-banner.test.sh`
- `tests/fm-herdr-lab.test.sh`
- `tests/fm-herdr-session-cleanup-e2e.test.sh`
- `tests/fm-herdr-session-cleanup.test.sh`
- `tests/fm-inactive-reconcile.test.sh`
- `tests/fm-lint-workflows.test.sh`
- `tests/fm-lint.test.sh`
- `tests/fm-next-cache-sweep.test.sh`
- `tests/fm-nm-pr-target.test.sh`
- `tests/fm-operational-input.test.sh`
- `tests/fm-peek-remote.test.sh`
- `tests/fm-pi-watch-extension.test.sh`
- `tests/fm-pr-merge.test.sh`
- `tests/fm-project-origin.test.sh`
- `tests/fm-remote-backlog-handoff.test.sh`
- `tests/fm-remote-doctor.test.sh`
- `tests/fm-remote-entrypoint.test.sh`
- `tests/fm-remote-job-orphan-reap.test.sh`
- `tests/fm-remote-job.test.sh`
- `tests/fm-remote-reply.test.sh`
- `tests/fm-remote-secondmate-parent-binding.test.sh`
- `tests/fm-remote-secondmate-trace-context.test.sh`
- `tests/fm-review-diff.test.sh`
- `tests/fm-secondmate-harness.test.sh`
- `tests/fm-secondmate-lifecycle-e2e.test.sh`
- `tests/fm-secondmate-liveness.test.sh`
- `tests/fm-secondmate-sync.test.sh`
- `tests/fm-send-inbox.test.sh`
- `tests/fm-send-popup-settle.test.sh`
- `tests/fm-send-remote-delivery.test.sh`
- `tests/fm-send-resolve-key.test.sh`
- `tests/fm-send-secondmate-marker.test.sh`
- `tests/fm-send-settle.test.sh`
- `tests/fm-send-strict.test.sh`
- `tests/fm-session-lock-ancestry.test.sh`
- `tests/fm-sessionstart-nudge.test.sh`
- `tests/fm-shared-captain-inheritance.test.sh`
- `tests/fm-spawn-batch.test.sh`
- `tests/fm-spawn-dispatch-profile.test.sh`
- `tests/fm-spawn-pool-base-freshen.test.sh`
- `tests/fm-spawn-worktree-settle.test.sh`
- `tests/fm-startup-memory-budget.test.sh`
- `tests/fm-startup-network.test.sh`
- `tests/fm-stow-cascade.test.sh`
- `tests/fm-subagent-pretool-check.test.sh`
- `tests/fm-supervision-events.test.sh`
- `tests/fm-supervision-instructions.test.sh`
- `tests/fm-tangle-guard.test.sh`
- `tests/fm-task-delivery.test.sh`
- `tests/fm-task-inbox.test.sh`
- `tests/fm-teardown-endpoint-safety.test.sh`
- `tests/fm-test-fixture-cleanup.test.sh`
- `tests/fm-test-isolation-proof.test.sh`
- `tests/fm-test-run.test.sh`
- `tests/fm-tmux-agent-liveness.test.sh`
- `tests/fm-tmux-submit-busy.test.sh`
- `tests/fm-tool-update-check.test.sh`
- `tests/fm-trace-context-lib.test.sh`
- `tests/fm-trace-context-spawn.test.sh`
- `tests/fm-transition-lib.test.sh`
- `tests/fm-update.test.sh`
- `tests/fm-vendor-auth-probe.test.sh`
- `tests/fm-voice-relay.test.sh`
- `tests/fm-wake-daemon-lifecycle-e2e.test.sh`
- `tests/fm-wake-drain-open-decisions-cursor.test.sh`
- `tests/fm-wake-drain-open-decisions.test.sh`
- `tests/fm-wake-drain-unread-status.test.sh`
- `tests/fm-wake-queue.test.sh`
- `tests/fm-watch-checkpoint.test.sh`
- `tests/fm-watch-recovery-loop.test.sh`
- `tests/fm-watcher-lock.test.sh`
- `tests/fm-x-mode.test.sh`
