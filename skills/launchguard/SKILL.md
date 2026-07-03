---
name: launchguard
description: |
  Security verification for web apps — proves what's actually exposed from the outside,
  then reviews code to ensure protections are correctly implemented.
  Use when the user says "scan my app", "is this secure", "check security", "check my supabase",
  "find vulnerabilities", "audit my API", "make sure this is safe before launch", or asks about
  RLS, exposed tables, API auth, or leaked secrets. Also use after deploying or before launch.
  Also use to "connect to LaunchGuard", "connect my Claude Code", or "watch this app on every
  deploy" — a lightweight link followed by one tailored, business-logic test.
  Also use to "clean up / manage / triage / dedupe / prune / review my LaunchGuard tests",
  "tidy my custom tests", "which guards can I archive", or to curate an existing chain suite.
  Also use to "verify a fix or PR works end-to-end", "prove signup/checkout/dashboard still
  works on every deploy" (functional regression), or "test as a real logged-in user, or as two
  different accounts/roles" (authenticated, captured-session); these run as chains (see CHAINS.md).
  Combines external verification (live scan) with code review (security patterns).
---

# LaunchGuard — Security Verification

This skill verifies your app's security through two complementary checks:

1. **External verification** (LaunchGuard scan) — Proves what's actually exposed from the outside by hitting the live app like an attacker would. This is the ground truth — not what your code *intends* to do, but what an outsider can *actually reach*.

2. **Code verification** (codebase review) — Reviews security-critical patterns in the project to ensure protections are correctly implemented and won't regress.

After both, you'll have a picture of what the scan saw and what the code review found — then you verify WITH the user what's actually a problem (vs intended-public), fix only what's real, and go deeper to prove the one boundary that matters.

> **You prove; LaunchGuard verifies.** You form the hypothesis — read the app and code, author the test. LaunchGuard reproduces it from scratch against the *live* target and returns the verdict: a hallucination check on you. Never call a boundary proven or safe from code-reading or a trace alone; report the run's verdict. The workspace code may not be what's deployed (other branch, un-pushed fix, stale checkout) — use it to find *where* to look, never as proof of what the live app *does*.

> **LaunchGuard also verifies that a flow WORKS (functional chains) and can run as a real authenticated user (captured-session chains), not just what's exposed.** See `CHAINS.md`.

> **The scan needs NO account and NO API key.** Just a publicly reachable URL. It's free (50/hour per IP). Power-user features — monitoring on every deploy, custom Bring-Your-Own tests, connect — use your LaunchGuard account, and logging in is one browser click (see `CONNECT.md`). **Authoring default (get this right up front):** for a FREE or unknown-plan account, author HTTP-artifact chains — authoring and HTTP runs (raw request replay, including HTTP cross-tenant) are free and unbounded, and free accounts keep up to 2 active saved chains; author a script / real-browser chain (`artifact:"script"`) only when the account is confirmed Pro. Branch on the live `requiresPro` / `402` signal, never a hardcoded tier. The full free/paid mapping (the `402` family, the fix's `locked:"signup"`) is the decision table in **Important notes** below. But the core scan below requires nothing.

> **Before you call anything a "finding" — read `reference/methodology.md` in this skill directory.** It is the pentester judgment layer: an ordered procedure (threat-model → reachability-from-fresh-state → enumerability → escalation → honest severity → intended-public filter → validation gate) that turns raw "the endpoint answered 200" into a defensible finding, and filters out the false positives a non-expert would otherwise ship. Load it for any "check my app" / "is this secure" / "find my vulnerabilities" request.

---

## Contents

- **What the external scan verifies** / **What the code review verifies** — the two checks
- **How to run** — Step 1 confirm target · 2 start scan · 3 stream · 4 report · 5 code review · 6 verify + fix (Phase A) · 7 prove one boundary (Phase B) · optional full deep audit
- **Boundaries** — what the free scan does and does not do
- **Communication** — non-technical framing
- **Important notes** — rate limit, scan link, the free/paid decision table (canonical in this skill)
- **Next steps** — `CONNECT.md`, `CHAINS.md`, `AUDIT.md`, `reference/methodology.md`

