# Agent Skills

A collection of Agent Skills (the open `SKILL.md` format) that work with Claude and other skills-compatible agents.

## Skills

| Skill | Category | What it does |
|---|---|---|
| [davinci-resolve-color-grading](skills/davinci-resolve-color-grading/SKILL.md) | Video | Gyroflow stabilization, DJI D-Log M normalization (LUT or CST), and a 4-level node-based grade in DaVinci Resolve. Also covers cutting a cinematic edit and YouTube 4K delivery. |
| [parallel-issue-resolver](skills/parallel-issue-resolver/SKILL.md) | Dev workflow | Resolves a batch of GitHub issues in parallel, one git worktree and one PR per issue. An independent reviewer checks each diff, CI must pass, then it squash-merges and closes each issue with a comment saying what was done. |

## Install

All skills:

```bash
npx skills add dhiraj-verhelm/agent-skills
```

One skill:

```bash
npx skills add dhiraj-verhelm/agent-skills --skill davinci-resolve-color-grading
```

## Adding a skill

1. Create a folder under `skills/` named after the skill, in kebab-case (for example `skills/my-new-skill/`).
2. Add a `SKILL.md` with frontmatter: `name` must match the folder name. `description` says what the skill does and when to use it.
   ```markdown
   ---
   name: my-new-skill
   description: What it does, and when an agent should use it.
   license: MIT
   ---

   # My New Skill
   ...
   ```
3. Put any supporting files (scripts, references, templates) in the same folder.
4. Add a row to the table above.
5. Optional: run `gh skill publish --dry-run` to validate the skill.

## Skill notes

### davinci-resolve-color-grading

Requirements: DaVinci Resolve 18 or later (free or Studio; noise reduction and some texture effects need Studio). The [Gyroflow OFX plugin](https://gyroflow.xyz) is optional. For the LUT path, you need the official DJI D-Log M to Rec.709 LUT for your drone.

Credit: the four-level grading method follows KC ian, ["The Highest Level of Color Grading: No LUTs, No Plugins"](https://www.youtube.com/watch?v=53gcbJPP5eA). Drone-specific additions are by Dhiraj Khanna.

### parallel-issue-resolver

Requirements: Claude Code (it uses subagents with worktree isolation), plus `git`, `jq` and an authenticated `gh` CLI. The target repo needs a GitHub remote and CI that reports checks on pull requests. Run it with a set of issue numbers, for example "resolve #12 #15 #18 in parallel". Its preflight script configures the repo on first run and writes no tracked files.

## License

MIT — see [LICENSE](LICENSE), unless a skill's own frontmatter says otherwise.
