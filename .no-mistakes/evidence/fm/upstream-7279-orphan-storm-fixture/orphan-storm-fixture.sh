#!/usr/bin/env bash
# Extracted orphan-storm fixture from tests/fm-procevent.test.sh, driven against
# the real bin/fm-procevent.sh of the run worktree. Arguments:
#   MODE=base|fixed      which fixture body to run (base commit vs target commit)
#   SOURCE_DELAY=<sec>   sleep injected before each launch's timestamp (default 0)
#   STAMP_MULT=<n>       timestamps written per launch (default 1; >1 fakes a storm)
set -u
WT=${WT:?}
. "$WT/tests/lib.sh"
ROOT=$WT
TMP_ROOT=$(fm_test_tmproot fm-7279-storm)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
MODE=${MODE:-fixed}; SOURCE_DELAY=${SOURCE_DELAY:-0}; STAMP_MULT=${STAMP_MULT:-1}
echo "# mode=$MODE source_delay=$SOURCE_DELAY stamp_mult=$STAMP_MULT tmp=$TMP_ROOT pid=$$"
pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
pe_register() { local home=$1 adapter=$2 id=$3; shift 3; fm_test_track_procevent_home "$home"; pe "$home" register "$adapter" "$id" "$@"; }
new_home() { mkdir -p "$1/state"; }
wait_for_lines() {
  local f=$1 want=$2 n=${3:-100} have
  for _ in $(seq 1 "$n"); do
    if [ -f "$f" ]; then have=$(wc -l < "$f" | tr -d ' '); else have=0; fi
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}
STORM_SOURCE="$TMP_ROOT/storm-source.sh"
cat > "$STORM_SOURCE" <<SH
#!/usr/bin/env bash
sleep $SOURCE_DELAY
for _ in \$(seq 1 $STAMP_MULT); do perl -MTime::HiRes=time -e 'printf "%.6f\\n", time' >> "\$1"; done
FM_HOME="\$2" perl -MPOSIX=setsid -e '
  my @command = @ARGV;
  defined(my \$pid = fork) or exit 1;
  exit 0 if \$pid;
  setsid() >= 0 or exit 1;
  open STDIN, "<", "/dev/null" or exit 1;
  open STDOUT, ">", "/dev/null" or exit 1;
  open STDERR, ">", "/dev/null" or exit 1;
  select undef, undef, undef, 0.2;
  exec @command;
' "\$3/bin/fm-procevent.sh" reconcile
exit 1
SH
chmod +x "$STORM_SOURCE"
HFLOOR="$TMP_ROOT/launch-floor"; new_home "$HFLOOR"
fm_test_track_procevent_home "$HFLOOR"
pe_register "$HFLOOR" lavish floor-src -- "$STORM_SOURCE" "$TMP_ROOT/launch-times" "$HFLOOR" "$ROOT"
T0=$SECONDS
if [ "$MODE" = base ]; then
  FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
    FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HFLOOR" reconcile >/dev/null
  floor_deadline=$((SECONDS + 30))
  while :; do
    floor_count=0
    [ ! -f "$TMP_ROOT/launch-times" ] || floor_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
    [ "$floor_count" -ge 3 ] && break
    [ "$SECONDS" -lt "$floor_deadline" ] \
      || fail "the orphan-storm fixture launched only $floor_count times within its observation window"
    sleep 0.1
  done
  launch_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  launch_span=$(perl -e '@t=<>; printf "%.3f", $t[-1] - $t[0]' "$TMP_ROOT/launch-times")
  pe "$HFLOOR" retire floor-src >/dev/null
else
  FM_PROCEVENT_OWNER_LEASE_SECONDS=600 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
    FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HFLOOR" reconcile >/dev/null
  wait_for_lines "$TMP_ROOT/launch-times" 3 600 \
    || fail "the orphan-storm fixture did not produce three launch samples"
  pe "$HFLOOR" retire floor-src >/dev/null
  launch_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  launch_span=$(perl -e '@t=<>; printf "%.3f", $t[-1] - $t[0]' "$TMP_ROOT/launch-times")
fi
echo "# launch_count=$launch_count launch_span=${launch_span}s wait=$((SECONDS - T0))s"
perl -e 'exit($ARGV[0] >= ($ARGV[1] - 1) * 0.8 ? 0 : 1)' "$launch_span" "$launch_count" \
  || fail "an orphaned source launched $launch_count times in only ${launch_span}s"
[ "$launch_count" -le 6 ] \
  || fail "an orphaned source stormed $launch_count launches during its owner-dead grace window"
# Post-retire check: no reconcile/runner for this fixture home may survive retire.
sleep 2
if lingering=$(pgrep -af -- "$HFLOOR" 2>/dev/null) && [ -n "$lingering" ]; then
  printf '# lingering after retire:\n%s\n' "$lingering"
  fail "processes for the fixture home survived retire"
fi
echo "# no processes referencing $HFLOOR after retire"
pass "an orphaned source command obeys the launch floor during its grace window"
