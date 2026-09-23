#!/usr/bin/env bash
# Live check: a home with config/pi-account refuses a raw Pi launch command.
set -u
ROOT=${ROOT:?}; LAB=$ROOT/bin/fm-herdr-lab.sh
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-acct-raw.XXXXXX")
SESSION=$("$LAB" name acct-raw)
trap '"$LAB" teardown "$SESSION" && echo "# teardown ok: $SESSION"; rm -rf "$T"' EXIT
"$LAB" provision "$SESSION" || exit 1
mkdir -p "$T/pi-work" "$T/proj" "$T/h/data/r1" "$T/h/state" "$T/h/config" "$T/h/projects"
printf '{"openai":{"type":"api_key","key":"sk-fm-lab-synthetic"}}\n' > "$T/pi-work/auth.json"
git -C "$T/proj" init -q; echo x > "$T/proj/README.md"; git -C "$T/proj" add .; git -C "$T/proj" -c user.name=t -c user.email=t@e.invalid commit -qm i
touch "$T/h/state/.last-watcher-beat"; printf 'off\n' > "$T/h/config/herdr-presentation-spaces"
printf '%s\nopenai\n' "$T/pi-work" > "$T/h/config/pi-account"
printf '# Task\n## Captain'"'"'s intent\nLab check.\n\n## Firstmate spec\nNothing.\n' > "$T/h/data/r1/brief.md"
echo "\$ fm-spawn.sh r1 <proj> 'pi --provider openai --model openai/gpt-4o-mini' --mode local-only --yolo off --backend herdr"
FM_GATE_REFUSE_BYPASS=1 HERDR_SESSION=$SESSION FM_SPAWN_NO_GUARD=1 FM_HOME="$T/h" FM_ROOT_OVERRIDE="$ROOT" CLAUDE_CONFIG_DIR=$T/none \
  "$ROOT/bin/fm-spawn.sh" r1 "$T/proj" 'pi --provider openai --model openai/gpt-4o-mini' --mode local-only --yolo off --backend herdr 2>&1 | tail -2
echo "rc=${PIPESTATUS[0]} record: $([ -e "$T/h/state/r1.meta" ] && echo yes || echo no) panes: $(herdr pane list --session "$SESSION" 2>/dev/null | jq '[.result.panes[]?]|length')"
