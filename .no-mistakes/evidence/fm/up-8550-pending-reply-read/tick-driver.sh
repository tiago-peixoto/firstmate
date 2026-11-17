# usage: driver.sh <repo-root> <home> <setup|ticks> [n]
set -u
ROOT=$1 home=$2 mode=$3 n=${4:-20}
[ "$mode" != setup ] || . "$ROOT/tests/lib.sh"
. "$ROOT/bin/fm-marker-lib.sh"
. "$ROOT/bin/fm-pending-reply-lib.sh"
export FM_PENDING_REPLY_NOW=5500 FM_HOME=$home FM_ROOT_OVERRIDE=$home FM_STATE_OVERRIDE=$home/state
state=$home/state
fm_backend_busy_state() { printf 'busy\n'; }
if [ "$mode" = setup ]; then
  mkdir -p "$state" "$home/mate/state"
  printf 'hibit\n' > "$home/mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$home/mate/.fm-secondmate-parent"
  fm_write_secondmate_meta "$state/hibit.meta" "$home/mate" "sess:fm-hibit" || exit 1
  : > "$state/hibit.status"
  i=0
  for kind in open open done done done; do
    i=$((i+1))
    corr=$(fm_pending_reply_create "$home" "$state" hibit "request number $i with a=b and café")
    fm_pending_reply_mark_delivered "$state" "$corr" || exit 1
    [ "$kind" = open ] || printf 'done [corr=%s]: finished %s\n' "$corr" "$i" >> "$state/hibit.status"
  done
  exit 0
fi
i=0; while [ $i -lt "$n" ]; do fm_pending_reply_tick "$state" || exit 1; i=$((i+1)); done
