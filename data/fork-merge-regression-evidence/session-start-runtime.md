# Session-start runtime comparison

This measurement answers whether the merged `tests/fm-session-start.test.sh` failure represents an unbounded regression or a bounded upstream cost that collided with the comparison runner's ad hoc 300-second ceiling. No code or timeout bound was changed for these runs.

## Completed runs

| Side | Context | Exit | Duration |
| --- | --- | ---: | ---: |
| merged head `c9467596` | isolated candidate rerun recorded in `candidates.log` | 0 | 213.480 s |
| pre-merge control | original full-suite comparison recorded in `control.log` | 0 | 201.914 s |
| merged head `c9467596` | fresh direct run 1 | 0 | 216.662 s |
| pre-merge control | fresh direct run 1 | 0 | 207.263 s |
| merged head `c9467596` | fresh direct run 2 | 0 | 251.623 s |
| pre-merge control | fresh direct run 2 | 0 | 221.391 s |

The merged median is 216.662 seconds with a 213.480-251.623-second range. The control median is 207.263 seconds with a 201.914-221.391-second range. The two fresh alternating pairs put the merged side 9.399 and 30.232 seconds above control; the earlier observations differ by 11.566 seconds. The direction is consistent, while the magnitude varies with host load.

Every completed direct run on both sides stayed below 300 seconds. The only observation above the comparison ceiling was the original loaded full-suite merged run, externally terminated at 301.387 seconds: 1.387 seconds, or 0.46%, above the imposed limit. It did not complete above 300 seconds, so the evidence supports a marginal loaded-suite collision, not a runtime that consistently exceeds 300 seconds.

## Bound and attribution

The merged script and control script each contain the same 50 session-start invocation lines after excluding helper declarations and comments, including the secondmate helper calls that route through `run_session_start`. The merged production path adds one synchronous `fm-home-summary-refresh.sh --best-effort` publication to every writable, non-reemit locked start. That helper sets `HOME_SUMMARY_TIMEOUT` to 60 seconds by default and runs the complete worker through `fm_run_timed`; a timeout is logged and converted to best-effort success. The session-start invocation itself remains bounded by `FM_SESSION_START_TIMEOUT`, default 120 seconds.

Therefore the added mechanism is explicitly bounded and selected by upstream. The complete test's wall time remains host-load-sensitive because it exercises many bounded session-start invocations, but the new synchronous step is not an unbounded wait. The observed 9.399-30.232-second paired overhead is consistent with paying that bounded publication repeatedly across the suite.

## Decision evidence

- Classification: bounded, explainable upstream cost; not an unbounded variable wait.
- 300-second behavior: not consistently exceeded; the one loaded-suite result was marginally over and externally killed.
- Selected comparison posture: on 2026-09-01 the captain chose to absorb the preferred upstream publication cost and raise this comparison's external per-script bound from 300 to 600 seconds. That is more than twice the merged direct maximum of 251.623 seconds and leaves 298.613 seconds above the one loaded-suite termination at 301.387 seconds. No production timeout, runtime assertion, or second guard changes.
