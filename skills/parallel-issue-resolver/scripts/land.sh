#!/usr/bin/env bash
# land.sh <issue> <branch> <comment-file> — land ONE finished issue.
#
# The whole tail of the pipeline, in the one order that is correct:
#
#   release worktree → rebase if conflicting → wait for CI → squash-merge
#   → verify merged → close issue with the comment → sync base → delete branch
#
# Every step is gated on the previous one. The issue is closed if and only if
# GitHub reports the PR as MERGED — never on a local merge, never on a hopeful
# `gh pr merge` exit code.
#
# Run from the MAIN checkout (not a worktree), on the base branch, clean tree.
#
# Exit codes (the orchestrator branches on these):
#   0  landed: merged, issue closed, branch + worktree cleaned up
#   2  precondition failed (wrong dir, dirty tree, missing PR, bad args)
#   3  conflict a rebase could not resolve — needs a human
#   4  CI failed or timed out — PR left open, issue left open
#   5  merge or close failed — PR may or may not be merged; inspect
set -euo pipefail

die() { echo "✗ $*" >&2; exit "${2:-2}"; }
say() { echo "→ $*"; }

CI_TIMEOUT="${PIR_CI_TIMEOUT:-1800}"   # seconds to wait for checks
CI_POLL="${PIR_CI_POLL:-20}"           # seconds between polls
CI_GRACE="${PIR_CI_GRACE:-120}"        # seconds to wait for checks to appear
REQUIRE_CI="${PIR_REQUIRE_CI:-1}"      # 0 = allow landing a PR with no checks
MERGE_METHOD="${PIR_MERGE_METHOD:---squash}"

[ $# -eq 3 ] || die "usage: land.sh <issue> <branch> <comment-file>"
ISSUE="$1"; BRANCH="$2"; COMMENT_FILE="$3"

command -v jq >/dev/null || die "jq is required"
command -v gh >/dev/null || die "gh is required"
[ -r "$COMMENT_FILE" ] || die "comment file not readable: $COMMENT_FILE"
[ -s "$COMMENT_FILE" ] || die "comment file is empty: $COMMENT_FILE — the close comment must say what was done"

# --- preconditions ----------------------------------------------------------
# Must be the main checkout: in a linked worktree these two paths differ.
[ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] \
  || die "run from the main checkout, not a worktree"
[ -z "$(git status --porcelain)" ] || die "working tree is dirty — commit or stash first"

BASE="$(git branch --show-current)"
[ -n "$BASE" ] || die "base checkout is in detached HEAD"
[ "$BASE" != "$BRANCH" ] || die "base checkout is on $BRANCH; check out the base branch first"

# --- review gate ------------------------------------------------------------
# An independent reviewer must have approved. Enforced here rather than left to
# the orchestrator's discipline, for the same reason the empty-comment check is:
# a gate that only exists in prose is a gate that gets skipped under pressure.
REVIEW="$(dirname "$COMMENT_FILE")/issue-$ISSUE.review.json"
if [ "${PIR_SKIP_REVIEW:-0}" = "1" ]; then
  echo "⚠ PIR_SKIP_REVIEW=1 — landing #$ISSUE with no independent review" >&2
else
  [ -r "$REVIEW" ] || die "no review found at $REVIEW — run the Phase 3 reviewer, or set PIR_SKIP_REVIEW=1"
  VERDICT="$(jq -r '.verdict // ""' "$REVIEW" 2>/dev/null || echo "")"
  NBLOCK="$(jq -r '(.blocking // []) | length' "$REVIEW" 2>/dev/null || echo 0)"
  case "$VERDICT" in
    approve) [ "$NBLOCK" -eq 0 ] || die "review approves but lists $NBLOCK blocking finding(s) — inconsistent, resolve by hand" ;;
    changes-requested) die "review requested changes ($NBLOCK blocking) on #$ISSUE — fix and re-review before landing" ;;
    *) die "review at $REVIEW has verdict '$VERDICT'; expected approve or changes-requested" ;;
  esac
  say "review: approve"
fi

restore_base() { git checkout --quiet "$BASE" 2>/dev/null || true; }

git fetch --quiet origin

# --- 1. release the worktree holding this branch ----------------------------
# Work is already pushed, so the worktree is disposable. It must go before any
# checkout/rebase of the branch, because git refuses to check out a branch that
# is live in another worktree. The path is derived from git, never guessed —
# Claude Code names worktrees by hash (agent-a0bba…), not by issue.
WT="$(git worktree list --porcelain \
      | awk -v b="refs/heads/$BRANCH" '
          /^worktree /{p=substr($0,10)}
          $0=="branch "b{print p}')"
if [ -n "$WT" ]; then
  say "removing worktree $WT"
  git worktree remove --force "$WT" || die "could not remove worktree $WT"
fi
git worktree prune

# --- 2. locate the PR -------------------------------------------------------
PR="$(gh pr list --head "$BRANCH" --state all --limit 1 --json number,state \
      --jq 'if length==0 then "" else (if .[0].state=="MERGED" then "MERGED:\(.[0].number)" else "\(.[0].number)" end) end')"
