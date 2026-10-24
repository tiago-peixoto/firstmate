# ADVERSARIAL: removing config/supervision-handoff-ack while a hand-back is pending

Fixture home: /tmp/fm-supervision-host.HjqQqU/ev-optout

## 1. boundary hand-back pending, owner alive, continuation lost  (2026-10-24T16:35:10Z)

opt-in flag present: yes
pending hand-back token: host-2206579-1792859705
handoff owner pid: 2210051 (alive: yes)
watcher pid: 2210593 (alive: yes) parent: 2210549
host pid recorded: 
host-left record: 2210549 linux-starttime=263972390 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d6f70746f75742f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2210549 2210051
hook exit code: 2

### state/.supervision-host.log
```
1792859706	start	gen=host-2206579-1792859705	primary=claude
1792859709	handoff	host-2206579-1792859705
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
1792859707	1	check	supervision-handoff:host-2206579-1792859705	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
```

## 2. flag removed: owner exited  (2026-10-24T16:35:12Z)

opt-in flag present: no
pending hand-back token: host-2206579-1792859705
handoff owner pid: <none> (alive: no)
watcher pid: 2210593 (alive: yes) parent: 2210549
host pid recorded: 
host-left record: 2210549 linux-starttime=263972390 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d6f70746f75742f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2210549 5856
hook exit code: 2

### state/.supervision-host.log
```
1792859706	start	gen=host-2206579-1792859705	primary=claude
1792859709	handoff	host-2206579-1792859705
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
1792859707	1	check	supervision-handoff:host-2206579-1792859705	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
```

## 3. next park takes over the left arm: exactly one host-owned watcher  (2026-10-24T16:35:14Z)

opt-in flag present: no
pending hand-back token: host-2206579-1792859705
handoff owner pid: <none> (alive: no)
watcher pid: 2223812 (alive: yes) parent: 2222150
host pid recorded: 2221004
host-left record: 2210549 linux-starttime=263972390 cmdline-hex=62617368002f746d702f666d2d7375706572766973696f6e2d686f73742e486a715171552f65762d6f70746f75742f62696e2f666d2d77617463682d61726d2e736800
arm processes from this home (pid ppid): 2222150 2221004
hook exit code: <running>

### state/.supervision-host.log
```
1792859706	start	gen=host-2206579-1792859705	primary=claude
1792859709	handoff	host-2206579-1792859705
1792859713	start	gen=host-2221004-1792859713	primary=claude
1792859713	take-over	arm=2210549
```
### state/.supervision-handoff.log
```
<absent>
```
### state/.wake-queue
```
1792859707	1	check	supervision-handoff:host-2206579-1792859705	check: supervision-handoff - the host handed supervision to main; drain, handle, and acknowledge this hand-back
```
