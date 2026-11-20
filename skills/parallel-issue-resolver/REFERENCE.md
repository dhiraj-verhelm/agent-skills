# Parallel Issue Resolver — Reference

Detailed mechanics behind [SKILL.md](SKILL.md). Read once before the first run.

## Why worktrees

A git worktree is **not a clone** — every worktree shares the one `.git` directory (object store + refs). A commit made inside `.claude/worktrees/agent-a0bba…` on branch `agent/issue-42` is instantly visible repo-wide, so the orchestrator can push, inspect, and rebase that branch from the main checkout without entering the worktree.

The one thing worktrees forbid is having the **same branch checked out in two places**. That is why `land.sh` removes the worktree *before* any checkout or rebase of the branch — and why the removal must be derived, not guessed (below).

## The stash stack is shared — agents must not use it

The same shared `.git` means there is exactly **one stash stack for the whole run**, not one per worktree. `git stash` in agent A's worktree and `git stash pop` in agent B's touch the same stack: B restores A's changes into B's tree, or drops them.

This is the worst failure mode in the skill because it is **silent**. Nothing errors; an agent gets a clean-looking tree and the wrong diff, and finds out only when its tests fail for reasons unconnected to its issue — or worse, doesn't find out at all. It has bitten multiple agents in a single run.

`prompts/implement.md` forbids `git stash` outright and gives the patch-file alternative. If an agent reports missing or unfamiliar changes in its tree, suspect this first: check `git stash list` (entries whose dates are inside this run are the run's, not the user's) and confirm each branch's committed diff is scoped to its own issue with `git diff {{BASE}}...agent/issue-<id> --stat` before letting anything land.

## Deriving the worktree path — never guess it

Claude Code names isolation worktrees by hash: `.claude/worktrees/agent-a0bba88da81a8e162`, **not** `.claude/worktrees/issue-42`. Any command written against the issue-shaped name silently does nothing, which is how orphaned worktrees and undeleted branches pile up. Always resolve the path from git:

```bash
git worktree list --porcelain \
  | awk -v b="refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0=="branch "b{print p}'
```

`land.sh` does this. `preflight.sh --fix` sweeps up anything earlier runs left behind.

## Deleting the branch: `-D`, not `-d`

After a **squash** merge on GitHub, the branch's commits do not exist on the base — a squashed replacement does. So `git branch -d agent/issue-42` refuses ("not fully merged") and the branch survives forever. `land.sh` uses `git branch -D`, but only *after* verifying `gh pr view --json state` reports `MERGED`. The verification is what makes the force-delete safe.

## Closing keywords are banned

`Closes #42` in a PR body makes GitHub close the issue automatically on merge — with **no comment**, so the issue's record ends with a bare "closed" event and a reader has to open the diff to learn anything. Worse, it removes the close from your control: it fires on merge whether or not the rest of the pipeline succeeded.

Use `Refs #42`. `land.sh` closes explicitly, gated on `state == MERGED`, with the handoff `.md` as the comment body. That is the entire point of the design.

## The handoff contract

Each subagent writes two files into `{{STATE_DIR}}` (= `<repo>/.claude/pir`, gitignored):

| File | Purpose | Consumer |
|------|---------|----------|
| `issue-<id>.json` | status, branch, PR number, files, checks | orchestrator's routing |
| `issue-<id>.md` | the substantive close comment | `land.sh` → `gh issue close --comment` |
| `issue-<id>.review.json` | independent reviewer's verdict + findings | `land.sh` review gate |

Files, not just the `RESULT:` line, because **the line lives in orchestrator context and context gets compacted mid-run**; the files are on disk. After a compaction you can rebuild the entire run state with `ls .claude/pir/*.json` and `gh pr list --head 'agent/issue-*'`.

`land.sh` refuses to run if the `.md` is missing or empty. A close with no explanation is treated as a failure, not a nuisance.

Status routing:

- `complete` → land it.
- `incomplete` → do **not** land. Leave branch, worktree, PR and issue alone; report to the user.
- `no-changes` → nothing to land; `preflight.sh --fix` removes the branch/worktree later.
- No handoff at all (subagent errored) → treat as `incomplete`. A failed subagent never blocks the others.

