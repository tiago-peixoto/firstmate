#!/usr/bin/env bash
# Wake this home once for each new actionable condition on a PR it owns.
#
# Usage:
#   fm-pr-health.sh poll
#   fm-pr-health.sh owned <pr-url>
#   fm-pr-health.sh arm
#
# Opt-in: with config/pr-health-monitor absent, poll exits silently without
# reading or writing anything, and arm and owned refuse (docs/configuration.md).
#
# Ownership is fm-contributions.sh owned. poll adds two sources and records
# each new URL through fm-contributions.sh enroll, so ownership outlives the
# worker: a github.com PR URL in a live task's status lines, and the open PR
# whose head is a live task copy's current branch (fm_pr_number_from_branch).
# Drafts and adopted branches count. A secondmate row never enrolls a PR,
# because the PR belongs to the secondmate's own home. No PR outside that set
# is ever read, so another home's PR is dropped without a forge read or a wake.
#
# Per owned open PR, poll reads the REST single-PR endpoint, which GitHub
# documents as starting the mergeability computation, and one GraphQL read for
# the base branch's current commit, review requests, latest reviews, and the
# head's check rollup with each context's isRequired. REST base.sha is not used:
# GitHub leaves it at an old base commit while the base branch moves.
# It prints one line per new condition, all in one check output, so one wake:
#   - conflict: REST mergeable is false. Wakes once per latest commit and base
#     commit; mergeable true clears it, and null (UNKNOWN) changes nothing.
#   - failing checks: a required context failed (a check run concluded other
#     than SUCCESS, NEUTRAL or SKIPPED, or a status is FAILURE or ERROR); when
#     no context is required, any failed context counts. Each name is judged
#     by its newest run (latest_checks in fm-contributions.jq), because GitHub
#     keeps a cancelled run in the rollup beside the passing rerun that replaced
#     it. Wakes once per latest commit and base commit; a pass with none
#     failing clears it, so a rerun that fails again wakes again.
#   - no reviewer: out of draft, every context counted above read and passing,
#     no user or team review requested, and no review by a user. Wakes once
#     per latest commit, because a base move alone changes nothing for it.
# A merged or closed PR is final and never read again. A failed or timed-out
# read, or a latest commit that differs between the two reads, leaves the PR's
# fingerprint untouched and prints nothing; fm-contributions.sh reports forge
# outages for the same URLs. Forge reads stop FM_CHECK_TIMEOUT (default 30)
# minus 5 seconds after the pass starts, each read is capped at 5 seconds, and
# PRs are rotated by the five-minute epoch bucket so a long list does not
# starve its tail.
# Fingerprints are fm-pr-health.v1 in state/pr-health.json, written by rename
# under state/.pr-health.lock; a pass that finds the lock held exits silently.
# A line is printed before its fingerprint is saved, so a pass killed between
# the two repeats one wake rather than losing it. An unreadable fingerprint
# file is reported once and replaced.
#
# owned is read-only and never contacts a forge. It prints "owned: <url>" and
# exits 0 when the flag is present, the monitor check is registered, and the
# URL is owned or named in a live task's status lines; otherwise it prints
# "not owned: <url>" and exits 1.
#
# arm writes state/pr-health.check.sh, binds it through fm-check-register.sh,
# and arms the contribution observer that reads the PRs poll enrolls.
# The monitor never comments on, edits, or fixes a PR.
# GraphQL, jq and bash -c programs below are literal, not shell expressions.
# shellcheck disable=SC2016
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-pr-health: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

