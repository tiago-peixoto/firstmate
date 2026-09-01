#!/usr/bin/env bash
# Static watcher program for one validated PR/MR monitor. GitHub observations
# cover reviews, conversation comments, review-thread comments, and merge;
# GitLab observations retain the existing merge coverage. Machine observations
# are consumed by bin/fm-watch.sh, while direct execution stays silent unless
# the PR/MR is merged or the forge cannot be read.
set -u
LC_ALL=C
export LC_ALL

mode=direct
prior_updated=
if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  mode=validated
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  prior_updated=$7
elif [ "$#" -eq 6 ] && [ "$1" = --snapshot ]; then
  mode=${1#--}
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

emit_observation() {
  if [ "$mode" = direct ]; then
    case "$1" in
      merged) printf '%s\n' merged ;;
      unavailable\ *) printf '%s\n' 'PR monitor unavailable' ;;
    esac
  else
    printf '%s\n' "$1"
  fi
}

numeric_max() {
  local raw=$1 value normalized max=0
  while IFS= read -r value || [ -n "$value" ]; do
    [ -n "$value" ] || continue
    case "$value" in *[!0-9]*) return 1 ;; esac
    normalized=$value
    while [ "${#normalized}" -gt 1 ] && [ "${normalized#0}" != "$normalized" ]; do
      normalized=${normalized#0}
    done
    if [ "${#normalized}" -gt "${#max}" ] \
      || { [ "${#normalized}" -eq "${#max}" ] && [ "$normalized" -gt "$max" ]; }; then
      max=$normalized
    fi
  done <<EOF
$raw
EOF
  printf '%s\n' "$max"
}

github_ids() {
  local endpoint=$1 raw
  raw=$(gh api --paginate "$endpoint" --jq '.[].id' 2>/dev/null) || return 1
  numeric_max "$raw"
}

case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0

    summary=$(gh api "/repos/$path/pulls/$number" \
      --jq '[if .merged_at != null then "merged" else .state end, ((.requested_reviewers | length) + (.requested_teams | length)), .updated_at] | @tsv' \
      2>/dev/null) || { emit_observation 'unavailable github'; exit 0; }
    IFS=$(printf '\t') read -r state requested updated extra <<EOF
$summary
EOF
    [ -z "${extra:-}" ] || { emit_observation 'unavailable github'; exit 0; }
    case "$requested" in ''|*[!0-9]*) emit_observation 'unavailable github'; exit 0 ;; esac
    [[ "$updated" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || { emit_observation 'unavailable github'; exit 0; }
    case "$state" in
      merged) emit_observation merged; exit 0 ;;
      open|closed) ;;
      *) emit_observation 'unavailable github'; exit 0 ;;
    esac
    if [ "$mode" = validated ] && [ "$updated" = "$prior_updated" ]; then
      emit_observation "unchanged $updated $requested"
      exit 0
    fi

    reviews=$(github_ids "/repos/$path/pulls/$number/reviews?per_page=100") \
      || { emit_observation 'unavailable github'; exit 0; }
    issue_comments=$(github_ids "/repos/$path/issues/$number/comments?per_page=100") \
      || { emit_observation 'unavailable github'; exit 0; }
    review_comments=$(github_ids "/repos/$path/pulls/$number/comments?per_page=100") \
      || { emit_observation 'unavailable github'; exit 0; }
    emit_observation "observed $updated $reviews $issue_comments $review_comments $requested"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) \
      || { emit_observation 'unavailable gitlab'; exit 0; }
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    case "$state" in
      merged) emit_observation merged ;;
      opened|closed)
        if [ "$mode" = validated ] && [ "$prior_updated" = - ]; then
          emit_observation 'unchanged - 0'
        else
          emit_observation 'observed - 0 0 0 0'
        fi
        ;;
      *) emit_observation 'unavailable gitlab' ;;
    esac
    ;;
esac
exit 0
