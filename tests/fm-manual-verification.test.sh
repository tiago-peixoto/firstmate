#!/usr/bin/env bash
# Behavior coverage for reusable private manual-verification artifacts.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-manual-verification)
mkdir -p "$TMP_ROOT"
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$HOME_ROOT"
HOME_REAL=$(cd "$HOME_ROOT" && pwd -P)
SCRIPT="$ROOT/bin/fm-manual-verify.mjs"
NOW=2026-08-03T12:34:56.000Z

EDITOR_SPEC="$TMP_ROOT/editor.json"
cat > "$EDITOR_SPEC" <<'JSON'
{
  "schemaVersion": 1,
  "taskId": "manual-verify-editor-selection",
  "verificationType": "browser-editor",
  "project": "Design Studio <unsafe>",
  "issue": "UI-42 </script><script>globalThis.pwned=true</script>",
  "issueUrl": "https://issues.example.test/UI-42?q=%3Cunsafe%3E",
  "prUrl": "https://github.com/example/design-studio/pull/42",
  "revision": "0123456789abcdef0123456789abcdef01234567",
  "environment": "isolated local review stack",
  "staleCheck": "Compare the running build identity with the exact revision above before testing.",
  "loginUrl": "http://localhost:4300/login?next=%2Feditor",
  "account": "safe-reviewer@example.test",
  "testUrl": "http://localhost:4300/projects/local-fixture/design",
  "preconditions": [
    "Use only the reversible local fixture.",
    "Confirm the editor reports Saved before starting."
  ],
  "blastRadius": "Local fixture only; selection steps must not save geometry.",
  "restoration": "Restore the fixture snapshot and confirm a reload matches the baseline.",
  "purpose": "Verify that a visible upper surface owns selection when another surface is geometrically underneath it.",
  "userOutcome": "The user selects what is visibly under the pointer at every supported view.",
  "contextFields": [
    {
      "id": "camera_state",
      "label": "Exact camera state",
      "type": "select",
      "required": true,
      "options": [
        {"value": "normal-oblique", "label": "Normal oblique with visible depth"},
        {"value": "cube-clamped-top", "label": "Exact cube-clamped top-down"}
      ]
    },
    {
      "id": "visible_occlusion",
      "label": "Visible occlusion at the pointer",
      "type": "textarea",
      "required": true,
      "help": "State which surface was visible and whether the lower surface had any visible footprint."
    },
    {
      "id": "click_target",
      "label": "Exact click target",
      "type": "text",
      "required": true
    },
    {
      "id": "product_rule",
      "label": "Expected product rule",
      "type": "textarea",
      "required": true
    }
  ],
  "sections": [
    {
      "title": "Scene identity",
      "description": "Record enough visible identity to repeat the click without private data.",
      "fields": [
        {
          "id": "scene_marker",
          "label": "Visible fixture marker",
          "type": "text",
          "required": true
        }
      ]
    }
  ],
  "steps": [
    {
      "id": "oblique-selection",
      "title": "Select at normal oblique",
      "setup": "Set a normal oblique view with both height and side walls visible.",
      "action": "Click the center of the nested footprint <img src=x onerror=globalThis.pwned=true>.",
      "expected": "The visibly upper surface highlights and remains selected."
    },
    {
      "id": "exact-top-selection",
      "title": "Select at exact top-down",
      "setup": "Use the camera cube until the view is exactly clamped top-down.",
      "action": "Repeat the same pointer click and note visible occlusion.",
      "expected": "Selection follows the stated product rule without an inferred camera state."
    }
  ]
}
JSON

GENERATE_OUT=$(FM_HOME="$HOME_ROOT" FM_MANUAL_VERIFY_NOW="$NOW" "$SCRIPT" generate "$EDITOR_SPEC" 2>&1) \
  || fail "generator refused a complete editor specification: $GENERATE_OUT"
