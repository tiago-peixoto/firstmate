# Live evidence: AI co-author trailer strip (base e5316501 vs change c278923b)

Same live flow both times: real bin/fm-spawn.sh Cursor crewmate (cursor-agent 2026.09.15-d2fe57e, commit attribution ON via a temp CURSOR_CONFIG_DIR) on a private tmux server, treehouse-leased worktree, brief asks for a local commit.

## Command Cursor typed (identical in both runs)
```
$ git add README.md && git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" -m "$(cat <<'EOF'
```

## BEFORE (base e5316501): commit object
```
tree f5657403ed339d4bc63c4a12ff026c1ae9e68a88
parent 2df0a39a5058aac2090552f04cae5f513cb2ec7f
author Tiago Peixoto <tiagop@hey.com> 1789696614 -0300
committer Tiago Peixoto <tiagop@hey.com> 1789696614 -0300

docs: add strip probe line

Co-authored-by: Cursor <cursoragent@cursor.com>
```

## AFTER (change c278923b): commit object
```
tree f5657403ed339d4bc63c4a12ff026c1ae9e68a88
parent c34c197d40534c8187f01cf86b9a5836ccbb688d
author Tiago Peixoto <tiagop@hey.com> 1789696602 -0300
committer Tiago Peixoto <tiagop@hey.com> 1789696602 -0300

docs: add strip probe line
```

The project's own commit-msg hook still ran in the AFTER run and saw the stripped message (see live-cursor-after/transcript.txt).
