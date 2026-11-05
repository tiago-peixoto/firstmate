# Live evidence for fm/tr-8153-bearings-calls

Driver: `drive-bearings-calls.sh <worktree> <evidence-dir>` (transcript in `drive-bearings-calls.log`).
It mints a disposable lab home with `bin/fm-lab-home.sh create`, writes a backlog whose `## Queued` section precedes `## In flight`,
raises the path-only hold with the real producer `bin/fm-captain-hold.sh hold path-call --title "Review proposal" --reason data/proposal/report.md`
(stored as `fm-hold-v1:<base64>`), then runs the real `bin/fm-bearings-snapshot.sh` three times.

- `bearings-all-decisions.json`: `--json --all-decisions` output. `long-call` keeps its 200+ character question with all three options.
  `path-call` is `needs presenting`; `prose-path-call` (prose containing a path) stays `presented`.
  Order is `waiting-call, cleared-call` (In flight, unblocked, `stops_worker: true`) before every Queued or blocked call,
  and `gated-call` (In flight, blocker still Queued) has `stops_worker: false`.
- `bearings-all-decisions.toon`: default captain-facing TOON output. `presentation` and `stops_worker` render as plain scalars.
- `bearings-default.json`: default bucket without `--all-decisions`; blocked holds are absent, worker-stopping calls still lead.
- `test-fm-bearings-snapshot.log`, `test-fm-fleet-snapshot-view.log`: the verification plan's two test files, exit status on the last line.
