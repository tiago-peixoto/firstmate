# Build provenance verification

Audience: maintainer verification.

This record supports one active guarantee: the model family that built an authored pull request reaches the forge and is readable by a home that holds nothing but a clone and a head SHA.

That guarantee rests on third-party behavior rather than on firstmate's own code.
Git never pushes or fetches `refs/notes/*` under a default refspec, and a forge is free to reject, hide, or render whatever ref namespaces it likes, so the claim is only as good as evidence against a real forge.
A local fixture cannot settle it: a note that never leaves the machine reads back exactly like one that travelled.
`bin/fm-pr-provenance.sh`'s header owns the mechanism, and `tests/fm-pr-provenance.test.sh` owns the portable regression over two clones of one bare repository.

## GitHub stores and serves the ref, and renders it nowhere

Verified on 2026-08-24 against `github.com` with git 2.50.1 (Apple Git-155) on macOS 26.5.2 arm64, using `git@github.com:tiago-peixoto/firstmate.git`.

The forge held no notes ref before, and pushing a branch did not create one:

```sh
git ls-remote origin 'refs/notes/*'
git push -u origin fm/<topic>
git ls-remote origin 'refs/notes/*'
```

```text
(no output before the push)
 * [new branch]      fm/<topic> -> fm/<topic>
(no output after the push)
```

That empty second reading is the load-bearing part: a branch push carries no note, so the record needs its own publish step or it never leaves the machine.

Stamping published it, and the forge served it back:

```sh
FM_HOME=<home> bin/fm-pr-provenance.sh stamp <task-id>
git ls-remote origin 'refs/notes/*'
```

```text
recorded: fb62b6637a771921a7366aae4dff89a787a19ae7 family=claude model=opus effort=high
49e3c957f5405897ca38c8f215e084a92f327970	refs/notes/build-provenance
```

## A different home reads it back through the forge alone

A fresh clone carried no note, which confirms the read side also needs its own fetch:

```sh
git clone git@github.com:tiago-peixoto/firstmate.git other-home
git -C other-home for-each-ref 'refs/notes/*'
git -C other-home notes --ref=refs/notes/build-provenance show fb62b6637a771921a7366aae4dff89a787a19ae7
```

```text
(no refs/notes/* present after clone)
error: no note found for object fb62b6637a771921a7366aae4dff89a787a19ae7.
```

With no `FM_HOME`, no state directory, and no path to the authoring home, the same clone then resolved the identity:

```sh
env -u FM_HOME -u FM_STATE_OVERRIDE bin/fm-pr-provenance.sh show other-home fb62b6637a771921a7366aae4dff89a787a19ae7
git -C other-home for-each-ref --format='%(objectname) %(refname)' 'refs/notes/*'
git ls-remote origin refs/notes/build-provenance
```

```text
family=claude
model=opus
effort=high
49e3c957f5405897ca38c8f215e084a92f327970 refs/notes/build-provenance
49e3c957f5405897ca38c8f215e084a92f327970	refs/notes/build-provenance
```

The ref the other home ended up holding is the same object the forge serves, so the record travelled through GitHub rather than through any shared local state.

## The refusal path fires in the same real setting

A commit on the default branch carries no record, and the same clone refused rather than reaching for a nearby one:

```sh
bin/fm-pr-provenance.sh show other-home "$(git -C other-home rev-parse origin/main)"
```

```text
error: cannot establish builder family for 510cdd54da67671b1210130497800f004526e8dd: no build record was published for this change
```

Exit status was 3.

## What to re-run

Repeat the three sections above after any change to how the record is published or read, and after a forge migration.
GitHub's handling of `refs/notes/*` is a vendor behavior: it can change without notice, and the portable regression in `tests/fm-pr-provenance.test.sh` cannot detect it, because a bare repository on the same machine will keep passing either way.
