# Live validation: explicit worker account selection (issue 4574)

Every transcript here comes from the real `bin/fm-spawn.sh` and `bin/fm-control.sh` at commit 7b281c9.
They ran against a real tmux 3.7c server on a private socket, a real treehouse pool, and throwaway Firstmate homes.
The runners were real: Claude Code 2.1.277, Pi 0.85.1, quota-axi 0.1.47, and codex-cli 0.154.0.
Nothing in the lab used the operator's real account roots.
HOME was a throwaway directory, and every Claude and Pi root was created for the lab.

## Lab setup

The tmux server and the spawning shell deliberately carried ambient credentials that a correct launch must ignore:
- `CLAUDE_CONFIG_DIR` pointing at an ambient root.
- `ANTHROPIC_API_KEY`.
- `CLAUDE_CODE_USE_BEDROCK=1` and `CLAUDE_CODE_USE_MANTLE=1`.
- `PI_CODING_AGENT_DIR` pointing at another logged-in Pi root.
- A provider key variable.

`mock-provider.py` is a local OpenAI-compatible server.
Pi workers talk only to it.
Each Pi account identity is a URL prefix with its own key (`/work`, `/personal`, `/other`, `/ordinary`).
Its request log is therefore the billing record: it shows which account a worker actually spent.
`lab-shared-pi-root-models.json` is the shared Pi root, which holds both a work identity and a personal identity.
Claude workers ran with `ANTHROPIC_BASE_URL` set to a dead localhost port, so no project context left the machine.
`lab-driver.sh` holds the helper functions used to drive every scenario.

## Scenarios

| File | What it shows |
| --- | --- |
| `A-claude-fresh-home-refuses.txt` | A home without `config/claude-account` refuses a Claude spawn, names the file to create, and creates no window, record, or worktree. |
| `B-pi-fresh-home-refuses.txt` | The same refusal for `pi` and `pi-signed` without `config/pi-account`, even though an ambient Pi root is set. |
| `C-claude-root-without-login-refuses.txt` | The real quota-axi preflight refuses a declared Claude root that holds no login. |
| `D-claude-declared-root-launch.txt`, `D-claude-worker-pane.txt` | A real Claude process launches with `CLAUDE_CONFIG_DIR` set to the declared root, and the ambient API key and Bedrock/Mantle switches removed (shown from the process environment). |
| `E-claude-environment-line-keeps-credentials.txt` | The `environment` line keeps those credentials on the real Claude process. |
| `F-I-pi-undeclared-provider-refuses.txt` | A personal home cannot spend the work identity in a shared Pi root; an unqualified model, or no model, also refuses. |
| `G-pi-declared-provider-launch.txt` | A real Pi worker answers through the declared personal identity only, not through the ambient root. |
| `H-pi-ambient-key-cannot-answer-for-root.txt` | An ambient key cannot stand in for a root that stores no credential; the explicit `environment` line admits it. |
| `J-pi-raw-command-must-pin-provider.txt` | A raw Pi command must pass `--provider <declared>` itself; otherwise it refuses. |
| `K-relaunch-refuses-before-stopping.txt` | Relaunch refuses a missing declaration or an undeclared provider before stopping the live agent (same pid); a valid relaunch keeps the pinned account. |
| `L-secondmate-reads-launching-home.txt` | A secondmate spends the launching home's account, never its own home's worker declaration. |
| `M-pi-provider-pin-blocks-fallback.txt` | Without `--provider`, bare Pi falls back to the work identity; Firstmate's pinned launch stays on the personal one. |
| `N-O-explicit-ordinary-selection.txt` | An explicit `ordinary` selection works for Pi (`$HOME/.pi/agent`) and is distinct from an absent file for Claude. |
| `P-malformed-declarations-refuse.txt` | A relative path, CRLF, a missing directory, a missing providers line, or a misspelled `environment` line all refuse. |
| `Q-undeclared-runner-still-launches.txt` | Codex, which carries no declaration, still launches from a home with no account files. |
| `R-no-credentials-copied.txt` | No lab key or credential file ended up in any Firstmate home. |

## Not driven live

The launch half of Claude `ordinary` was not driven here.
A real Claude with `CLAUDE_CONFIG_DIR` unset reads the operator's default macOS Keychain login, which this sandboxed run must neither use nor rotate.
`tests/fm-worker-account.test.sh` covers that launch line under a throwaway HOME.
