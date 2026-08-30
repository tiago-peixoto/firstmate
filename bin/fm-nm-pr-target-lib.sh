# shellcheck shell=bash
# fm-nm-pr-target-lib.sh - fail-closed refusal that keeps the validation
# pipeline from opening a pull request anywhere except this home's configured
# push target.
# Usage: . bin/fm-nm-pr-target-lib.sh
#
# THE DEFECT THIS CLOSES (2026-08-28). A fork-topology home registers no-mistakes
# with TWO targets. `no-mistakes init --fork-url <fork>` records the fork as the
# branch push URL and keeps the registration's own remote as the pull-request
# base; its flag help states that contract directly ("GitHub fork remote URL to
# push branches to while opening PRs against origin"), and the pipeline's PR step
# builds its host from the registration remote while using the fork only for the
# `--head <owner>:<branch>` prefix. That is the tool behaving as designed. What
# nothing checked was whether the base it picks is where this home's work is
# actually meant to go. On 2026-08-28 that gap put two large pull requests on
# OFFICIAL UPSTREAM from work that was never meant to leave the fork, and a third
# was moments away.
#
# WHY THIS IS A REFUSAL AND NOT A REPORT. The captain's bar is that the wrong
# target must be UNREACHABLE - not warned about, not confirmed, not linted after
# the fact. A pull request is outward-facing and cannot be un-sent, so a check
# that fires once the PR exists is already too late. This library therefore
# refuses, and refuses BEFORE the run starts, at the one Git operation every
# pipeline run must perform.
#
# THE CHOKEPOINT. `no-mistakes axi run` enters the pipeline by running a real
# `git push <gate-remote> HEAD:refs/heads/<branch>` from the working clone, with
# no `--no-verify`. Git therefore runs that clone's `pre-push` hook first. A hook
# refusal makes the push fail, and the tool's own fallback is gated on the push
# having SUCCEEDED, so a refused push starts no run at all - the review, push,
# and PR steps are never reached. Blocking the gate push is what makes the wrong
# target unreachable rather than merely reported.
#
# THE RULE. The pipeline may open a pull request only against the repository this
# home already pushes to. Concretely: the registration's PR base must be the same
# repository as `origin`'s push URL. That one rule is correct for every topology
# this repo runs - a fork home passes only when both name the fork, a classic
# single-origin project passes because both name the same place, and the private
# fork-integration clone passes because its registration names the fork it pushes
# to. It needs no allow-list to maintain and no per-home policy file to drift.
#
# FAIL CLOSED IN THE STRICT SENSE. Every one of these REFUSES rather than falling
# back to any default: the configured push target cannot be read, `origin` is
# missing or carries several push URLs, the no-mistakes binary is absent, the
# registration cannot be read, either field is empty, or either URL cannot be
# parsed into a repository identity. There is deliberately no "cannot tell, allow
# it" branch, because the state this guard exists to stop is exactly the state in
# which something is unreadable or unexpected.
#
# COMPARING BY IDENTITY, NOT BY STRING. The two URLs legitimately arrive in
# different shapes: Git remotes are usually scp-like (`git@host:owner/repo.git`)
# while a registration may hold an `https://` form, and no-mistakes redacts
# embedded credentials before printing (userinfo becomes `redacted`; host and
# path survive). Raw string equality would refuse those honest differences, so
# both sides normalize to `<host>/<owner>/<repo>` first. Host case is folded
# because DNS is case-insensitive; the path is NOT folded, because only some
# forges treat owner and repository case-insensitively and refusing a case
# difference errs in the safe direction.
#
# WHAT THIS DEPENDS ON, AND WHICH WAY IT BREAKS. The guarantee rests on four
# facts about the installed no-mistakes: the registration remote is the PR base,
# `no-mistakes status` reports it as `remote:`, entering the pipeline is a real
# `git push` with hooks enabled, and a refused gate push starts no run.
# docs/verification/pr-target-guard.md records each with the evidence and says
# which direction its failure goes. Three of the four fail SAFE - a changed
# status format, for instance, yields an empty base and refuses. The one that
# fails dangerous is the gate push: if a release stopped pushing, or started
# bypassing hooks, this guard would go quiet. Re-check that one on every upgrade.
#
# No side effects on source. set -u / set -e safe. Every function RETURNS rather
# than exits, so callers choose their own refusal shape; bin/fm-nm-pr-target.sh
# owns the exit codes and the operator-facing message.

