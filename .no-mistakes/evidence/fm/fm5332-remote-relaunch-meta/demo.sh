#!/usr/bin/env bash
# Operator transcript: remote secondmate relaunch vs the parent's own record.
# Usage: demo.sh <firstmate-root>
# The SSH boundary is a stub that answers like a host whose relaunch succeeded
# (it resolves "default" to claude/claude-opus-5-5/high), or refuses.
set -u
ROOT=$1
T=$(mktemp -d); H=$T/home; mkdir -p $H/data $H/state $H/config $T/bin
printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' > $H/data/secondmates.md
seed() {
cat > $H/state/ios.meta <<M
window=remote:ios
endpoint_task_id=ios
worktree=/srv/fm-home
project=/srv/fm
harness=pi
kind=secondmate
mode=secondmate
yolo=off
model=openai-codex/gpt-5.6-sol
effort=medium
home=/srv/fm-home
remote_host=remote-mac
remote_root=/srv/fm
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
M
chmod 600 $H/state/ios.meta
}
cat > $T/bin/ssh <<'S'
#!/usr/bin/env bash
[ "${MODE:-}" = refuse ] && { echo 'error: unverified remote secondmate harness: notaharness' >&2; exit 1; }
echo 'relaunched ios harness=claude from=pi model=default effort=default backend=herdr endpoint=fm-remote:w1:p2 worktree=/srv/fm-home'
printf 'schema=fm-remote-secondmate-control.v1\nbackend=herdr\ntarget=fm-remote:w1:p2\nherdr_session=fm-remote\nharness=claude\nmodel=claude-opus-5-5\neffort=high\n'
S
chmod +x $T/bin/ssh
printf '#!/usr/bin/env bash\nexit 1\n' > $T/bin/gh; chmod +x $T/bin/gh
export FM_HOME=$H FM_SSH_BIN=$T/bin/ssh
show() { echo "--- parent state/ios.meta (harness/model/effort/pr lines):"; grep -E '^(harness|model|effort|pr|pr_head)=' $H/state/ios.meta; echo "--- last key in record: $(tail -1 $H/state/ios.meta | cut -d= -f1)"; }
echo "=== checkout: $(git -C $ROOT rev-parse --short HEAD)"
seed; show
echo; echo "=== operator arms a PR poll (fm-pr-check.sh), then relaunches onto claude default default"
PATH=$T/bin:$PATH FM_GUARD_GRACE=999999 $ROOT/bin/fm-pr-check.sh ios https://github.com/example/repo/pull/1 >/dev/null 2>&1; show
if [ -x $ROOT/bin/fm-remote-secondmate-relaunch.sh ]; then
  echo '$ bin/fm-remote-secondmate-relaunch.sh ios claude default default'
  $ROOT/bin/fm-remote-secondmate-relaunch.sh ios claude default default; echo "rc=$?"
else
  echo '$ bin/fm-on.sh ios fm-remote-secondmate-control.sh relaunch ios claude default default   (documented path at base)'
  $ROOT/bin/fm-on.sh ios fm-remote-secondmate-control.sh relaunch ios claude default default; echo "rc=$?"
fi
show
( . $ROOT/bin/fm-pr-lib.sh; fm_pr_poll_artifacts_valid $H/state ios $ROOT/bin/fm-pr-poll.sh && echo "PR poll artifacts: VALID" || echo "PR poll artifacts: INVALID" )
if [ -x $ROOT/bin/fm-remote-secondmate-relaunch.sh ]; then
  echo; echo "=== refused relaunch leaves record byte-identical"
  cp $H/state/ios.meta $T/before
  MODE=refuse $ROOT/bin/fm-remote-secondmate-relaunch.sh ios notaharness - -; echo "rc=$?"
  cmp $T/before $H/state/ios.meta && echo "record unchanged: yes"
  echo; echo "=== local mate refused"
  printf 'window=firstmate:fm-l\nendpoint_task_id=l\nharness=codex\nkind=secondmate\n' > $H/state/l.meta
  $ROOT/bin/fm-remote-secondmate-relaunch.sh l claude - -; echo "rc=$?"
fi
rm -rf $T