---

## What the external scan verifies

The scan hits your live, deployed app and produces evidence for each check:

- **Database (Supabase/Firebase):** anonymous table read (SELECT + row count) and write (INSERT/UPDATE/DELETE via rollback transactions); whether RLS is actually blocking, not just enabled; service-role key leaked in client JS; public/listable storage buckets; callable-without-auth RPC and edge functions; hidden tables accessible but not in code (PGRST205).
- **API endpoints:** routes that answer unauthenticated; what data they return without auth (body previews); cost-sinkhole risk (AI/email/compute callable unauth); publicly-exposed OpenAPI/Swagger specs.
- **Secrets:** API keys/tokens/credentials, service-role keys, and server-side env vars embedded in the client JS bundle.
- **Infrastructure:** live subdomains (attack-surface width) and the detected tech stack (to contextualize findings).

---

## What the code review verifies

After the scan, review the user's codebase for these patterns:

- **Supabase:** RLS enabled on every table (`ALTER TABLE ... ENABLE ROW LEVEL SECURITY` in migrations); a `CREATE POLICY` per table matching the auth model; service-role key never in client code (only `NEXT_PUBLIC_SUPABASE_ANON_KEY` exposed); admin operations go through API routes, not the client; storage bucket/object policies defined.
- **API routes:** auth middleware on every route that reads/writes user data; rate limiting on expensive (AI/email/SMS/compute) routes; no secrets in client bundles (keys in `.env`, never `NEXT_PUBLIC_`-prefixed); request bodies validated/typed; errors return generic messages, not stack traces or internal state.
- **Environment & deployment:** `.env*` in `.gitignore`; secrets in the host's env config (Vercel/Netlify), not in code; no debug/dev-only endpoints left ungated in production.

---

## How to run

### Step 1: Confirm the target

Ask the user for their deployed URL. Or look in their project (`.env.local`, `vercel.json`, `package.json`) for deployment URLs — but ALWAYS confirm before scanning. Must be publicly reachable (not localhost). If they haven't deployed yet, tell them to deploy first or use a tunnel like ngrok.

### Step 2: Start the external scan

```bash
curl -s -X POST https://www.launchguard.dev/api/scan \
  -H "Content-Type: application/json" \
  -d '{"url": "TARGET_URL", "client": "claude-code-skill"}'
```

Response: `{"scanId": "uuid", "streamUrl": "https://..."}`

### Step 3: Stream results

```bash
curl -sN --max-time 300 "STREAM_URL_FROM_STEP_2"
```

Use bash timeout of 600000ms. The stream URL may return HTTP 400 with `{"error":"..."}` if the target is unreachable — show that to the user.

SSE format: `event:` line + `data:` line (JSON) + blank line. Ignore unrecognized event types.

**Key events:**
- `phase` / `pipeline` — Progress updates. Keep user informed.
- `model` — Product summary and detected tech stack.
- `discovery` — Endpoints found by each tool.
- `endpoints_finalized` — The authoritative final endpoint list (use this as the canonical set, not the per-tool `discovery` events).
- `subdomains` — Subdomains discovered for the target (attack-surface width).
- `secrets` — Leaked credentials in JS. May not appear if none found.
- `supabase_findings` — Database security issues. May not appear if no Supabase detected.
- `probe_data` — Flagged API endpoints worth investigating.
- `done` — Scan complete: `findingCount`, `criticalCount`, `highCount`, `mediumCount`, stats.
- `error` — Scan failed with reason.

### Step 4: Present the verification report

Structure as a checklist — show what was verified and what the status is:

