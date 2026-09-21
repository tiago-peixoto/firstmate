# Live Pi primary: nested Pi CLI vs. session binding (before/after)

Real Pi 0.86.1 interactive TUI, started with plain `pi` in a private tmux server (`tmux -L fm-lab-pimarker-<variant> -f /dev/null`).
Each variant used a throwaway FM_HOME and Pi HOME (`defaultProjectTrust: "always"`) and a `git archive` copy of the tree.
No model was logged in, so no tokens were spent.
Every command ran from inside the live Pi session with Pi's `!!command` (shell only, not sent to a model), the same way the primary runs repo scripts.
`bin/fm-watch-arm.sh` was stubbed in the lab copies because watcher arming is not under test.

## Base 09dc7b39 (before the fix)

| Step | watch marker pid | turn-end marker pid | lock pid | session start |
|---|---|---|---|---|
| Pi 81527 starts (lock free) | 81527 | 81527 | - | - |
| `!!bin/fm-session-start.sh` | 81527 | 81527 | 81527 | no alarm |
| `!!pi --help` | 15305 (dead) | 15305 (dead) | 81527 | - |
| `!!bin/fm-session-start.sh` | 15305 | 15305 | 81527 | **`PI_WATCH_EXTENSION: not loaded`** (false: Pi 81527 is live with both extensions loaded) |

`fm_pi_extension_owns_supervision` then returned false, so the watcher hand-off loses its extension-owned tolerance.
A restarted base session (Pi 74076) showed the same replacement from the refused `bin/fm-spawn.sh probe-x /nonexistent-project --scout --harness pi --backend tmux` probe: both markers became 19394.

## Fix ba3125f4 (this branch)

| Step | watch marker pid | turn-end marker pid | lock pid | session start |
|---|---|---|---|---|
| Pi 91873 starts (lock free) | 91873 | 91873 | - | - |
| `!!bin/fm-session-start.sh` | 91873 | 91873 | 91873 | no alarm |
| `!!pi --help` | 91873 | 91873 | 91873 | - |
| `!!bin/fm-session-start.sh` | 91873 | 91873 | 91873 | no alarm |
| `!!bin/fm-spawn.sh ... --harness pi` (refused at line 2779, after the probe) | 91873 | 91873 | 91873 | - |
| `!!bin/fm-session-start.sh` | 91873 | 91873 | 91873 | no alarm |
| `/reload` (lock names this Pi process) | 91873 (rewritten) | 91873 (rewritten) | 91873 | - |
| `!!bin/fm-session-start.sh` | 91873 | 91873 | 91873 | no alarm |

After `/reload`, both marker mtimes advanced, so the self-lock branch still writes the marker, and the stub arm log shows the owning session (ppid 91873) still armed the watcher.
`fm_pi_extension_owns_supervision` returned true throughout.
Full TUI transcripts: `tui-fix-pi-session.txt`, `tui-base-pi-session.txt`, `tui-base-spawn-probe.txt`.
