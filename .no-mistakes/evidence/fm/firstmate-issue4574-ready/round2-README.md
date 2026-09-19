# Live validation round 2: explicit worker account selection (issue 4574) at 62694b3

The files without a `round2-`, `s<N>-`, `pane-` or `firstmate-pane` prefix come from an earlier run of this step at commit 7b281c9 (see `README.md`).
This round re-drives the behavior at the target commit 62694b3, including what changed since then: several providers per Pi home, separate-word-only raw `--provider`, the provider-only model-list fallback on Pi 0.84.0, and the optional final newline.

## How the product was stood up

The target commit was exported with `git archive` into its own Firstmate checkout, which is also the home (`config/`, `state/`, `data/` inside it, as an end user runs it).
The same was done for the base commit 1bb72cc to reproduce the original bug.
A real tmux 3.7c server ran on a private socket (`-L fm4574`) with the shell settings in `round2-lab/tmux.conf`.
Its environment carried an ambient account that a correct launch must not spend: `CLAUDE_CONFIG_DIR` pointing at a directory with a usable login, `ANTHROPIC_API_KEY=sk-ant-AMBIENT-sentinel`, and `PI_CODING_AGENT_DIR` pointing at another directory.
Every `fm-spawn.sh` and `fm-control.sh` call was typed into the firstmate pane of that server (`round2-lab/run.sh`, `round2-lab/lib.sh`), so spawn ran exactly as a firstmate session runs it.

Real tools answered every account check: quota-axi 0.1.47 for Claude, Pi 0.85.1 for `pi auth check`, and Pi 0.84.0 (installed into a temp prefix) for the older-Pi fallback.
The declared Pi root in S7, S9, S10 and S16 was the operator's real `~/.pi/agent`, used read-only through `pi auth check --no-refresh`.
Every Claude root, and every other Pi root, was a throwaway directory.

Only the final agent binary in each worker pane was a recorder (`round2-lab/shim-*`).
It prints the account environment and argv the launched process actually received, then stays alive like an agent, so no model tokens were spent.
`treehouse get` was a stand-in that enters a prepared isolated git worktree of the test project.

## Scenarios

| Scenario | Result | Evidence |
| --- | --- | --- |
| BASE: at 1bb72cc, a home with no account file launches the worker on the ambient `CLAUDE_CONFIG_DIR` and ambient API key (the bug) | reproduced | `round2-62694b3-transcripts.txt` BASE, `pane-fm-base-claude.txt` |
| S1: fresh home, Claude spawn refuses, names `config/claude-account`, creates no window, record or agent | pass | transcripts S1 |
| S2: fresh home, Pi spawn refuses and names `config/pi-account` | pass | transcripts S2 |
| S3: declared Claude root with a login; the agent gets that root, and the ambient key and ambient config dir never reach it; trust goes to the declared root | pass | transcripts S3, `s3-claude-worker-pane.txt` |
| S4: declared Claude root with no login is refused by the real quota-axi check, despite the usable ambient account | pass | transcripts S4 |
| S5: `ordinary` Claude refuses when the user has no default login, and launches with `CLAUDE_CONFIG_DIR` unset when it has one | pass | transcripts S5, `s5-claude-ordinary-worker-pane.txt` |
| S6: the `environment` line keeps the API key on the agent and still selects the declared root | pass | transcripts S6, `s6-claude-environment-worker-pane.txt` |
| S7: declared Pi root plus `openai-codex`; the agent gets the declared root, not the ambient one, and `--provider openai-codex` | pass | transcripts S7, `s7-pi-declared-root-worker-pane.txt` |
| S8: Pi refuses an undeclared provider, an unqualified model, a declared provider the root has no login for (the ambient Anthropic key cannot answer), and an empty root | pass | transcripts S8 |
| S9: one home declaring `openai-codex codex-native` launches both, each pinned to its own provider | pass | transcripts S9, `pane-fm-s9a-pi.txt`, `pane-fm-s9b-pi.txt` |
| S10: raw Pi commands without `--provider`, with `--provider=`, or with another provider refuse; `--provider openai-codex` launches | pass | transcripts S10, `pane-fm-s10-pi.txt` |
| S10c: a raw Claude command cannot bypass a missing declaration | pass | transcripts S10c |
| S11: relaunch after the declaration is removed refuses while the agent keeps running, with no progress note written | pass | transcripts S11 |
| S11b: relaunch of a stopped task launches under the newly declared root from the same home | pass (account half) | transcripts S11b, `s11-relaunch-worker-pane.txt` |
| S12: a local secondmate spends the launching home's account, not its own home's file | pass | transcripts S12, `s12-secondmate-pane.txt` |
| S13: Pi 0.84.0 refuses a root that lists no model for the provider (not as "cannot authenticate"), and accepts a model pattern when the root lists the provider | pass | transcripts S13, `pane-fm-s13-pi.txt` |
| S14: Codex still launches from a home with no account files | pass | transcripts S14, `pane-fm-s14-codex.txt` |
| S15: CRLF, a relative path, and a missing directory refuse; `ordinary` without a final newline launches | pass | transcripts S15, `pane-fm-s15-claude.txt` |
| S16: `pi-signed` refuses without `config/pi-account` and launches pinned when declared | pass | transcripts S16, `pane-fm-s16-pis.txt` |

## Limits

S11b's `fm-control` then reported that it could not confirm the replacement agent (`endpoint reads 'ambiguous'`).
That is expected: the recorder is not a Claude TUI, so the state classifier cannot recognize it.
The account half, which is what this change owns, is shown by the launch line and the recorded process environment.
A successful relaunch of a live Claude agent needs a real Claude composer, which this round did not start in order to avoid spending tokens.
