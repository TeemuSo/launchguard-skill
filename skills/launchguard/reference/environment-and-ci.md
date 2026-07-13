# Environment and CI: running black-box e2e against a real per-PR deployment

Read this BEFORE wiring a repo's continuous testing. The authoring discipline (how to write a test
that does not lie) lives in `methodology.md` and `functional-methodology.md`. This file is the layer
above: **where the test runs, what it runs against, and how the PR's own build gets a working
backend without touching the app's code.** Getting this wrong is why teams conclude "e2e against
previews is impossible" and give up. It is not impossible. It is configuration.

## What `@watched` means (read this first if the word is unclear)

`@watched` is a tag on the small subset of tests that run **continuously against the live
deployment, on every deploy**: the standing guards. The rest of the suite runs in the normal dev
loop (on a PR, locally, nightly). A watched test that was green and turns red on a deploy is a
regression you get alerted about. This is the whole point of the product: catching the day a change
silently breaks a guarantee, including drift a pre-merge suite never sees (an access policy edited in
a dashboard, an env var flipped, a dependency bump) because there was no code change to test.

You watch a test only if both hold: it is **black-box and self-provisioning** (safe to run against a
live deployment with no setup), and it **guards something you never want to break silently** (money,
data access, the core journey). Everything below is how to run that subset against the right target.

## The one principle: test the PR build, never a shared branch alias

A pull request produces its own deployment with its own URL (a Vercel preview, for example). A
branch alias like `staging.example.com` serves the latest deployment of that branch, which is
already-merged code, not the PR's diff. Fail-then-green only means something against the code under
review, so **the test target is the per-PR deployment URL, not any stable alias.** Everything below
exists to make that per-PR deployment fully functional.

## The unlock: the app is already env-driven, so a preview is a config, not a code change

A well-built app reads its backend from environment variables: database URL and keys, payment keys,
the webhook secret, a non-production flag. That means the app does not need to change to run in a new
environment; it needs the right env values. If the team already has a working non-production
environment, that proves the switches exist. **A per-PR preview is the same app pointed at a
non-production backend through env vars.** Do not modify the app to make testing work. If you find
yourself proposing an app code change to enable a test, stop: the switch you need almost always
already exists as an env flag the team built for their own non-prod environment.

The preview needs, in its preview-scoped env, the same values that make the non-prod environment work:

- **Database** (URL + keys): point at the existing non-prod project.
- **Payments** (test-mode keys): the same test keys the non-prod environment uses. Test cards work only in test mode; against live keys they fail, so a misconfig cannot charge a real card.
- **The non-production flag.** Most apps gate their test affordances (a magic OTP, skipping real SMS/email sends) behind a flag. On a hosted deploy `NODE_ENV` is always `production`, so this is usually a separate env var. Set it to the value that turns on non-prod behavior. **Check whether that same flag is load-bearing in more than one place**: it commonly gates auth affordances AND is read elsewhere (a webhook that only credits events tagged with a given environment, a feature gate). A wrong value can make a flow time out with no error.

## The self-referencing URL rule

