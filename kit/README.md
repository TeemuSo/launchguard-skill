# LaunchGuard repo process kit

A portable issues -> PR backbone for any repo. One command installs issue
forms, a PR template, an automated review that posts on every PR, auto-close of
linked issues on non-default branches, and the LaunchGuard reporter that sends
your test verdicts to your dashboard.

## Quickstart (any repo, first try)

```bash
# 1. Install (from inside the repo, or pass its path)
bash "${CLAUDE_PLUGIN_ROOT}/kit/install.sh" /path/to/repo

# 2. Commit and push what it installed
cd /path/to/repo && git add .github launchguard-reporter.mjs && git commit -m "chore: repo process kit" && git push

# 3. Give the automated review a credential (ONE of these; until then it
#    skips with a notice, it does not fail)
claude setup-token && gh secret set CLAUDE_CODE_OAUTH_TOKEN   # Pro/Max token
gh secret set ANTHROPIC_API_KEY                               # or a Console API key
```

The review posts through the Claude GitHub App. Install it once for your
account or the repo: https://github.com/apps/claude.

## The loop (one agent per issue)

1. Open an issue from the `task` or `bug` form (acceptance criteria + proof plan baked in).
2. One agent takes the issue: branch, build, open a PR with `Closes #N` in the body.
3. The automated review posts a "## Automated review" comment on the PR by itself.
4. State the proof in the PR body: what you drove against the running app, and what you saw.
5. Merge. The linked issue closes, on any branch.

## What each piece does

| File | Does |
|---|---|
| `.github/ISSUE_TEMPLATE/task.yml`, `bug.yml` | Issue forms: what/why/acceptance/proof (task), expected/actual/repro/evidence (bug). Apply the `task`/`bug` labels; the installer creates missing labels. |
| `.github/pull_request_template.md` | PR body skeleton: `Closes #N`, proof section, playbook checklist. |
| `.github/workflows/claude-code-review.yml` | Automated review on every PR. ALWAYS posts one "## Automated review" summary comment (plus inline comments on specific issues). Skips with a notice when no credential secret is set. |
| `.github/workflows/issue-autoclose.yml` | GitHub only honors `Closes #N` for merges into the DEFAULT branch. This restores it for merges into any other branch (for example `dev`), and stays silent on default-branch merges so nothing double-fires. |
| `launchguard-reporter.mjs` | Sends every test's verdict to your LaunchGuard dashboard at the end of a CI run you already pay for: no new job, no extra browser launch. Copied next to each `playwright.config` found. Plain ESM, no dependencies, no build, **no npm install**: Playwright loads a reporter by file path. Add it to the config's `reporter` list and set `LAUNCHGUARD_API_KEY`; without the key it prints a notice and no-ops. It sends test identity, verdict, and a sanitized message, never your test source. |
| `kit/selftest.sh` | End-to-end self-test: point it at a fresh empty repo (`gh repo create x --private`, then `bash kit/selftest.sh OWNER/x`) and it drives the whole loop above, printing the real evidence for every leg (comment URLs and bodies, issue close events, run conclusions). Legs it cannot witness (no credential) are reported SKIP, never faked. |

## Installer behavior

- Idempotent: existing files are SKIPPED (use `--force` to overwrite), so a
  repo that already has its own review workflow keeps it.
- Creates the `task` and `bug` labels if missing (fresh GitHub repos are
  seeded with `bug` but NOT `task`).
- Detects your default branch and tells you when the issue forms and PR
  template will actually render in GitHub's UI (default branch only).
- Degrades gracefully: no `gh`, no origin remote, or no credential secret is
  a printed notice, never a failure.

## How the reporter decides your app is broken

It classifies Playwright's own answer; it never re-derives one by pattern
matching error text, which drifts with every Playwright release.

| Playwright says | We report | Meaning |
|---|---|---|
| `status === expectedStatus` | passed | Includes `test.fail()`: you already declared this outcome, so it is not news. |
| `status === 'timedOut'` | could not run | Never reached a verdict about your app. Same mapping `allure-playwright` uses. |
| an `expect` step in the failing chain (`TestStep.category`) | **broken** | A claim about your app was checked and violated. |
| anything else | could not run | The safe sink. We never guess red. |

"Could not run" is never a verdict about your app, and never turns anything red.

## Portability rules (keep it this way)

- Nothing in `templates/` may reference a specific repo, branch name, product,
  or directory layout. The kit must install identically into a single-service
  repo or a monorepo.
- The reporter is copied next to `playwright.config`, never to a fixed path, so
  monorepos work. It stays a plain visible tracked file: a config pointing at a
  reporter that is not committed breaks every CI run on load.
- Repo-specific tuning happens in the TARGET repo after install (the installer
  never overwrites), not by editing the kit for one consumer.
- External requirements: `gh` (authenticated). For automated review: one of
  the two secrets above plus the Claude GitHub App. For the reporter:
  `LAUNCHGUARD_API_KEY`. Each one missing is a printed notice, never a failure.

## Known limits (honest by design)

- GitHub reads issue forms AND the PR template from the repo's DEFAULT branch
  only. Installed on a working branch, they ride along until that branch is
  promoted; until then open issues with `gh issue create` using the same
  fields, and paste the PR template structure into PR bodies.
- `pull_request`-triggered workflows added by a PR do run on that same PR, but
  `issue-autoclose.yml` (a `closed`-type trigger) must already be on the BASE
  branch when the merge happens; land the kit first, then the loop is complete
  for every following PR.
- The reporter needs to know which APP a run belongs to, and a per-PR preview
  URL cannot tell it: every PR would mint a new app. Set `app` in the reporter
  options (or `LAUNCHGUARD_APP`) to your real domain, or it prints a notice and
  reports nothing.
- The review agent posts as `claude[bot]` via the Claude GitHub App. If you
  cannot install the app, add `github_token: ${{ secrets.GITHUB_TOKEN }}` to
  the review step; comments then post as `github-actions[bot]`.
