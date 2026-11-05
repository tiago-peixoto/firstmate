#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# The verb says the request was answered, not that the work behind it is
# finished. --task <child> names the child task the request concerns: the helper
# reads that child's current state through bin/fm-crew-state.sh in this home and
# appends it to the line as "child=<id> child-state=<verdict>", which the parent
# records beside the request outcome (bin/fm-pending-reply-lib.sh). Without
# --task, or when the child cannot be read, the verdict is unknown.
#
# --doc offers reviewed, non-secret Markdown/text from this home's data/.
# bin/fm-document-snapshot.sh owns capture, safety checks, and the 1 MiB bound.
# It freezes the bytes in data/report-snapshots/<sha256>.md and retains the
# source host, home, and supplied path in the correlated report. Local delivery
# verifies the parent's copy before appending. Remote delivery queues a required
# snapshot offer: bin/fm-procevent-remote-reply.sh copies and verifies it, and
# escalates on the parent only a snapshot it refuses or cannot verify, so
# queuing is not a receipt from the parent.
# That adapter uses the existing remote-file transport, including documents
# above its ordinary 256 KiB report limit, up to the snapshot safety bound.
# Never pass a credential file or a document not reviewed for secret content.
#
# Usage:
#   fm-secondmate-report.sh [--task <child>] <verb> <corr_id> <note...>
#   fm-secondmate-report.sh [--task <child>] --doc <verb> <corr_id> <doc-path> <note...>
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --task repack-panels done abcdef0123456789 "spinner fix verified"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh [--task <child>] <verb> <corr_id> <note...>
  fm-secondmate-report.sh [--task <child>] --doc <verb> <corr_id> <doc-path> <note...>

--doc captures a reviewed non-secret .md/.txt document under this home's data/.
A local parent verifies its copy before the answer is written. Remote success
queues the offer, not a receipt: that parent verifies its copy or escalates.
The maximum is 1048576 bytes.
EOF
  exit 2
}

DOC_MODE=0
CHILD=
while [ $# -gt 0 ]; do
  case "$1" in
    --doc) DOC_MODE=1; shift ;;
    --task)
      [ $# -ge 2 ] && [ -n "$2" ] || usage
      CHILD=$2
      shift 2
      ;;
    *) break ;;
  esac
done

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

DOCUMENT_MARKER=
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  SNAPSHOT=$(FM_HOME="$HOME_DIR" "$SCRIPT_DIR/fm-document-snapshot.sh" capture "$DOC_PATH")
  DIGEST=${SNAPSHOT##*/}
  DIGEST=${DIGEST%.md}
  BYTES=$(wc -c < "$HOME_DIR/$SNAPSHOT" | tr -d ' ')
  fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR" >/dev/null
  if [ "$FM_PARENT_CHANNEL_ROUTE" = local ]; then
    FM_HOME="$FM_SECONDMATE_PARENT_HOME" "$SCRIPT_DIR/fm-document-snapshot.sh" receive "$DIGEST" "$BYTES" \
      < "$HOME_DIR/$SNAPSHOT" >/dev/null
  fi
  printf -v DOCUMENT_MARKER 'report=%s source-host=%q source-home=%q source-document=%q' \
    "$SNAPSHOT" "$(hostname)" "$HOME_DIR" "$DOC_PATH"
fi

# The child's state is read last, immediately before the line is written.
CHILD_STATE=unknown
if [ -n "$CHILD" ]; then
  CHILD_RAW=$(FM_HOME="$HOME_DIR" fm_run_timed 30 "$SCRIPT_DIR/fm-crew-state.sh" "$CHILD" 2>/dev/null | head -1) || true
  case "$CHILD_RAW" in
    'state: '*) CHILD_STATE=${CHILD_RAW#state: }; CHILD_STATE=${CHILD_STATE%% *} ;;
  esac
fi
CHILD_MARKER=$(fm_pending_reply_child_marker "$CHILD" "$CHILD_STATE")

if [ "$DOC_MODE" = 1 ]; then
  BODY="${*:+$* }($DOCUMENT_MARKER via-helper $CHILD_MARKER)"
else
  BODY="$* (via-helper $CHILD_MARKER)"
fi
"$SCRIPT_DIR/fm-status-write.sh" "$DESTINATION" "$VERB" --corr "$CORR" -- "$BODY"
