# Declared pause survives a foreign append — end-to-end evidence

Branch `fm/firstmate-declared-pause-masked-by-any-append`
(base `5b4ba1b` → target `160fdc3`).

`repro-declared-pause.sh` drives a whole firstmate tree — the real
`bin/fm-crew-state.sh`, `bin/fm-watch.sh` and `bin/fm-wake-drain.sh` — over the
reported live sequence from `state/firstmate-attest-upstream-pr3753.status`:

    paused: waiting on the upstream maintainer to review PR 3753
    working: run 01M1T9RF188DHFWHN5YRQVXZ8Q step ci,failed   <- foreign append

with the crew's pane idle and unchanged for 500s, past the watcher's
possible-wedge threshold. Only `no-mistakes` (no active run) and `tmux` (an idle
pane) are faked; every decision in the transcripts is the product's own.

    ./repro-declared-pause.sh <tree> <label> [masked|undeclared|bounded]

## declared-pause-before-after.txt — the defect and the fix

| | base 5b4ba1b | target 160fdc3 |
|---|---|---|
| `fm-crew-state.sh` | `state: working · source: status-log · run …` | `state: paused · source: status-log · waiting on the upstream maintainer…` |
| `crew_absorb_class` | `none` (wedge ladder) | `paused` (absorbed) |
| `fm-watch.sh` | exits: `stale: … (idle 501s, possible wedge, escalation 1)` | no wake |
| `fm-wake-drain.sh` | one `stale` row handed to firstmate | empty |
| wedge ladder | `.wedge-escalations` = 1 | not climbing; `.paused-<win>` written |

Each of those base wake rows is one supervision turn — the cost the intent's two
measurements attribute to already-declared workers.

## declared-pause-safety-directions.txt — suppression neither widened nor silent

* `undeclared`: byte-for-byte the same log with the `paused:` line removed still
  escalates on the target — `stale: … (idle 501s, possible wedge, escalation 1)`.
* `bounded`: the absorbed declaration comes back past `FM_PAUSE_RESURFACE_SECS`
  as `stale: … (paused 501s, awaiting external - declared pause, rechecked on a
  long cadence not a wedge; confirm the wait still holds)` — a recheck, never a
  wedge, so a worker that declared a wait and then genuinely wedged is still
  reachable.