ARTIFACT=$(printf '%s' "$GENERATE_OUT" | jq -er '.artifact') \
  || fail "generator did not return a structured artifact path: $GENERATE_OUT"
assert_present "$ARTIFACT" "generator did not create the private artifact"
[ "$ARTIFACT" = "$HOME_REAL/data/manual-verify-editor-selection/manual-verification.html" ] \
  || fail "generator wrote outside the task-owned private artifact path: $ARTIFACT"

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}
[ "$(file_mode "$ARTIFACT")" = 600 ] || fail "generated artifact is not mode 0600"
[ "$(file_mode "$(dirname "$ARTIFACT")")" = 700 ] || fail "generated task directory is not mode 0700"
pass "complete structured input renders only to a private task-owned path"

python3 - "$ARTIFACT" <<'PY' || fail "generated artifact did not preserve unambiguous review content safely"
from html.parser import HTMLParser
from pathlib import Path
import sys

raw = Path(sys.argv[1]).read_text()
assert "</script><script>" not in raw
assert "<img src=x onerror=globalThis.pwned=true>" not in raw
assert "overflow-x: hidden" in raw
assert "min-width: 0" in raw
assert "@media (max-width: 640px)" in raw
assert 'name="viewport"' in raw

class Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts = []
    def handle_data(self, data):
        self.parts.append(data)

parser = Text()
parser.feed(raw)
text = " ".join(parser.parts)
for expected in (
    "Exact camera state",
    "Visible occlusion at the pointer",
    "Exact click target",
    "Expected product rule",
    "Select at normal oblique",
    "Select at exact top-down",
    "Pass",
    "Fail",
    "Blocked",
    "Not Run",
    "Actual behavior",
    "Notes",
    "Repeatability",
    "Acceptance impact",
    "Evidence links",
    "Console health",
    "Network health",
    "Data side effects",
    "Restoration result",
    "Unverified items",
    "Free-form observations",
    "Overall result",
    "PASS conflicts with unresolved verification items",
    "Reset saved draft",
):
    assert expected in text, expected
PY
RUNTIME_JS="$TMP_ROOT/generated-runtime.js"
python3 - "$ARTIFACT" "$RUNTIME_JS" <<'PY' || fail "could not extract the generated browser runtime"
from pathlib import Path
import re
import sys
raw = Path(sys.argv[1]).read_text()
scripts = re.findall(r'<script(?: [^>]*)?>([\s\S]*?)</script>', raw)
assert len(scripts) >= 2
Path(sys.argv[2]).write_text(scripts[-1])
PY
node --check "$RUNTIME_JS" >/dev/null || fail "generated browser runtime is not executable JavaScript"
pass "artifact captures the previously missing facts, multiple steps, contradiction warning, and narrow-layout safeguards"

assert_contains "$(printf '%s' "$GENERATE_OUT" | jq -r '.draftKey')" "manual-verify-editor-selection" \
  "draft identity does not include the artifact identity"
assert_contains "$(printf '%s' "$GENERATE_OUT" | jq -r '.draftKey')" "0123456789abcdef" \
  "draft identity does not include the exact revision"
assert_contains "$(printf '%s' "$GENERATE_OUT" | jq -r '.queueKey')" "0123456789abcdef" \
  "stable queue identity does not include the exact revision"

ORDER=$(printf '%s' "$GENERATE_OUT" | jq -r '.handoff.commands[].action')
[ "$ORDER" = $'create-session-without-opening\narm-feedback-return\npresent-artifact' ] \
  || fail "handoff does not arm feedback before presentation: $ORDER"
[ "$(printf '%s' "$GENERATE_OUT" | jq -r '.handoff.commands[0].argv[-1]')" = "--no-open" ] \
  || fail "first handoff action can open a browser before feedback is armed"
assert_contains "$(printf '%s' "$GENERATE_OUT" | jq -r '.handoff.commands[1].argv[0]')" "fm-procevent-lavish.sh" \
  "handoff does not use the registered Lavish process-event adapter"
