#!/usr/bin/env bash
# Live check of fm-send's batched close failure path: one answer closes two
# keys, the status file cannot be appended, and the operator runs the printed
# manual close command. It must close both keys and must not run answer text
# as shell code.
#
# Usage: e2e-multikey-failed-close.sh <firstmate-checkout>
set -u
ROOT=$(cd "$1" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm4767-failclose.XXXXXX")
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
export FM_GATE_REFUSE_BYPASS=1
HOME_DIR="$WORK/home"; STATE="$HOME_DIR/state"; BIN="$WORK/bin"
mkdir -p "$STATE" "$BIN"
cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  send-keys) exit 0 ;;
  display-message) for a in "$@"; do case "$a" in *cursor_y*) echo 1; exit 0 ;; esac; done; echo fakepane; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf '%s\n' fm-t1; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/sleep"
chmod +x "$BIN"/*
printf 'window=sess:fm-t1\nkind=ship\n' > "$STATE/t1.meta"
printf 'needs-decision [key=budget]: approve spend?\nneeds-decision [key=vendor]: pick a vendor\n' > "$STATE/t1.status"
drain() { FM_ROOT_OVERRIDE="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null \
  | sed -n '/OPEN DECISIONS/,/^$/p' | sed 's/^/  drain> /'; }

echo "firstmate checkout: $ROOT"
echo "== before the answer"
drain
marker="$WORK/injected"
answer="ok, acme'; touch $marker; echo '"
chmod 0400 "$STATE/t1.status"
echo "\$ fm-send.sh t1 --resolve-key budget --resolve-key vendor \"$answer\"   (status file made read-only)"
rc=0
env PATH="$BIN:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 \
  "$ROOT/bin/fm-send.sh" t1 --resolve-key budget --resolve-key vendor "$answer" >/dev/null 2>"$WORK/err" || rc=$?
chmod 0600 "$STATE/t1.status"
echo "fm-send rc=$rc"
grep -v '^$' "$WORK/err" | sed 's/^/  stderr> /'
# The printed command legitimately spans lines (a newline inside printf's
# quoted format), so take everything after the marker, as an operator copying it would.
manual=$(cat "$WORK/err")
manual=${manual#*Close it manually with: }
manual=${manual% - do not resend the answer.}
echo "== operator runs the printed manual close command"
bash -c "$manual"; echo "manual close rc=$?"
echo "== status file after the manual close"
sed 's/^/  | /' "$STATE/t1.status"
echo "== drain after the manual close"
out=$(drain)
if [ -n "$out" ]; then printf '%s\n' "$out"; echo "RESULT: FAIL - decisions still open"; fi
if [ -e "$marker" ]; then echo "RESULT: FAIL - answer text ran as shell code"; fi
[ "$rc" -ne 0 ] || echo "RESULT: FAIL - failed close did not exit nonzero"
[ -z "$out" ] && [ ! -e "$marker" ] && [ "$rc" -ne 0 ] \
  && echo "RESULT: PASS - failed close exits nonzero, manual command closes both keys, answer text stays inert"
