# Pull-request target guard verification

Repeatable evidence for the refusal that keeps the validation pipeline from opening a pull request anywhere except this home's configured push target.
Current behavior and rationale are owned by [`../fork-main.md`](../fork-main.md) ("The pull-request target is enforced, not assumed") and by the header of `bin/fm-nm-pr-target-lib.sh`; this page records evidence only.

Date: 2026-08-29.
no-mistakes: v1.57.0 (0fcbbff).
Git: 2.50.1 (Apple Git-155).
Shell: GNU bash 3.2.57 (macOS).

## Why this page exists

The colocated suite `tests/fm-nm-pr-target.test.sh` proves the guard's own logic with a fake `no-mistakes`, which is the right shape for CI: it needs no tool, no daemon, and no credentials.
What a fake cannot prove is that the guard is attached to anything real.
The guarantee - that a wrong-target pull request is unreachable rather than merely reported - rests on four facts about the installed no-mistakes, each of which a future release could change.
Those four are recorded here so a version bump can re-check them instead of the guard quietly becoming decorative.

Each fact below names what breaks if it stops holding, and in which direction.

## 1. The registration's own remote is the pull-request base

The `--fork-url` contribution model splits the two targets: branches go to the fork, pull requests go to the registration's remote.
This is the behavior the guard exists to constrain, not a misconfiguration.

```console
$ no-mistakes init --help | grep -- --fork-url
      --fork-url string        GitHub fork remote URL to push branches to while opening PRs against origin
```

Confirmed in the tool's source at `internal/gate/gate.go`:

```go
// InitWithFork is Init plus an optional GitHub fork push URL. The origin remote
// remains the parent repository used for PRs.
```

and at `internal/pipeline/steps/host.go`, where the pull-request host is built from the registration's upstream URL while the fork supplies only the `--head <owner>:<branch>` prefix:

```go
host := resolvedHost(sctx, sctx.Repo.UpstreamURL)
repo := github.HostPrefixedSlugForHost(sctx.Repo.UpstreamURL, host)
```

If this changed so the fork became the pull-request base, the guard would refuse a topology that had become safe - a false refusal, which is the harmless direction, and visible immediately.

## 2. `no-mistakes status` reports that base as `remote:`

```console
$ no-mistakes status
    repo:  <path>
  remote:  <url>          # the pull-request base
    fork:  <url>          # branch push URL only
    gate:  <path>
  daemon:  ● running
```

`bin/fm-nm-pr-target-lib.sh` is the single reader of this format, shared with `bin/fm-fork-remotes.sh`'s migration proof.
If the format changed, the parse would yield an empty base and the guard would refuse with "no pull-request base recorded" rather than allow - again the safe direction, and `tests/fm-nm-pr-target.test.sh` case (g) pins that behavior.

## 3. Entering the pipeline is a real `git push`, with hooks enabled

`internal/cli/axi_drive.go` triggers a run by pushing the branch to the gate remote:

```go
pushErr := git.PushWithOptions(ctx, ".", gate.RemoteName, "refs/heads/"+branch, "", false, pushOptions)
```

`pushSourceWithOptions` assembles a plain `git push` and passes no `--no-verify`, so Git runs the working clone's `pre-push` hook.
This is what gives the guard a chokepoint at all.

That line is also the ONLY push the CLI makes from the working clone; every later pipeline step runs in the tool's own worktree under its data directory.

```console
$ grep -rn 'Push[A-Za-z]*(ctx, "\."' --include='*.go' internal/ | grep -v _test
internal/cli/axi_drive.go:306:  pushErr := git.PushWithOptions(ctx, ".", gate.RemoteName, "refs/heads/"+branch, "", false, pushOptions)
```

So the guard has exactly one interception point: it gates pipeline entry and touches nothing else the tool does.
If a future release bypassed hooks or stopped pushing, the guard would silently stop firing - this is the one fact whose failure is in the DANGEROUS direction, so re-check it on every no-mistakes upgrade.

## 4. A refused gate push starts no run

The fallback that would otherwise rerun the gate's existing head is gated on the push having succeeded:

```go
func shouldRerunAfterNoActiveRun(pushErr error) bool {
	return pushErr == nil
}
```

So a hook refusal returns an error from `triggerRun` instead of routing around it.
Without this, a refused push could still start a run from a previously-gated head.

## Live end-to-end check

`bin/fm-nm-pr-target.sh check` reads the real registration and the real remote, so it exercises facts 1 and 2 against the installed tool with no fixture:

```console
$ bin/fm-nm-pr-target.sh check
pr-target: REFUSED the pipeline would open a pull request against <official-upstream>, but this home pushes to <fork>
$ echo $?
4
```

That refusal on this fork-topology home is the correct verdict and reproduces the 2026-08-28 defect as a verdict rather than as a pull request.
A home whose registration names the repository it pushes to prints `pr-target: ok push-target=<id> pr-base=<id>` and exits 0.

The same one rule was run against all three topologies this machine actually holds, which is the evidence that it generalizes without an allow-list to maintain:

| registration | verdict | exit |
| --- | --- | --- |
| firstmate primary: official upstream as base, fork as push target | REFUSED | 4 |
| private fork-integration clone: fork as both | ok | 0 |
| an ordinary single-origin project clone: one URL as both | ok | 0 |

Only the topology that carries two different targets refuses, and it refuses because those two targets genuinely disagree.

Facts 3 and 4 are verified by reading the installed release's source, as recorded above, because exercising them for real would mean starting an actual validation run.
The portable suite covers the equivalent behavior with a real `git push` into a real gate-shaped bare repository, which is what makes its central case a genuine end-to-end refusal rather than a message assertion.

## Suite output

```console
$ bash tests/fm-nm-pr-target.test.sh | tail -1
ok - (j) a relocated shim falls back to the pushing worktree's own guard
```

Nineteen assertions, all passing; run it from the repo root.
Its central case was confirmed to fail against the pre-guard tree, reporting `gate push was ACCEPTED while the pipeline's PR base ... differs from the push target`, so it is known to go red on the real defect rather than only green on the fix.
