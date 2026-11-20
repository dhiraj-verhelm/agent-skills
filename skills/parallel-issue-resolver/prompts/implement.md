# Implement issue #{{ISSUE_ID}}

You are working in an **isolated git worktree** on branch `{{BRANCH}}`, branched from `{{BASE}}`. Everything you do stays on this branch. Resolve **only** issue #{{ISSUE_ID}} — ignore all other issues.

Your job ends with a pull request open and a handoff written. You do **not** merge, and you do **not** close the issue — the orchestrator does that only once GitHub confirms the PR merged.

**Never run `git stash` (or `git stash pop`/`apply`/`drop`).** Your worktree is isolated but its `.git` is not: every agent in this run shares **one global stash stack**. `git stash` pushes your uncommitted work onto a stack other agents are pushing to and popping from concurrently, and `git stash pop` will happily restore *someone else's* changes into your tree — or destroy yours. It fails silently: you get a clean-looking tree and the wrong diff. To set changes aside, use a path outside the repo:

```bash
git diff > /tmp/issue-{{ISSUE_ID}}.patch   # save
git checkout -- <explicit paths>           # clear
git apply /tmp/issue-{{ISSUE_ID}}.patch    # restore
```

If you find changes in your tree you did not make, do **not** stash or discard them — they are probably another agent's. Report it and stop.

## 1. Understand

- `gh issue view {{ISSUE_ID}}` — read the full issue and its comments. If it names a parent PRD/epic/issue, read that too.
- `git log -n 10 --oneline` for recent context.
- If the repo records architectural decisions (`CONTEXT.md`, `docs/adr/`, `docs/decisions/`, `adr/`), read the ones covering the area you're touching — an ADR is a decision the team already made and defended, and contradicting one is a blocking review finding no matter how good the code is.
- Explore the repo and load the relevant code into context. Pay special attention to **test files** touching the areas you'll change, and to existing patterns/conventions — match them.

## 2. Implement (red-green-refactor where it fits)

1. **RED**: write one failing test for the next slice of behaviour.
2. **GREEN**: write the minimal implementation to pass it.
3. **REPEAT** until the issue is satisfied.
4. **REFACTOR** for clarity once green.

Not every issue suits TDD (config, docs, mechanical changes) — use judgement, but always leave the change covered by *some* check.

## 3. Verify before committing

Detect the repo's toolchain from its lockfiles/manifests and run the checks — **do not assume any one ecosystem**:

- **JS/TS**: package manager from lockfile (pnpm if `pnpm-lock.yaml`, yarn if `yarn.lock`, bun if `bun.lockb`, else npm). Type-check via the `type-check` / `typecheck` / `tsc` script if present; tests via the `test` script. In a monorepo, run for the **package you touched** (e.g. `pnpm -F <pkg> test`), not the whole repo.
- **Python**: runner from the project — `uv run pytest` if `uv.lock`, `poetry run pytest` if `poetry.lock` / `[tool.poetry]`, else `pytest` (or `python -m pytest`) in the active venv. Scope tests to what you touched. Run a type-checker/linter **only if the project configures one** (`mypy` / `pyright` / `ruff` — check `pyproject.toml`, `setup.cfg`, `mypy.ini`). If none is configured, skip it and say so.
- **Other** (Rust/Go/…): the idiomatic command — `cargo test`, `go test ./...`, etc.

The checks that exist for the code you changed must pass. Don't get blocked on pre-existing, unrelated failures — note them instead. If the repo has no test command at all, build/type-check only and say so.

**Record the exact commands you ran and their results** — they go in the handoff, and the reader of the closed issue will rely on them.

## 4. Commit

One or more focused commits. Stage **explicit paths** — never `git add -A` or `git add .`. Each message states what was done (+ issue ref), key decisions, and any caveats. Keep it concise.

## 5. Tidy your own diff

`git diff {{BASE}}...HEAD` and clean up what you'd be embarrassed to hand over: debug output, dead code, commented-out attempts, unclear names, needless complexity, comments that restate the code. Re-run the checks and commit any refinements.

