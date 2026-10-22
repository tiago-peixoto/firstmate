# Evidence index - fm/upstream-5226 (Kimi project MCP refusal)

- fm-kimi-harness-suite.log - `bash tests/fm-kimi-harness.test.sh` (real bin/fm-spawn.sh, fake kimi + fake tmux backend, isolated HOME and KIMI_CODE_HOME), exit 0. The eleven new cases and the ambient KIMI_CODE_HOME assertion are the last lines.
- real-spawn-declaring-dir-refused.txt - real bin/fm-spawn.sh (target) in a disposable lab FM_HOME, real Kimi Code CLI 2.3.0 on PATH, project declares .kimi-code/mcp.json: refused before Kimi started, no key sent, marker command never ran.
- real-kimi-2.3.0-enter-starts-project-mcp-hazard.txt - raw Kimi 2.3.0: one Enter on the declaring-directory prompt starts the declared stdio command (the hazard being prevented).
- real-kimi-2.3.0-trust-prompt-declaring-dir.txt / real-kimi-2.3.0-after-enter-declaring-dir.txt - pane captures for that hazard run.
- real-spawn-plain-dir-kimi-2.3.0-target.txt - real spawn (target), plain project: Kimi 2.3.0's reworded prompt (`Trust and continue` / `Exit`) is not the recognized complete dialog, so no key is sent and readiness fails.
- real-spawn-plain-dir-kimi-2.3.0-base.txt - same run on the base commit 05a68cb2: identical outcome, so the 2.3.0 prompt drift is pre-existing, not introduced by this change.
- real-spawn-root-mcp-json-adversarial.txt - real spawn (target), project declares servers only in a root `.mcp.json` (undocumented, but Kimi 2.3.0 reads it): the pre-launch read finds nothing, Kimi starts, the 2.3.0 prompt carries no `Project MCP targets:` header, no key is sent, marker never ran.