```
## External Verification (LaunchGuard scan)

Target: example.com | Scan ID: abc-123
Full report: https://www.launchguard.dev/scan/abc-123

### Database: [what the scan reached / all locked]
- ✓ 12 tables tested — all protected by RLS
- ✗ `profiles` answered reads without auth (847 rows)
- ✓ No service role key in client code
- ✓ Storage buckets: 2 found, both private

### API Endpoints: [what the scan reached / all locked]  
- ✓ 34 endpoints discovered, 12 probed
- ✗ POST /api/chat — responds without auth (AI endpoint, possible cost risk)
- ✓ All other routes return 401/403 for unauthenticated requests

### Secrets: [what the scan saw / none found]
- ✓ 18 JS bundles scanned
- ✗ a possible OpenAI API key in the main bundle
```

✓ = the scan confirmed this locked from the outside (a witnessed pass). ✗ = the scan could REACH it without auth — an OBSERVATION to verify with the user in Phase A (Step 6), not a verdict that it's a bug. This is a picture of what the scan saw, not a list of confirmed problems.

**Verify on the surface — don't just take my summary for it.** Point the user at the independent LaunchGuard surface so they can see the actual evidence themselves, not just my recap: the full scan report lives at `https://www.launchguard.dev/scan/{scanId}` (and, once connected, the dashboard). The human verifies on LaunchGuard, not via the agent — say "open the run yourself to see the raw evidence."

**The stream gives you COUNTS, not always the full itemized list.** The `done` event carries per-tier counts (`criticalCount` / `highCount` / `mediumCount`, and `lowCount`), but the SSE stream may **not** itemize every low / surface-hardening finding inline. So your checklist can be complete on the critical/high items yet under-list the lows. For the full, itemized list, point the user at the web report at `https://www.launchguard.dev/scan/{scanId}` — which doubles as the "verify on the surface" step above.

**Severity:** use the scan's own field as emitted (the `done` event carries `criticalCount` / `highCount` / `mediumCount`); present each finding at whatever tier the scan reports rather than hand-mapping a finding type to a tier yourself. Lead with the most urgent class, a service-role key exposed, tables writable unauth, or an unprotected AI endpoint. (No contradiction with `CHAINS.md`: **scan findings are graded** into these tiers, whereas a **custom-test's product status is binary Exploitable / Safe** — two different surfaces, not two ratings of the same thing.) Treat the scan's tier as an OBSERVATION to route through the intended-public / verify-with-the-user gate (Step 6), not a final verdict.

**If 0 findings:** show the checklist all ✓. Clarify this verifies the external surface — internal logic bugs and authenticated-user exploits are NOT tested — but it does prove the data layer and API perimeter are solid. A clean scan is not the end — it's where the real proof starts. Go straight to Phase B (Step 7): prove or break the one boundary that matters. (The full ~22-invariant audit in `AUDIT.md` is available as a heavier opt-in.)

### Step 5: Code review

**Requires the app's SOURCE in the current project.** Steps 5–6 read and edit local files. If the target is just a URL with no local checkout, **skip the code review and say so** ("no local source for this target, so the code review is skipped — the external scan stands on its own") and go straight to Step 7. Do not invent file citations you can't open.

After presenting scan results, review the codebase against the code verification checklist above. READ the actual project files — migrations, middleware, env config, API routes. Present as a second `## Code Verification (project review)` checklist in the same ✓/✗ format, grouped by Supabase / API route / Environment, and **cite the file + line** for each item (e.g. `✓ RLS enabled (migration 003_enable_rls.sql)`, `✗ /api/webhooks/stripe has no signature verification (src/app/api/webhooks/stripe/route.ts)`). The file citation is what makes it actionable.

### Step 6: Verify with the user, then fix only what's real (Phase A)

The scan produced OBSERVATIONS, not verdicts — a readable table or an answering endpoint may be public by design. Do NOT auto-fix everything the scan flagged. For each thing the scan reached (each ✗):

1. Surface it to the user as an observation, in plain language.
2. READ the relevant project files (schema, migrations, middleware, the route) to understand the code's intent, and apply the intended-public filter from `reference/methodology.md` (an aggregate counter, a published pricing list, or a public feed answering anonymously is NOT a finding).
3. Decide WITH THE USER whether it's intended-public or a real problem. LaunchGuard does not decide this; you and the user do.

