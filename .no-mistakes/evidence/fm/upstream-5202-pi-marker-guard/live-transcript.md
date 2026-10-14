# Live Pi nested-probe marker check (#5202)

Real `pi` 1.1.0 ran as a lab primary (`pi -a`, cwd = run worktree, FM_HOME = disposable lab home, private fm-lab tmux socket).
Session start and the nested probes ran through Pi's `!` shell, so they are real descendants of the Pi process.

## Target commit 8ac12777
- Fresh start on a free lock: both markers named Pi pid 1795645.
- `bin/fm-session-start.sh`: `lock acquired: harness pid 1795645`, no PI_WATCH_EXTENSION line (session-start-start1.txt).
- `pi -a --help; pi -a --list-models` from inside Pi: both markers still named 1795645.
- `bin/fm-session-start.sh` again: no PI_WATCH_EXTENSION line (session-start-start2.txt).

## Base commit 0397cb2b (same steps, extension files checked out from base, then restored)
- Lock held by Pi pid 1872365.
- After the nested `pi -a --help; pi -a --list-models`: both markers named dead pid 1897119.
- `bin/fm-session-start.sh` printed `PI_WATCH_EXTENSION: not loaded ...` (session-start-base2.txt line 21).

## Target, relaunch after the lock pid died
- First Pi 1936826 took the lock, then its tmux server was killed (pid dead).
- New Pi 1962727 started: both markers named 1962727 before session start.
- `bin/fm-session-start.sh`: `lock acquired: harness pid 1962727`, no alarm (session-start-r2.txt).
- Nested probes then left both markers on 1962727 and session start stayed clean (session-start-r3.txt).
