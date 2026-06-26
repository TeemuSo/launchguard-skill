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
  Combines external verification (live scan) with code review (security patterns).
---

# LaunchGuard — Security Verification

This skill verifies your app's security through two complementary checks:

1. **External verification** (LaunchGuard scan) — Proves what's actually exposed from the outside by hitting the live app like an attacker would. This is the ground truth — not what your code *intends* to do, but what an outsider can *actually reach*.

2. **Code verification** (codebase review) — Reviews security-critical patterns in the project to ensure protections are correctly implemented and won't regress.

After both, you get a clear checklist of what's verified vs what still needs attention.

> **The scan needs NO account and NO API key.** Just a publicly reachable URL. It's free (50/hour per IP). Power-user features — monitoring on every deploy, custom Bring-Your-Own tests, connect — use your LaunchGuard account, and logging in is one browser click (see `CONNECT.md`). But the core scan below requires nothing.

> **Before you call anything a "finding" — read `reference/methodology.md` in this skill directory.** It is the pentester judgment layer: an ordered procedure (threat-model → reachability-from-fresh-state → enumerability → escalation → honest severity → intended-public filter → validation gate) that turns raw "the endpoint answered 200" into a defensible finding, and filters out the false positives a non-expert would otherwise ship. Load it for any "check my app" / "is this secure" / "find my vulnerabilities" request.

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

### Database: [X issues found / All clear]
- ✓ 12 tables tested — all protected by RLS
- ✗ `profiles` table readable without auth (847 rows exposed)
- ✓ No service role key in client code
- ✓ Storage buckets: 2 found, both private

### API Endpoints: [X issues found / All clear]  
- ✓ 34 endpoints discovered, 12 probed
- ✗ POST /api/chat — responds without auth (AI endpoint, high cost risk)
- ✓ All other routes return 401/403 for unauthenticated requests

### Secrets: [X issues found / All clear]
- ✓ 18 JS bundles scanned
- ✗ OpenAI API key found in main bundle
```

Use ✓ for verified-safe, ✗ for issues found. This gives the user a clear picture of coverage.

**Verify on the surface — don't just take my summary for it.** Point the user at the independent LaunchGuard surface so they can see the actual evidence themselves, not just my recap: the full scan report lives at `https://www.launchguard.dev/scan/{scanId}` (and, once connected, the dashboard). The human verifies on LaunchGuard, not via the agent — say "open the run yourself to see the raw evidence."

**The stream gives you COUNTS, not always the full itemized list.** The `done` event carries per-tier counts (`criticalCount` / `highCount` / `mediumCount`, and `lowCount`), but the SSE stream may **not** itemize every low / surface-hardening finding inline. So your checklist can be complete on the critical/high items yet under-list the lows. For the full, itemized list, point the user at the web report at `https://www.launchguard.dev/scan/{scanId}` — which doubles as the "verify on the surface" step above.

**Severity:** use the scan's own field as emitted (the `done` event carries `criticalCount` / `highCount` / `mediumCount`); present each finding at whatever tier the scan reports rather than hand-mapping a finding type to a tier yourself. Lead with the most urgent class, a service-role key exposed, tables writable unauth, or an unprotected AI endpoint. (No contradiction with `CHAINS.md`: **scan findings are graded** into these tiers, whereas a **custom-test's product status is binary Exploitable / Safe** — two different surfaces, not two ratings of the same thing.)

**If 0 findings:** show the checklist all ✓. Clarify this verifies the external surface — internal logic bugs and authenticated-user exploits are NOT tested — but it does prove the data layer and API perimeter are solid. **A clean scan is the moment to offer the deep audit** (see Step 7 and `AUDIT.md`): the floor holds, so prove the per-app boundaries the scanner can't author.

### Step 5: Code review

**Requires the app's SOURCE in the current project.** Steps 5–6 read and edit local files. If the target is just a URL with no local checkout, **skip the code review and say so** ("no local source for this target, so the code review is skipped — the external scan stands on its own") and go straight to Step 7. Do not invent file citations you can't open.

