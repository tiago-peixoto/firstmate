# Real-tmux lab transcript (bin/fm-watch.sh against a private tmux socket in a disposable lab home)

Fixture: lab home from bin/fm-lab-home.sh, tmux server on socket fm-lab under the lab, window fmlab:crew running a bare bash shell (harness=grok recorded, so the backend reports the agent dead), real bin/fm-crew-state.sh (answers unknown).

## setup
--- real pane (tmux capture-pane on the private socket)
idle, holding for the upstream tool release
lab$
--- pane_current_command: bash
--- agent liveness as the backend sees it:
dead
--- real fm-crew-state.sh verdict:
state: unknown · source: none · worktree gone (torn down?)

## A. first stable sight of 'paused:' on a dead agent -> one plain stale wake, no wedge timer
watcher[a]: exited rc=0 after 5s
stale: fmlab:crew
.paused-fmlab_crew = '' (age 1s)
.paused-resurfaced-fmlab_crew = declared:r1:3436007374726f6e673a34343a38313836323535333a323032362d31302d32332031383a33303a30382e353032393930373131202b3032303000726567756c61722066696c653a38316234002d007265616461626c65007265616461626c65 (age 1s)
.paused-rechecked-fmlab_crew = 1792773018 (age 1s)
.stale-since-fmlab_crew absent

## B. unchanged pane, throttle aged past FM_PAUSE_RESURFACE_SECS=240 -> bounded recheck
watcher[b]: exited rc=0 after 1s
stale: fmlab:crew (paused 553s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)

## B2. unchanged pane inside the cadence -> no wake across 12s of polls
watcher[b2]: still alive after 12s (absorbing); stopping it
[2026-10-23T18:31:12+0200] absorbed stale (paused, awaiting external, age 564s): fmlab:crew
[2026-10-23T18:31:14+0200] absorbed stale (paused, awaiting external, age 565s): fmlab:crew
[2026-10-23T18:31:15+0200] absorbed stale (paused, awaiting external, age 567s): fmlab:crew

## C. dead agent, 'until 2027-10-23T00:00Z' -> absorbed inside the cadence, one recheck past it
--- declaration: paused: provider rate limit, resume until 2027-10-23T00:00Z (status age 500s)
watcher[c1]: still alive after 12s (absorbing); stopping it
[2026-10-23T18:33:43+0200] absorbed stale (paused until 31476377s from now, declared time not reached): fmlab:crew
[2026-10-23T18:33:45+0200] absorbed stale (paused until 31476375s from now, declared time not reached): fmlab:crew
[2026-10-23T18:33:47+0200] absorbed stale (paused until 31476373s from now, declared time not reached): fmlab:crew
[2026-10-23T18:33:49+0200] absorbed stale (paused until 31476371s from now, declared time not reached): fmlab:crew
watcher[c2]: exited rc=0 after 1s
stale: fmlab:crew (paused 514s, awaiting external - the declared time is beyond the recheck cadence; confirm the wait still holds)

## D. pane hash changes every poll (date loop) -> quiet inside the cadence, one recheck past it, quiet again after
--- real pane now ticks:
18:33:54.072184268
18:33:54.378913150
18:33:54.690975034
--- pane_current_command: sleep
watcher[d1]: still alive after 15s (absorbing); stopping it
--- polls completed (beacon) vs crew-state reads: reads=8
.stale-fmlab_crew absent
watcher[d2]: exited rc=0 after 1s
stale: fmlab:crew (paused 518s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)
.stale-fmlab_crew = 259d3d73dd825b77da057b217342e72d (age 1s)
watcher[d3]: still alive after 15s (absorbing); stopping it
.stale-fmlab_crew absent

## D1. crew-state reads for the ticking pane inside the cadence, 20s at FM_POLL=1, target vs base af1c6817
d1-base.log:--- tree: /tmp/fm-base.1nWocT
d1-base.log:--- polls (triage-log absorb lines):  ; crew-state reads: 9
d1-target.log:--- tree: /home/firstmate/.no-mistakes/worktrees/5284051b2355/01M5MRX3KG4WRKZ0G9F3GJYVGR
d1-target.log:--- polls (triage-log absorb lines):  ; crew-state reads: 9
