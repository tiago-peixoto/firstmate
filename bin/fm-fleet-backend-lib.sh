#!/usr/bin/env bash
# Fleet runtime binding, independent of runtime detection and session creation.
# read STATE prints herdr/hc, or nothing for an absent pin; errors are nonzero.
# validate STATE CONFIG BACKEND prints the accepted concrete backend, read-only.
# bind STATE CONFIG BACKEND validates and atomically claims STATE/fleet-backend.
# Only herdr/hc fleets are pinned; unrelated unbound backends keep legacy behavior.
# A managed selection must agree with FM_BACKEND, CONFIG/backend, the pin, and
# every STATE/*.meta record (including remote_backend for remote routes).
# Legacy remote routes without remote_backend mean herdr; local records without
# backend mean tmux. Explicitly empty fields and read failures are not defaults.
# No record is migrated, overwritten, or inferred from a runtime probe.
#
# Call read before detection; validate explicit choices against that result.
# Resume passes the recorded runtime, never a newly detected choice.
# Only secondmate creation binds the primary's selection; worker spawns and
# recovery never do. Pass it explicitly to each child and bind against that
# child's state/config.
# Callers retain the existing task-set lock through binding and meta publication.
# The fleet lock serializes pins; it does not replace task lifecycle locks.

_fm_fleet_backend_check() {
  local mode=$1 state=$2 requested=$4 parent
  # Unbound legacy homes must remain usable without the managed-runtime Python dependency.
  if [ -n "$state" ] && [ ! -e "$state/fleet-backend" ] && [ ! -L "$state/fleet-backend" ]; then
    parent=$state
    while [ ! -d "$parent" ] && [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
      parent=$(dirname -- "$parent")
    done
    if [ -d "$parent" ] && [ -x "$parent" ]; then
      if [ "$mode" = read ]; then return 0; fi
      case "$requested" in
        herdr|hc|''|[!a-z]*|*[!a-z0-9-]*) ;;
        *) printf '%s\n' "$requested"; return 0 ;;
      esac
    fi
  fi
  FM_BACKEND=${FM_BACKEND:-} python3 - "$@" <<'PY'
import os
import re
import stat
import sys
from pathlib import Path

mode, state_arg, config_arg, requested = sys.argv[1:]

def read(path, optional=False):
    try:
        info = path.stat()
    except FileNotFoundError:
        if optional and not path.is_symlink():
            return None
        raise ValueError(f"missing record: {path}")
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"not a regular file: {path}")
    return path.read_text()

def token(value, path):
    value = value.strip()
    if not re.fullmatch(r"[a-z][a-z0-9-]*", value):
        raise ValueError(f"invalid runtime in {path}")
    return value

def agree(actual, expected, source):
    if actual != expected:
        raise ValueError(f"{source} selects {actual}, requested {expected}; refusing runtime change")