This is tidying, not review. **An independent reviewer who did not write this code will review it after you** — you cannot approve your own work, so don't spend effort trying to. Spend it on making the change genuinely correct and on being straight in your handoff about anything you skipped or are unsure of. Flagging your own weak spot costs one honest line; having the reviewer find it costs a full fix-and-re-review round.

## 6. Push and open the PR

```bash
git push -u origin {{BRANCH}}
gh pr create --base {{BASE}} --head {{BRANCH}} --title "<type>(<scope>): <what changed>" --body "..."
```

Match the repo's existing PR title convention (check `gh pr list --state merged --limit 5`).

**The PR body must not contain `Closes #{{ISSUE_ID}}`, `Fixes #…`, or `Resolves #…`.** Those make GitHub close the issue silently on merge, with no record of what was done. Write **`Refs #{{ISSUE_ID}}`** instead. Closing is the orchestrator's job and always carries a summary.

PR body structure:

```
## What
<what changed, in plain terms>

## Why
Refs #{{ISSUE_ID}} — <the problem this solves>

## How
<key implementation decisions, anything a reviewer would otherwise have to reverse-engineer>

## Verification
<exact commands run and their results>

## Notes
<caveats, follow-ups, deliberate omissions — or "none">
```

If the push or `gh pr create` fails, do not retry blindly — record the failure in the handoff and report `incomplete`.

## 7. Handoff (required — this is how your work gets landed)

Write **two files** into `{{STATE_DIR}}` (an absolute path; write there, not into your worktree):

**`{{STATE_DIR}}/issue-{{ISSUE_ID}}.json`** — machine state:

```json
{
  "issue": "{{ISSUE_ID}}",
  "branch": "{{BRANCH}}",
  "status": "complete",
  "pr": 812,
  "files": ["path/one.ts", "path/two.test.ts"],
  "checks": "pnpm -F @acme/server test — 412 passed; tsc --noEmit — clean",
  "notes": ""
}
```

`status` is `complete` (PR is open and ready), `incomplete` (couldn't finish — explain in `notes`), or `no-changes` (nothing to do — explain in `notes`).

**`{{STATE_DIR}}/issue-{{ISSUE_ID}}.md`** — the comment that will be posted when the issue is closed. A human reading only this must understand what was done and why, without opening the diff. Write it for that reader.

```markdown
Resolved in PR #<pr> — <one-line summary of the change>.

**What was implemented**
- <specific behavioural change, not "updated the service">
- <another>

**How it works**
<short paragraph: the approach, and any decision a future reader would question>

**Files changed**
- `path/one.ts` — <what changed here>
- `path/two.test.ts` — <what it covers>

**Verification**
<exact commands and results>

**Notes**
<caveats, deliberate omissions, follow-up issues — or omit this section>
```

Be specific. "Fixed the bug" is a failure to write this file. Name the behaviour that changed.

If `status` is not `complete`, still write the `.md` with what you did and what remains, and leave it on the issue as a comment: `gh issue comment {{ISSUE_ID}} --body-file {{STATE_DIR}}/issue-{{ISSUE_ID}}.md`. **Never close the issue yourself.**

## 8. Report

End your final message with exactly one line:

`RESULT: {"issue":"{{ISSUE_ID}}","branch":"{{BRANCH}}","status":"complete","pr":<number>}`

## 9. If you are sent review findings

You may be messaged later with blocking findings from the independent reviewer. If so:

- Fix **only** what's listed. Don't refactor around it, don't fix unrelated things you notice.
- If you believe a finding is wrong, say why rather than changing code you think is correct — a reasoned disagreement is a valid response and the orchestrator will adjudicate.
- Re-run the checks, commit, and `git push` to the same branch (the PR updates itself).
- Update `{{STATE_DIR}}/issue-{{ISSUE_ID}}.md` so the close comment reflects the final state, not the first draft.
- End with: `RESULT: {"issue":"{{ISSUE_ID}}","branch":"{{BRANCH}}","status":"complete","pr":<number>,"round":<n>}`

Work on a single issue only.
