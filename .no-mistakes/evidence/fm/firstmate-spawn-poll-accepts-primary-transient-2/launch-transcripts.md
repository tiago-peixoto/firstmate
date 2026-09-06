# firstmate#3808 — end-to-end launch transcripts

A Firstmate home whose **project is itself a linked worktree** of a repository.
`treehouse get` reports the repository's **primary checkout** as its own cwd
while it is still fetching and checking out the pooled slot, so the task pane
reads the primary for the first seconds before settling into the isolated slot.

Fixture shape (`$R` = a temp root):

| path | role |
|---|---|
| `$R/acme` | repository primary checkout |
| `$R/acme-mate` | the Firstmate home's project — a **linked worktree** of `acme` |
| `$R/acme-slot-7` | the isolated worktree `treehouse get` creates for the task |

The task pane reports `$R/acme` for its first 3 reads, then `$R/acme-slot-7`.
Real `bin/fm-spawn.sh`, real git worktrees; `tmux`/`treehouse` are stubs
standing in for the terminal backend.

---

## BEFORE — base commit c499f84

```
### BEFORE (base c499f84) — crewmate launch, pane transiently on the repository primary

repository primary checkout  : $R/acme
firstmate home's project     : $R/acme-mate     (linked worktree of acme)
isolated slot treehouse gets : $R/acme-slot-7   (linked worktree of acme)
pane reads reporting primary : 3

$ bin/fm-spawn.sh demo-ship-a1 $R/acme-mate --mode no-mistakes --yolo off
error: treehouse get did not yield an isolated worktree (resolved '$R/acme'; worktree root '$R/acme'; spawning project '$R/acme-mate'); refusing to launch to avoid tangling the primary checkout. Inspect target firstmate:fm-demo-ship-a1

exit status: 1

$ cat $FM_HOME/state/demo-ship-a1.meta   # recorded task worktree
(no metadata written - launch refused)

### BEFORE (base c499f84) — scout launch, same transient

repository primary checkout  : $R/acme
firstmate home's project     : $R/acme-mate     (linked worktree of acme)
isolated slot treehouse gets : $R/acme-slot-7   (linked worktree of acme)
pane reads reporting primary : 3

$ bin/fm-spawn.sh demo-scout-a1 $R/acme-mate --scout
error: treehouse get did not yield an isolated worktree (resolved '$R/acme'; worktree root '$R/acme'; spawning project '$R/acme-mate'); refusing to launch to avoid tangling the primary checkout. Inspect target firstmate:fm-demo-scout-a1

exit status: 1

$ cat $FM_HOME/state/demo-scout-a1.meta   # recorded task worktree
(no metadata written - launch refused)

```

Both launches exit 1 with the exact error from the report, and no task
metadata is written.

---

## AFTER — the change under test (93b2fce)

```
### AFTER (fix) — crewmate launch, pane transiently on the repository primary

repository primary checkout  : $R/acme
firstmate home's project     : $R/acme-mate     (linked worktree of acme)
isolated slot treehouse gets : $R/acme-slot-7   (linked worktree of acme)
pane reads reporting primary : 3

$ bin/fm-spawn.sh demo-ship-a1 $R/acme-mate --mode no-mistakes --yolo off
spawned demo-ship-a1 harness=codex kind=ship mode=no-mistakes yolo=off window=firstmate:fm-demo-ship-a1 worktree=$R/acme-slot-7

exit status: 0

$ cat $FM_HOME/state/demo-ship-a1.meta   # recorded task worktree
worktree=$R/acme-slot-7
project=$R/acme-mate
kind=ship

### AFTER (fix) — scout launch, same transient

repository primary checkout  : $R/acme
firstmate home's project     : $R/acme-mate     (linked worktree of acme)
isolated slot treehouse gets : $R/acme-slot-7   (linked worktree of acme)
pane reads reporting primary : 3

$ bin/fm-spawn.sh demo-scout-a1 $R/acme-mate --scout
spawned demo-scout-a1 harness=codex kind=scout window=firstmate:fm-demo-scout-a1 worktree=$R/acme-slot-7

exit status: 0

$ cat $FM_HOME/state/demo-scout-a1.meta   # recorded task worktree
worktree=$R/acme-slot-7
project=$R/acme-mate
kind=scout

```

Both launches now land on the isolated slot `treehouse` created, and
`state/<id>.meta` records that slot — never the repository primary.

---

## AFTER — a pane that never reaches an isolated worktree still refuses loudly

The same fixture, but the pane reports the repository primary forever
(`treehouse get` never enters a slot). Real 60s deadline, real `sleep`:

```
### AFTER (fix) — pane NEVER reaches an isolated worktree, so the launch still refuses loudly

repository primary checkout  : $R/acme
firstmate home's project     : $R/acme-mate     (linked worktree of acme)
isolated slot treehouse gets : $R/acme-slot-7   (linked worktree of acme)
pane reads reporting primary : 999

$ bin/fm-spawn.sh demo-ship-a1 $R/acme-mate --mode no-mistakes --yolo off
error: treehouse get did not enter an isolated worktree within 60s (last seen '$R/acme': it is the repository's primary checkout (its git dir is the spawning project's common git dir); spawning project '$R/acme-mate'); inspect window firstmate:fm-demo-ship-a1

exit status: 1

$ cat $FM_HOME/state/demo-ship-a1.meta   # recorded task worktree
(no metadata written - launch refused)

```

The launch still refuses, exits 1, writes no metadata, and the refusal now
names the last path the pane reported and why it was rejected.
