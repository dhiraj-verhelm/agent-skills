#!/usr/bin/env bash
# preflight.sh [--fix] — the skill's single entry point. Run before every run.
#
# Self-bootstrapping: there is no separate setup step to remember, and none for
# anyone you hand this skill to. Phase A configures whatever isn't configured
# yet (idempotent, silent when there's nothing to do); Phase B verifies the repo
# is in a state where a parallel run will actually succeed.
#
# It mutates NO tracked file. Ignore rules go in .git/info/exclude (per-clone,
# never committed) rather than .gitignore, so running this leaves zero diff in
# the user's repo — important both for trust and because a dirty tree would
# fail this script's own clean-tree check.
#
# --fix additionally removes leftovers that are provably safe to remove:
# worktrees git has marked prunable, and agent/* branches whose PR is MERGED or
# whose commits are all contained in the base branch. Anything with unmerged
# work is reported and never touched.
set -euo pipefail

FIX=0
[ "${1:-}" = "--fix" ] && FIX=1

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ not in a git repo" >&2; exit 2; }
cd "$ROOT"
[ "$(git rev-parse --git-dir)" = "$(git rev-parse --git-common-dir)" ] \
  || { echo "✗ run from the main checkout, not a worktree" >&2; exit 2; }

PROBLEMS=0
note() { echo "  ⚠ $*"; PROBLEMS=$((PROBLEMS+1)); }
ok()   { echo "  ✓ $*"; }

# ===========================================================================
# PHASE A — bootstrap (idempotent; prints only when it changes something)
# ===========================================================================
echo "Bootstrap:"
CHANGED=0

# --- A1. .git/info/exclude — keep our artifacts out of git, tracked-file-free
GITDIR="$(git rev-parse --git-common-dir)"
EXCLUDE="$GITDIR/info/exclude"
mkdir -p "$(dirname "$EXCLUDE")"; touch "$EXCLUDE"
# Every file this script creates must be listed here, or it shows up untracked
# and fails the clean-tree check below. settings.local.json is named precisely
# rather than excluding all of .claude/, because teams do commit .claude/skills/
# and .claude/settings.json. (Easy to miss locally: a global core.excludesFile
# containing .claude/ hides this on your own machine but not on anyone else's.)
for pat in '.claude/worktrees/' '.claude/pir/' '.claude/settings.local.json' '.worktreeinclude'; do
  grep -qxF "$pat" "$EXCLUDE" || { printf '%s\n' "$pat" >> "$EXCLUDE"; echo "  ✓ excluded $pat (local, uncommitted)"; CHANGED=1; }
done

# --- A2. .worktreeinclude — gitignored env/secret files to copy into worktrees
# Claude Code copies every file matching a pattern here AND gitignored into each
# new worktree, so agents get a working .env with no manual step.
#
# -i so SECRETS.json / Secrets.toml count. The second grep prunes vendored dirs:
# a gitignored .venv/ or node_modules/ holds hundreds of paths containing
# "secret" (typeshed stubs, streamlit, hvac) that would otherwise all be copied.
IGNORED="$(
  git ls-files --others --ignored --exclude-standard 2>/dev/null \
    | grep -iE '(^|/)\.env($|\.)|secret' \
    | grep -vE '(^|/)(\.venv|venv|node_modules|\.tox|\.nox|\.mypy_cache|\.pytest_cache|\.ruff_cache|__pycache__|site-packages|\.eggs|[^/]+\.egg-info|dist|build|target|vendor|\.git)/' \
    || true
)"
WTI=".worktreeinclude"
WANT="$(printf '%s\n' ".env" ".env.local" ".env.*"; [ -n "$IGNORED" ] && printf '%s\n' "$IGNORED")"

if [ ! -f "$WTI" ]; then
  { echo "# Gitignored files copied into every Claude Code worktree."
    echo "# Managed by parallel-issue-resolver. Hand-added lines are preserved."
    printf '%s\n' "$WANT"
  } | awk '!seen[$0]++' > "$WTI"
  echo "  ✓ created $WTI ($(grep -cvE '^#|^$' "$WTI") pattern(s))"; CHANGED=1
else
  # An existing file is APPENDED to, never regenerated. Rewriting it whole —
  # even just to refresh the header comment — produces a diff, and this file is
  # tracked in some repos, so that diff dirties the tree (failing the clean-tree
  # check below) and eventually rides along in someone's unrelated PR.
  MISSING="$(printf '%s\n' "$WANT" | grep -vxF -f <(grep -vE '^#|^$' "$WTI") || true)"
  if [ -n "$MISSING" ]; then
    printf '%s\n' "$MISSING" >> "$WTI"
    echo "  ✓ $WTI += $(printf '%s\n' "$MISSING" | tr '\n' ' ')"; CHANGED=1
    git ls-files --error-unmatch "$WTI" >/dev/null 2>&1 \
      && echo "    ($WTI is tracked — commit this change)"
  fi
fi

# --- A3. worktree.baseRef=head — branch worktrees from local HEAD, which
# Phase B then verifies is in sync with origin.
mkdir -p .claude/pir
SETTINGS=".claude/settings.local.json"
if command -v jq >/dev/null 2>&1; then
  CUR="$(jq -r '.worktree.baseRef // ""' "$SETTINGS" 2>/dev/null || echo "")"
  if [ "$CUR" != "head" ]; then
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    jq '.worktree.baseRef = "head"' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "  ✓ set worktree.baseRef=head in $SETTINGS"; CHANGED=1
  fi