[ "$(printf '%s' "$GENERATE_OUT" | jq -r '.handoff.commands[2].argv | index("--no-open")')" = null ] \
  || fail "presentation command still suppresses the browser open"
pass "handoff plan establishes the existing process-event return path before presentation"

ANSWERS="$TMP_ROOT/editor-answers.json"
cat > "$ANSWERS" <<'JSON'
{
  "context": {
    "camera_state": "cube-clamped-top",
    "visible_occlusion": "Only the upper surface was visible; the lower surface had no visible footprint.",
    "click_target": "Canvas center of the nested footprint.",
    "product_rule": "The visibly upper surface must win at this exact camera state.",
    "scene_marker": "Synthetic nested-roof fixture"
  },
  "steps": [
    {
      "id": "oblique-selection",
      "status": "PASS",
      "actual": "The upper surface highlighted and remained selected.",
      "notes": "Repeated after returning from top-down."
    },
    {
      "id": "exact-top-selection",
      "status": "FAIL",
      "actual": "The fully hidden lower surface became selected.",
      "notes": "Repeated three times at the exact cube clamp."
    }
  ],
  "repeatability": "EVERY_TIME",
  "acceptanceImpact": "BLOCKING",
  "evidenceLinks": "file:///private/evidence/selection-failure.png",
  "consoleHealth": "PASS",
  "consoleNotes": "No console errors.",
  "networkHealth": "PASS",
  "networkNotes": "No failed requests.",
  "dataSideEffects": "No save request and no geometry mutation.",
  "restorationResult": "NOT_NEEDED",
  "restorationNotes": "Selection-only check.",
  "unverifiedItems": "None.",
  "observations": "The hover matched the unexpected selected surface.",
  "overall": "FAIL",
  "contradictionConfirmed": false,
  "contradictionReason": ""
}
JSON

SUBMISSION=$(FM_MANUAL_VERIFY_NOW=2026-08-03T13:00:00.000Z "$SCRIPT" submission "$ARTIFACT" "$ANSWERS" 2>&1) \
  || fail "unambiguous failed-step submission was rejected: $SUBMISSION"
printf '%s' "$SUBMISSION" | jq -e '
  .summary | contains("cube-clamped-top") and
  contains("Only the upper surface was visible") and
  contains("Canvas center of the nested footprint") and
  contains("visibly upper surface must win")
' >/dev/null || fail "human-readable summary omitted a fact needed to diagnose the ambiguous selection report"
printf '%s' "$SUBMISSION" | jq -e '
  .options.tag == "manual-verification" and
  .options.queueKey == "fm-manual-verification:manual-verify-editor-selection:0123456789abcdef0123456789abcdef01234567" and
  .options.data.kind == "manual-verification" and
  .options.data.schemaVersion == 1 and
  .options.data.revision == "0123456789abcdef0123456789abcdef01234567" and
  .options.data.overall == "FAIL" and
  (.options.data.steps | length) == 2 and
  .options.data.context.camera_state == "cube-clamped-top"
' >/dev/null || fail "submission lacks stable typed context or exact revision identity: $SUBMISSION"
pass "structured submission expresses camera, occlusion, target, repeatability, evidence, and product rule without ambiguity"

INCOMPLETE="$TMP_ROOT/incomplete.json"
jq '.context.camera_state="" | .steps[1].actual="" | .dataSideEffects=""' "$ANSWERS" > "$INCOMPLETE"
set +e
INCOMPLETE_OUT=$(FM_MANUAL_VERIFY_NOW=2026-08-03T13:00:00.000Z \
  "$SCRIPT" submission "$ARTIFACT" "$INCOMPLETE" 2>&1)