[ -n "$PR" ] || die "no PR found for branch $BRANCH — the implementing agent never opened one"

if [ "${PR%%:*}" = "MERGED" ]; then
  PR="${PR#MERGED:}"
  say "PR #$PR already merged — skipping to close"
else
  # --- 3. rebase if GitHub says it cannot merge cleanly ---------------------
  # Serialized landing means each merge can stale the next PR. Rebase onto the
  # freshly-updated base and force-push, rather than merging base into the
  # branch, so the PR diff stays reviewable.
  STATE="$(gh pr view "$PR" --json mergeable --jq .mergeable)"
  if [ "$STATE" = "CONFLICTING" ]; then
    say "PR #$PR conflicts with origin/$BASE — rebasing"
    trap restore_base EXIT
    git checkout --quiet "$BRANCH"
    if ! git rebase "origin/$BASE"; then
      git rebase --abort || true
      restore_base; trap - EXIT
      die "rebase of $BRANCH onto origin/$BASE hit conflicts a script cannot resolve — resolve #$ISSUE by hand" 3
    fi
    git push --force-with-lease origin "$BRANCH" || { restore_base; trap - EXIT; die "force-push of $BRANCH failed" 3; }
    restore_base; trap - EXIT
    say "rebased and pushed; CI will re-run"
    sleep 5   # let GitHub register the new head before polling checks
  fi

  # --- 4. wait for CI ------------------------------------------------------
  say "waiting for checks on PR #$PR (timeout ${CI_TIMEOUT}s)"
  START="$(date +%s)"
  while :; do
    NOW="$(date +%s)"; ELAPSED=$(( NOW - START ))
    CHECKS="$(gh pr checks "$PR" --json bucket,name 2>/dev/null || true)"

    if [ -z "$CHECKS" ] || [ "$CHECKS" = "[]" ]; then
      if [ "$ELAPSED" -lt "$CI_GRACE" ]; then sleep "$CI_POLL"; continue; fi
      if [ "$REQUIRE_CI" = "0" ]; then
        say "no checks configured — proceeding (PIR_REQUIRE_CI=0)"; break
      fi
      die "no checks reported on PR #$PR after ${CI_GRACE}s; set PIR_REQUIRE_CI=0 to land without CI" 4
    fi

    FAIL="$(jq -r '[.[]|select(.bucket=="fail")]|length' <<<"$CHECKS")"
    PEND="$(jq -r '[.[]|select(.bucket=="pending")]|length' <<<"$CHECKS")"

    if [ "$FAIL" -gt 0 ]; then
      echo "✗ CI failed on PR #$PR:" >&2
      jq -r '.[]|select(.bucket=="fail")|"    \(.name)"' <<<"$CHECKS" >&2
      die "PR #$PR left open, issue #$ISSUE left open — fix the failures and re-land" 4
    fi
    [ "$PEND" -eq 0 ] && { say "all checks green"; break; }
    [ "$ELAPSED" -ge "$CI_TIMEOUT" ] && die "checks still pending after ${CI_TIMEOUT}s on PR #$PR" 4
    sleep "$CI_POLL"
  done

  # --- 5. merge ------------------------------------------------------------
  say "merging PR #$PR ($MERGE_METHOD)"
  gh pr merge "$PR" $MERGE_METHOD --delete-branch || die "gh pr merge failed for #$PR" 5
fi

# --- 6. verify the merge actually happened ----------------------------------
# The close in step 7 hangs off this and nothing else.
MERGED="$(gh pr view "$PR" --json state --jq .state)"
[ "$MERGED" = "MERGED" ] || die "PR #$PR is $MERGED, not MERGED — refusing to close issue #$ISSUE" 5

# --- 7. close the issue with the substantive comment ------------------------
ISTATE="$(gh issue view "$ISSUE" --json state --jq .state)"
if [ "$ISTATE" = "OPEN" ]; then
  say "closing issue #$ISSUE with the work summary"
  gh issue close "$ISSUE" --comment "$(cat "$COMMENT_FILE")" \
    || die "PR #$PR merged but closing issue #$ISSUE failed — close it by hand" 5
else
  say "issue #$ISSUE already $ISTATE — posting the summary as a comment"
  gh issue comment "$ISSUE" --body "$(cat "$COMMENT_FILE")" || true
fi

# --- 8. sync base and clean up ----------------------------------------------
git pull --ff-only origin "$BASE" || say "⚠ could not fast-forward $BASE — pull by hand"
# -D not -d: a squash-merged branch is never "fully merged" in local terms, so
# -d always refuses. Safe here because step 6 proved the work is on the base.
git show-ref --verify --quiet "refs/heads/$BRANCH" && git branch -D "$BRANCH" >/dev/null
git worktree prune

echo "✓ #$ISSUE landed via PR #$PR — merged, closed, cleaned up"
