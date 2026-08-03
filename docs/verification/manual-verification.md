# Manual-verification artifact verification

Audience: maintainer verification.

This record holds reusable evidence for the generated manual-verification artifact and its Lavish handoff.
`bin/fm-manual-verify.mjs` owns the input schema, rendering, private output, and exact command plan.
`.agents/skills/manual-verification/SKILL.md` owns the operating procedure.
`.agents/skills/process-event-sources/SKILL.md` owns feedback-source handling and its loss limitation.

Verified on 2026-08-03 on macOS with Node 22.23.1, `lavish-axi` 0.1.43, and `chrome-devtools-axi` 0.1.27.
The audited implementation tree identity was `b344097fe9deaeeafa428f0c658ecc27496fc4c8`.

## Real Lavish in-frame audit

The private synthetic specification used the reusable `operational-tool` type and contained no credential, customer identifier, project route, screenshot, or private finding.
The artifact was generated, opened without presentation, armed through the existing process-event adapter, and only then presented:

```sh
bin/fm-manual-verify.mjs generate data/firstmate-lavish-manual-verification-template/spec.json
lavish-axi data/firstmate-lavish-manual-verification-template/manual-verification.html --no-open
bin/fm-procevent-lavish.sh arm data/firstmate-lavish-manual-verification-template/manual-verification.html
lavish-axi data/firstmate-lavish-manual-verification-template/manual-verification.html
```

The final arm result was:

```text
registered: lavish-0951257d410e00be (lavish)
armed: lavish-0951257d410e00be
owner: live
liveness: reconciliation established this source owner
```

The final Lavish open result reported `status: opened` at the exact tree identity.
The real in-frame audit ran at a 1440 by 900 desktop viewport and a 390 by 844 narrow viewport while the registered source remained `OWNER live` with `PENDING 0`.
No final-revision `layout_warnings` result was captured at either viewport.
The final clean browser reported no console error.
The narrow accessibility snapshot retained the stale-revision warning, exact revision, every native control, the complete-verification action, and the reset action without a horizontal-overflow warning.

The final browser checks used:

```sh
CHROME_DEVTOOLS_AXI_SESSION=fm-manual-verify-audit-final \
  chrome-devtools-axi open http://127.0.0.1:4387/session/0951257d410e00be
CHROME_DEVTOOLS_AXI_SESSION=fm-manual-verify-audit-final \
  chrome-devtools-axi resize 390 844
CHROME_DEVTOOLS_AXI_SESSION=fm-manual-verify-audit-final \
  chrome-devtools-axi console --type error
```

The console result was:

```text
console:
## Console messages
<no console messages found>
```

## Interactive safeguards

A synthetic failed step plus overall PASS made the in-frame alert `PASS conflicts with unresolved verification items` visible and exposed the required confirmation checkbox.
The same contradictory answer set is rejected by the executable `submission` interface until confirmation and a reason are supplied.

A synthetic draft survived Lavish's in-session artifact reload with its revision-bound field values and contradiction state restored.
Changing the exact revision produced a different draft key and started with no prior-revision answers.
The custom accessible reset dialog allowed `Keep draft` without changing answers and `Reset all answers` cleared the field values, contradiction state, and saved draft.

The browser evidence was complemented by the portable behavior suite:

```sh
bin/fm-test-run.sh tests/fm-manual-verification.test.sh
bin/fm-test-run.sh tests/fm-procevent.test.sh
```

That suite covers required fields, multiple steps, ambiguity-removing editor context, contradiction handling, safe HTML and script serialization, path and URL refusal, private modes, draft and revision identity, stable typed submission context, narrow-layout safeguards, non-editor input, live-owner establishment, foreign-owner refusal, and acknowledgement re-arming.

## Delivery boundary

The process-event listener was explicitly retired after the audit and `bin/fm-procevent.sh list` returned `no sources registered`.
This audit does not change the published Lavish poll limitation.
The poll destructively clears source feedback before returning, so Firstmate must never claim lossless, no-loss, at-least-once, or generic exactly-once delivery.