INCOMPLETE_CODE=$?
set -e
expect_code 2 "$INCOMPLETE_CODE" "submission missing required diagnostic evidence"
assert_contains "$INCOMPLETE_OUT" "context.camera_state" "missing context did not name its required field"
assert_contains "$INCOMPLETE_OUT" "steps[1].actual" "failed step accepted no actual behavior"
assert_contains "$INCOMPLETE_OUT" "dataSideEffects" "submission accepted no side-effect statement"
pass "required context, failed-step actual behavior, and core evidence stop incomplete submissions"

CONTRADICTORY="$TMP_ROOT/contradictory.json"
jq '.overall="PASS"' "$ANSWERS" > "$CONTRADICTORY"
set +e
CONTRADICTION_OUT=$(
  FM_MANUAL_VERIFY_NOW=2026-08-03T13:00:00.000Z "$SCRIPT" submission "$ARTIFACT" "$CONTRADICTORY" 2>&1
)
CONTRADICTION_CODE=$?
set -e
expect_code 2 "$CONTRADICTION_CODE" "PASS with an unresolved failed step and no confirmation"
assert_contains "$CONTRADICTION_OUT" "contradictionConfirmed" \
  "contradictory PASS did not explain the visible confirmation requirement"

CONFIRMED="$TMP_ROOT/confirmed.json"
jq '.overall="PASS" | .contradictionConfirmed=true | .contradictionReason="Accepted as a known non-blocking exception after explicit review."' \
  "$ANSWERS" > "$CONFIRMED"
FM_MANUAL_VERIFY_NOW=2026-08-03T13:00:00.000Z "$SCRIPT" submission "$ARTIFACT" "$CONFIRMED" >/dev/null \
  || fail "visible contradiction confirmation could not be submitted"
pass "overall PASS cannot hide an unresolved failed step without deliberate visible confirmation"

MALFORMED="$TMP_ROOT/malformed.json"
jq 'del(.steps[0].expected)' "$EDITOR_SPEC" > "$MALFORMED"
set +e
MALFORMED_OUT=$(FM_HOME="$HOME_ROOT" "$SCRIPT" generate "$MALFORMED" 2>&1)
MALFORMED_CODE=$?
set -e
expect_code 2 "$MALFORMED_CODE" "malformed structured input"
assert_contains "$MALFORMED_OUT" "steps[0].expected" "validation error did not name the malformed field"

UNSAFE_PATH="$TMP_ROOT/unsafe-path.json"
jq '.taskId="../escape"' "$EDITOR_SPEC" > "$UNSAFE_PATH"
set +e
UNSAFE_PATH_OUT=$(FM_HOME="$HOME_ROOT" "$SCRIPT" generate "$UNSAFE_PATH" 2>&1)
UNSAFE_PATH_CODE=$?
set -e
expect_code 2 "$UNSAFE_PATH_CODE" "unsafe task output path"
assert_contains "$UNSAFE_PATH_OUT" "taskId" "unsafe output rejection did not name taskId"
assert_absent "$TMP_ROOT/escape" "unsafe task id escaped the private data root"

UNSAFE_URL="$TMP_ROOT/unsafe-url.json"
jq '.loginUrl="javascript:globalThis.pwned=true"' "$EDITOR_SPEC" > "$UNSAFE_URL"
set +e
UNSAFE_URL_OUT=$(FM_HOME="$HOME_ROOT" "$SCRIPT" generate "$UNSAFE_URL" 2>&1)
UNSAFE_URL_CODE=$?
set -e
expect_code 2 "$UNSAFE_URL_CODE" "unsafe login URL"
assert_contains "$UNSAFE_URL_OUT" "loginUrl" "unsafe URL rejection did not name loginUrl"
pass "malformed inputs, unsafe URLs, and path traversal stop with actionable errors"

