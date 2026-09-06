# Regression proof: tests/fm-spawn-worktree-settle.test.sh

## Against BASE bin/fm-spawn.sh (c499f84) - the new cases fail with the reported error
```
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - an already-settled pane confirms on the next read, not a whole extra cycle
not ok - spawn should succeed once the pane leaves the primary checkout
error: treehouse get did not yield an isolated worktree (resolved '/private/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T/fm-spawn-worktree-settle.ZSrJSo/settle-primary-transient/primary'; worktree root '/private/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T/fm-spawn-worktree-settle.ZSrJSo/settle-primary-transient/primary'; spawning project '/private/var/folders/r8/cylyt7xd7t50y9x5wc05my380000gn/T/fm-spawn-worktree-settle.ZSrJSo/settle-primary-transient/mate'); refusing to launch to avoid tangling the primary checkout. Inspect target firstmate:fm-settle-primary-transient-z3: expected exit 0, got 1
```

## Against the change under test (93b2fce) - all four cases pass
```
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - an already-settled pane confirms on the next read, not a whole extra cycle
ok - a transient primary-checkout pane read is not accepted as the worktree
ok - a pane stuck on the primary checkout fails loudly at the deadline
# all fm-spawn-worktree-settle tests passed
```
