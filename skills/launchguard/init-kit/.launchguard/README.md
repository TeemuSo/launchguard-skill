# LaunchGuard e2e kit

Drop this folder at your repo root. It guides an agent (Claude Code) through generating and running
black-box end-to-end tests that gate every PR: the machine describes the flow, writes a test that
fails on the current code and passes after the change, and posts a proof a human reads in ten seconds.

You are the PM (write the issue) and the QA reviewer (approve the green PR plus proof). You never read
test code.

## The loop, start to finish

1. **Issue.** Describe the feature or bug in plain language, with acceptance criteria. This is the spec.
2. **Setup the environment (once per repo).** The test must run against the PR's own build with a working backend. See "Environment" below and `environment-and-ci.md` in the skill. The rule: test the per-PR deployment, never a shared branch alias, and reuse your existing non-prod backend through env, never a code change.
3. **Pick the flow.** Only revenue-critical, retention-critical, or security-invariant flows earn a watched test. A cosmetic tweak does not.
4. **Author the black-box test.** Standard Playwright, driven from a URL, provisioning through the real app (no DB seeds, no mocks). Follow the authoring discipline: `functional-methodology.md` (does it still work) and `methodology.md` plus `invariants.md` (is it still secure). Two gates per test: prove you reached the state, then assert the outcome. A pass is a positive signal, never silence.
5. **Prove fail-on-base, then green.** Revert only the app files the PR changed, run the test, watch it go red for the right reason, restore, watch it go green. Red on the current code is the witness that the test has teeth.
6. **Wire CI.** The `@watched` subset runs on every PR against the per-PR preview, in parallel. The full seeded suite runs on-demand or nightly. See `environment-and-ci.md`.
7. **Post the proof.** Emit the structured proof payload to `POST /api/proof` and share the public URL on the PR (the `visual-correctness` skill owns this contract). The green check plus the proof page is what the reviewer approves.
8. **Accumulate.** Any discovery that cost more than ~15 minutes becomes one line in `APP-PROFILE.md`, in the same PR. The suite and the profile grow together.

## Environment (fill in `APP-PROFILE.md`, then verify)

The test target is the per-PR deployment URL, resolved from the deployment event
(`deployment_status.target_url` on Vercel), with the protection-bypass header. The app runs the PR's
code pointed at a non-prod backend supplied entirely through preview-scoped env vars:

- Database: your existing non-prod project's URL and keys.
- Payments: your non-prod test-mode keys (test cards only function in test mode).
- The non-prod flag your app already uses to enable test affordances (a magic OTP, skipping real SMS/email). On a hosted deploy `NODE_ENV` is always `production`, so this is a separate env var you already set on your non-prod environment. Set it on preview too.

If a webhook credits state (payment, messaging), it resolves against the shared backend, so it does
not need to reach the preview unless the PR changes the webhook handler itself. Full detail and the
worked example: `environment-and-ci.md`.

## The non-negotiables (why this is trustworthy, not just green)

- Black-box only: a test gets a URL and provisions through the app. It survives refactors.
- A pass is a positive signal (a real 401/403 for a security denial, a real outcome for a functional flow), never an empty response or "no error thrown."
- Fail-on-base is mandatory. A test that never failed proves nothing.
- Determinism: wait on state, never on time. Assert on stable signals (role, text, route, status), not CSS or animation frames.
- No app code changes to make a test pass. The switches you need already exist as env flags.

## Where the depth lives

The authoring discipline and the environment strategy are the LaunchGuard skill's reference docs
(installed with the plugin): `functional-methodology.md`, `methodology.md`, `invariants.md`,
`environment-and-ci.md`. This kit is the orchestration; those are the detail.