# Exit code the CLI and the pre-push hook use for a target refusal, distinct
# from an ordinary usage error (2) and from the gate-agent refusal (3) so a
# caller or test can tell which guard fired.
# shellcheck disable=SC2034 # Consumed by sourcing callers (bin/fm-nm-pr-target.sh, tests).
FM_NM_TARGET_EXIT=4

# The remote name no-mistakes gives the gate it pushes runs through.
FM_NM_TARGET_GATE_REMOTE=no-mistakes

# fm_nm_target_reset: clear the reason/detail this library reports through.
fm_nm_target_reset() {
  FM_NM_TARGET_REASON=
  FM_NM_TARGET_CONFIGURED=
  FM_NM_TARGET_REGISTERED=
  FM_NM_TARGET_REG_REMOTE=
  FM_NM_TARGET_REG_FORK=
}
fm_nm_target_reset

# fm_nm_target_identity <url>: print the normalized `<host>/<owner>/<repo>`
# identity of a Git URL, or return 1 when it cannot be parsed into one.
#
# Accepts the forms a real remote or registration actually holds: scheme URLs
# (ssh, git, https, http), scp-like `[user@]host:path`, and an explicitly
# rooted local path (`/`, `./`, `../`, `~/`), which normalizes to
# `file:<absolute-path>` so two distinct local repos never compare equal. A bare
# token that is neither - `github.com`, a remote name typed by mistake - is
# REFUSED rather than guessed at as a relative directory.
fm_nm_target_identity() { # <url>
  local url=$1 rest host path
  case "$url" in
    *$'\n'*|*$'\r'*) return 1 ;;
  esac
  url=${url#"${url%%[![:space:]]*}"}
  url=${url%"${url##*[![:space:]]}"}
  [ -n "$url" ] || return 1
  while [ "${url%/}" != "$url" ]; do url=${url%/}; done
  [ -n "$url" ] || return 1

  case "$url" in
    ssh://*|git://*|https://*|http://*)
      rest=${url#*://}
      # Strip userinfo, including the `redacted` placeholder no-mistakes
      # substitutes for credentials before printing a registration.
      rest=${rest#*@}
      host=${rest%%/*}
      path=${rest#*/}
      [ "$path" != "$rest" ] || return 1
      ;;
    *://*)
      # An unrecognized scheme is not guessed at.
      return 1
      ;;
    /*|./*|../*|~/*)
      printf 'file:%s\n' "$(fm_nm_target_abspath "$url")"
      return 0
      ;;
    *:*)
      # scp-like only when the colon precedes any slash; otherwise this is a
      # relative path that merely contains a colon.
      case "${url%%:*}" in
        */*) printf 'file:%s\n' "$(fm_nm_target_abspath "$url")"; return 0 ;;
      esac
      rest=${url#*@}
      host=${rest%%:*}
      path=${rest#*:}
      [ "$path" != "$rest" ] || return 1
      ;;
    *)
      # Not a URL and not an explicitly rooted path: refuse rather than treat a
      # bare token as a relative directory that happens to compare equal.
      return 1
      ;;
  esac

  # Drop a port so `host:22/owner/repo` and `host/owner/repo` agree.
  host=${host%%:*}
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  [ -n "$host" ] || return 1

  while [ "${path#/}" != "$path" ]; do path=${path#/}; done
  while [ "${path%/}" != "$path" ]; do path=${path%/}; done
  path=${path%.git}
  while [ "${path%/}" != "$path" ]; do path=${path%/}; done
  # A repository identity needs both an owner and a name; a bare host is not one.
  case "$path" in
    ''|*/) return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$host" "$path"
}

# fm_nm_target_abspath <path>: best-effort absolute, symlink-resolved form of a
# local repository path. Falls back to the input when the path does not exist,
# which still compares equal to itself and unequal to a different path.
fm_nm_target_abspath() { # <path>
  local p=$1 resolved
  if [ "${p#\~/}" != "$p" ]; then
    p="$HOME/${p#\~/}"
  fi
  p=${p%.git}
  if resolved=$(cd "$p" 2>/dev/null && pwd -P); then
    printf '%s' "$resolved"
    return 0
  fi
  if resolved=$(cd "$p.git" 2>/dev/null && pwd -P); then
    printf '%s' "${resolved%.git}"
    return 0
  fi
  printf '%s' "$p"
}

# WHY THESE RETURN THROUGH GLOBALS. A refusal has to carry its reason to the
# caller, and a reason set inside `$(...)` dies with that subshell. So the three
# readers below assign their result to a global and return a status, rather than
# printing it. fm_nm_target_identity stays a plain printer because it sets no
# reason of its own.

# fm_nm_target_configured <repo>: set FM_NM_TARGET_CONFIGURED to the identity of
# this home's configured push target - the push URL of `origin` in <repo>.
# Returns 1 with FM_NM_TARGET_REASON set when it cannot be read unambiguously.
#
# `remote get-url --all --push` is used rather than the single-value form so a
# remote configured with SEVERAL push URLs is refused as ambiguous instead of
# silently guarding only the first one.
fm_nm_target_configured() { # <repo>
  local repo=$1 urls count url identity
  FM_NM_TARGET_CONFIGURED=
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    FM_NM_TARGET_REASON="not a Git worktree: $repo"
    return 1
  fi
  if ! urls=$(git -C "$repo" remote get-url --all --push origin 2>/dev/null); then
    FM_NM_TARGET_REASON="cannot read the configured push target: no 'origin' remote in $repo"
    return 1
  fi
  urls=$(printf '%s\n' "$urls" | sed '/^[[:space:]]*$/d')
  if [ -z "$urls" ]; then
    FM_NM_TARGET_REASON="cannot read the configured push target: 'origin' has no push URL"
    return 1
  fi
  count=$(printf '%s\n' "$urls" | wc -l | tr -d ' ')
  if [ "$count" != 1 ]; then
    FM_NM_TARGET_REASON="cannot read the configured push target: it is ambiguous, 'origin' has $count push URLs"
    return 1
  fi
  url=$urls
  if ! identity=$(fm_nm_target_identity "$url"); then
    FM_NM_TARGET_REASON="cannot parse the configured push target into a repository: $url"
    return 1
  fi
  FM_NM_TARGET_CONFIGURED=$identity
}

# fm_nm_target_registration_read <repo>: set FM_NM_TARGET_REG_REMOTE and
# FM_NM_TARGET_REG_FORK from the ordinary no-mistakes registration, or return 1
# with FM_NM_TARGET_REASON set.
#
# ONE owner for how a registration is read, shared with bin/fm-fork-remotes.sh's
# migration proof so the two can never disagree about which field is the
# pull-request base. `remote:` IS that base: the pipeline resolves its PR host
# from the registration remote and uses `fork:` only for the head-branch owner.
# An empty fork field is legitimate - that is a single-origin registration.
fm_nm_target_registration_read() { # <repo>
  local repo=$1 out
  FM_NM_TARGET_REG_REMOTE=
  FM_NM_TARGET_REG_FORK=
  if ! command -v no-mistakes >/dev/null 2>&1; then
    FM_NM_TARGET_REASON="cannot read the pipeline registration: no-mistakes is not installed"
    return 1
  fi
  if ! out=$(cd "$repo" 2>/dev/null && no-mistakes status 2>&1); then
    FM_NM_TARGET_REASON="cannot read the pipeline registration: no-mistakes status failed"
    return 1
  fi
  FM_NM_TARGET_REG_REMOTE=$(printf '%s\n' "$out" | awk '$1 == "remote:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  FM_NM_TARGET_REG_FORK=$(printf '%s\n' "$out" | awk '$1 == "fork:" { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')
  if [ -z "$FM_NM_TARGET_REG_REMOTE" ]; then
    FM_NM_TARGET_REASON="cannot read the pipeline registration: no pull-request base recorded"
    return 1
  fi
}

# fm_nm_target_registered <repo>: set FM_NM_TARGET_REGISTERED to the identity of
# the repository the pipeline would open a pull request against. Returns 1 with
# FM_NM_TARGET_REASON set when it cannot be read or parsed.
fm_nm_target_registered() { # <repo>
  local repo=$1 identity
  FM_NM_TARGET_REGISTERED=
  fm_nm_target_registration_read "$repo" || return 1
  if ! identity=$(fm_nm_target_identity "$FM_NM_TARGET_REG_REMOTE"); then
    FM_NM_TARGET_REASON="cannot parse the pipeline's pull-request base into a repository: $FM_NM_TARGET_REG_REMOTE"
    return 1
  fi
  FM_NM_TARGET_REGISTERED=$identity
}

# fm_nm_target_assert <repo>: return 0 only when the pipeline's pull-request base
# is the same repository as this home's configured push target. Any other
# outcome - including anything unreadable - returns non-zero with
# FM_NM_TARGET_REASON set; FM_NM_TARGET_CONFIGURED and FM_NM_TARGET_REGISTERED
# hold whichever sides were read.
fm_nm_target_assert() { # <repo>
  local repo=$1
  fm_nm_target_reset
  fm_nm_target_configured "$repo" || return 1
  fm_nm_target_registered "$repo" || return 1
  if [ "$FM_NM_TARGET_CONFIGURED" != "$FM_NM_TARGET_REGISTERED" ]; then
    FM_NM_TARGET_REASON="the pipeline would open a pull request against $FM_NM_TARGET_REGISTERED, but this home pushes to $FM_NM_TARGET_CONFIGURED"
    return 1
  fi
  return 0
}

# fm_nm_target_has_gate_remote <repo>: return 0 when a validation pipeline is
# actually registered for <repo> - that is, when one of its remotes is the gate a
# run would be pushed to.
#
# This answers "is there a pipeline here at all", which is a different question
# from "is its target correct". Callers that only REPORT use it to stay quiet
# about a repository that never runs the pipeline; it must never gate the
# refusal itself, which applies to any gate push wherever it comes from.
fm_nm_target_has_gate_remote() { # <repo>
  local repo=$1 name url
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    url=$(git -C "$repo" remote get-url "$name" 2>/dev/null || true)
    fm_nm_target_is_gate_push "$name" "$url" && return 0
  done < <(git -C "$repo" remote 2>/dev/null || true)
  return 1
}

# fm_nm_target_is_gate_push <remote-name> <remote-url>: return 0 when a push is
# entering the validation pipeline.
#
# Two independent signals, either of which counts, so a renamed remote is still
# recognized: the name no-mistakes uses for its gate, and a URL that resolves
# under a no-mistakes gate repository. The second mirrors the unspoofable-path
# backstop in bin/fm-gate-refuse-lib.sh and derives from the gate's real
# location, which cannot be moved without breaking the gate's own Git access.
fm_nm_target_is_gate_push() { # <remote-name> <remote-url>
  local name=${1:-} url=${2:-}
  [ "$name" = "$FM_NM_TARGET_GATE_REMOTE" ] && return 0
  case "$url" in
    */.no-mistakes/repos/*.git|*/.no-mistakes/repos/*.git/) return 0 ;;
  esac
  return 1
}
