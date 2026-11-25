#!/usr/bin/env bash
# Manual drive of the real bin/fm-wake-drain.sh against a disposable state and config.
set -u
ROOT=$1; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
D="$ROOT/bin/fm-wake-drain.sh"
run() { echo "\$ fm-wake-drain.sh $* [config=$(basename "$FM_CONFIG_OVERRIDE")]"; "$D" "$@" > "$T/out" 2> "$T/err"; echo "exit=$?"; sed 's/^/  stdout| /' "$T/out"; sed 's/^/  stderr| /' "$T/err"; }
ack() { set -- $(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$1"); run --ack-through "$1" --recovery-generation "$2"; }
for gate in on off; do
  mkdir -p "$T/cfg-$gate" "$T/state-$gate"; : > "$T/cfg-$gate/supervision-host-off"
  [ $gate = on ] && : > "$T/cfg-$gate/result-replay"
  export FM_CONFIG_OVERRIDE="$T/cfg-$gate" FM_STATE_OVERRIDE="$T/state-$gate"
  echo "=== gate $gate: worker writes a done: line, main drains twice ==="
  printf 'done: shipped PR 42\n' > "$FM_STATE_OVERRIDE/task-a.status"
  run; cp "$T/err" "$T/stale-$gate.err"; run
  if [ $gate = on ]; then
    echo "=== adversarial: a newer result lands, then the OLD acknowledgement is replayed ==="
    cp "$T/err" "$T/first.err"
    ack "$T/first.err"; run
    printf 'done: second result after ack\n' >> "$FM_STATE_OVERRIDE/task-a.status"
    run; echo "--- stale ack (from the first episode) ---"; ack "$T/first.err"; run
    echo "=== matching acknowledgement, then a silent drain ==="
    cp "$T/err" "$T/cur.err"; ack "$T/cur.err"; run
  fi
done
