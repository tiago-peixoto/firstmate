#!/usr/bin/env bash
# Manual live drive: scaffold a real ship brief, then run its receipt command
# and its file-tool fallback exactly as a worker would, against the real lib.
set -u
ROOT=$1
HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief-drive.XXXXXX")
trap 'rm -rf "$HOME_DIR"' EXIT
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"
lib() { FM_STATE_OVERRIDE="$HOME_DIR/state" bash -c '. "$1"; fn=$2; shift 2; "$fn" "$@"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"; }

echo "## defaults (no FM_TASK_INBOX_* in env)"
env | grep -c '^FM_TASK_INBOX_' || true
echo "grace=$(lib fm_task_inbox_grace_secs) ring_max=$(lib fm_task_inbox_ring_max) busy_max=$(lib fm_task_inbox_busy_max)"

echo; echo "## scaffold a ship brief in a disposable FM_HOME"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" ship demo-project --mode no-mistakes >/dev/null || { echo "scaffold failed"; exit 1; }
BRIEF="$HOME_DIR/data/ship/brief.md"
echo "--- inbox section as the worker sees it:"
sed -n '/^# Firstmate instruction inbox/,/^An empty or absent inbox needs no action\./p' "$BRIEF"

echo; echo "## firstmate steers the worker (real record write) and the watcher sees it unread"
REC=$(lib fm_task_inbox_write "$HOME_DIR/state" ship "please also update the changelog")
echo "record=$REC"
echo "due_action(grace=0) before any read: $(FM_TASK_INBOX_GRACE_SECS=0 lib fm_task_inbox_due_action "$HOME_DIR/state" ship)"

echo; echo "## worker runs the brief's receipt command verbatim (NNN -> 001)"
cmd=$(sed -n 's/^Immediately after reading each message, before acting, record that you read it: `\(.*\)`\.$/\1/p' "$BRIEF")
echo "command: ${cmd//NNN/001}"
bash -c "${cmd//NNN/001}"; echo "exit=$?"
ls -la "$HOME_DIR/state/ship.inbox/.read/"
echo "record still in inbox root: $([ -f "$REC" ] && echo yes || echo no)"
echo "due_action(grace=0) after read: $(FM_TASK_INBOX_GRACE_SECS=0 lib fm_task_inbox_due_action "$HOME_DIR/state" ship)"
echo "record_busy after read returns: $(lib fm_task_inbox_record_busy "$HOME_DIR/state" ship "$REC")"

echo; echo "## worker finishes: runs the brief's handled move verbatim"
mv_cmd=$(sed -n 's/^Then act on the message and acknowledge completed handling by moving it: `\(.*\)`\.$/\1/p' "$BRIEF")
echo "command: ${mv_cmd//NNN/001}"
bash -c "${mv_cmd//NNN/001}"; echo "exit=$?"
ls "$HOME_DIR/state/ship.inbox/handled/"
echo "due_action after handled: $(FM_TASK_INBOX_GRACE_SECS=0 lib fm_task_inbox_due_action "$HOME_DIR/state" ship)"

echo; echo "## second steer: worker without a shell uses the file-tool fallback path from the brief"
REC2=$(lib fm_task_inbox_write "$HOME_DIR/state" ship "second steer")
echo "record=$REC2"
echo "due_action(grace=0) before read: $(FM_TASK_INBOX_GRACE_SECS=0 lib fm_task_inbox_due_action "$HOME_DIR/state" ship)"
fb_dir=$(sed -n 's/^If the command fails or cannot run, use your file tools to create \(.*\) if needed, then create the empty receipt \(.*\) for the message you just read\.$/\1/p' "$BRIEF")
fb_file=$(sed -n 's/^If the command fails or cannot run, use your file tools to create \(.*\) if needed, then create the empty receipt \(.*\) for the message you just read\.$/\2/p' "$BRIEF")
echo "fallback dir  (literal from brief): $fb_dir"
echo "fallback file (literal from brief): ${fb_file//NNN/002}"
mkdir -p "$fb_dir" && : > "${fb_file//NNN/002}"
ls -la "$HOME_DIR/state/ship.inbox/.read/"
echo "due_action(grace=0) after file-tool receipt: $(FM_TASK_INBOX_GRACE_SECS=0 lib fm_task_inbox_due_action "$HOME_DIR/state" ship)"

echo; echo "## adversarial: a receipt for a record nobody wrote, and a bogus path"
"$ROOT/bin/fm-task-inbox-read.sh" "$HOME_DIR/state/ship.inbox/009.msg"; echo "exit(missing 009)=$?"
"$ROOT/bin/fm-task-inbox-read.sh" "$HOME_DIR/state/ship.inbox/../x.msg"; echo "exit(non-inbox dir)=$?"
"$ROOT/bin/fm-task-inbox-read.sh"; echo "exit(no args)=$?"
"$ROOT/bin/fm-task-inbox-read.sh" --help; echo "exit(--help)=$?"
ls "$HOME_DIR/state/ship.inbox/.read/"
