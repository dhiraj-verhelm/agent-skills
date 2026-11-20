---
name: parallel-issue-resolver
description: Resolve several GitHub issues in parallel, each in its own isolated git worktree, then land each one through its own pull request. Plans a dependency graph from the issue numbers, implements each unblocked issue concurrently via subagents, has a separate independent reviewer check each diff before it can land, copies env/secret files into every worktree automatically, opens one PR per issue, waits for CI to pass, squash-merges, and closes each issue with a comment describing exactly what was done. Use when the user gives a set of issue numbers (e.g. "resolve #12 #15 #18", "fix these issues in parallel", "work these tickets in worktrees", "parallelise these issues") and wants them done concurrently.
license: MIT
compatibility: Requires Claude Code (subagents with worktree isolation and SendMessage), git, an authenticated gh CLI, and jq. Target repo must be on GitHub.
---

# Parallel Issue Resolver

Resolve a batch of GitHub issues concurrently, each isolated in its own git worktree, then land each through its own pull request. Five phases — **Plan → Implement → Review → Fix → Land**.

**The load-bearing rule: an issue is closed if and only if GitHub reports its PR as `MERGED`.** Not on a local merge, not on a green test run in a worktree, not on a subagent's say-so. Every close carries a comment saying what was actually implemented.

Work reaches `main` the same way a human's would: branch → PR → CI → squash-merge. Nothing lands that CI has not seen.

## Quick start

User says: *"Resolve #12 #15 #18 in parallel"*.

1. **Preflight**: `bash <skill-dir>/scripts/preflight.sh` — must exit 0 before you spawn anything. There is no separate setup step; it configures the repo itself on first run.
2. **Plan**: read each issue, build a dependency graph, pick the issues that can run *now* without colliding.
3. **Implement**: one subagent per unblocked issue with `isolation: "worktree"`, **all spawned in a single message** so they run concurrently. Each implements, commits, pushes, opens a PR, and writes a handoff.
4. **Review**: a *separate* reviewer subagent per issue — never the author — reads the diff against the issue and returns `approve` or `changes-requested`.
5. **Fix**: send blocking findings back to the original implementer, then re-review. Two rounds maximum.
6. **Land**: for each approved issue, `bash <skill-dir>/scripts/land.sh <issue> <branch> <comment-file>` — one at a time.
7. **Loop** if newly-unblocked issues remain.

Read [REFERENCE.md](REFERENCE.md) for mechanics, command detection, and gotchas before the first run.

## Phase 0 — Preflight

Run this before **every** batch. It is the only setup command in the skill:

```bash
bash <skill-dir>/scripts/preflight.sh        # add --fix to clear safe leftovers
```

It bootstraps whatever isn't configured yet — `.worktreeinclude` so gitignored `.env`/secret files are copied into every worktree, ignore rules, `worktree.baseRef: "head"` — then verifies the run will actually succeed: required tools present, tree clean, `gh` authed, base in sync with origin, CI triggering on `pull_request`, and no leftover `agent/issue-*` branches or orphaned worktrees that would collide.

Bootstrapping is idempotent and prints only when it changes something, so from the second run on it's purely a check. **It writes no tracked file** — ignore rules go in `.git/info/exclude`, so the skill never leaves a diff in anyone's repo.

**If it exits non-zero, stop and fix — do not spawn agents.** Report what it found to the user.

Capture the base branch: `git branch --show-current` → **BASE**. All PRs target BASE.

## Phase 1 — Plan (orchestrator, inline)

For each issue: `gh issue view <id> --json number,title,body,labels,state,comments`. If an issue references a parent PRD/epic, read that too.

Skip any issue that is already `CLOSED`, or that already has an open PR (`gh pr list --search "<id> in:body"`) — say so rather than duplicating work.

Build a dependency graph. Issue **B is blocked by A** if any hold:
- B needs code/infra that A introduces.
- B and A modify overlapping files/modules → concurrent edits would collide.
- B depends on an API shape or decision A establishes.

An issue is **unblocked** if it has zero blocking deps on the other issues *in this batch*. Only unblocked issues run this round. If every issue is blocked, run just the one with the weakest deps to break the cycle.

Assign each a deterministic branch: `agent/issue-<id>`. **Tell the user the batch plan before spawning** — which issues run now, which wait, and why.

## Phase 2 — Implement (parallel subagents)

For **each** unblocked issue, spawn one subagent via the Agent tool with `isolation: "worktree"`. **Put all the spawns in one message** so they run concurrently.

- Subagent type: `general-purpose` (needs edit + bash).
- **Name it `impl-<id>`** — you'll need the name to send review findings back to it in Phase 4 with its context intact.
- Prompt: the contents of [prompts/implement.md](prompts/implement.md) with `{{ISSUE_ID}}`, `{{BRANCH}}` (= `agent/issue-<id>`), `{{BASE}}`, and `{{STATE_DIR}}` (absolute path to `<repo>/.claude/pir`) filled in.