Fix and prove ONLY the items the user confirms are real. Never generate fix code based solely on scan output — always READ the project files first. After a fix is applied, re-run the external scan to prove it closed the boundary from the outside: code fix → external proof.

### Step 7: Go deeper — prove or break the one boundary that matters (Phase B)

This step is the SAME for every outcome — a clean scan starts here directly, and a scan with findings arrives here after Phase A. It is NOT gated on clearing scan items; the deep proof is where the real value is, whatever the scan saw. The framing is outcome-neutral: a witnessed GREEN is as valuable as a RED, and you never manufacture a finding.

The perimeter scan proves the universal floor. It does NOT cover the per-app boundaries that actually break vibe-coded apps — cross-tenant reads, IDOR, privilege escalation, paywall bypass, cost abuse — because a generic scanner can't author them. The default deep step is ONE tailored test: connect the project (see `CONNECT.md`), read `/context`, author ONE tailored test, submit it as a saved Proof (`"watched": false`, the default), run it, and report the verdict. **The moment `POST /api/v1/connect` returns, show the human the `dashboardUrl` it hands back** (`https://launchguard.dev/app/<id>`) so they have a live page to follow along and run the test themselves while this step takes a few minutes (see `CONNECT.md`). Proving the boundary is FREE; watching it on every deploy is a separate follow-up the user opts into (below), not part of this first run.

To also turn on ongoing monitoring by email (re-run on every deploy, no connected agent needed):

```bash
curl -s -X POST https://api.launchguard.dev/api/skill/register-guard \
  -H "Content-Type: application/json" \
  -d '{"email": "USER_EMAIL", "target_url": "TARGET_URL"}'
```

`register-guard` also accepts an `lg_` key instead of an email — pass `-H "Authorization: Bearer $LAUNCHGUARD_API_KEY"` and drop `"email"` (it resolves the user from the key). Prefer this when you already authenticated via `CONNECT.md` Step 0.

For continuous, account-linked monitoring (re-run on every deploy, custom tests, regression alerts), connect the project — see `CONNECT.md`.

### Optional: the full deep audit (heavier opt-in)

Beyond the ONE tailored test in Step 7 (the default deep step), the full deep audit is the heavier, systematic option: it walks ALL ~22 fundamental security boundaries — cross-tenant reads, privilege escalation, forced browsing, cost abuse, traversal, token handling — fitting and proving each against YOUR app's routes and data, because those are per-app and a generic scanner can't author them. Offer it as the exhaustive pre-launch pass when the user wants more than the single Phase-B test, framed for the founder:

> "Step 7 proves the one boundary that matters most. For a complete pre-launch pass — whatever the scan came back — I can run a deep audit of the ~22 fundamental security boundaries, customized and proven against YOUR app's routes and data. Want that?"

If they say yes, follow **`AUDIT.md`**: it walks every invariant in `reference/invariants.md`, fits each to this app, and proves it with a witnessed chain or a code-review finding.

---

## Boundaries

