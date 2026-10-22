#!/usr/bin/env bash
# Drive the real PR health monitor from a disposable lab home against real GitHub, read-only.
set -u
ROOT=$PWD
EV=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
printf '# Backlog\n\n## Queued\n' > "$LAB/data/backlog.md"
REAL_GH=$(command -v gh)
mkdir -p "$LAB/shim"
: > "$EV/gh-calls.log"; : > "$EV/tmux-calls.log"
cat > "$LAB/shim/gh" <<SH
#!/usr/bin/env bash
# Forwarding shim: logs every call and its response, forwards to the real gh unchanged.
printf '%s\n' "\$*" | tr '\n' ' ' >> "$EV/gh-calls.log"; printf '\n' >> "$EV/gh-calls.log"
resp=\$(mktemp "$EV/responses/response.XXXXXX")
printf '%s\n' "\$*" > "\$resp.cmd"
"$REAL_GH" "\$@" > "\$resp"
rc=\$?
cat "\$resp"
exit \$rc
SH
printf '#!/bin/sh\nprintf "tmux %%s\\n" "$*" >> "%s"\nexit 1\n' "$EV/tmux-calls.log" > "$LAB/shim/tmux"
printf '#!/bin/sh\nexit 0\n' > "$LAB/shim/no-mistakes"
chmod 700 "$LAB/shim/"*
run() { # label cmd...
  local label=$1; shift
  printf '\n$ %s\n' "$*" | tee -a "$EV/transcript.txt"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/shim:$PATH" FM_HOME="$LAB" "$@" > "$EV/$label.out" 2> "$EV/$label.err"
  local rc=$?
  { cat "$EV/$label.out"; sed 's/^/stderr: /' "$EV/$label.err"; printf '[exit %s]\n' "$rc"; } | tee -a "$EV/transcript.txt"
}
PR_FALLBACK=https://github.com/kunchenguid/firstmate/pull/7208
PR_CONFLICT=https://github.com/kunchenguid/firstmate/pull/7612
date -u '+started %FT%TZ' | tee -a "$EV/transcript.txt"
echo "== Scenario: flag absent (default off) ==" | tee -a "$EV/transcript.txt"
ls -A "$LAB/state" "$LAB/data" > "$EV/flag-off-before.ls"
run flag-off-poll "$ROOT/bin/fm-pr-health.sh" poll
run flag-off-arm "$ROOT/bin/fm-pr-health.sh" arm
ls -A "$LAB/state" "$LAB/data" > "$EV/flag-off-after.ls"
{ printf 'gh calls so far: %s\n' "$(wc -l < "$EV/gh-calls.log")"; diff "$EV/flag-off-before.ls" "$EV/flag-off-after.ls" && echo 'state and data unchanged'; } | tee -a "$EV/transcript.txt"

echo "== Scenario: opt in, enroll PR with failing reported checks and no required contexts ==" | tee -a "$EV/transcript.txt"
run flag-on touch "$LAB/config/pr-health-monitor"
run enroll-7208 "$ROOT/bin/fm-contributions.sh" enroll ship1 "$PR_FALLBACK"
run arm "$ROOT/bin/fm-pr-health.sh" arm
ls -A "$LAB/state" | tee -a "$EV/transcript.txt"
run poll-1 bash "$LAB/state/pr-health.check.sh"
run poll-2 bash "$LAB/state/pr-health.check.sh"
cp "$LAB/state/pr-health.json" "$EV/pr-health-after-7208.json"

echo "== Scenario: enroll a PR with a definite conflict ==" | tee -a "$EV/transcript.txt"
run enroll-7612 "$ROOT/bin/fm-contributions.sh" enroll conflict1 "$PR_CONFLICT"
run poll-3 bash "$LAB/state/pr-health.check.sh"
run poll-4 bash "$LAB/state/pr-health.check.sh"
cp "$LAB/state/pr-health.json" "$EV/pr-health-after-7612.json"
cp -r "$LAB/data" "$EV/lab-data"
date -u '+finished %FT%TZ' | tee -a "$EV/transcript.txt"
echo "== gh calls ==" | tee -a "$EV/transcript.txt"
cut -c1-120 "$EV/gh-calls.log" | tee -a "$EV/transcript.txt"
echo "== tmux calls (expect none) ==" | tee -a "$EV/transcript.txt"
cat "$EV/tmux-calls.log" | tee -a "$EV/transcript.txt"