try:
    if not state_arg:
        raise ValueError("STATE must be explicit")
    state = Path(state_arg)
    pin_path = state / "fleet-backend"
    if pin_path.is_symlink():
        raise ValueError(f"binding must not be a symlink: {pin_path}")
    pin = read(pin_path, optional=True)
    if pin is not None:
        pin = token(pin, pin_path)
        if pin not in ("herdr", "hc"):
            raise ValueError(f"invalid binding in {pin_path}: {pin}")
    if mode == "read":
        if pin:
            print(pin)
        sys.exit(0)
    requested = token(requested, "requested backend")
    if pin:
        agree(pin, requested, pin_path)
    if requested not in ("herdr", "hc"):
        print(requested)
        sys.exit(0)
    if not config_arg:
        raise ValueError("CONFIG must be explicit")
    config = Path(config_arg) / "backend"
    configured = read(config, optional=True)
    if configured is not None:
        for line in configured.split('\n'):
            value = re.sub(r"[ \t\r\v\f]", "", line)
            if value:
                agree(token(value, config), requested, config)
                break
    if "FM_BACKEND" in os.environ and os.environ["FM_BACKEND"]:
        agree(token(os.environ["FM_BACKEND"], "FM_BACKEND"), requested, "FM_BACKEND")
    try:
        names = os.listdir(state)
    except FileNotFoundError:
        if state.is_symlink():
            raise ValueError(f"missing state directory: {state}")
        names = []
    for name in sorted(names):
        if not name.endswith(".meta"):
            continue
        path = state / name
        fields = {}
        for line in read(path).splitlines():
            key, separator, value = line.partition("=")
            if separator and key in ("backend", "remote_backend", "remote_host", "window"):
                if key in fields and fields[key] != value:
                    raise ValueError(f"conflicting {key} fields in {path}")
                fields[key] = value
        remote = (fields.get("window", "").startswith("remote:")
                  or "remote_host" in fields or "remote_backend" in fields
                  or fields.get("backend") == "remote")
        if remote:
            recorded = token(fields.get("remote_backend", "herdr"), path)
        else:
            recorded = token(fields.get("backend", "tmux"), path)
        agree(recorded, requested, path)
    print(requested)
except (OSError, ValueError) as error:
    print(f"error: fleet backend: {error}", file=sys.stderr)
    sys.exit(1)
PY
}

fm_fleet_backend_read() { # <state>
  _fm_fleet_backend_check read "${1:-}" '' ''
}

fm_fleet_backend_validate() { # <state> <config> <backend>
  local config=${2:-} backend=${3:-} line selected
  case "$backend" in
    herdr|hc) ;;
    *)
      if [ -n "$config" ] && [ -f "$config/backend" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
          selected=$(printf '%s' "$line" | tr -d '[:space:]')
          [ -n "$selected" ] || continue
          case "$selected" in
            herdr|hc)
              printf 'error: fleet backend: %s/backend selects %s, requested %s; refusing runtime change\n' "$config" "$selected" "$backend" >&2
              return 1 ;;
          esac
          break
        done < "$config/backend" || return 1
      fi
      ;;
  esac
  _fm_fleet_backend_check validate "${1:-}" "${2:-}" "${3:-}"
}

fm_fleet_backend_bind() ( # <state> <config> <backend>
  local state=${1:-} config=${2:-} backend=${3:-} lock tmp=''
  fm_fleet_backend_validate "$state" "$config" "$backend" >/dev/null || return 1
  case "$backend" in
    herdr|hc) ;;
    *) printf '%s\n' "$backend"; return 0 ;;
  esac
  # Sourcing wake helpers creates STATE; isolate that side effect to this bind.
  local STATE=$state FM_STATE_OVERRIDE=$state
  export STATE FM_STATE_OVERRIDE
  if ! command -v fm_lock_acquire_wait_max >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "${BASH_SOURCE[0]%/*}/fm-wake-lib.sh" || return 1
  fi
  mkdir -p "$state" || return 1
  lock="$state/.fleet-backend.lock"
  fm_lock_acquire_wait_max "$lock" 10 || {
    echo "error: fleet backend: cannot acquire $lock" >&2
    return 1
  }
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"; fm_lock_release "$lock"' EXIT
  fm_fleet_backend_validate "$state" "$config" "$backend" >/dev/null || return 1
  if [ ! -e "$state/fleet-backend" ]; then
    tmp=$(umask 077; mktemp "$state/.fleet-backend.XXXXXX") || return 1
    printf '%s\n' "$backend" > "$tmp" || return 1
    # link publishes the complete file and refuses every existing destination.
    python3 - "$tmp" "$state/fleet-backend" <<'PY' || return 1
import os
import sys
try:
    os.link(sys.argv[1], sys.argv[2])
except OSError as error:
    print(f"error: fleet backend: cannot publish binding: {error}", file=sys.stderr)
    sys.exit(1)
PY
  fi
  printf '%s\n' "$backend"
)