- The **free scan** does NOT perform exploitation, load testing, rate limit testing, credential stuffing, or any active attack. It probes and observes. (Authoring a **Bring Your Own Test** chain — see `CHAINS.md` — is a separate opt-in flow that reproduces ONE read-only exploit against the user's domain, sending the minimum requests.)
- Does NOT do SQL injection, XSS testing, brute force, or DDoS simulation.
- The free external **scan** does NOT do authenticated scanning (it observes only the unauthenticated surface). Authenticated and multi-actor testing IS part of the product, via captured-session **chains** (see `CHAINS.md`): they run as a real logged-in user, or as two different accounts/roles. Per the decided axis (`MONETIZATION.md`), the one FREE "authenticated-style" run is the anonymous-key HTTP cross-tenant path: running a chain as HTTP (raw request replay, near-zero cost) is FREE and unbounded, including HTTP cross-tenant (the engine's own inline anon-signup mint). But a captured-session chain is a real-browser (script) run carrying a stored credential, so it IS Pro: a non-Pro caller gets `402 browser_testing_requires_pro` (real-browser run) or `402 stored_credentials_require_pro` (stored credential). So branch on the server's runtime entitlement signals (`requiresPro` / `402`), never on a hardcoded tier claim.
- ALWAYS confirm target URL with user before scanning. Only scan domains they own.
- ONLY report issues that appear in scan data or that you can see in the code. Never speculate.
- When presenting secrets, redact (show first 8 chars + "..."). Never output full keys.
- A clean external scan does not mean "fully secure" — say what it does and doesn't cover.

## Communication

Users are often non-technical builders (Cursor, Lovable, Bolt). Explain in business-impact terms. If you say "RLS" — immediately say what it means in plain language. Be honest about severity without causing panic.

## Important notes

- Scans are free, no account needed. Rate limit: 50/hour per IP (HTTP 429 if exceeded).
- All write probes use rollback transactions — nothing is modified on the target.
- Scan results link: `https://www.launchguard.dev/scan/{scanId}`
- **Free/paid boundary (canonical in this skill).** The rationale — "we gate the system of record, not the act" — lives in `MONETIZATION.md` (decided 2026-06-29; free browser proof cut 2026-06-30); do not re-derive it. What you branch on:

| Action | Free? | Server signal when gated |
|---|---|---|
| Anonymous scan, full findings, unlimited depth | Free | — |
| AI-authored fix, authenticated owner | Free | anonymous caller → `fixPrompt.locked: "signup"` (a signup wall, not a paywall; there is no `locked: "pro"` for the fix) |
| HTTP chain run (request replay), incl. HTTP cross-tenant | Free, unbounded | — |
| Saving custom chains | Free up to **2 active** (authoring + running are free; *storing* is the gate) | 3rd active ingest → `402 pro_required`, `reason: "free_chain_limit"` (archive one to free a slot; Pro = unlimited saved chains) |
| Real-browser / script run (`artifact:"script"`, Browserbase) | Pro | `402 browser_testing_requires_pro` |
| Running a chain carrying a stored credential | Pro | `402 stored_credentials_require_pro` |
| Active verification, AI verdict, stepped chains | Pro | `402 pro_required` |
| `byo_template` depth gates (`cost` / `idor` / `broken_access`) | current server enforcement | `requiresPro: true` on the `/context` `byo_template` row |

  Pro is also the persistence layer (stored sessions, on-deploy monitoring, memory). Always branch on the live signal (`requiresPro` / the `402` family / `locked`), never a hardcoded tier — server enforcement may still lag the decided axis. **Deprecated (gone):** the old `e2e_volume_requires_pro` reason and the per-host free-proof bound no longer exist; a non-Pro HTTP chain run is free and unbounded.

---

## Next steps

The scan above is the happy path. When the user wants more, load the right companion file:

- **`CONNECT.md`** — link the project to LaunchGuard for ongoing protection (monitoring on every deploy) and custom tests. Starts with a one-click device login (no keys to paste), then the connect handshake and the `/context` bridge loop that lets you start expert instead of re-reconning.
- **`CHAINS.md`** — Bring Your Own Test: prove a *specific* exploit is real (a stranger can run up the AI bill, a logged-in user can read another tenant's rows); prove a flow WORKS via a functional chain (PASS = green, e.g. verify a fix/PR end-to-end or guard signup/checkout on every deploy); and run captured-session authenticated tests as a real logged-in user, or as two different accounts/roles. Verbatim templates plus the triage/cleanup rules for an existing suite.
- **`AUDIT.md`** — the deep per-app audit: systematically walk all ~22 fundamental security invariants, **fitting each to THIS app's real routes/tables/identities** and proving it with a witnessed chain or a code-review finding. This is the heavier opt-in beyond the single tailored Phase-B test (Step 7), not the default deep step — reach for it when the user wants a systematic pass over every invariant. The catalog it walks is `reference/invariants.md`.
- **`reference/methodology.md`** — the finding discipline. **Read it before calling anything a finding**, from the scan OR a custom test.
