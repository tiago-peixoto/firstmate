#!/usr/bin/env bash
# Behavior tests for the opt-in Claude Stop hook that asks a primary for a live
# read when its reply admits answering from memory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-memory-answer-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-memory-answer-guard)
PRIMARY="$TMP_ROOT/primary"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

mkdir -p "$PRIMARY/bin" "$PRIMARY/state" "$PRIMARY/config"
printf '# fixture\n' > "$PRIMARY/AGENTS.md"
git -C "$PRIMARY" init -q

# run_guard <root> <reply> [stop_hook_active]; the exit status is the hook's.
run_guard() {
  local root=$1 reply=$2 active=${3:-false}
  jq -nc --arg reply "$reply" --argjson active "$active" \
    '{session_id:"s1", hook_event_name:"Stop", stop_hook_active:$active, last_assistant_message:$reply}' \
    | env -u GROK_AGENT -u GROK_HOOK_EVENT FM_ROOT_OVERRIDE="$root" FM_HOME="$root" \
        FM_STATE_OVERRIDE="$root/state" FM_CONFIG_OVERRIDE="$root/config" \
        "$GUARD" >"$OUT" 2>"$ERR"
}

assert_silent() {
  [ ! -s "$OUT" ] || fail "$1 wrote stdout: $(cat "$OUT")"
  [ ! -s "$ERR" ] || fail "$1 wrote stderr: $(cat "$ERR")"
}

MEMORY_REPLY='Captain, from memory the PR is already merged and its checks passed.'

test_absent_config_is_silent() {
  rm -f "$PRIMARY/config/memory-answer-guard"
  run_guard "$PRIMARY" "$MEMORY_REPLY" || fail "absent config must exit 0"
  assert_silent "absent config"
  pass "without config/memory-answer-guard a from-memory reply ends the turn unchanged"
}

test_memory_admission_blocks_once() {
  : > "$PRIMARY/config/memory-answer-guard"
  run_guard "$PRIMARY" "$MEMORY_REPLY" || fail "a blocking hook must exit 0"
  jq -e '.decision == "block" and (.reason | contains("\"from memory\"")) and (.reason | contains("live"))' "$OUT" >/dev/null \
    || fail "a from-memory reply must block with a live-read reason: $(cat "$OUT")"
  run_guard "$PRIMARY" 'If I recall correctly, the drain ran clean.' || fail "hook failed"
  jq -e '.decision == "block"' "$OUT" >/dev/null || fail "'if I recall' must block: $(cat "$OUT")"
  run_guard "$PRIMARY" "$MEMORY_REPLY" true || fail "a continuation stop must exit 0"
  assert_silent "continuation stop"
  pass "a reply admitting a from-memory answer blocks once, and the continuation reply ends the turn"
}

test_live_answer_is_silent() {
  : > "$PRIMARY/config/memory-answer-guard"
  run_guard "$PRIMARY" 'Captain, I read the PR just now: it is open with 2 checks failing.' || fail "hook failed"
  assert_silent "a live answer"
  run_guard "$PRIMARY" '' || fail "an empty reply must exit 0"
  assert_silent "an empty reply"
  pass "a reply that does not admit a memory answer ends the turn unchanged"
}

test_secondmate_home_and_bad_payload_are_silent() {
  local second="$TMP_ROOT/second"
  mkdir -p "$second/bin" "$second/state" "$second/config"
  printf '# fixture\n' > "$second/AGENTS.md"
  git -C "$second" init -q
  printf 'sm-fixture\n' > "$second/.fm-secondmate-home"
  : > "$second/config/memory-answer-guard"
  run_guard "$second" "$MEMORY_REPLY" || fail "a secondmate home must exit 0"
  assert_silent "secondmate home"
  printf 'not json' | FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$PRIMARY" FM_STATE_OVERRIDE="$PRIMARY/state" \
    FM_CONFIG_OVERRIDE="$PRIMARY/config" "$GUARD" >"$OUT" 2>"$ERR" || fail "a bad payload must exit 0"
  assert_silent "bad payload"
  pass "a secondmate home and an unreadable payload never block"
}

test_tracked_stop_hook_is_registered() {
  local matches
  matches=$(jq '[.hooks.Stop[0].hooks[] | select(.command | contains("/bin/fm-memory-answer-guard.sh"))
    | select(.asyncRewake | not) | select(.command | contains("${GROK_AGENT:-}${GROK_HOOK_EVENT:-}"))] | length' \
    "$ROOT/.claude/settings.json") || fail "tracked Stop hooks could not be read"
  [ "$matches" -eq 1 ] || fail "expected one synchronous grok-inert Stop hook for fm-memory-answer-guard.sh, saw $matches"
  pass "tracked Claude Stop settings run fm-memory-answer-guard.sh once, synchronously, and inert under grok"
}

fm_test_run \
  test_absent_config_is_silent \
  test_memory_admission_blocks_once \
  test_live_answer_is_silent \
  test_secondmate_home_and_bad_payload_are_silent \
  test_tracked_stop_hook_is_registered
