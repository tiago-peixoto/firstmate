L="$TMPDIR/fm4574-live"; H="$L/firstmate"; P="$L/proj"
T() { tmux -L fm4574 "$@"; }
# fm <label> <script> <args...>: run a Firstmate command from the firstmate pane and wait for it
fm() {
  local label=$1 q=""; shift
  rm -f "$L/out/$label.rc" "$L/out/$label.log"
  printf -v q '%q ' "$L/run.sh" "$label" "$@"
  T send-keys -t firstmate:firstmate -l "$q"; T send-keys -t firstmate:firstmate Enter
  for _ in $(seq 1 300); do [ -f "$L/out/$label.rc" ] && break; sleep 0.5; done
  echo "rc=$(cat "$L/out/$label.rc" 2>/dev/null || echo TIMEOUT)"; cat "$L/out/$label.log"
}
brief() { mkdir -p "$H/data/$1"; printf '# Task\n## Captain'"'"'s intent\nLive check for issue 4574.\n\n## Firstmate spec\nExercise the account selection.\n' > "$H/data/$1/brief.md"; }
slot() { echo "$L/wt/slot-$1" > "$L/next-wt"; }
windows() { T list-windows -a -F '#{session_name}:#{window_name}'; }
