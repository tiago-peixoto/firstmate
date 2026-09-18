#!/usr/bin/env bash
# fm-send --automatic to a REMOTE secondmate waiting on its own decision: the
# deferral must happen before any transport. ssh is replaced by a logger that
# records any attempt (no remote host is reachable from this machine).
set -u
ROOT=${ROOT:?}
W=$(mktemp -d /tmp/fm4228-rsend.XXXXXX); W=$(cd "$W" && pwd -P)
export FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0
mkdir -p "$W/fakebin" "$W/home/state" "$W/home/data"; chmod 755 "$W/home/state"
printf '#!/usr/bin/env bash\nprintf "ssh %%s\\n" "$*" >> "%s/ssh.log"\nexit 255\n' "$W" > "$W/fakebin/ssh"; chmod +x "$W/fakebin/ssh"; : > "$W/ssh.log"
printf '%s\n' window=fm-remote:p1 endpoint_task_id=rsm harness=claude kind=secondmate mode=secondmate yolo=off \
  remote_host=remote-mac remote_root=/remote/root remote_backend=herdr remote_herdr_session=fm-remote remote_target=fm-remote:p1 > "$W/home/state/rsm.meta"
printf -- '- rsm - remote test domain (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-08-02)\n' > "$W/home/data/secondmates.md"
printf 'needs-decision [key=pick]: alpha or beta?\n' > "$W/home/state/rsm.status"
echo "== remote secondmate rsm (remote_host=remote-mac) waits on its own decision"
echo "\$ fm-send.sh fm-rsm --automatic 'please re-read your AGENTS.md'"
PATH="$W/fakebin:$PATH" FM_HOME="$W/home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-send.sh" fm-rsm --automatic 'please re-read your AGENTS.md' 2>&1 \
  | grep -v -e '^●' -e '^WARNING: watcher' -e '^$' | sed 's/^/  | /'; echo "  exit=${PIPESTATUS[0]}"
echo "  ssh transport attempts: $(wc -l < "$W/ssh.log" | tr -d ' ')"
echo "  pending-reply records: $(ls "$W/home/state"/.pending-reply* "$W/home/state/pending-reply" 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$W"
