# Host log rows for a close that turns main-only at its turn (handle_wake rc 2)

## opt-in without (config/supervision-handoff-ack absent)

hook exit: 2; pending token: <none>; watcher alive: yes

### state/.supervision-host.log
```
start	gen=host-2735224-1792860355	primary=claude
pass-through	attended	main-only	signal: /tmp/fm-supervision-host.2xlOVG/late-main-only-without/state/demo.status
```
### Stop hook stderr (rewake banner)
```
firstmate watcher wake - one supervision event needs a handling turn now.
signal: /tmp/fm-supervision-host.2xlOVG/late-main-only-without/state/demo.status
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
```

## opt-in with (config/supervision-handoff-ack present)

hook exit: 2; pending token: host-2744474-1792860364; watcher alive: yes

### state/.supervision-host.log
```
start	gen=host-2744474-1792860364	primary=claude
handoff	host-2744474-1792860364
```
### Stop hook stderr (rewake banner)
```
firstmate watcher wake - one supervision event needs a handling turn now.
signal: /tmp/fm-supervision-host.2xlOVG/late-main-only-with/state/demo.status
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
```