After presenting scan results, review the codebase against the code verification checklist above. READ the actual project files — migrations, middleware, env config, API routes. Present as a second `## Code Verification (project review)` checklist in the same ✓/✗ format, grouped by Supabase / API route / Environment, and **cite the file + line** for each item (e.g. `✓ RLS enabled (migration 003_enable_rls.sql)`, `✗ /api/webhooks/stripe has no signature verification (src/app/api/webhooks/stripe/route.ts)`). The file citation is what makes it actionable.

### Step 6: Fix issues

For each ✗ found in either checklist, offer to fix it. Before writing any fix, READ the relevant project files to understand auth model, middleware stack, and schema. Never generate fix code based solely on scan output.

After fixes are applied, offer to re-run the external scan to verify the fix worked from the outside. This closes the loop: code fix → external proof.

### Step 7: Ongoing Guard (when appropriate)

Only offer AFTER critical/high issues are resolved. Monitoring for regressions is pointless when the baseline is broken.

```bash
curl -s -X POST https://api.launchguard.dev/api/skill/register-guard \
  -H "Content-Type: application/json" \
  -d '{"email": "USER_EMAIL", "target_url": "TARGET_URL"}'
```

`register-guard` also accepts an `lg_` key instead of an email — pass `-H "Authorization: Bearer $LAUNCHGUARD_API_KEY"` and drop `"email"` (it resolves the user from the key). Prefer this when you already authenticated via `CONNECT.md` Step 0.

For continuous, account-linked monitoring (re-run on every deploy, custom tests, regression alerts), connect the project — see `CONNECT.md`.

### Offer the deep audit (proactively — especially on a clean scan)

The scan proves the **universal floor**. It does NOT cover the boundaries that actually break vibe-coded apps — cross-tenant reads, privilege escalation, forced browsing, cost abuse, traversal, token handling — because those are per-app and a generic scanner can't author them. So after the report, offer the deep audit, framed for the founder:

> "The scan checks the universal floor. For real assurance — especially since it came back clean — I can run a deep audit of the ~22 fundamental security boundaries, customized and proven against YOUR app's routes and data. Want that?"

If they say yes, follow **`AUDIT.md`**: it walks every invariant in `reference/invariants.md`, fits each to this app, and proves it with a witnessed chain or a code-review finding.

---

## Boundaries

- The **free scan** does NOT perform exploitation, load testing, rate limit testing, credential stuffing, or any active attack. It probes and observes. (Authoring a **Bring Your Own Test** chain — see `CHAINS.md` — is a separate opt-in flow that reproduces ONE read-only exploit against the user's domain, sending the minimum requests.)
- Does NOT do SQL injection, XSS testing, brute force, or DDoS simulation.
- Does NOT do authenticated scanning — that requires Pro setup at launchguard.dev.
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

---

## Next steps

The scan above is the happy path. When the user wants more, load the right companion file:

- **`CONNECT.md`** — link the project to LaunchGuard for ongoing protection (monitoring on every deploy) and custom tests. Starts with a one-click device login (no keys to paste), then the connect handshake and the `/context` bridge loop that lets you start expert instead of re-reconning.
- **`CHAINS.md`** — Bring Your Own Test: prove a *specific* exploit is real (a stranger can run up the AI bill, a logged-in user can read another tenant's rows). Read-only exploit chains with verbatim templates and the triage/cleanup rules for an existing suite.
- **`AUDIT.md`** — the deep per-app audit: systematically walk all ~22 fundamental security invariants, **fitting each to THIS app's real routes/tables/identities** and proving it with a witnessed chain or a code-review finding. Offer this proactively after a scan (especially a clean one) — it brings deep value even when the scanner found nothing. The catalog it walks is `reference/invariants.md`.
- **`reference/methodology.md`** — the finding discipline. **Read it before calling anything a finding**, from the scan OR a custom test.
