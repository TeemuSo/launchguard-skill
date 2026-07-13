# INIT: add continuous black-box e2e to the user's own repo (you do this, not the user)

Load this when the user says "set up LaunchGuard on this repo", "wire LaunchGuard into my CI",
"watch this app on every deploy from my repo", or "init LaunchGuard". You ADD a test layer; you do
not configure their infrastructure. Read `reference/environment-and-ci.md` first.

## Non-negotiables

- **Additive, with exactly one sanctioned edit.** You ADD new files (the watched config, the workflow, `.launchguard/`, new specs). The ONE edit allowed to an existing file is **adding a `@watched` tag to a spec you are promoting**. Nothing else in an existing file changes. Never touch app code, the existing `playwright.config.ts`, or any other existing file, and never overwrite a file without asking.
- **Never touch infrastructure.** No `vercel env`, no `gh secret set`, no Vercel project settings. You READ the environment to target it; you never change it. If a prerequisite is missing, REPORT it and continue with everything that does not depend on it.
- **Kit files are starting points, not truth. Reconcile every default against THIS repo before shipping it** (Step 1). A template that does not fit the repo is how the watched tier silently never runs.
- **Test the per-PR deployment, never a branch alias** (`deployment_status.target_url`, supplied at run time).
- **A pass is a positive signal, never silence** (`reference/methodology.md`, `.launchguard/assert.ts`). This binds the kit too: an absent check reads as green, so a workflow that never fires is a silent failure. Prove the lane runs (Step 4).

## Step 0 — Detect the repo (do not ask what you can read)

- Stack + host: Next.js on Vercel? (`next.config.*`, `vercel.json`, a linked project). If not Vercel, adapt the target-URL source (still the per-PR deployment).
- App package dir and test dir (sets `working-directory` and `testDir`).
- **Is deployment protection even ON?** If previews are publicly reachable, you need NO bypass secret and NO bypass header. Do not add or flag either. Only wire the bypass when protection is actually on. Check before assuming.
- The non-prod flag: grep the auth/OTP/SMS code for the flag that enables test affordances (a magic OTP, skipping real sends) on a hosted deploy. On a hosted deploy `NODE_ENV` is always `production`, so it is usually a separate env var. Record the exact var and the value that turns it on. **Then check whether that same flag is load-bearing elsewhere** (a webhook that only credits events tagged with a given environment, a feature gate). It often is; a wrong value makes a flow time out with no error.
- Existing app playbook + any existing black-box spec (provisions through the app, no DB seeds). These become the profile and the first watched spec candidate.
- **The repo's existing CI decisions.** Read the current e2e workflows. If a journey makes a real payment, it likely runs one browser only and no retries on purpose (a retry pays again). Your kit defaults must not override those decisions.

## Step 1 — Add the kit, reconciled to the repo

Copy from `init-kit/` (in this skill directory): `.launchguard/`, `playwright.launchguard.ts`,
`.github/workflows/launchguard-watched.yml`. Then reconcile each against Step 0:

- **The workflow trigger is the classic silent-death trap. Pin the real environment name.** `deployment_status.environment` is the Vercel project's environment name, which on a multi-project repo is like `Preview – <project>` (note: an en-dash, and one per project). Enumerate the real names and pin the exact one for the app:
  `gh api repos/{owner}/{repo}/deployments --paginate --jq '.[].environment' | sort -u`
  Set the workflow `if:` to that exact string. `== 'Preview'` will silently never match.
- **`playwright.launchguard.ts`:** set `testDir`; set the project list to match the repo's real constraints. If a watched journey makes a real payment, ship it chromium-only and retries 0 (the kit defaults there already, but confirm you did not widen them).
- **The workflow's `concurrency:` group stays** (a shared non-prod backend plus a fixed test identity means two PRs running at once collide). If the repo already serializes e2e differently, match that instead.
- **`launchguard-watched.yml`:** set `working-directory`; fill companion services and app env from the profile (e.g. a separate static site a flow needs, served in the job and pointed at the preview).
- **`APP-PROFILE.md`:** fill from Step 0, or point it at the existing playbook.

## Step 2 — Verify the environment (READ ONLY)

Confirm the test layer targets correctly; change nothing.

1. **Target.** Read the repo's target resolution (e.g. `tests/helpers/target.ts`). Confirm the watched config takes `TARGET_URL` at run time; the workflow supplies it from `deployment_status.target_url`.
2. **Bypass, only if protection is on** (Step 0). If on, check `gh secret list` for the bypass secret and, if missing, name it for the user. If protection is off, skip this entirely.
3. **The non-prod flag on Preview.** Confirm the value the app needs (and that any webhook/feature gate keyed on the same flag agrees). Do NOT set it; if you cannot confirm, say so.

## Step 3 — Author the first @watched tests (two, no more)

- **One security invariant the app can actually leak:** cross-customer read. Provision two identities through the app, read B's object as A, assert with `expectNoForeignRows`. B must actually have data first, or a green is meaningless.
- **One revenue-critical journey** that already exists as a black-box spec: add the `@watched` tag (the sanctioned edit). If none exists, author one, provisioning through the app, asserting on deltas with a per-run marker.

Every watched test: black-box, two gates (reached-the-state, then the outcome), waits on state not time.

## Step 4 — Prove teeth LOCALLY, and prove the lane fires

A preview deployment is immutable, so you cannot revert files "against the preview." Prove teeth on a
**local compiled build or the dev stack** instead:

- For a **functional** journey: revert only the app files under test, run red, restore, run green, confirm a clean tree (`git status --short`).
- For a **security invariant that was never broken**: there is nothing to revert, so transiently weaken the specific check (comment out the auth guard), run and watch the test go RED for the right reason, then **restore immediately** and confirm green and a clean tree. This transient sabotage-restore is the sanctioned way to prove a never-broken invariant has teeth. It is local only, never committed, never pushed.
- **The preview lane itself proves out on the first real PR after merge, not now.** `deployment_status` workflows only run from the workflow file on the default branch, so the PR that adds the workflow cannot fire it. That is why the kit workflow also has a `workflow_dispatch` with a `target_url` input: dispatch it manually against a known preview URL to prove the lane green before you rely on it. Say this to the user; do not claim the auto-trigger is proven when it cannot be yet.

## Step 5 — Post the proof and report

- Publishing the proof sends screenshots and verdicts to an EXTERNAL service (a public LaunchGuard URL). Say so and get a yes before posting. The exact contract (endpoint `https://www.launchguard.dev/api/proof`, the criteria/subchecks JSON, the local paired-evidence gate) is in the `visual-correctness` skill; follow it rather than improvising a payload.
- Report in chat, plain language: what you added, what runs per PR (and that the auto-trigger proves on the first merged PR), which guarantees are watched, and any prerequisite the user must supply (the exact one-liner and single value). Never leave a filepath as the deliverable.

## What genuinely needs the human

- A secret/token you must not create (the bypass secret if protection is on, a payment key). Name it and the one value; do everything else around it.
- A product judgment on what "this flow succeeded" means when ambiguous. Ask one crisp question.
