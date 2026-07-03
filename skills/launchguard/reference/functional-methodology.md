# Functional methodology — the discipline that turns a script into a real deploy-gate

Read this BEFORE you author any **functional** chain — a chain whose job is to prove a critical user
journey **still works** after a deploy. It is the functional counterpart to the security
`methodology.md`. Where the security methodology disciplines an agent biased toward "VULNERABLE:
CRITICAL," this file disciplines an agent biased toward "the test went green." A functional chain
that passes by accident is worse than no chain: it gives the user a false "your signup still works"
right up until a customer can't sign up.

A functional chain runs the **same rails** as a security script chain — a self-contained
`@playwright/test` spec, stored and re-run by LaunchGuard with a captured session — but with
`intent:"functional"`. The verdict meaning flips: **PASS = working (green), an assertion FAIL =
broken (red), ERROR = inconclusive.**

The core failure this prevents: a flow that silently lands on an error page, a login redirect, or an
empty shell while a loose assertion (`await page.goto(...)` with no follow-up `expect`) still goes
green. That is **pass-by-accident**, and it is to functional testing what the false positive is to
security testing. The two-gate rule below is the cure.

> A functional chain is a **script** chain (`artifact:"script"`), not the HTTP request-plus-matcher
> chain in the "Bring Your Own Test" section of SKILL.md. The spec is a Playwright test the runner
> executes in a headless browser. The Proof vs Guard distinction (`watched`) applies to it exactly as
> it does to HTTP chains — see "Proof vs Guard" in `chains-reference.md`.
>
> **To INGEST one, follow `chains-reference.md` §12 — the script-chain ingest contract — exactly.** The
> body is FLAT: top-level `artifact:"script"` + the Playwright spec as a top-level `script` STRING (it
> is stored and read back at `spec.script.source`), with the `// @lg-intent:` / `// @lg-secure-when:`
> header tags **declared in the source, colons required**. Do NOT send `spec.steps` / `spec.assertion`
> — if you do, the HTTP runner silently wins and your script is never executed (§12's footgun). An
> authenticated functional chain references a captured session by top-level `credentialId` (§9).

> **⚠️ PLAN GATE — running a functional/script chain is a real-browser run, which is PRO.** A functional
> chain executes a Playwright spec in a real/hosted browser. Running a chain in a real/hosted browser
> (`artifact:"script"`, Browserbase) is PRO — a non-Pro caller gets `402 browser_testing_requires_pro`.
> A chain carrying a stored credential (an authenticated functional chain via `credentialId`) is also Pro
> (`402 stored_credentials_require_pro`). So a functional/script chain runs — and re-runs as a Guard on
> every deploy — ONLY on a confirmed-Pro account. **When authoring for a FREE or unknown-plan account,
> DEFAULT TO HTTP-artifact chains** (the request-plus-matcher chains in `CHAINS.md`: HTTP runs, including
> HTTP cross-tenant, are FREE and unbounded); author script/browser chains only when the account is
> confirmed Pro, and branch on the live server signal (`402` / `requiresPro`), never a hardcoded tier.
> (The free own-machine counterpart is **LaunchProof** — a local Playwright e2e harness that runs
> real-browser proof in the user's OWN browser on their OWN machine at zero hosted-browser cost; the
> HOSTED browser e2e we run is Pro.)

---

## Contents

- **Step 1 — PICK** the right functional chains (revenue-critical, deterministic, two-gate-able)
- **Step 2 — the TWO-GATE pattern**: gate (a) desired-state reached, gate (b) acceptance criteria
- **Step 3 — determinism / anti-flake** rules
- **Step 4 — cost & intent** for expensive/irreversible steps (scan spend, checkout, login email)
- **Step 5 — verdict mapping**: PASS = `fixed` = working, FAIL = `vulnerable` = broken, ERROR = `inconclusive`
- **Step 6 — Proof or Guard?** (`watched`); watching a script chain is Pro (`402 browser_testing_requires_pro`)
- **Quick pre-authoring checklist** + **What still needs a human**

---

## Step 1 — PICK the right functional chains (don't test everything)

A functional chain that you **watch** (a Guard) costs a re-run on every deploy, forever. Spend that
budget on the journeys that **earn or retain revenue**, are **deterministic**, and have a **crisp
acceptance criterion**.

Pick a flow only if all three hold:

- **Revenue- or retention-critical.** Signup/auth, the core value action (kick off the work, see the
  result), the paywall/checkout handoff, the defensible product surface (author a test, run a test),
  the dashboard/account surfaces that keep a paying user. If a deploy breaking it would cost a signup,
  a conversion, or a renewal — test it. A cosmetic tweak that breaks nothing the user pays for — skip
  it.
- **Deterministic.** The flow produces the **same observable outcome every run** from a known starting
  state. If the outcome depends on a fresh LLM completion, a third party's mood, or a race, it is not
  a functional chain — it will flake red and the user will mute it. (The security suite's "one false
  alarm and they mute you forever" lesson applies identically.)
- **Two-gate-able.** You can name BOTH a *desired-state* signal (you reached the right place) AND an
  *acceptance* signal (the right thing happened). If you can only assert "no exception thrown," the
  flow isn't ready to be a chain yet — find the stable signal first.

> Do: "Scan kickoff is the free funnel; it deterministically returns a `scanId` + `streamUrl`; I can
> gate (a) on `status === 200` and (b) on a non-empty `scanId`. Good chain."
>
> Don't: "Let me chain the homepage hero animation." (Not revenue-critical, no crisp acceptance
> signal, will flake on timing.)

---

## Step 2 — The TWO-GATE authoring pattern (the spine)

Every functional chain asserts **two** things, in order:

- **Gate (a) — DESIRED STATE REACHED.** Prove the precondition/navigation *actually happened* before
  you assert the outcome. Assert you're on the authenticated page (`toHaveURL`), the request reached a
  real identity (`expect(status).not.toBe(401)`), the expected element/route resolved
  (`toBeVisible`). **Never accept "no exception was thrown" as gate (a).** A `page.goto()` that 302s
  to `/sign-in` throws nothing — without gate (a), a loose acceptance assertion downstream can still
  go green against the login page.
- **Gate (b) — ACCEPTANCE CRITERIA.** The actual `expect()` for the flow — the outcome the user came
  for.

Wrap **each gate in its own named `test.step()`**. The step names are the pre-run checklist a user
sees before the run and the live timeline during it, so make the desired-state step a *named, visible*
step — a reviewer reading the checklist should see the chain proves it reached the page before it
judged the page. (This is the `test.step()` authoring contract the UI surfaces.)

### Concrete example — "free user is paywalled on a Pro action"

```ts
// @lg-intent: functional
// @lg-secure-when: pass   // functional: PASS = the flow behaves as required

import { test, expect } from "@playwright/test";

test("free user hits the Pro paywall", async ({ page, baseURL }) => {
  // Gate (a): DESIRED STATE — prove the request reached a REAL authenticated identity,
  // not the anonymous 401 an unauthenticated probe would see. Without this, a 401 from a
  // dropped session would look like "the gate fired" and pass by accident.
  const probe = await test.step("Reach the gate as an authenticated free user", async () => {
    await page.goto("/", { waitUntil: "domcontentloaded" });
    await expect(page).toHaveURL(new RegExp(`^${baseURL}/?$`)); // we are really on the app, with our session
    const res = await page.evaluate(async () => {
      const r = await fetch("/api/guard/chains/00000000-0000-0000-0000-000000000000/ai-verdict", {
        method: "POST",
      });
      return { status: r.status };
    });
    expect(res.status).not.toBe(401); // <-- the desired-state gate: we are NOT anonymous
    return res;
  });

  // Gate (b): ACCEPTANCE — the paywall actually enforced for this free identity.
  await test.step("Assert the paywall fired (402 pro_required)", async () => {
    expect(probe.status).toBe(402); // the real acceptance criterion
  });
});
```

The same skeleton applies to a render flow: gate (a) = `await page.goto(path)` then
`await expect(page).toHaveURL(path)` **and** the page shell is present (not redirected, not an error
boundary); gate (b) = the specific region the user needs (`await expect(findingsList).toBeVisible()`).

---

## Step 3 — Determinism / anti-flake rules

A flaky functional chain is a liability — it cries wolf, the user mutes it, and a real break later
ships silently. Author for determinism:

- **Wait on STATE, never on time.** Use Playwright **web-first** assertions
  (`toBeVisible`, `toHaveURL`, `toHaveText`) and explicit `waitForResponse`/`waitForURL`. **No
  `waitForTimeout(...)` / arbitrary sleeps** — they're either flaky or slow, never both-safe.
- **Assert on STABLE signals, located the way a user perceives them.** Prefer role / accessible label /
  visible text; a route or a status code; a stable heading — over a CSS class, a structural XPath, a
  localized string marketing rewrites weekly, or an animation frame. Use an explicit `data-testid` where
  the app already exposes one, but black-box against a deployed app you usually cannot add hooks to the
  source, so role/text is your primary tool, not a fallback.
- **One acceptance per chain.** Keep gate (b) to a single, crisp criterion. A chain that asserts five
  loosely-related things has five ways to flake and tells you nothing precise when it breaks.
- **Provision preconditions through the app's own surfaces, every run.** Black-box, you cannot touch the
  database — so if a chain needs a known scan/app/conversation to exist, create it as a **setup step**
  through the product's real UI or API, the same path a user would, never depending on "whatever happens
  to be there." **Tag each run's created data with a unique marker** (a per-run id in the name/message)
  and assert on that marker: with no database to reset, **uniqueness — not cleanup — is what keeps a
  re-run from colliding with a past one.**
- **No retries — author so green means green.** The runner runs with no retries so a real FAIL is
  deterministic. Author so a green run is green for the right reason, not because a retry papered over
  a race.
- **Pin the identity to a repeatable session.** Prefer a **captured `storageState`** when the login is
  non-deterministic or expensive — a real magic-link/email round trip, MFA, an SMS OTP to a real phone —
  because re-driving it every run flakes on delivery. Upload that session once as a credential and
  reference it by top-level `credentialId` at ingest (lifecycle in `chains-reference.md` §9; placement in
  §12). When the login is **deterministic** instead — a fixed test OTP or test password with no real
  email/SMS — driving it inline in the script is equally repeatable, self-refreshing (nothing to
  re-capture when a session expires), and re-tests the login itself; either is valid. Keep a dedicated
  magic-link round-trip chain as its own single chain.

> **Context-dependent — decide per chain, don't hardcode a side.** A few choices have no single right
> answer; pick by the situation rather than a blanket rule:
> - **Locator:** user-perceivable (role/label/text) vs an explicit `data-testid` — prefer the former;
>   reach for a test-id only where semantics are absent and the app already exposes one.
> - **Identity:** captured session vs inline deterministic login — non-deterministic logins get captured,
>   deterministic ones can go either way.
> - **Retries:** a retry is a diagnostic, not a fix. A chain that only goes green on a retry is still
>   flaky — investigate it; never paper a real break over with re-runs.
> - **Isolation:** a shared reusable identity is fine only for flows that don't mutate durable server
>   state; use a fresh/unique identity when they do.
> - **Live vs mocked dependencies:** against a live deployed target you usually cannot and should not mock
>   the app's own backend — the point is the real integrated system. Don't apply "mock third parties" as a
>   default.

---

## Step 4 — Cost & intent for expensive/irreversible steps (light touch)

There are **no** throwaway-account or data-hygiene rules here — tenant-scoped writes (RLS) are
reversible, so database "pollution" isn't a concern. Two small, practical rules:

- **The one real recurring cost is LLM/scan spend.** A chain that fires a **real scan on every deploy
  burns model tokens.** So for scan-triggering flows, **prefer asserting the scan was QUEUED over
  running a full scan.** The scan's token spend happens when the browser opens the SSE `streamUrl`,
  **not** when `POST /api/scan` returns (that route just inserts a `scans` row and mints the
  `streamUrl`) — so a kickoff chain that asserts `200` + a `scanId` + a `streamUrl` and **never opens
  the stream** proves the funnel without burning tokens. The real cost control is **target
  selection**: only point the tool at domains you're comfortable spending money on. There is no clever
  in-chain safeguard that substitutes for that.
- **For checkout and login, assert the INTENT, not the completed action** — which is just the two-gate
  rule applied:
  - **Checkout.** There is **no payment card on the account, so checkout can never complete a real
    charge.** A checkout/paywall chain simply asserts the **session was created / the redirect
    happened** (e.g. `checkoutUrl` starts with `https://checkout.stripe.com/`). Don't auto-complete
    payment; don't forge a signature-verified webhook. Checkout is not a recurring-cost risk.
  - **Login email.** A magic-link login round trip is the **only** chain that reads a real inbox. Keep
    it as one dedicated chain. **Every other authenticated chain uses a captured `storageState`** and
    never touches email — drive the session, don't re-login on every deploy.

---

## Step 5 — How `intent:"functional"` maps to verdicts

Functional chains flow through the **identical** verdict lifecycle as security script chains (store →
run → verdict → regression → list/dedupe). Only the *meaning* of the verdict flips, because the
security convention is "secure-when-pass":

| Playwright result | Verdict | Functional meaning |
|---|---|---|
| all `expect()` PASS | `fixed` | **WORKING / GREEN** — the flow behaves as required |
| an `expect()` assertion FAILs | `vulnerable` | **BROKEN / RED** — the flow regressed; surfaces with `regression:true` if it was green before |
| ERROR / timeout / no tests | `inconclusive` | **INCONCLUSIVE** — the run was unsound; never a false "broken" or false "working" |

Render `fixed` → **green "working"** and `vulnerable` → **red "broken"** for functional chains. Never
show a user "vulnerable" for a broken signup. The live `done` event already carries an intent-framed
`health` field (`healthy` / `broken` for functional, `secure` / `vulnerable` for security) — use it so
the wording matches the intent.

Crucially, the **FAIL-vs-ERROR split is what makes a functional chain trustworthy**: a flake (network
blip, timeout, infra hiccup) routes to `inconclusive`, **never** to a false red. That's the same
robustness that lets the security suite run at zero false alarms.

**Author so the two gates land on the right side of this table:** gate (a) failing means *the test
couldn't even reach the flow* — author it as a hard `expect` so it surfaces as a real RED you
investigate (a vanished session, a route that 404s), not a silent green. Gate (b) failing is the
genuine "the feature broke" RED you ship the alert on.

---

## Step 6 — Proof or Guard? (does this functional chain re-run on every deploy?)

A functional chain is one of two classes, exactly like an HTTP chain (see "Proof vs Guard" in
`chains-reference.md`):

- **Proof** (`watched: false`, **the default**) — you author it, run it once to confirm the flow works
  right now, report the verdict, and it stays as stored evidence. It does **not** re-run on deploy.
- **Guard** (`watched: true`) — it joins the deploy-replay suite and re-runs on every detected deploy,
  alerting on regression (a `fixed`/working chain that comes back `vulnerable`/broken).

**Most functional chains are worth watching** — proving a flow "still works after a deploy" is the
whole point of a deploy-gate, so a functional Guard is the natural goal. **But a watched functional Guard
re-runs a real/hosted browser on every deploy, which is metered Pro compute — so continuous browser
watching is a PRO capability, and a non-Pro deploy re-run is refused with `402 browser_testing_requires_pro`.**
On a FREE or unknown-plan account, don't promote a script chain to a Guard; guard the invariant with an
HTTP-artifact chain where it can be expressed as HTTP (free, unbounded), or hand the browser proof over as
LaunchProof to run on the user's own machine. But still **default to Proof
and promote deliberately**: confirm the chain is green and non-flaky on its first run, then set
`watched: true` (ingest it that way, or `PATCH /api/v1/chains/<id> { "watched": true }`). Promoting a
flaky chain to a Guard is how you teach a user to mute LaunchGuard. Only watch a chain you've seen pass
cleanly for the right reason.

---

## Quick pre-authoring checklist (copy into your notes, fill per chain)

```
PICK
  [ ] Revenue/retention-critical?  [ ] Deterministic from a known start?  [ ] Both gates nameable?
  -> any "no" => don't author it yet.

TWO GATES (each in its own named test.step())
  [ ] Gate (a) DESIRED STATE: asserted reached (toHaveURL / not 401 / element visible) — NOT "no throw"
  [ ] Gate (b) ACCEPTANCE: the one crisp expect() for the outcome

DETERMINISM
  [ ] Web-first waits on state, zero waitForTimeout  [ ] Stable signals (role/text/route/status; testid if present)
  [ ] Preconditions provisioned via app surfaces + unique marker  [ ] Identity: captured session, or inline deterministic login

COST / INTENT (light touch)
  [ ] Scan-triggering? -> prefer asserting QUEUED over running a full scan (tokens cost money).
      Don't open streamUrl on a kickoff chain. Cost control = only target domains you'll pay to scan.
  [ ] Checkout/login -> assert the INTENT (session created / redirect happened); no card on account.
  [ ] Authed chains use captured storageState; only the one login chain reads the inbox.

VERDICT MAPPING
  [ ] PASS=fixed=working/green  [ ] FAIL=vulnerable=broken/red  [ ] ERROR=inconclusive (flakes land here)

PROOF vs GUARD
  [ ] Author as Proof; run it once; only set watched:true after a clean, non-flaky green.
```

---

## What still needs a human (don't fake these)

- **Is this flow's "done" really this signal?** Sometimes the crisp acceptance criterion is a product
  judgment (what does "the dashboard loaded successfully" mean for THIS app). Read the code, make a
  call, ask one question on ambiguity.
- **Durable test identities.** Re-run-forever logged-in chains need durable captured sessions. How
  those are minted and refreshed is an infra/product decision — surface it, don't hand-wave a flaky
  live login into the chain.