PR_URL_RE='https://github\.com/[A-Za-z0-9-]+/[A-Za-z0-9._-]+/pull/[1-9][0-9]*'
HEALTH="$STATE/pr-health.json"
LOCK_HELD=0
TMP=
cleanup() {
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$STATE/.pr-health.lock" || true
  [ -z "$TMP" ] || rm -rf -- "$TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

flag_on() { [ -e "$CONFIG/pr-health-monitor" ]; }

meta_value() { sed -n "s/^$2=//p" "$1" | tail -n 1; }

live_tasks() { # id <TAB> worktree, for each task that is not a secondmate
  local meta id
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_pr_task_id_valid "$id" || continue
    [ "$(meta_value "$meta" kind)" != secondmate ] || continue
    printf '%s\t%s\n' "$id" "$(meta_value "$meta" worktree)"
  done
}

status_urls() { # id <TAB> url, for each PR URL in a live task's status lines
  local id wt url
  while IFS=$'\t' read -r id wt; do
    [ -f "$STATE/$id.status" ] || continue
    grep -oE "$PR_URL_RE" "$STATE/$id.status" 2>/dev/null | sort -u | while IFS= read -r url; do
      printf '%s\t%s\n' "$id" "$url"
    done
  done < <(live_tasks)
}

owned_json() { # -> $TMP/owned.json
  "$SCRIPT_DIR/fm-contributions.sh" owned > "$TMP/owned.json" 2> "$TMP/owned.err"
}

save_health() { # json-file
  local staged
  staged=$(umask 077; mktemp "$STATE/.pr-health.XXXXXX")
  cp "$1" "$staged"
  fm_pr_regular_destination_on_device_or_absent "$HEALTH" "$(fm_pr_file_device "$STATE")" \
    || { rm -f -- "$staged"; fail 'unsafe fingerprint destination'; }
  mv -f -- "$staged" "$HEALTH"
}

gh_read() { # deadline args... : one bounded forge read
  local left=$(($1 - $(date +%s)))
  shift
  [ "$left" -gt 0 ] || return 124
  [ "$left" -le 5 ] || left=5
  fm_run_timed "$left" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

PR_QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){
headRefOid isDraft baseRef{target{oid}}
reviewRequests(first:50){nodes{requestedReviewer{__typename}}}
latestReviews(first:50){nodes{author{__typename}}}
statusCheckRollup{contexts(first:100){pageInfo{hasNextPage} nodes{__typename
... on CheckRun{name status conclusion startedAt isRequired(pullRequestNumber:$number)}
... on StatusContext{context state createdAt isRequired(pullRequestNumber:$number)}}}}}}}'

