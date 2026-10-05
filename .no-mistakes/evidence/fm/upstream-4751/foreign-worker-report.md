# Probe: can a crewmate in the `foreign` worktree follow the `firstmate-coding-guidelines` instruction?

## Conclusion

Yes, through the fallback path only.
The Skill tool did not resolve the skill name `firstmate-coding-guidelines` in this session.
The fallback file named by the worker role contract was readable with the Read tool on the first attempt.

## What I did

I ran the three steps of the Firstmate spec and nothing else.
I edited no project file.

### Step 1 - Skill tool

Call: Skill tool with `skill: firstmate-coding-guidelines` and no arguments.

Result: the skill did not resolve.
Exact error text returned by the tool:

```
<tool_use_error>Unknown skill: firstmate-coding-guidelines</tool_use_error>
```

The name is also absent from the list of available skills that the session printed at startup.

### Step 2 - Fallback from the worker role contract

The worker role contract (launch brief, line 9) says: if the `firstmate-coding-guidelines` skill name does not resolve in this session, read the file below instead.

- File path read: `/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M46H32NZJGJTWXDWWNHJCZTD/.agents/skills/firstmate-coding-guidelines/SKILL.md`
- Tool: Read (the dedicated file-read tool, not a shell command).
- Outcome: the read succeeded on the first call and returned all 135 lines.
- Permission prompt: the call returned content with no denial and no hook feedback.
  A worker cannot see a prompt that a human approves, so this is the limit of what I can observe.
  The parent directory `/home/firstmate/.no-mistakes/worktrees/5284051b2355/01M46H32NZJGJTWXDWWNHJCZTD/.agents/skills` is listed as an additional working directory of this session, which is consistent with no prompt.

### Step 3 - Frontmatter and location

Frontmatter lines of the file, quoted verbatim (lines 2 to 6).
The `description:` value is a folded block scalar, so it spans the three lines that follow the key.

```
name: firstmate-coding-guidelines
description: >-
  Agent-only reference for changing firstmate's shared, tracked material per AGENTS.md section 1.
  Use before editing any of that material, whether working as firstmate directly or as a crewmate briefed on a firstmate-repo task.
  Covers the knowledge-placement decision tree, the one-owner rule for contracts, the inline-stub pattern for content moved into a skill, AGENTS.md size discipline, trigger hygiene for new skills, and repo style rules (one sentence per line, plain dash, no agent co-author, shellcheck-clean bin scripts, colocated tests, and maintainer-verification evidence).
```

Command output, both run in one Bash call from the worktree:

```
$ pwd
/tmp/fm-lab.TMGbza/treehouse/.treehouse/foreign-251621/1/foreign
$ git rev-parse --show-toplevel
/tmp/fm-lab.TMGbza/treehouse/.treehouse/foreign-251621/1/foreign
```

## Observations

- The same frontmatter carries `user-invocable: false` (line 7) and `metadata: internal: true` (lines 8 to 9).
  I did not test whether those keys, or the skill living outside this project's worktree, cause the `Unknown skill` error.
- The steering inbox `/tmp/fm-lab.TMGbza/state/skill-foreign.inbox` held only the `handled` directory, so no steering message was waiting.

## Recommendation

Keep the fallback path in the worker role contract for briefs that run in a project other than Firstmate.
In this session the fallback was the only way to load the guidelines.
Nothing here needs a code change.

## Not done

Per the spec, I skipped the completion gate of the `captain-hold-lifecycle` skill.