The app must derive its own origin from the incoming request (or the deployment's own URL var), not
from a fixed public URL. A fixed public site URL scoped to Preview makes every preview advertise the
wrong host: redirects, embedded widgets, and OAuth callbacks all point at the alias instead of the
deployment. Keep a fixed canonical URL for production only; on preview and local the app self-
references. This is env configuration (do not scope the fixed URL to Preview), not a code change.

## Vercel specifics (the common host)

- **Deployment protection (only if it is on).** If previews sit behind Vercel Authentication, generate a `VERCEL_AUTOMATION_BYPASS_SECRET` (project settings, Protection Bypass for Automation) and send it as the `x-vercel-protection-bypass` header on every request so navigations, sub-resources, and iframes all pass. If protection is off, you need none of this. Check before adding it.
- **Get the exact per-PR URL from the deployment event.** Trigger the test job on `deployment_status` and read `github.event.deployment_status.target_url`. Never hardcode a URL, never use a branch alias.
- **Pin the real environment name (a silent-death trap).** `deployment_status.environment` is the project's environment name, which on a multi-project repo is like `Preview – <project>` (with an en-dash, one per project), not `Preview`. Enumerate the real names and pin the exact one: `gh api repos/{owner}/{repo}/deployments --paginate --jq '.[].environment' | sort -u`. A wrong name means the job never runs, and an absent check reads as green.
- **`deployment_status` only fires from the default branch.** The workflow file must be on the default branch to trigger at all, so the PR that adds it cannot fire it. Ship a `workflow_dispatch` with a manual `target_url` input to prove the lane before relying on the auto-trigger.
- **The app's own origin at runtime** comes from `VERCEL_URL` (server) or the request origin; `VERCEL_ENV` distinguishes `production` from `preview`.

```yaml
on:
  deployment_status:
  workflow_dispatch:
    inputs:
      target_url: { description: 'Preview URL to test', required: true }
jobs:
  watched:
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.deployment_status.state == 'success' &&
       github.event.deployment_status.environment == 'Preview – REPLACE-ME')
    steps:
      - run: npx playwright test --grep @watched
        env:
          TARGET_URL: ${{ github.event.inputs.target_url || github.event.deployment_status.target_url }}
          # Only when protection is on:
          VERCEL_AUTOMATION_BYPASS_SECRET: ${{ secrets.VERCEL_AUTOMATION_BYPASS_SECRET }}
```

## Async webhooks: the part everyone thinks is the blocker, and is not

A payment or messaging webhook posts to a fixed endpoint, and a per-PR URL is dynamic, so the
instinct is "webhooks cannot work on previews." They can, because **a webhook usually only writes to
the database; it does not run the code under test.** When the preview shares the non-prod backend:

1. The preview app creates the payment (test keys), tagged with the customer and amount in metadata.
2. The browser pays. The provider fires the event to the **non-prod account's already-registered webhook**, which credits the **shared** database by customer id, not by URL.
3. The preview reads that same shared database and sees the credit.

The credit lands regardless of which deployment processed the webhook, because it resolves against
shared state. So the full pay-to-outcome journey runs on the preview with zero per-PR webhook setup.
**One thing to confirm:** if the webhook filters events by an environment tag (some do, for CI
isolation), the preview's non-prod flag must be set to the value the webhook credits, or the payment
lands but the balance never updates. The one real exception: **if the PR changes the webhook handler
itself,** the webhook is the code under test, and only then do you forward events to the preview with
the provider's local-dev pattern (a CLI listener forwarding to the preview URL, with the preview's
webhook secret set to the listener's secret).

## Database options, by effort

- **Reuse the non-prod project (least effort, default).** Point preview env at the existing non-prod database. Safe to share because black-box tests provision through the app and assert on deltas, not absolute state, so they need no teardown and repeat cleanly (see `functional-methodology.md`, "provision through the app's own surfaces").
- **Database branching (isolated per PR).** A branching integration auto-provisions an ephemeral database per PR with migrations and seed applied. Perfect isolation, more moving parts.
- **A dedicated test project.** A second persistent database only for previews. Middle ground.

## Two tiers, split by cost and purpose

- **Watched tier, every deploy:** the `@watched` black-box subset (the security invariants plus the one or two revenue-critical journeys), against the per-PR preview. This is the standing guard and finishes in a couple of minutes.
- **Full regression, on-demand or nightly:** the whole seeded suite (DB preconditioning, device matrix), on `workflow_dispatch` plus a cron, against local or staging.

Why the split saves time: a suite run against a dev server pays a cold per-route compile every run,
uncached, and if `workers` is 1 it pays them serially. A preview is a compiled build, warm, so the
per-route tax disappears. Do not test a dev server in CI; test a compiled build (the preview, or a
production build served locally).

## Shared-state caveats (small, real)

- A shared database plus one fixed test identity means concurrent runs can collide. Allocate a test identity per PR (PR number modulo the available pool), or run the watched job at concurrency 1 per repo (a `concurrency:` group on the workflow).
- Reuse-and-assert-deltas is the discipline that makes a shared backend safe. If a test asserts absolute state, it will flake under concurrency; assert the change it caused, tagged with a per-run marker.

## Proving teeth against an immutable preview

A preview deployment cannot be edited, so you cannot revert files "against the preview." Prove a
test has teeth on a **local compiled build or the dev stack**: for a functional journey, revert the
app files under test, run red, restore, run green. For a security invariant that was never broken,
transiently weaken the specific check, watch the test go red, then restore immediately and confirm a
clean tree. This is local only, never committed. The preview lane itself proves out on the first real
PR after merge (see the default-branch note above); do not claim the auto-trigger is proven before it
can be.

## What `launchguard init` does with this (additive, non-destructive)

`launchguard init` ADDS a test layer and verifies the environment. It never changes the user's
deployment config, env vars, or secrets, and never edits app code. It:

- Adds the watched Playwright config, the two-tier workflows (with the pinned environment name and the `workflow_dispatch` fallback), and conservative defaults, as new files that do not touch the existing config.
- Reads the environment to confirm the test layer will target it (target resolution, whether a bypass secret is needed and exists, the non-prod flag). It reports anything missing; it does not provision it.
- Knows that shared-backend webhooks resolve against shared state, so it does not force per-PR webhook infra unless the webhook is the code under test.

The environment is the user's to own; this doc is the strategy. Repo-specific facts (the exact flag
name and value, the layout, any quirks) live in that repo's own `.launchguard/APP-PROFILE.md`, never
here.