# The fingerprint step: previous fingerprint plus one REST and one GraphQL
# read -> {fp, lines}. A null result means the reads disagree and nothing moves.
STEP='
  $rest[0] as $r | ($gql[0].data.repository.pullRequest // null) as $g
  | ($prev[0] // {}) as $p
  | if $r.merged_at != null or $r.state == "closed" then {fp:($p + {final:true}),lines:[]}
    elif $g == null or $g.headRefOid != $r.head.sha or ($g.baseRef.target.oid // null) == null then null
    else
      $r.head.sha as $head | ($head + ":" + $g.baseRef.target.oid) as $at
      | ($tasks | join(", ")) as $owners
      | ($g.statusCheckRollup // null) as $roll
      | [$roll.contexts.nodes[]? | if .__typename == "CheckRun"
          then {name, started_at:.startedAt, required:(.isRequired == true),
                ok:(.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED")),
                failing:(.status == "COMPLETED" and .conclusion != null and (.conclusion | IN("SUCCESS","NEUTRAL","SKIPPED") | not))}
          else {name:.context, started_at:.createdAt, required:(.isRequired == true),
                ok:(.state == "SUCCESS"), failing:(.state | IN("FAILURE","ERROR"))} end]
        | latest_checks as $ctx
      | any($ctx[]; .required) as $has_required
      | [$ctx[] | select(.required or ($has_required | not))] as $relevant
      | ([$relevant[] | select(.failing) | .name] | unique) as $failing
      | (($relevant | length) > 0 and all($relevant[]; .ok) and ($roll.contexts.pageInfo.hasNextPage | not)) as $green
      | ($r.draft != true and $green
         and ([$g.reviewRequests.nodes[]? | select(.requestedReviewer.__typename | IN("User","Team"))] | length) == 0
         and ([$g.latestReviews.nodes[]? | select(.author.__typename == "User")] | length) == 0) as $unreviewed
      | (if $r.mergeable == false then $at elif $r.mergeable == true then null else $p.conflict end) as $conflict
      | (if ($failing | length) > 0 then $at else null end) as $checks
      | (if $unreviewed then $head else $p.reviewer end) as $reviewer
      | ("at latest commit " + $head[:7]) as $where
      | {fp:{conflict:$conflict,checks:$checks,reviewer:$reviewer},
         lines:([
           (select($conflict != null and $conflict != $p.conflict)
            | "pr-health: \($url) conflicts with its base \($where) (task \($owners))"),
           (select($checks != null and $checks != $p.checks)
            | "pr-health: \($url) has failing \(if $has_required then "required " else "" end)checks \($where): \($failing[:3] | join(", "))\(if ($failing | length) > 3 then " and \(($failing | length) - 3) more" else "" end) (task \($owners))"),
           (select($unreviewed and $reviewer != $p.reviewer)
            | "pr-health: \($url) is green and out of draft with no reviewer requested \($where) (task \($owners))")])}
    end'

read_pr() { # url deadline -> $TMP/rest.json $TMP/gql.json
  local url=$1 deadline=$2 part number owner repo rest_rc=0 gql_rc=0
  part=${url#https://github.com/}; number=${part##*/}; part=${part%/pull/*}
  owner=${part%%/*}; repo=${part#*/}
  gh_read "$deadline" api "repos/$owner/$repo/pulls/$number" > "$TMP/rest.json" 2>/dev/null &
  local rest_pid=$!
  gh_read "$deadline" api graphql -F "owner=$owner" -F "repo=$repo" -F "number=$number" \
    -f "query=$PR_QUERY" > "$TMP/gql.json" 2>/dev/null &
  local gql_pid=$!
  wait "$rest_pid" || rest_rc=$?
  wait "$gql_pid" || gql_rc=$?
  [ "$rest_rc" -eq 0 ] && [ "$gql_rc" -eq 0 ]
}

lookup_branch_pr() { # worktree branch deadline -> url
  local wt=$1 branch=$2 deadline=$3 left number url
  left=$((deadline - $(date +%s)))
  [ "$left" -gt 0 ] || return 1
  [ "$left" -le 5 ] || left=5
  number=$(fm_run_timed "$left" bash -c '. "$1/fm-pr-lib.sh"; fm_pr_number_from_branch "$2" "$3" open' \
    _ "$SCRIPT_DIR" "$wt" "$branch") || return 1
  url=$(cd "$wt" && gh_read "$deadline" pr view "$number" --json url -q .url 2>/dev/null) || return 1
  printf '%s\n' "$url" | grep -Ex "$PR_URL_RE"
}

enroll_new() { # deadline : enroll status and branch PRs not yet owned
  local deadline=$1 id wt url branch default cached
  : > "$TMP/enroll.tsv"
  status_urls >> "$TMP/enroll.tsv"
  while IFS=$'\t' read -r id wt; do
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || continue
    default=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [ "$branch" != "${default#origin/}" ] || continue
    [ "$branch" != "$(meta_value "$STATE/$id.meta" base_branch)" ] || continue
    cached=$(jq -r --arg id "$id" --arg branch "$branch" '.branches[$id] | select(.branch == $branch) | .url' "$TMP/health.json")
    if [ -n "$cached" ]; then
      printf '%s\t%s\n' "$id" "$cached" >> "$TMP/enroll.tsv"
      continue
    fi
    url=$(lookup_branch_pr "$wt" "$branch" "$deadline") || continue
    jq --arg id "$id" --arg branch "$branch" --arg url "$url" '.branches[$id] = {branch:$branch,url:$url}' \
      "$TMP/health.json" > "$TMP/next.json" && mv "$TMP/next.json" "$TMP/health.json"
    printf '%s\t%s\n' "$id" "$url" >> "$TMP/enroll.tsv"
  done < <(live_tasks)
  while IFS=$'\t' read -r id url; do
    jq -e --arg id "$id" --arg url "$url" 'any(.[]; .url == $url and (.tasks | index($id)) != null)' "$TMP/owned.json" >/dev/null \
      && continue
    "$SCRIPT_DIR/fm-contributions.sh" enroll "$id" "$url" >/dev/null 2>&1 || continue
    jq --arg id "$id" --arg url "$url" '
      if any(.[]; .url == $url) then map(if .url == $url then .tasks = (.tasks + [$id] | unique) else . end)
      else . + [{url:$url,tasks:[$id],final:false}] end' "$TMP/owned.json" > "$TMP/next.json" \
      && mv "$TMP/next.json" "$TMP/owned.json"
  done < <(sort -u "$TMP/enroll.tsv")
}

poll() {
  local deadline timeout url step
  flag_on || exit 0
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  timeout=${FM_CHECK_TIMEOUT:-30}
  case "$timeout" in ''|*[!0-9]*) timeout=30 ;; esac
  deadline=$(( $(date +%s) + (timeout > 10 ? timeout - 5 : 5) ))
  FM_WAKE_QUEUE="$STATE/.wake-queue"
  FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.pr-health.lock" || exit 0
  LOCK_HELD=1
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-health.XXXXXX")
  if [ -e "$HEALTH" ] && ! jq -e '.schema == "fm-pr-health.v1" and (.prs | type == "object") and (.branches | type == "object")' \
    "$HEALTH" > /dev/null 2>&1; then
    printf 'pr-health: unreadable fingerprint record replaced; conditions already reported may wake once more\n'
    rm -f -- "$HEALTH"
  fi
  if [ -e "$HEALTH" ]; then cp "$HEALTH" "$TMP/health.json"
  else printf '{"schema":"fm-pr-health.v1","prs":{},"branches":{},"ownership_error":false}\n' > "$TMP/health.json"; fi
  if ! owned_json; then
    if ! jq -e '.ownership_error == true' "$TMP/health.json" >/dev/null; then
      printf 'pr-health: owned PRs could not be read: %s\n' "$(head -n 1 "$TMP/owned.err" | cut -c1-160)"
      jq '.ownership_error = true' "$TMP/health.json" > "$TMP/next.json" && save_health "$TMP/next.json"
    fi
    exit 0
  fi
  enroll_new "$deadline"
  # Keep fingerprints and branch lookups only for what this home still owns.
  jq --slurpfile owned "$TMP/owned.json" --arg live "$(live_tasks | cut -f1 | paste -sd ' ' -)" '
    ($owned[0] | map(.url)) as $urls | ($live | split(" ")) as $ids
    | .ownership_error = false
    | .prs |= with_entries(select(.key | IN($urls[])))
    | .branches |= with_entries(select(.key | IN($ids[])))' "$TMP/health.json" > "$TMP/next.json"
  save_health "$TMP/next.json"
  cp "$TMP/next.json" "$TMP/health.json"
  jq -r --slurpfile health "$TMP/health.json" --argjson bucket "$(( $(date +%s) / 300 ))" '
    [.[] | select(.final | not) | select(($health[0].prs[.url].final // false) | not) | .url] | sort
    | if length == 0 then . else ($bucket % length) as $o | .[$o:] + .[:$o] end | .[]' "$TMP/owned.json" > "$TMP/urls"
  while IFS= read -r url; do
    [ $((deadline - $(date +%s))) -ge 2 ] || break
    read_pr "$url" "$deadline" || continue
    jq -L "$SCRIPT_DIR" -n --arg url "$url" --slurpfile rest "$TMP/rest.json" --slurpfile gql "$TMP/gql.json" \
      --slurpfile prev <(jq --arg url "$url" '.prs[$url] // {}' "$TMP/health.json") \
      --argjson tasks "$(jq -c --arg url "$url" '[.[] | select(.url == $url) | .tasks[]] | unique' "$TMP/owned.json")" \
      "include \"fm-contributions\"; $STEP" > "$TMP/step.json" 2>/dev/null || continue
    step=$(cat "$TMP/step.json")
    [ "$step" != null ] || continue
    jq -r '.lines[]' "$TMP/step.json"
    jq --arg url "$url" --slurpfile step "$TMP/step.json" '.prs[$url] = $step[0].fp' "$TMP/health.json" > "$TMP/next.json"
    if ! cmp -s "$TMP/next.json" "$TMP/health.json"; then
      save_health "$TMP/next.json"
      cp "$TMP/next.json" "$TMP/health.json"
    fi
  done < "$TMP/urls"
}

owned() {
  local url=$1
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-health.XXXXXX")
  if flag_on && fm_custom_check_registered "$STATE" pr-health \
    && { status_urls | cut -f2 | grep -Fx "$url" >/dev/null \
      || { owned_json && jq -e --arg url "$url" 'any(.[]; .url == $url and (.final | not))' "$TMP/owned.json" >/dev/null; }; }; then
    printf 'owned: %s\n' "$url"
    return 0
  fi
  printf 'not owned: %s\n' "$url"
  return 1
}

arm() {
  local staged
  flag_on || fail 'config/pr-health-monitor is absent; the PR health monitor stays off'
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail 'state directory unavailable'
  fm_pr_regular_destination_on_device_or_absent "$STATE/pr-health.check.sh" "$(fm_pr_file_device "$STATE")" \
    || fail 'unsafe check destination'
  staged=$(umask 077; mktemp "$STATE/.pr-health-check.XXXXXX")
  printf '%s\n' '#!/usr/bin/env bash' \
    "export FM_HOME=$(printf '%q' "$FM_HOME")" \
    "export FM_STATE_OVERRIDE=$(printf '%q' "$STATE")" \
    "export FM_DATA_OVERRIDE=$(printf '%q' "$DATA")" \
    "export FM_CONFIG_OVERRIDE=$(printf '%q' "$CONFIG")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-health.sh") poll" > "$staged"
  chmod 700 "$staged"
  mv -f -- "$staged" "$STATE/pr-health.check.sh"
  "$SCRIPT_DIR/fm-check-register.sh" pr-health
  "$SCRIPT_DIR/fm-contributions.sh" arm >/dev/null || fail 'the contribution observer could not be armed'
}

case "${1:-}" in
  poll) [ "$#" -eq 1 ] || fail 'poll takes no arguments'; poll ;;
  owned) [ "$#" -eq 2 ] || fail 'owned needs one PR URL'; owned "$2" ;;
  arm) [ "$#" -eq 1 ] || fail 'arm takes no arguments'; arm ;;
  *) usage >&2; exit 2 ;;
esac
