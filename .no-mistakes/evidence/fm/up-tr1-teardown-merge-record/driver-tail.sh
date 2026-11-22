
# ---- live-validation driver (appended to the helper section of tests/fm-teardown.test.sh) ----
nm_setup() {  # <name> <forge> <forge-state: open|merged|closed|unreadable>
  local case_dir forge=$2 st=$3 head
  case_dir=$(make_case "$1")
  case "$forge" in
    github) NM_URL=https://github.com/example/repo/pull/7; NM_LOG=gh ;;
    forgejo) NM_URL=https://git.example.org/team/repo/pulls/7; NM_LOG=tea ;;
    gitlab) NM_URL=https://gitlab.example.com/team/sub/repo/-/merge_requests/7; NM_LOG=glab ;;
  esac
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "ready PR"
  add_fork_with_pushed_branch "$case_dir"
  printf 'pr=%s\n' "$NM_URL" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  case "$forge:$st" in
    github:open) add_gh_pr_open_for_head "$case_dir" "$head" ;;
    github:closed) add_gh_pr_open_for_head "$case_dir" "$head" CLOSED ;;
    github:merged) add_gh_pr_merged_for_head "$case_dir" "$head" ;;
    forgejo:open) add_tea_pull_for_head "$case_dir" false "$head" git.example.org open ;;
    forgejo:merged) add_tea_pull_for_head "$case_dir" true "$head" git.example.org closed ;;
    gitlab:open) add_glab_mr_for_head "$case_dir" opened "$head" ;;
    gitlab:merged) add_glab_mr_for_head "$case_dir" merged "$head" ;;
    *:unreadable)
      for b in gh gh-axi tea glab; do
        printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/%s.log"\nexit 1\n' "$case_dir" "$NM_LOG" > "$case_dir/fakebin/$b"
        chmod +x "$case_dir/fakebin/$b"
      done ;;
  esac
  NM_CASE=$case_dir
}
nm_run() {  # <label> [teardown args]
  local label=$1 rc=0 out; shift
  out=$(run_teardown "$NM_CASE" "$@" 2>&1) || rc=$?
  printf '%s | exit=%s | forge_read=%s | record=%s | copy=%s | backlog=%s\n' "$label" "$rc" \
    "$([ -e "$NM_CASE/$NM_LOG.log" ] && echo yes || echo no)" \
    "$([ -e "$NM_CASE/state/task-x1.meta" ] && echo kept || echo removed)" \
    "$([ -d "$NM_CASE/wt" ] && echo kept || echo removed)" \
    "$(backlog_row_state "$NM_CASE" 2>/dev/null || echo '?')"
  printf '%s\n' "$out" | grep -E 'REFUSED|--force only' | sed "s#$TMP_ROOT#<tmp>#g; s/^/    /" || true
}

echo "== matrix: open PR, forge x existing review flag x retain-open-pr =="
for retain in no yes; do for forge in github forgejo gitlab; do for flag in none park-on-review auto-land; do
  nm_setup "m-$forge-$flag-$retain" "$forge" open
  [ "$flag" = none ] || : > "$NM_CASE/config/$flag"
  [ "$retain" = no ] || : > "$NM_CASE/config/retain-open-pr"
  nm_run "retain=$retain forge=$forge flag=$flag"
done; done; done

echo "== unreadable forge record =="
for retain in no yes; do for forge in github forgejo gitlab; do
  nm_setup "u-$forge-$retain" "$forge" unreadable
  [ "$retain" = no ] || : > "$NM_CASE/config/retain-open-pr"
  nm_run "retain=$retain forge=$forge record=unreadable"
done; done

echo "== lifecycle with retain-open-pr: open -> merged =="
for forge in github forgejo gitlab; do
  nm_setup "l-$forge" "$forge" open; : > "$NM_CASE/config/retain-open-pr"
  nm_run "forge=$forge PR open"
  head=$(git -C "$NM_CASE/wt" rev-parse HEAD)
  case "$forge" in
    github) add_gh_pr_merged_for_head "$NM_CASE" "$head" ;;
    forgejo) add_tea_pull_for_head "$NM_CASE" true "$head" git.example.org closed ;;
    gitlab) add_glab_mr_for_head "$NM_CASE" merged "$head" ;;
  esac
  nm_run "forge=$forge PR merged"
done

echo "== --force with retain-open-pr and an open PR =="
nm_setup f-github github open; : > "$NM_CASE/config/retain-open-pr"
nm_run "unforced"
rm -f "$NM_CASE/gh.log"
nm_run "--force" --force

echo "== flag toggled on an existing home: absent -> present takes effect on next invocation =="
nm_setup t-github github open; : > "$NM_CASE/config/retain-open-pr"
nm_run "flag present"
rm "$NM_CASE/config/retain-open-pr"; rm -f "$NM_CASE/gh.log"
nm_run "flag removed"