Each subagent implements, tidies its own diff, pushes, opens a PR, and writes two handoff files into `{{STATE_DIR}}`. The files are the durable record — they survive context compaction, the `RESULT` line does not. See [REFERENCE.md](REFERENCE.md#the-handoff-contract).

## Phase 3 — Independent review (parallel subagents)

**The implementing agent does not review its own work.** For each issue that came back `complete` with an open PR, spawn a *separate* reviewer — again **all in one message**.

- Subagent type: `general-purpose`. **Name it `review-<id>`.**
- **No `isolation: "worktree"`** — review is read-only and works off `git diff {{BASE}}...{{BRANCH}}` from the base checkout. No worktree to create or clean up.
- Prompt: [prompts/review.md](prompts/review.md) with `{{ISSUE_ID}}`, `{{BRANCH}}`, `{{BASE}}`, `{{PR}}`, `{{STATE_DIR}}` filled in.

The reviewer writes `{{STATE_DIR}}/issue-<id>.review.json` with a verdict of `approve` or `changes-requested` plus findings. It never edits, pushes, merges, or comments — it reports, you decide.

Post the verdict to the PR so the reasoning is on the record where a human would look for it:

```bash
gh pr comment <PR> --body "$(jq -r '"**Automated review: \(.verdict)**\n\n\(.summary)"' .claude/pir/issue-<id>.review.json)"
```

## Phase 4 — Fix round (only for `changes-requested`)

Send the blocking findings back to the **original implementer**, which still has the code in context:

```
SendMessage → to: "impl-<id>"
```

> Independent review of PR #<pr> found <n> blocking issue(s). Fix only these, re-run the checks, push to the same branch, and update your handoff `.md` to match the final state.
>
> <the `blocking` array, verbatim>
>
> If you think a finding is wrong, say why instead of changing code you believe is correct.

Then re-run Phase 3 for that issue (a fresh `review-<id>` agent — round 2).

**Cap at two review rounds.** If an issue is still `changes-requested` after round 2, stop: leave the PR and issue open, and tell the user what's unresolved with the reviewer's findings. Three rounds means the issue is underspecified or the disagreement needs a human, and further rounds burn tokens without converging.

If the implementer pushes back on a finding rather than fixing it, read both arguments and adjudicate yourself. Don't just relay it back — that's how loops form.

## Phase 5 — Land (orchestrator, from the BASE checkout)

Land issues **one at a time, serially** — never in parallel. Each merge changes BASE, which can stale the next PR; `land.sh` rebases when GitHub reports a conflict, and that only works against an already-updated base.

For each issue whose handoff says `status: "complete"` **and whose review verdict is `approve`**:

```bash
bash <skill-dir>/scripts/land.sh <issue> agent/issue-<issue> .claude/pir/issue-<issue>.md
```

The script does the whole tail in the only correct order: check the review verdict → release the worktree → rebase if conflicting → poll CI to green → squash-merge → **verify GitHub reports `MERGED`** → close the issue with the handoff comment → fast-forward BASE → delete the branch → prune worktrees.

It refuses to land anything without an `approve` verdict on disk, so the review is a gate rather than a habit. `PIR_SKIP_REVIEW=1` overrides it — if you use that, say so out loud, because it removes the only check CI can't perform.

Branch on its exit code:

| Code | Meaning | What you do |
|------|---------|-------------|
| `0` | Landed, closed, cleaned up | Continue to the next issue |
| `2` | Precondition failed | Fix and re-run; do not force past it |
| `3` | Rebase conflict a script can't resolve | Resolve by hand on that branch, push, re-run `land.sh` |
| `4` | CI failed or timed out | Read the failing check, fix on the branch, push, re-run `land.sh` |
| `5` | Merge/close problem | Inspect the PR — it may be merged with the issue still open |

Anything not `0` leaves the PR **and** the issue open, deliberately. Report those to the user with the PR link; don't retry blindly.

Then **loop back to Phase 1** if blocked issues remain.

## Phase 6 — Report

Tell the user, per issue: landed (PR # + link), left open and why, or skipped and why. For anything left open after two review rounds, include the reviewer's unresolved blocking findings. Never claim an issue is done without the merged PR number.

## Requirements

Runs in **Claude Code**: it relies on subagents with `isolation: "worktree"`, `SendMessage`, and `.worktreeinclude`. Install with `npx skills add dhiraj-verhelm/agent-skills --skill parallel-issue-resolver`, or copy this directory into `~/.claude/skills/` or a repo's `.claude/skills/`. There is no per-repo setup, no config to edit, and no paths to fix.

What it needs on the machine: `git`, `gh` (authenticated), and `jq`. Preflight checks all three and names any that are missing.

What it needs from the repo: a GitHub remote, and CI that reports checks on pull requests. Preflight warns if it finds no such CI. You can still run with `PIR_REQUIRE_CI=0`, which lands PRs without a CI gate. Say so out loud if you do, because it removes the skill's main safety property.

What it will **not** do to the repo: modify any tracked file. Ignore rules are written to `.git/info/exclude`, so bootstrapping leaves no diff and nothing can leak into a commit.

Scripts are invoked as `bash <path>`, so a lost executable bit during copying doesn't break anything.

## Safety & gates

- **Never `git push` to BASE**, and never `--force` anything but the agent's own branch (`--force-with-lease`, only inside `land.sh`'s rebase).
- **Never `git add -A` / `git add .`** — stage explicit paths only.
- **Never put `Closes #N` / `Fixes #N` in a PR body.** That makes GitHub close the issue silently on merge, with no comment about what was done. Use `Refs #N`; closing is explicit, gated on verified merge, and always carries the summary.
- Never merge with `--admin`, and never skip a red check.
- One subagent per issue, working only on its issue.
- If preflight fails, stop and tell the user. If the tree is dirty, stop — worktrees branch from HEAD.