elif [ ! -f "$SETTINGS" ]; then
  printf '{\n  "worktree": { "baseRef": "head" }\n}\n' > "$SETTINGS"
  echo "  ✓ created $SETTINGS with worktree.baseRef=head"; CHANGED=1
fi

[ "$CHANGED" -eq 0 ] && ok "already configured"

# ===========================================================================
# PHASE B — verify
# ===========================================================================
BASE="$(git branch --show-current)"
echo "Base branch: ${BASE:-<detached>}"
[ -n "$BASE" ] || { echo "✗ detached HEAD — check out a branch first" >&2; exit 2; }

# --- B0. tools -------------------------------------------------------------
echo "Tools:"
MISSING=""
for t in git gh jq; do command -v "$t" >/dev/null || MISSING="$MISSING $t"; done
if [ -n "$MISSING" ]; then note "missing required tool(s):$MISSING — install before running"; else ok "git, gh, jq present"; fi

# --- B1. clean tree --------------------------------------------------------
echo "Working tree:"
if [ -n "$(git status --porcelain)" ]; then
  note "dirty — commit or stash before running (worktrees branch from HEAD)"
  git status --short | head -10 | sed 's/^/      /'
else
  ok "clean"
fi

# --- B2. gh auth -----------------------------------------------------------
echo "GitHub CLI:"
if gh auth status >/dev/null 2>&1; then ok "authenticated"; else note "gh not authenticated — run: gh auth login"; fi

# --- B3. base in sync with origin -----------------------------------------
echo "Base vs origin:"
if git fetch --quiet origin 2>/dev/null && git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  BEHIND="$(git rev-list --count "$BASE..origin/$BASE")"
  AHEAD="$(git rev-list --count "origin/$BASE..$BASE")"
  [ "$BEHIND" -gt 0 ] && note "$BASE is $BEHIND commit(s) behind origin/$BASE — run: git pull --ff-only"
  [ "$AHEAD"  -gt 0 ] && note "$BASE is $AHEAD unpushed commit(s) ahead of origin/$BASE — PRs would contain them; push or reset first"
  [ "$BEHIND" -eq 0 ] && [ "$AHEAD" -eq 0 ] && ok "in sync"
else
  note "no origin/$BASE — the PR flow needs a remote"
fi

# --- B4. CI + merge capability --------------------------------------------
echo "CI:"
if ls .github/workflows/*.y*ml >/dev/null 2>&1 && grep -qlE 'pull_request' .github/workflows/*.y*ml >/dev/null 2>&1; then
  ok "workflows trigger on pull_request"
elif command -v gh >/dev/null && LAST_PR_CHECKS="$(gh pr list --state all --limit 5 --json number --jq '.[].number' 2>/dev/null \
       | while read -r n; do gh pr checks "$n" --json name --jq 'length' 2>/dev/null || echo 0; done | sort -rn | head -1)" \
     && [ "${LAST_PR_CHECKS:-0}" -gt 0 ]; then
  # CI outside GitHub Actions (Cloud Build, Buildkite, …) still reports checks on PRs,
  # and land.sh gates on `gh pr checks`, so recent PRs carrying checks is the real test.
  ok "no Actions workflow, but recent PRs carry checks (external CI) — land.sh gates on them"
else
  note "no workflow triggers on pull_request — landing would have no CI gate (set PIR_REQUIRE_CI=0 to accept this)"
fi
if command -v gh >/dev/null && SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"; then
  AM="$(gh api graphql -f query="{repository(owner:\"${SLUG%%/*}\",name:\"${SLUG##*/}\"){autoMergeAllowed}}" \
        --jq .data.repository.autoMergeAllowed 2>/dev/null || echo "unknown")"
  [ "$AM" = "true" ] && ok "native auto-merge available" \
                     || ok "no native auto-merge (free/private plan) — land.sh polls checks and merges explicitly"
fi

# --- B5. leftover agent branches ------------------------------------------
echo "Leftover agent branches:"
LEFT="$(git branch --list 'agent/issue-*' --format='%(refname:short)')"
if [ -z "$LEFT" ]; then
  ok "none"
else
  for b in $LEFT; do
    UNMERGED="$(git rev-list --count "$BASE..$b" 2>/dev/null || echo 0)"
    PRSTATE="$(gh pr list --head "$b" --state all --limit 1 --json state --jq '.[0].state // "NONE"' 2>/dev/null || echo "UNKNOWN")"
    if [ "$PRSTATE" = "MERGED" ] || [ "$UNMERGED" = "0" ]; then
      if [ "$FIX" = "1" ]; then
        git branch -D "$b" >/dev/null && echo "  ✓ deleted $b (PR $PRSTATE, $UNMERGED unmerged commits)"
      else
        echo "  · $b — landed (PR $PRSTATE, $UNMERGED unmerged commits); --fix removes it"
      fi
    else
      note "$b has $UNMERGED unmerged commit(s), PR $PRSTATE — left alone; land or delete it by hand"
    fi
  done
fi

# --- B6. orphaned worktrees ------------------------------------------------
echo "Worktrees:"
PRUNABLE="$(git worktree list --porcelain | awk '/^worktree /{p=substr($0,10)} /^prunable/{print p}')"
if [ -z "$PRUNABLE" ]; then
  ok "no prunable worktrees"
elif [ "$FIX" = "1" ]; then
  git worktree prune && echo "  ✓ pruned: $(echo "$PRUNABLE" | tr '\n' ' ')"
else
  for p in $PRUNABLE; do echo "  · prunable: $p — --fix prunes it"; done
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
  echo "✓ ready — base: $BASE"
else
  echo "✗ $PROBLEMS problem(s) above — resolve before spawning agents (try: preflight.sh --fix)"
  exit 1
fi
