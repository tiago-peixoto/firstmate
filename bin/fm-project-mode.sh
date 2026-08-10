#!/usr/bin/env bash
# Resolve a project's REGISTERED delivery posture from the data/projects.md registry.
# Prints two words to stdout: "<mode> <yolo>" where mode is one of
# direct-PR|local-only and yolo is on|off.
#
# MECHANICAL CONSUMERS ONLY. This answers "what posture did the captain register
# for this project", never "how does this task ship". A task's delivery mode and
# yolo are resolved by firstmate at intake and passed explicitly to
# bin/fm-brief.sh, bin/fm-spawn.sh, and bin/fm-promote.sh (AGENTS.md section 7).
# The consumers are bin/fm-fleet-sync.sh (skip local-only clones),
# bin/fm-home-seed.sh (refuse local-only seeding), and bin/fm-spawn.sh's
# registry-deviation notice.
#
# Registry line format (data/projects.md):
#   - <name> [<mode>] - <desc> (added <date>)          -> <mode> off
#   - <name> [<mode> +yolo] - <desc> (added <date>)    -> <mode> on
#
# Registered modes:
#   direct-PR              push + PR via gh-axi
#   local-only             local branch, no remote/PR, guarded local merge
# yolo (orthogonal) = when on, firstmate may make routine approval decisions itself.
#   AGENTS.md section 7 is the single owner of authority exceptions and stronger
#   captain boundaries.
#
# --raw remains accepted for compatible callers; supported modes need no mapping,
# so its output is identical to the ordinary form.
#
# A missing registry, missing project, unannotated legacy entry, retired mode, or
# unknown mode exits non-zero and names the required explicit migration.
# It never silently reinterprets an old posture as a less rigorous mode.
# Usage: fm-project-mode.sh [--raw] <project-name>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/projects.md"
RAW=0
if [ "${1:-}" = "--raw" ]; then
  RAW=1
  shift
fi
NAME=${1:?usage: fm-project-mode.sh [--raw] <project-name>}

if [ ! -f "$REG" ]; then
  echo "error: no registry at $REG; register $NAME explicitly as direct-PR or local-only" >&2
  exit 1
fi

# awk emits "<mode> <yolo> <invalid-extra-token> <annotated>" or nothing.
parsed=$(awk -v n="$NAME" '
  $1=="-" && $2==n {
    mode=""; yolo="off"; invalid=0; annotated=0;
    if ($3 ~ /^\[/) {
      annotated=1;
      s="";
      for (i=3; i<=NF; i++) { s = s (s==""?"":" ") $i; if ($i ~ /\]$/) break }
      gsub(/^\[|\]$/, "", s);           # strip the surrounding brackets
      k = split(s, a, " ");
      mode=a[1];
      for (j=2; j<=k; j++) {
        if (a[j]=="+yolo") yolo="on";
        else invalid=1;
      }
    }
    print mode, yolo, invalid, annotated; exit
  }
' "$REG")

if [ -z "$parsed" ]; then
  echo "error: project \"$NAME\" not in registry; register it explicitly as direct-PR or local-only" >&2
  exit 1
fi

read -r mode yolo invalid annotated <<EOF
$parsed
EOF
[ "$annotated" = 1 ] || {
  echo "error: project $NAME uses a legacy registry entry with no delivery mode; set [direct-PR] or [local-only] explicitly" >&2
  exit 1
}
[ "$invalid" = 0 ] || {
  echo "error: invalid registry annotation for $NAME; use [direct-PR], [direct-PR +yolo], [local-only], or [local-only +yolo]" >&2
  exit 1
}
case "$mode" in
  direct-PR|local-only) ;;
  no-mistakes|no-mistakes-prod-only)
    echo "error: delivery mode \"$mode\" for $NAME is retired; change the registry entry explicitly to direct-PR or local-only" >&2
    exit 1 ;;
  *)
    echo "error: unknown mode \"$mode\" for $NAME; use direct-PR or local-only" >&2
    exit 1 ;;
esac
case "$yolo" in on|off) ;; *) echo "error: invalid yolo posture for $NAME" >&2; exit 1 ;; esac
echo "$mode $yolo"
