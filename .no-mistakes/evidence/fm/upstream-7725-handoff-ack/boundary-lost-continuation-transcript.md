# boundary hand-back with a lost main continuation (opt-in enabled)

Fixture home: /tmp/fm-supervision-host.HjqQqU/ev-boundary
Real scripts: bin/fm-claude-stop-autoarm.sh, bin/fm-supervision-host.sh, bin/fm-supervision-handoff.sh, bin/fm-watch-arm.sh, bin/fm-watch.sh, bin/fm-wake-drain.sh. The harness is a bash process named claude; the engine is the suite stub.

## 1. park started: host owns the watcher  (2026-10-24T16:34:36Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2157911 (alive: yes) parent: 2157837
host pid recorded: 2157278
host-left record: <none>
arm processes from this home (pid ppid): 2157837 2157278
hook exit code: <running>

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
<absent>
```

### Stop hook stderr (what Claude would receive as the exit-2 continuation)
```
firstmate watcher wake - one supervision event needs a handling turn now.
supervision-host: cycle boundary - the host ended its park at its bound; drain, acknowledge, and end the turn
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
```

## 2. hand-back emitted, hook process group torn down, main NEVER runs its turn  (2026-10-24T16:34:39Z)

opt-in flag present: yes
pending hand-back token: host-2157278-1792859675
handoff owner pid: 2161096 (alive: yes)
watcher pid: 2161660 (alive: yes) parent: 2161615
host pid recorded: 
host-left record: 2161615 linux-starttime=263969351 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d626f756e646172792f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2161615 2161096
hook exit code: 2

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
1792859678	handoff	host-2157278-1792859675
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
1792859677	1	check	supervision-handoff:host-2157278-1792859675	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
```

## 3. a later event closed the one-shot successor (pid 2161660); the owner replaced it and raised the hand-back again  (2026-10-24T16:34:42Z)

opt-in flag present: yes
pending hand-back token: host-2157278-1792859675
handoff owner pid: 2161096 (alive: yes)
watcher pid: 2165445 (alive: yes) parent: 2165395
host pid recorded: 
host-left record: 2165395 linux-starttime=263969729 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d626f756e646172792f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2165395 2161096
hook exit code: 2

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
1792859678	handoff	host-2157278-1792859675
```
### state/.supervision-handoff.log
```
1792859682	retry	host-2157278-1792859675	deferred
```
### state/.wake-queue
```
1792859677	1	check	supervision-handoff:host-2157278-1792859675	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859680	2	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-boundary/state/other.status
1792859681	3	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-boundary/state/other.status
```

### main drain output (what a main turn would read)
```
1792859677	1	check	supervision-handoff:host-2157278-1792859675	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859681	3	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-boundary/state/other.status
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 3 --recovery-generation 2161660.1792859681.IaxCta
wake annotation: latest wake-EVENT observed at drain, not current state: other.status: working [at=1792859680]: another event
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
```

## 4. ADVERSARIAL: a stale acknowledgement (--ack-through 0) that never saw the check row  (2026-10-24T16:34:44Z)

opt-in flag present: yes
pending hand-back token: host-2157278-1792859675
handoff owner pid: 2161096 (alive: yes)
watcher pid: 2165445 (alive: yes) parent: 2165395
host pid recorded: 
host-left record: 2165395 linux-starttime=263969729 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d626f756e646172792f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2165395 2161096
hook exit code: 2

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
1792859678	handoff	host-2157278-1792859675
```
### state/.supervision-handoff.log
```
1792859682	retry	host-2157278-1792859675	deferred
```
### state/.wake-queue
```
1792859677	1	check	supervision-handoff:host-2157278-1792859675	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859680	2	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-boundary/state/other.status
1792859681	3	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-boundary/state/other.status
```

## 5. main acknowledges with the exact printed command: --ack-through 3 --recovery-generation 2161660.1792859681.IaxCta  (2026-10-24T16:34:45Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2165445 (alive: yes) parent: 2165395
host pid recorded: 
host-left record: 2165395 linux-starttime=263969729 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d626f756e646172792f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2165395 5856
hook exit code: 2

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
1792859678	handoff	host-2157278-1792859675
```
### state/.supervision-handoff.log
```
1792859682	retry	host-2157278-1792859675	deferred
```
### state/.wake-queue
```
```

## 6. next park (turn end): exactly one arm, the host's child, owns the watcher  (2026-10-24T16:34:47Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2174398 (alive: yes) parent: 2172975
host pid recorded: 2171980
host-left record: 2165395 linux-starttime=263969729 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d626f756e646172792f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2172975 2171980
hook exit code: <running>

### state/.supervision-host.log
```
1792859675	start	gen=host-2157278-1792859675	primary=claude
1792859678	handoff	host-2157278-1792859675
1792859687	start	gen=host-2171980-1792859686	primary=claude
1792859687	take-over	arm=2165395
```
### state/.supervision-handoff.log
```
1792859682	retry	host-2157278-1792859675	deferred
```
### state/.wake-queue
```
```
