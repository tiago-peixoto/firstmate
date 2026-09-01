# Crew-state undetermined end-to-end evidence

Generated from target commit `f6689be4ccd15deb43a44faf62c81e35932c16c6`. Fixture-only paths are ephemeral.

## Fleet view shown to the operator

```text
# Fleet View

Schema: fm-fleet-snapshot.v1
Home: <fixture>/view-home

## Under Way
| ID | Current | Kind | Repo/Project | Backend | Endpoint | Artifact | Path | Watch / return channel |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| undetermined-task | undetermined / run-step | ship | alpha | tmux | present | - | <fixture>/view-home/projects/undetermined-task | bin/fm-peek.sh fm-undetermined-task |

## Queued
No queued backlog records found.

## Done
No done backlog records found.

## Secondmates
For kind=secondmate, bearings selects validated structured state from that registered home; parent events and bounded terminal evidence are fallback-only supplements and never current-state authority.
```

## Structured secondmate summary

```json
{
  "valid": false,
  "state": "unknown",
  "reason": "child current state unavailable or undetermined: undetermined-task",
  "invalidity": {
    "kind": "child_current_unavailable",
    "ids": [
      "undetermined-task"
    ]
  },
  "decisions_open": [
    {
      "id": "undetermined-task",
      "key": "route",
      "verb": "needs-decision",
      "summary": "choose the delivery route",
      "reason": null,
      "source": "status"
    }
  ]
}
```

## Real watcher surfaces conflicting evidence

### Stable ordinary worker

```text
watcher output: stale: test:fm-evidence-ship-stable
queued event: stale: stale: test:fm-evidence-ship-stable
pause-cadence wording: absent
```

### Changed secondmate pane

```text
watcher output: stale: test:fm-evidence-secondmate-changed
queued event: stale: stale: test:fm-evidence-secondmate-changed
pause-cadence wording: absent
```

### Over-age busy pane

```text
watcher output: stale: test:fm-evidence-busy-undetermined
queued event: stale: stale: test:fm-evidence-busy-undetermined
pause-cadence wording: absent
wedge timer: absent
```
