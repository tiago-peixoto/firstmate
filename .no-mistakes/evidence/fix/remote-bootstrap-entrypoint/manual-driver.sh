#!/usr/bin/env bash
# usage: drive.sh <rev-label> <worktree> [base-rev]
set -u
WT=$2; BASE=${3:-}
T=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-boot.XXXXXX")" && pwd -P)
R=$T/code; H=$T/home; P=$T/project-home
mkdir -p "$R/bin/backends" "$H/.local/bin" "$P"
printf 'fixture\n' > "$R/AGENTS.md"
cp "$WT"/bin/fm-remote-entrypoint.sh "$WT"/bin/fm-remote-doctor.sh "$WT"/bin/fm-backend.sh "$WT"/bin/*-lib.sh "$R/bin/"
cp "$WT/bin/backends/hc.sh" "$R/bin/backends/"
if [ -n "$BASE" ]; then
  for f in fm-remote-entrypoint.sh fm-remote-doctor.sh; do git -C "$WT" show "$BASE:bin/$f" > "$R/bin/$f"; done
fi
chmod +x "$R"/bin/*.sh
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/bin/herdr-core"; chmod +x "$R/bin/herdr-core"
git -C "$R" init -q; git -C "$R" add AGENTS.md bin
cat > "$T/env" <<'SH'
cd() { if [ "$#" -eq 1 ] && [ "$1" = "$REAL_HOME" ]; then builtin cd "$ACCT"; else builtin cd "$@"; fi; }
SH
LINK=$H/.local/bin/fm-remote-entrypoint.sh
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
boot() {
  local argv; argv=$(printf '%s\0' fm-remote-doctor.sh --backend hc "$@" | base64 | tr -d '\n')
  REAL_HOME="$(unset HOME; printf '%s' ~)" ACCT="$H" BASH_ENV="$T/env" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/jobs" \
    bash "$R/bin/fm-remote-entrypoint.sh" 1 "$(b64 "$R")" "$(b64 "$P")" "$argv" 2>&1
  echo "  exit=$?"
}
direct() {
  env -i PATH="$R/bin:/usr/bin:/bin" HOME="$H" FM_HOME="$P" FM_ROOT_OVERRIDE="$R" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/jobs" \
    "$R/bin/fm-remote-doctor.sh" --backend hc "$@" 2>&1
  echo "  exit=$?"
}
show() { grep -E 'entrypoint=|entrypoint-link|remote-job-worker=|hc-server=|exit=|error|die|invalid|remote' ; echo "  link now: $( [ -L "$LINK" ] && readlink "$LINK" || echo '<absent>')"; }
echo "=== $1 ==="
for state in conflict absent; do
  rm -f "$LINK"; [ $state = conflict ] && ln -s /operator/active-root/bin/fm-remote-entrypoint.sh "$LINK"
  for mode in check --fix; do
    echo "--- entrypoint bootstrap, link=$state, mode=$mode"
    if [ $mode = check ]; then boot | show; else boot --fix | show; fi
  done
done
if [ -z "$BASE" ]; then
  for state in conflict absent; do
    rm -f "$LINK"; [ $state = conflict ] && ln -s /operator/active-root/bin/fm-remote-entrypoint.sh "$LINK"
    for mode in check --fix; do
      echo "--- direct doctor with FM_ROOT_OVERRIDE, link=$state, mode=$mode"
      if [ $mode = check ]; then direct | show; else direct --fix | show; fi
    done
  done
fi
rm -rf "$T"
