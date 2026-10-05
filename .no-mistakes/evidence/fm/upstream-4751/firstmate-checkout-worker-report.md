# Probe: can the `firstmate-coding-guidelines` skill instruction be followed from this Firstmate worktree

## Conclusion

Yes.
The skill name `firstmate-coding-guidelines` resolved through the Skill tool in this session, and the tool loaded the content from this worktree's own copy.
The worker role contract therefore did not require the fallback file, and I did not read it.

## Step 1 - Skill tool invocation

I invoked the Skill tool with skill name `firstmate-coding-guidelines`.
The tool returned this result verbatim, with no error text:

```
Launching skill: firstmate-coding-guidelines
```

The session then delivered the full skill body, starting with this line:

```
Base directory for this skill: /tmp/fm-lab.TMGbza/treehouse/.treehouse/fmrepo-a122fa/1/fmrepo/.claude/skills/firstmate-coding-guidelines
```

The body that followed began with the heading `# firstmate-coding-guidelines` and ended with the `## Repo style rules` section.

## Step 2 - What the worker role contract required

The contract (launch brief, line 9) says:

> If the `firstmate-coding-guidelines` skill name does not resolve in this session, read `/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M46H32NZJGJTWXDWWNHJCZTD/.agents/skills/firstmate-coding-guidelines/SKILL.md` instead.

The condition of that sentence was false, because the skill name resolved.
Did the contract require me to read a fallback file: no.
Did I read a fallback file: no.
I only listed the fallback directory, and the listing shows that the fallback file exists (see Evidence).

## Step 3 - Load directory, `pwd`, and repository root

The tool reported the load directory as `/tmp/fm-lab.TMGbza/treehouse/.treehouse/fmrepo-a122fa/1/fmrepo/.claude/skills/firstmate-coding-guidelines`.
In this worktree `.claude/skills` is a symlink to `../.agents/skills`, so the file the tool read is `.agents/skills/firstmate-coding-guidelines/SKILL.md` inside this worktree.
The tool did not load the content from the fallback path under `/home/firstmate/.no-mistakes/worktrees/`.

```
$ pwd
/tmp/fm-lab.TMGbza/treehouse/.treehouse/fmrepo-a122fa/1/fmrepo
$ git rev-parse --show-toplevel
/tmp/fm-lab.TMGbza/treehouse/.treehouse/fmrepo-a122fa/1/fmrepo
```

## Evidence

One command produced the output above and the listings below:

```
$ ls -la .agents/skills/firstmate-coding-guidelines/
-rw-rw-r--  1 firstmate firstmate 12579 Oct  5 19:33 SKILL.md

$ ls -la /home/firstmate/.no-mistakes/worktrees/5284051b2355/01M46H32NZJGJTWXDWWNHJCZTD/.agents/skills/firstmate-coding-guidelines/
-rw-rw-r--  1 firstmate firstmate 12579 Oct  5 19:16 SKILL.md

$ ls -la .claude
drwxrwxr-x  3 firstmate firstmate   60 Oct  5 19:33 mods
-rw-rw-r--  1 firstmate firstmate 2102 Oct  5 19:33 settings.json
-rw-rw-r--  1 firstmate firstmate 1296 Oct  5 19:34 settings.local.json
lrwxrwxrwx  1 firstmate firstmate   17 Oct  5 19:33 skills -> ../.agents/skills
```

Both copies of `SKILL.md` have the same size, 12579 bytes.
I did not compare their contents, so I cannot say that they are identical.

## Limits of this probe

- This probe covers one worker runtime (Claude Code) in one worktree of the Firstmate repository itself.
- It does not show what happens in a worktree of another project, where `.claude/skills` does not point at the Firstmate skills; the fallback sentence exists for that case and this probe did not exercise it.
- I edited no project file.
- I skipped the `captain-hold-lifecycle` completion gate, as the brief instructed for this probe.

## Recommendation

No change is needed for this case.
If the fallback path itself needs proof, run the same probe from a worktree where the skill name does not resolve.
