## Flag ON: fm-send --fire-and-forget into a live Claude pane whose composer holds a captain draft
rc=0
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at <LAB>/state/domain.inbox/001.msg and the watcher will ring it once more
.retry-ring => 001.msg (written)

## Watcher inbox_steer_check with open needs-decision [key=pick], mark aged 10m
check rc=0
mark still: 001.msg; pane composer untouched (no doorbell)

## After 'resolved [key=pick]': watcher check
check rc=0
.retry-ring removed; Claude received doorbell and handled 001.msg

## Third check: quiet
check rc=0
doorbell count in pane scrollback: 1

## Flag OFF: same send
rc=0
fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at <LAB>/state/domain.inbox/002.msg and the watcher will re-ring
no .retry-ring written; watcher check:
check rc=0
doorbell count still 1 (no retry ring)
