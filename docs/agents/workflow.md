# Workflow: ticket → branch + worktree → PR → CI + review → squash-merge

Every change reaches `main` through a pull request. No integration branches:
ticket PRs target `main` directly. `scripts/ticket.sh` runs each step; this
file is the rulebook. Decided 2026-10-29.

## One-time setup per clone

```bash
git config core.hooksPath .githooks   # pre-push refuses direct pushes to main
```

The repo is private on a free plan, so GitHub cannot enforce branch
protection. The rules below are enforced by this hook, by `ticket.sh land`
refusing to merge without its gate, and by repo settings: **squash-merge
only**, head branches deleted on merge.

## Roles

- **Orchestrator** (one Claude session): picks the frontier from the issue
  tracker (`issue-tracker.md`), starts tickets, spawns implementers and
  reviewers, and is the **only one who merges**. Merges are serialized.
- **Implementer** (one agent per ticket): works in the ticket's worktree,
  commits, opens the PR when done, then stops and reports. Never merges.
- **Review agent** (one per PR revision): reviews the PR diff against `main`
  (the `code-review` skill), then records a verdict. Never edits code.

## Steps

1. **Start** — orchestrator: `scripts/ticket.sh start <n>` creates branch
   `ticket/<nn>-<slug>` from `origin/main` in a worktree under
   `.claude/worktrees/` (gitignored, luacheck-excluded) and prints the path.
   An implementer spawned with harness worktree isolation instead runs
   `scripts/ticket.sh start <n> --here` as its first command.
2. **Build** — implementer commits on the ticket branch. No PR and no CI
   until the work is done; run the local checks (`CLAUDE.md` → Commands).
3. **PR** — implementer writes the ticket's acceptance criteria, each ticked
   with its evidence (command + result, unit-test name, screenshot paths), to a
   file and runs `scripts/ticket.sh pr <n> criteria.md`. This pushes the
   branch and opens the PR to `main` titled `#<n>: <ticket title>` with
   `Closes #<n>`. CI (`check.yml`) runs on the PR.
4. **Review** — orchestrator spawns a review agent on the PR. It writes its
   findings to a file and runs `scripts/ticket.sh review <n> pass|fail
   findings.md`, which posts them as a PR comment and sets the
   **`review-agent` commit status** on the head commit. (GitHub forbids
   approving your own PR, and every agent uses the same account, so the
   verdict is a commit status. Any new push clears it.)
5. **Fix loop** — on a red CI or a `fail` verdict, the orchestrator resumes
   the **same implementer** (SendMessage, context intact) with the findings.
   After **two** failed rounds, stop: `gh issue edit <n> --add-label
   ready-for-human`, comment why, and move to the next ticket.
6. **Land** — orchestrator: `scripts/ticket.sh land <n>`.
   - If the branch is behind `main`, it rebases it in its worktree,
     force-pushes with lease and exits 3. CI re-runs; review the new head
     (step 4), then `land` again. `main` is always a tested state.
   - When up to date it requires green checks, a passing `review-agent`
     status on the head commit and a non-draft PR, then squash-merges
     (subject `#<n>: <title> (#<pr>)`), removes the worktree and the branch.
     `Closes #<n>` closes the issue.
7. **Next frontier** — tickets whose blockers are now closed.

`scripts/ticket.sh status <n>` shows PR, CI and review state at any time.

## Non-ticket changes

Same flow without an issue number: a branch (`chore/<slug>`, `fix/<slug>`)
in a worktree, a PR to `main`, green CI and a review-agent status, then a
squash-merge with `gh pr merge --squash`.

## CI

- `check.yml` — lint, LuaJIT load-check, offline unit test. Runs on PRs and
  on pushes to `main`. Merge gate.
- `live.yml` — headless test against the real APIs. **Manual only**
  (Actions → live-apis → Run workflow, or `gh workflow run live.yml`).
  Never gates a merge: external APIs hiccup and DOAB is 403 everywhere.
- `release.yml` — on a `v*` tag: runs `check.yml`, verifies the tag matches
  `openshelf_version.lua`, zips `openshelf.koplugin` and publishes a GitHub
  Release with the zip.

## Releases and the Kobo

`main` carries in-progress work. A release is a PR that bumps
`openshelf.koplugin/openshelf_version.lua`; once it lands, tag that commit
on main and push the tag (tags are not refused by the hook):

```bash
git tag v0.6.0 origin/main && git push origin v0.6.0
```

The device runs tags only: `scripts/deploy.sh` refuses an untagged or dirty
checkout unless given `--dev`.
