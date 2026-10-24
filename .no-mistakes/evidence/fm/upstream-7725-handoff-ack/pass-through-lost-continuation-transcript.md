# pass-through hand-back with a lost main continuation (opt-in enabled)

Fixture home: /tmp/fm-supervision-host.HjqQqU/ev-pass-through
Real scripts: bin/fm-claude-stop-autoarm.sh, bin/fm-supervision-host.sh, bin/fm-supervision-handoff.sh, bin/fm-watch-arm.sh, bin/fm-watch.sh, bin/fm-wake-drain.sh. The harness is a bash process named claude; the engine is the suite stub.

## 1. park started: host owns the watcher  (2026-10-24T16:34:50Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2178290 (alive: yes) parent: 2178242
host pid recorded: 2177747
host-left record: <none>
arm processes from this home (pid ppid): 2178242 2177747
hook exit code: <running>

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
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
signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.
```

## 2. hand-back emitted, hook process group torn down, main NEVER runs its turn  (2026-10-24T16:34:56Z)

opt-in flag present: yes
pending hand-back token: host-2177747-1792859689
handoff owner pid: 2184353 (alive: yes)
watcher pid: 2185855 (alive: yes) parent: 2185752
host pid recorded: 
host-left record: 2185752 linux-starttime=263970940 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d706173732d7468726f7567682f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2185752 2184353
hook exit code: 2

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
1792859692	pass-through	attended	main-only	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859695	handoff	host-2177747-1792859689
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
1792859691	1	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859691	2	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859693	3	check	supervision-handoff:host-2177747-1792859689	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
```

## 3. a later event closed the one-shot successor (pid 2185855); the owner replaced it and raised the hand-back again  (2026-10-24T16:34:58Z)

opt-in flag present: yes
pending hand-back token: host-2177747-1792859689
handoff owner pid: 2184353 (alive: yes)
watcher pid: 2193050 (alive: yes) parent: 2193009
host pid recorded: 
host-left record: 2185752 linux-starttime=263970940 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d706173732d7468726f7567682f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2193009 2184353
hook exit code: 2

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
1792859692	pass-through	attended	main-only	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859695	handoff	host-2177747-1792859689
```
### state/.supervision-handoff.log
```
1792859697	retry	host-2177747-1792859689	deferred
```
### state/.wake-queue
```
1792859691	1	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859691	2	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859693	3	check	supervision-handoff:host-2177747-1792859689	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859697	4	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/other.status
1792859697	5	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/other.status
```

### main drain output (what a main turn would read)
```
1792859691	2	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859693	3	check	supervision-handoff:host-2177747-1792859689	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859697	5	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/other.status
WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through 5 --recovery-generation 2185855.1792859697.jl6Tzw
wake annotation: latest wake-EVENT observed at drain, not current state: demo.status: needs-decision [at=1792859690]: which export format?
wake annotation: latest wake-EVENT observed at drain, not current state: other.status: working [at=1792859696]: another event
OPEN DECISIONS (still open, folded from the durable status logs - not just the latest line):
demo needs-decision: which export format?
OPEN DECISIONS: close one by answering it: bin/fm-send.sh <task> --resolve-key <key> '<answer>'
WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else.
```

## 4. ADVERSARIAL: a stale acknowledgement (--ack-through 0) that never saw the check row  (2026-10-24T16:35:00Z)

opt-in flag present: yes
pending hand-back token: host-2177747-1792859689
handoff owner pid: 2184353 (alive: yes)
watcher pid: 2193050 (alive: yes) parent: 2193009
host pid recorded: 
host-left record: 2193009 linux-starttime=263971343 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d706173732d7468726f7567682f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2193009 2184353
hook exit code: 2

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
1792859692	pass-through	attended	main-only	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859695	handoff	host-2177747-1792859689
```
### state/.supervision-handoff.log
```
1792859697	retry	host-2177747-1792859689	deferred
1792859700	retry	host-2177747-1792859689	deferred
```
### state/.wake-queue
```
1792859691	1	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859691	2	signal	demo.status	needs-decision: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859693	3	check	supervision-handoff:host-2177747-1792859689	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
1792859697	4	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/other.status
1792859697	5	signal	other.status	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/other.status
```

## 5. main acknowledges with the exact printed command: --ack-through 5 --recovery-generation 2185855.1792859697.jl6Tzw  (2026-10-24T16:35:01Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2193050 (alive: yes) parent: 2193009
host pid recorded: 
host-left record: 2193009 linux-starttime=263971343 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d706173732d7468726f7567682f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2193009 5856
hook exit code: 2

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
1792859692	pass-through	attended	main-only	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859695	handoff	host-2177747-1792859689
```
### state/.supervision-handoff.log
```
1792859697	retry	host-2177747-1792859689	deferred
1792859700	retry	host-2177747-1792859689	deferred
```
### state/.wake-queue
```
```

## 6. next park (turn end): exactly one arm, the host's child, owns the watcher  (2026-10-24T16:35:04Z)

opt-in flag present: yes
pending hand-back token: <none>
handoff owner pid: <none> (alive: no)
watcher pid: 2204338 (alive: yes) parent: 2203462
host pid recorded: 2202680
host-left record: 2193009 linux-starttime=263971343 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d706173732d7468726f7567682f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2203462 2202680
hook exit code: <running>

### state/.supervision-host.log
```
1792859690	start	gen=host-2177747-1792859689	primary=claude
1792859692	pass-through	attended	main-only	signal: /tmp/fm-supervision-host.HjqQqU/ev-pass-through/state/demo.status
1792859695	handoff	host-2177747-1792859689
1792859703	start	gen=host-2202680-1792859702	primary=claude
1792859703	take-over	arm=2193009
```
### state/.supervision-handoff.log
```
1792859697	retry	host-2177747-1792859689	deferred
1792859700	retry	host-2177747-1792859689	deferred
```
### state/.wake-queue
```
```
