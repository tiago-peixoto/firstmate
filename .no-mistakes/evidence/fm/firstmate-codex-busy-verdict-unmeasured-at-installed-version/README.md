# Codex native activity visibility — test evidence

Branch `fm/firstmate-codex-busy-verdict-unmeasured-at-installed-version`, head `dec4393`.
Host: macOS, `codex-cli 0.153.2`, `herdr 0.8.2`.

## 1. `real-launch-path-demo/` — the intent working end to end

`transcript.txt` is the operator-visible run of the **real** Firstmate launch path
(`bin/fm-spawn.sh` → `bin/fm-codex-appserver.py` → the installed Codex TUI) inside an
isolated non-default Herdr lab, read back through the two consumer surfaces an operator
actually uses: the native verdict reader and `bin/fm-crew-state.sh`.

| Phase | Operator-visible result |
| --- | --- |
| Before the native launch | `state: unknown · harness state unavailable (unknown codex-unverified)` — the reported defect |
| Turn running | `state: working · source: pane · harness busy (codex-appserver)` |
| Turn completed | `idle codex-appserver`, native turn `completed`, `state: done` |
| Observer stopped (SIGSTOP) | `unknown codex-appserver-disconnected` — never idle, never success |
| Observer resumed | back to `idle codex-appserver` on the same thread |
| API failure | `unknown codex-appserver-failed`, native `systemError`/`failed`, `state: failed`, supervision `crew_absorb_class → none` |
| Later turn | recovers `completed` on the same thread |
| Exit | binding removed, 0700 transport dir removed, no orphaned launcher/server/TUI |
| App-server refuses to start | worker still launches as plain Codex; arming retired from meta and sidecars; one `working:` status line records why |

Model turns are served by a disposable local Responses provider injected through a CLI
overlay, so it needs no account quota; the credentialed equivalent is §2. The Codex binary, the
launch path, the private app-server transport, the crew-state reader and the supervision
classifier are all the production ones.

Reproduce: `bash real-launch-path-demo/run.sh <repo-root>`

## 2. `codex-native-live/` — the credentialed guard passes

`FM_CODEX_NATIVE_LIVE=1 bin/fm-test-run.sh tests/fm-codex-appserver-live-e2e.test.sh`
is the repository's own required lifecycle acceptance. The Codex account was out of
messages on the earlier attempt; after the captain added credits it now runs to
completion, unmodified, against the real credentialed account:

```
FM_TEST_END tests/fm-codex-appserver-live-e2e.test.sh exit=0 duration_ms=176386
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
credentialed native lifecycle guard passed: codex-cli 0.153.2
```

All 39 checks pass, including every case the credential-free demo in §1 could not reach:

| Case | Check |
| --- | --- |
| Real long foreground tool call | `foreground command is executing during activity check`, `long foreground tool remains native busy`, `crew-state proves later input is working` |
| Interruption of a running tool | `interrupt is a native interrupted turn`, `a subsequent turn recovers after interruption` |
| User-input wait | `native input wait is parked in crew-state` (`unknown codex-appserver-waiting-input`) |
| Restart with a stale binding | `restart mints a fresh task incarnation`, `stale launch binding cannot classify replacement`, `replacement activity resumes after stale-binding rejection` |
| Secondmate leg (distinct FM_HOME) | `secondmate has parent-owned generation and native activity`, `secondmate launcher publishes the native turn-end wake`, `secondmate observation loss is unknown`, `secondmate cleanup removes native transport` |

Scope note: the guard exercises the user-input wait (`request_user_input`) but not a
separate command-approval wait, which would require changing the account's approval
policy — the intent requires approval behaviour to be preserved. The
`codex-appserver-waiting-approval` branch is covered by `tests/fm-codex-appserver.test.sh`.

Files: `live-guard-transcript.txt` (this passing run), `commands.jsonl` (every command,
result and native snapshot the guard recorded), `blocked-pane.txt` (the earlier
quota-exhausted pane, kept for history).

## 3. Independent re-run, and a version drift that arrived mid-run

`live-acceptance-0.153.2.txt` is a second, independent pass of the same credentialed
guard (39 checks, `exit=0`, 174s), run after the §2 transcript. Both passes agree.

Between the two, the host's `codex` was upgraded: `~/.local/bin/codex` was repointed to
release `0.153.4` at 14:27 today. The change pins the capability gate to `codex-cli
0.153.2` (`bin/fm-codex-appserver.py`, `VERIFIED_VERSION`), so on the host as it now
stands the gate closes and Codex workers fall back to `unknown codex-unverified`:

```
$ FM_CODEX_NATIVE_LIVE=1 bin/fm-test-run.sh tests/fm-codex-appserver-live-e2e.test.sh
AssertionError: installed Codex version codex-cli 0.153.4
```
(`live-acceptance-as-installed-0.153.4.txt`)

That is the intent's "keep the capability gate closed for unsupported or unverified
paths" behaving correctly, not a defect. The re-run above pins PATH to the `0.153.2`
release still installed at `~/.codex/packages/standalone/releases/`; no system state was
changed. Refreshing the gate to `0.153.4` is a captain decision: it needs this guard
re-run at `0.153.4` plus the literal refresh that
`docs/verification/runtime-backends.md` prescribes.

## 4. `crew-state-captain-view.txt` — the surface the captain reads

Every `bin/fm-crew-state.sh` line the live run produced, in lifecycle order:
`working`, `done`, `parked · Codex waiting for user input`, `failed · Codex native turn
failed`, and `unknown` only on genuine observation loss — where before this change all
of them read `unknown · harness state unavailable (unknown codex-unverified)`.

## 5. `degrade-before-after.txt` — an observer failure must not veto the worker

Direct A/B of the last two commits, against a Codex that passes the version gate but
whose `app-server` will not start:

| | launcher exit | worker | stranded `busy_gen=` in meta | status log |
| --- | --- | --- | --- | --- |
| before (`84d2796^`) | `1` | **none — pane is empty** | 1 line | (silent) |
| after (`HEAD`) | `0` | plain Codex, `--model gpt-5-codex` preserved | 0 lines | `working: native Codex activity observation was not established (...)` |

`degrade-path-fixture.txt` is the portable regression for the same property
(`tests/fm-codex-appserver.test.sh`, 22 checks, `exit=0`).
