# Live run: Claude secondmate busy contract through `--settings`

Target commit: faa8e4272e0c784c01e2c608b360ec1fe816195d.
Product: real `bin/fm-spawn.sh --secondmate`, real tmux 3.x on a private `fm-lab` socket, real Claude Code 2.1.292 with the machine's normal login.
Lab: a marked lab home from `bin/fm-lab-home.sh create` as the parent home, and a detached clone of this worktree as the secondmate home, so the home carries the tracked `.claude/settings.json` Stop guard.
The driver is `lab-spawn-driver.sh` in this directory.
The lab and its tmux server were removed at the end of the run.

## 1. Spawn (real `fm-spawn.sh sm-live <home> claude --secondmate`)

The pane command during spawn was a recorder that saved the argv the spawn built, so the launch brief did not reach a model.

```
spawned sm-live harness=claude kind=secondmate mode=secondmate yolo=off window=firstmate:fm-sm-live worktree=/tmp/fm-lab.0eKxDJ/sm
```

Argv the spawn handed to `claude`:

```
--dangerously-skip-permissions
--add-dir
/tmp/fm-lab.0eKxDJ/primary/state/sm-live.inbox
--settings
/tmp/fm-lab.0eKxDJ/primary/state/sm-live.claude-settings.json
: Firstmate operational input waiting: read '.../operational-inbox/1791383275-fa67a26e9d475385.msg' ...
```

Parent home state after spawn:

```
sm-live.busy-gen  sm-live.busy-state  sm-live.claude-settings.json  sm-live.git-hooks  sm-live.inbox  sm-live.meta
busy-state: v1 gen=g1791383274.4528.20759 seq=1 state=busy source=fm-spawn event=launch-brief
fm_busy_classify tmux firstmate:fm-sm-live claude sm-live <state> 'working'  ->  busy fm-spawn
```

The secondmate home's `.fm-busy-stop` pointer carried `gen=g1791383274.4528.20759`.
The settings file is saved as `spawned-claude-settings.json`: it has `UserPromptSubmit`, `StopFailure`, `SessionEnd`, `feedbackDrafts` and `attribution`, and no `Stop` entry.

The captain's file was seeded before the spawn as `{"permissions":{"allow":["Bash(echo captain-rule)"]}}`.
`sha256sum -c` reported `OK` for `<home>/.claude/settings.local.json` after the spawn, after three real Claude turns, after the raw respawn, and at the end.

## 2. Real Claude Code loads the hooks from the file

Real `claude` was started in the secondmate home with the same flags and a one-line prompt in place of the brief.
Claude's trust dialog listed the captain's rule, which shows Claude still read `settings.local.json` beside the `--settings` file:

```
 ⚠ This folder pre-approves 1 tool permission in .claude/settings.local.json:
   Bash(echo captain-rule)
```

Busy record in the parent home, sampled every 0.5 s (`busy-record-trace.log`):

```
16:28:14 seq=1 state=busy source=fm-spawn    event=launch-brief
16:28:30 seq=2 state=idle source=claude-hook event=session-end         <- a first Claude process was closed
16:28:54 seq=3 state=busy source=claude-hook event=user-prompt-submit  <- turn 1 "Reply with the single word ok"
16:28:55 seq=4 state=idle source=claude-hook event=stop
16:30:27 seq=5 state=busy source=claude-hook event=user-prompt-submit  <- turn 2 runs Bash(sleep 8)
16:30:38 seq=6 state=idle source=claude-hook event=stop
16:31:25 seq=7 state=busy source=claude-hook event=user-prompt-submit  <- turn 3
16:31:27 seq=8 state=idle source=claude-hook event=stop
```

The `--settings` file has no `Stop` hook, so the `event=stop` rows can only come from the home's tracked Stop guard reading `.fm-busy-stop`.
That also shows Claude merged the file's hooks with the home's `.claude/settings.json` hooks and did not replace them.

Active-turn classifier during turn 2 (real pane tail from `tmux capture-pane`):

```
before:   idle claude-hook
16:30:28  classify=busy claude-hook | seq=5 state=busy source=claude-hook
16:30:39  classify=idle claude-hook | seq=6 state=idle source=claude-hook
```

Pane at the end of turn 2:

```
❯ Run the shell command "sleep 8" with the Bash tool, then reply done.
● Bash(sleep 8)
  ⎿  (No output)
● Captain, done - sleep 8 ran in the Bash tool and exited with no output.
```

No `sm-live.turn-ended` marker existed in the parent state at any point.

## 3. Raw respawn over the armed secondmate (the skip-branch fix)

The `fm-sm-live` window was killed to stand in for a crashed pane, so `fm-control exit` never ran.
Then: `fm-spawn.sh sm-live <home> 'claude --dangerously-skip-permissions' --secondmate`.

```
before: sm-live.busy-gen sm-live.busy-state present, pointer gen=g1791383274.4528.20759, classify = idle claude-hook
spawned sm-live harness=claude kind=secondmate mode=secondmate yolo=off window=firstmate:fm-sm-live
after:  state has sm-live.claude-settings.json sm-live.git-hooks sm-live.inbox sm-live.meta (no busy-gen, no busy-state)
        ls <home>/.fm-busy-stop -> No such file or directory
        raw launch argv: --dangerously-skip-permissions
        classify = unknown missing
```

Adversarial step: the real Claude session from section 2 was still open and still held the hooks for the retired generation.
A fourth turn was submitted there, and then `/exit`.

```
after the turn:      no busy record; classify = unknown missing
after SessionEnd:    no busy record; no parent turn-ended marker
```

## 4. Not driven live

A Stop that the home guard blocks into a continuation was attempted (an empty `state/child.meta` in the lab home before turn 3).
The guard allowed the Stop in that lab home, so the blocked path was not reached with real Claude.
`tests/fm-busy-adapter-wiring.test.sh` runs the real guard script for that path and passed (`busy-adapter-wiring.log`).