If a branch name doesn't match what you assigned, trust `git branch --list 'agent/*'` and the handoff over your assumption.

## Why review is a separate agent

An author reviewing their own diff is checking the code against the same understanding that produced it. If that understanding was wrong — the usual reason work fails review — self-review confirms the error rather than catching it. It also has every incentive to conclude it is finished, having just declared itself finished.

So the reviewer is a distinct agent with a fresh context, spawned by the orchestrator, and it is told to read **the issue before the diff**. That order is deliberate: forming an independent expectation first is what makes the review a comparison rather than a rationalisation.

Three properties worth preserving if you modify this:

- **Read-only.** A reviewer that can edit will fix what it finds, and nobody reviews the fix. Findings go back to the implementer instead.
- **No worktree.** Review runs off `git diff BASE...BRANCH` from the base checkout, so it needs no isolation, no env files, and no cleanup. Reviewers are therefore much cheaper than implementers.
- **Approve-with-no-findings is a valid outcome.** A reviewer that believes it must find something will manufacture blockers, and each false blocker costs a fix round plus a re-review. The prompt says this explicitly; keep it if you rewrite.

CI and review catch different things. CI proves the tests pass; the reviewer asks whether the tests test anything, whether the issue was actually satisfied, and whether the implementer's account of its own work is true. Neither substitutes for the other, which is why `land.sh` requires both.

### The two-round cap

Round 1 finds real defects. Round 2 confirms they're fixed. By round 3 you are usually watching two agents disagree about something underspecified in the issue, and more rounds don't converge — they just cost tokens and drift the diff. Stop, and hand the disagreement to the user with both positions.

If the implementer argues a finding is wrong rather than fixing it, the orchestrator adjudicates. Relaying the objection back to the reviewer is how loops form.

### Skipping review

`PIR_SKIP_REVIEW=1` makes `land.sh` land without a verdict. It exists for mechanical batches (dependency bumps, generated files) where review is theatre. Announce it when you use it — it removes the only gate that catches code which passes its tests while doing the wrong thing.

## Land serially, not in parallel

Implementation parallelises; landing does not. Each squash-merge rewrites BASE, which can turn the next PR red or conflicting. `land.sh` handles that by rebasing onto a **freshly fetched** base — which only works if the previous merge has already happened. Landing two issues concurrently races them into exactly the conflict the sequencing exists to avoid.

Cost: landing is mostly waiting on CI, so a batch of five is roughly five CI runs end-to-end. That is the price of every change being CI-verified against the base it actually lands on.

## Dependency graph: a prediction, verify it after

Phase 1 infers collisions from issue *prose*, before any code exists. It is a decent prediction and a poor guarantee. Once the subagents return, check the actual diffs before landing:

```bash
for b in $(git branch --list 'agent/issue-*' --format='%(refname:short)'); do
  echo "== $b"; git diff --name-only "$BASE...$b"
done | sort | uniq -d
```

Overlapping paths across branches mean the graph missed an edge. Land the smaller/foundational one first and expect `land.sh` to rebase the other — or, if the overlap is deep, land one and re-run the second issue fresh in the next round rather than forcing a messy rebase.

## Env / secret files in worktrees

A fresh worktree has none of your gitignored files. `.worktreeinclude` (written by `scripts/preflight.sh` on first run) fixes this: Claude Code copies every file that matches a pattern in it **and** is gitignored into each new worktree — including subagent-isolation worktrees. Tracked files are never duplicated. This is what makes the run seamless: agents get `.env`, `.env.local`, nested env files, and secret configs with no manual copy step.

`.worktreeinclude` only applies to worktrees **Claude Code creates** (subagent isolation, `--worktree`, desktop sessions). It does **not** apply to worktrees you make by hand with `git worktree add`. Always let `isolation: "worktree"` create them.

**Vendored-dir pruning (matters for Python).** Preflight detects secret files by matching `\.env` / `secret` (case-insensitively) in gitignored paths — but a gitignored `.venv/` or `node_modules/` holds hundreds of files with "secret" in their path (typeshed stubs, streamlit, hvac). It prunes those dirs so only real project secrets land in `.worktreeinclude`. If you use an unusual virtualenv/dependency dir name, extend the prune list in `scripts/preflight.sh`.

Preflight **preserves** manual edits to `.worktreeinclude` and only appends newly-detected files, so you can hand-add anything the detector misses.

## Why no tracked file is ever written

Ignore rules go in `.git/info/exclude`, not `.gitignore`. Two reasons, and the second is a bug the earlier design actually had:

1. **Distribution.** A skill that appends to a shared, committed `.gitignore` puts an unexplained diff in the repo of everyone you hand it to, and eventually into someone's PR.
2. **Self-consistency.** `.gitignore` is tracked, so writing to it dirties the working tree — and preflight then refuses to run on its own output, because a clean tree is one of its checks. Setup and preflight fought each other.

`.git/info/exclude` is per-clone and never committed, so bootstrapping is invisible to git. The only files the skill creates are `.worktreeinclude`, `.claude/pir/`, and `.claude/settings.local.json`, all three excluded by it.

## Base branch and origin

`worktree.baseRef: "head"` makes worktrees branch from current local HEAD rather than `origin/HEAD`. Combined with preflight's requirement that BASE be in sync with origin, worktrees start from the same commit CI will test against. Preflight warns on unpushed local commits precisely because they'd otherwise leak into every PR diff.

## CI gating

`land.sh` polls `gh pr checks <pr> --json bucket,name` and refuses to merge unless every check is out of the `pending` bucket with none in `fail`. Tunables (env vars):

| Var | Default | Meaning |
|-----|---------|---------|
| `PIR_CI_TIMEOUT` | `1800` | seconds before giving up on pending checks |
| `PIR_CI_POLL` | `20` | seconds between polls |
| `PIR_CI_GRACE` | `120` | seconds to wait for checks to *appear* after push |
| `PIR_REQUIRE_CI` | `1` | `0` lets a PR with no checks land (repos without CI) |
| `PIR_MERGE_METHOD` | `--squash` | `--merge` or `--rebase` if the repo prefers |

**On free-plan private repos** `gh pr merge --auto` does not work (`autoMergeAllowed: false`, and branch protection returns HTTP 403). That is why `land.sh` polls and merges explicitly instead of delegating to GitHub's auto-merge. Check with:

```bash
gh api graphql -f query='{repository(owner:"OWNER",name:"REPO"){autoMergeAllowed}}'
```

If a repo *does* allow auto-merge with required checks, `gh pr merge --auto --squash` is a valid simplification of step 4–5.

## Detecting commands

No `npm` assumption. Detect the ecosystem from lockfiles/manifests, then the commands within it.

**JS/TS:**

| Need | How |
|------|-----|
| Package manager | `pnpm-lock.yaml`→pnpm, `yarn.lock`→yarn, `bun.lockb`→bun, else `package-lock.json`→npm |
| Type-check | first present script of `type-check`, `typecheck`, or run `tsc --noEmit` |
| Tests | the `test` script; in a monorepo run it for the touched package (`pnpm -F <pkg> test`, `npm test -w <pkg>`) |
| Monorepo? | turbo/nx/lerna config or a `workspaces` field — prefer per-package commands to keep runs fast |

**Python** (`pyproject.toml` / `setup.py` / `requirements*.txt` / `*.lock` present):

| Need | How |
|------|-----|
| Runner | `uv.lock`→`uv run`, `poetry.lock` or `[tool.poetry]`→`poetry run`, else the active venv |
| Tests | `pytest` (or `python -m pytest`); scope to the touched path |
| Type-check | **only if configured** — `mypy` / `pyright` (check `pyproject.toml`, `setup.cfg`, `mypy.ini`) or `ruff`. None configured → skip it |

**Other** (Rust/Go/…): `cargo test`, `go test ./...`, etc. If no test command exists in any ecosystem, type-check/build only and say so.

Local checks are a fast filter, not the gate — CI on the PR is the gate. Pre-existing failures on the base branch are not yours to fix; note them and judge against *new* failures introduced by the diff.

## Looping for blocked issues

After a landing round, issues blocked on a now-merged issue are unblocked. Re-run Phase 1 with the remaining numbers, against the freshly pulled base. Stop when none are left, or when the only remaining ones are blocked on issues outside this batch (report those).

## Recovering a half-finished run

Everything needed is on disk or on GitHub — nothing lives only in context:

```bash
ls .claude/pir/*.json                                   # what each agent reported
git branch --list 'agent/issue-*'                       # branches still around
gh pr list --state open --search 'head:agent/issue-'    # PRs still open
bash <skill-dir>/scripts/preflight.sh                   # drift between them
```

Re-running `land.sh` for an issue is safe and idempotent: it detects an already-merged PR and skips straight to closing, and it no-ops on a worktree or branch that's already gone.

## Concurrency & cost notes

- Spawn all unblocked subagents **in one message** so they run concurrently. Each is a full implement+review+PR agent — this is the expensive part; scale the batch to the work.
- Keep each subagent scoped to exactly one issue. Overlapping edits across issues are what the Phase 1 graph exists to prevent — if two issues must touch the same module, mark one blocked and do them in separate rounds.

## Safety recap

- **Never push to BASE.** Agent branches only; `--force-with-lease` only inside `land.sh`'s rebase.
- **Never `git add -A` / `git add .`** — stage explicit paths.
- **Never `Closes #N`** in a PR body. **Never `gh pr merge --admin`.** Never skip a red check.
- Close an issue only after `gh pr view --json state` reports `MERGED`, and only with a comment describing the work.
- If preflight fails or the base tree is dirty, stop and tell the user.
- Don't hand-create worktrees; let subagent `isolation: "worktree"` do it so `.worktreeinclude` and cleanup all apply.
