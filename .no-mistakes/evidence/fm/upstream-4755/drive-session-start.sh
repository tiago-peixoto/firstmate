#!/usr/bin/env bash
# Run the real fm-session-start.sh and fm-bearings-snapshot.sh in a lab home
# holding one escalated pending reply left by an earlier session.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX FM_PENDING_REPLY_SESSION; do unset "$v"; done
export FM_HOME=$LAB TMUX_TMPDIR=$LAB/tmux
STATE=$LAB/state
. "$ROOT/bin/fm-pending-reply-lib.sh"
corr=$(FM_PENDING_REPLY_SEND_HOOK=true FM_PENDING_REPLY_NOW=1000 fm_pending_reply_create "$LAB" "$STATE" mate "approve the migration plan")
rec=$(fm_pending_reply_path "$STATE" "$corr")
fm_pending_reply_set "$rec" phase escalated
fm_pending_reply_set "$rec" surfaced_session "99999:earlier-session"
printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=mate pending-reply-id=%s request=approve the migration plan\n' "$corr" "$corr" >> "$STATE/mate.status"
run_start() { timeout 120 "$ROOT/bin/fm-session-start.sh" 2>&1; }
snap() { timeout 120 "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -c '[.decisions_open[] | select(.key|startswith("pending-reply-"))]'; }

echo "== A: home WITHOUT config/pending-reply-resurface"
out=$(run_start)
echo "session-start mentions pending-reply-escalated: $(printf '%s' "$out" | grep -c 'pending-reply-escalated')"
echo "bearings pending-reply rows: $(snap)"
"$ROOT/bin/fm-lock.sh" release >/dev/null 2>&1 || true

echo "== B: home WITH config/pending-reply-resurface"
: > "$LAB/config/pending-reply-resurface"
out=$(run_start)
echo "session-start lines mentioning the reminder:"
printf '%s\n' "$out" | grep -n 'pending-reply' | sed 's/^/  /'
echo "record surfaced_session now: $(fm_pending_reply_get "$rec" surfaced_session)"
echo "bearings pending-reply rows: $(snap)"
echo "bearings human view excerpt:"
timeout 120 "$ROOT/bin/fm-bearings-snapshot.sh" 2>/dev/null | grep -n -i -B1 -A1 'pending-reply' | sed 's/^/  /'
"$ROOT/bin/fm-lock.sh" release >/dev/null 2>&1 || true
TMUX_TMPDIR=$LAB/tmux tmux -L fm-lab kill-server 2>/dev/null || true