ORIGINAL_DRAFT_KEY=$(printf '%s' "$GENERATE_OUT" | jq -r '.draftKey')
REVISED_SPEC="$TMP_ROOT/revised.json"
jq '.revision="fedcba9876543210fedcba9876543210fedcba98"' "$EDITOR_SPEC" > "$REVISED_SPEC"
REVISED_OUT=$(FM_HOME="$HOME_ROOT" FM_MANUAL_VERIFY_NOW="$NOW" "$SCRIPT" generate "$REVISED_SPEC") \
  || fail "revised artifact generation failed"
REVISED_DRAFT_KEY=$(printf '%s' "$REVISED_OUT" | jq -r '.draftKey')
[ "$ORIGINAL_DRAFT_KEY" != "$REVISED_DRAFT_KEY" ] \
  || fail "draft persistence can leak answers across revisions"
[ "$(printf '%s' "$GENERATE_OUT" | jq -r '.queueKey')" != "$(printf '%s' "$REVISED_OUT" | jq -r '.queueKey')" ] \
  || fail "submission queue identity can collide across revisions"
pass "draft and queue identities are stable per artifact and isolated by exact revision"

API_SPEC="$TMP_ROOT/api.json"
cat > "$API_SPEC" <<'JSON'
{
  "schemaVersion": 1,
  "taskId": "manual-verify-api-health",
  "verificationType": "backend-api",
  "project": "Example Service",
  "issue": "Routine API compatibility check",
  "revision": "staging-build-2026-08-03.7",
  "environment": "staging read-only API",
  "staleCheck": "Read the deployment build endpoint and compare it with the identity above.",
  "loginUrl": "https://auth.example.test/login",
  "account": "read-only verification role",
  "testUrl": "https://api.example.test/v1/health",
  "preconditions": ["Use the read-only client and a synthetic request body."],
  "blastRadius": "Read-only health and validation endpoints only.",
  "restoration": "No restoration should be needed; record any unexpected write.",
  "purpose": "Verify response compatibility and rejection behavior through the public API.",
  "userOutcome": "API clients receive stable responses and actionable validation errors.",
  "contextFields": [
    {"id": "client", "label": "Client and version", "type": "text", "required": true},
    {"id": "request_id", "label": "Response correlation identifier", "type": "text", "required": false}
  ],
  "sections": [],
  "steps": [
    {
      "id": "health-response",
      "title": "Read service health",
      "setup": "Use the read-only staging client.",
      "action": "Request GET /v1/health.",
      "expected": "The service returns the documented healthy response without a data write."
    },
    {
      "id": "invalid-request",
      "title": "Reject a malformed request",
      "setup": "Use a synthetic invalid identifier.",
      "action": "Call the documented validation endpoint.",
      "expected": "The service returns the documented client error with no side effect."
    }
  ]
}
JSON
API_OUT=$(FM_HOME="$HOME_ROOT" FM_MANUAL_VERIFY_NOW="$NOW" "$SCRIPT" generate "$API_SPEC") \
  || fail "non-editor API specification was rejected"
API_ARTIFACT=$(printf '%s' "$API_OUT" | jq -er '.artifact') || fail "API artifact path missing"
API_TEXT=$(python3 - "$API_ARTIFACT" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys
class Text(HTMLParser):
    def __init__(self): super().__init__(); self.parts=[]
    def handle_data(self, data): self.parts.append(data)
p=Text(); p.feed(Path(sys.argv[1]).read_text()); print(" ".join(p.parts))
PY
)
assert_contains "$API_TEXT" "Client and version" "API artifact omitted its natural verification context"
assert_contains "$API_TEXT" "Response correlation identifier" "API artifact omitted its diagnostic context"
assert_contains "$API_TEXT" "GET /v1/health" "API artifact omitted its public action"
assert_not_contains "$API_TEXT" "Exact camera state" "API artifact forced editor-only camera concepts"
assert_not_contains "$API_TEXT" "Visible occlusion" "API artifact forced editor-only occlusion concepts"
pass "non-editor checks retain the shared evidence core without editor-specific concepts"

printf 'ok - manual-verification generator and Lavish handoff contract\n'
