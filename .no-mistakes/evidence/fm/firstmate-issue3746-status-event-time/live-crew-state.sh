#!/usr/bin/env bash
# Live: current-state reconciliation (fm-crew-state.sh, the surface PR 3753 owns)
# reads a stamped event exactly as it reads the unstamped twin; time never
# decides current state.
. "$(dirname "$0")/live-common.sh"
trap cleanup_tmux EXIT
H=$(make_home crew)
S="$H/state"
mkdir -p "$H/projects/wt"
tmux new-session -d -s firstmate -n fm-t1 'cat'
write_meta "$S/t1.meta" "window=firstmate:fm-t1" "worktree=$H/projects/wt" "project=alpha" \
  "harness=claude" "kind=ship" "mode=direct-PR"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$S" t1)
"$ROOT/bin/fm-busy-event.sh" apply "$S" t1 idle --gen "$gen" --source claude-hook --event stop
cs() { FM_HOME="$H" FM_STATE_OVERRIDE="$S" "$ROOT/bin/fm-crew-state.sh" t1 2>/dev/null; }
now=$(date +%s); old=$((now - 7200))
say "G. Idle crew: crew-state for unstamped vs stamped (fresh and 2h-old) last events"
for pair in 'done: PR ready' 'needs-decision [key=k] : pick A or B' 'blocked: need creds' 'failed: build broke' 'working: still going'; do
  verb=${pair%%:*}; verb=${verb%% *}; rest=${pair#"$verb"}
  head=${rest%%:*}; note=${rest#*:}
  for variant in legacy fresh old; do
    case $variant in
      legacy) line="$verb$head:$note" ;;
      fresh) line="$verb$head [at=$now]:$note" ;;
      old) line="$verb$head [at=$old]:$note" ;;
    esac
    line=${line//  / }
    printf '%s\n' "$line" > "$S/t1.status"
    r=$(cs); printf '%-44s -> %s\n' "'$line'" "$r"
    eval "out_$variant=\$(printf '%s' \"\$r\" | cut -d'·' -f1-2)"
  done
  check "same state/source for '$pair' legacy vs stamped fresh vs stamped 2h-old" \
    [ "$out_legacy" = "$out_fresh" -a "$out_fresh" = "$out_old" ]
done
printf '\nFAILS=%s\n' "$FAILS"
