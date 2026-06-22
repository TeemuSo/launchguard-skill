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
  Combines external verification (live scan) with code review (security patterns).
---

# LaunchGuard — Security Verification

This skill verifies your app's security through two complementary checks:

1. **External verification** (LaunchGuard scan) — Proves what's actually exposed from the outside by hitting the live app like an attacker would. This is the ground truth — not what your code *intends* to do, but what an outsider can *actually reach*.

2. **Code verification** (codebase review) — Reviews security-critical patterns in the project to ensure protections are correctly implemented and won't regress.

After both, you get a clear checklist of what's verified vs what still needs attention.

---

## What the external scan verifies

The scan hits your live, deployed app and produces evidence for each check:

### Database layer (Supabase/Firebase)
| Check | What it proves |
|-------|---------------|
| Table read access | Whether anonymous users can SELECT from each table (+ row count if exposed) |
| Table write access | Whether anonymous users can INSERT/UPDATE/DELETE (tested via rollback transactions) |
| RLS enforcement | Whether row-level security is actually blocking queries, not just enabled |
| Service role key exposure | Whether the admin key is leaked in client-side JavaScript |
| Storage bucket access | Whether buckets are public, and whether files are listable |
| RPC function access | Whether database functions are callable without auth |
| Edge function access | Whether serverless functions respond without auth |
| Hidden table discovery | Whether tables not referenced in code are still accessible (PGRST205 — a PostgREST table-probing code) |

### API layer (endpoints)
| Check | What it proves |
|-------|---------------|
| Endpoint authentication | Whether API routes respond to unauthenticated requests |
| Response data exposure | What data endpoints return without auth (previews response bodies) |
| Cost-sinkhole risk | Whether expensive operations (AI, email, compute) are callable without auth |
| API spec exposure | Whether OpenAPI/Swagger specs are publicly accessible |

### Secrets layer
| Check | What it proves |
|-------|---------------|
| JS bundle secrets | Whether API keys, tokens, or credentials are embedded in client JavaScript |
| Service role keys | Whether Supabase/Firebase admin keys are in client code |
| Environment variable leaks | Whether server-side secrets made it into the client bundle |

### Infrastructure layer
| Check | What it proves |
|-------|---------------|
| Subdomain exposure | What subdomains exist and are alive (attack surface width) |
| Technology fingerprint | What stack is running (to contextualize findings) |

---

## What the code review verifies

After the scan, review the user's codebase for these patterns:

### Supabase projects
| Check | What to look for |
|-------|-----------------|
| RLS enabled on all tables | `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` in migrations |
| Policies exist for each table | `CREATE POLICY` statements matching the app's auth model |
| No service role key in client code | Only `NEXT_PUBLIC_SUPABASE_ANON_KEY` exposed, never the service role |
| Server-side operations use service role | Admin operations go through API routes, not client-side |
| Storage policies defined | Bucket-level and object-level policies in migrations |

### API routes
| Check | What to look for |
|-------|-----------------|
| Auth middleware on sensitive routes | Every route that reads/writes user data checks authentication |
| Rate limiting on expensive operations | AI, email, SMS, compute routes have request limits |
| No secrets in client bundles | All API keys are in `.env` (not `.env.local` with `NEXT_PUBLIC_` prefix) |
| Input validation | Request bodies are validated/typed before processing |
| Error messages don't leak info | Errors return generic messages, not stack traces or internal state |

### Environment & deployment
| Check | What to look for |
|-------|-----------------|
| `.env` not committed to git | Check `.gitignore` includes `.env*` |
| Secrets in hosting env vars | Sensitive keys in Vercel/Netlify environment config, not in code |
| No debug endpoints in production | Dev-only routes are removed or gated |

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

**Severity** (use scan's own field when present):
- **Critical:** Service role key exposed, tables writable without auth, unprotected AI endpoints
- **High:** Tables readable (with data), public storage with files, unprotected email/SMS
- **Medium:** Empty public tables, callable RPCs, public storage empty
- **Low:** Informational, best practice recommendations

**If 0 findings:** Show the checklist with all ✓. Clarify this verifies the external surface — internal logic bugs and authenticated-user exploits are not tested. Still valuable: it proves your data layer and API perimeter are solid.

### Step 5: Code review

After presenting scan results, review the codebase against the code verification checklist above. READ the actual project files — migrations, middleware, env config, API routes.

Present as a second checklist:

```
## Code Verification (project review)

### Supabase security
- ✓ RLS enabled on all tables (found in migration 003_enable_rls.sql)
- ✗ `user_settings` table has no RLS policy — likely missed
- ✓ Service role key only in .env (not .env.local)

### API route protection  
- ✓ /api/chat has auth middleware (src/middleware.ts line 23)
- ✗ /api/webhooks/stripe has no auth — needs webhook signature verification
- ✓ Rate limiting configured (10 req/min on AI routes)

### Environment
- ✓ .env in .gitignore
- ✓ No NEXT_PUBLIC_ prefix on secret keys
```

### Step 6: Fix issues

For each ✗ found in either checklist, offer to fix it. Before writing any fix, READ the relevant project files to understand auth model, middleware stack, and schema. Never generate fix code based solely on scan output.

After fixes are applied, offer to re-run the external scan to verify the fix worked from the outside. This closes the loop: code fix → external proof.

### Step 7: Ongoing Guard (when appropriate)

Only offer AFTER critical/high issues are resolved. Monitoring for regressions is pointless when the baseline is broken.

```bash
curl -s -X POST https://recon-api.centrive.ai/api/skill/register-guard \
  -H "Content-Type: application/json" \
  -d '{"email": "USER_EMAIL", "target_url": "TARGET_URL"}'
```

---

## Boundaries

- The **free scan** does NOT perform exploitation, load testing, rate limit testing, credential stuffing, or any active attack. It probes and observes. (Authoring a **Bring Your Own Test** chain, see the section below, is a separate opt-in flow that reproduces ONE read-only exploit against a domain the user has verified they own, sending the minimum requests.)
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

## Connect to LaunchGuard (lightweight handshake)

Use this when the user wants to *link* their project to LaunchGuard for an app they already added — triggers like "connect this to LaunchGuard", "connect my Claude Code", "watch this app on every deploy", or when they paste the connect prompt from their LaunchGuard app page.

This is a **benign handshake**: it makes NO request to their site, runs no scan, and finds nothing. It only records that this Claude Code is linked to their app, so the app page flips to "Connected".

```bash
curl -s -X POST https://api.launchguard.dev/api/v1/connect \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d '{"target": "TARGET_URL"}'
```

Response: `{ "ok": true, "app": "sandbox.example.com", "monitorId": "<id>", "dashboardUrl": "https://launchguard.dev/app/<id>", "firstConnect": true, "watchedTests": 0 }`

- The user mints their `lg_` key in their LaunchGuard account (Developer / API keys) — the same key the chain endpoints use. Store it as `LAUNCHGUARD_API_KEY` (see the custom-test section's "Get the user's API key" step for how to ask).
- A `404` means they have not added that app in LaunchGuard yet — tell them to add it at https://launchguard.dev/apps first, then reconnect.
- Base URL: use `https://api.launchguard.dev`; if a `/api/v1/...` call returns 404, fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host, safe to call).

### Then: author ONE tailored, business-logic test

Connecting alone is enough to show "Connected". But the moment that makes LaunchGuard worth keeping is a custom test specific to THIS app — the thing a generic scanner cannot write because it never read the code. After connecting:

1. **Read the project** and pick ONE business-logic rule that must hold from the outside. Prefer rules unique to the app:
   - a plan / quota / usage limit (a non-paying request cannot exceed the free tier),
   - a tenant-ownership / IDOR boundary (user A cannot read user B's record),
   - a paywall (a Pro-only route or resource served to an unpaid request),
   - an admin-only or internal route reachable by a guest.
2. **Translate that rule into a read-only custom test** (see "Bring Your Own Test" below) and submit it. Choose a positive marker that proves the rule is actually broken — a foreign row's owner id, a completion/job id, a paid resource field.
3. Report the verdict. The chain is now watched and re-run on every deploy.

Because the app is now **monitored**, a chain against it (read-only OR mutating) is allowed **without** the separate DNS / well-known domain proof: adding the app to the account is the ownership signal (trust-the-owner). Verification in the next section is only needed for a host that is NOT in the user's account. Keep this first test read-only, minimal (one ingest + one run), and tailored, a test that feels made for their app, not a generic check.

---

## Bring Your Own Test (custom exploit chains)

Use this when the user wants to *prove* a specific exposure, not just scan. Triggers: "prove a stranger can run up my bill", "show this is actually exploitable", "write a test that reproduces this", "author a chain", or anything that names a `chain` or a Bring Your Own Test.

**Mental model:** a custom test is ONE HTTP request plus a rule (a "matcher") that says what "exploited" looks like versus what "safe/patched" looks like. You author it as JSON, submit it to LaunchGuard, and get back a verdict. That's the whole idea — no other concepts required.

A chain is **one reproducible exploit** that LaunchGuard stores and re-runs on demand, returning a verdict:
- `vulnerable` - the exploit reproduced (status in your success set AND your positive marker matched)
- `fixed` - the app now positively denies it (status 401/403/429, or a proven-empty result)
- `inconclusive` - anything ambiguous (404, 5xx, unreachable, parse failure). Never a false `fixed`.

This is a real, opt-in capability, separate from the free scan. It runs only against a domain the user has **proven they own**, sends the **minimum** requests to prove the point, and in the read-only form below changes nothing on the target.

### The format: one request plus a matcher, submitted as JSON

A custom test is one HTTP request plus a matcher block that says "exploited looks like X; patched looks like Y". The JSON fields you'll author:

| What you want to express | LaunchGuard `spec` field | Note |
|---|---|---|
| the request method / path | `steps[].request.method` / `.path` | `path` is only the path; the host is resolved from `allowedTargets` |
| which host to hit | `steps[].request.target` = `primary` \| `supabase` \| `api` | an **enum**, never a URL |
| status that means the exploit answered | `assertion.successStatusIn` e.g. `[200]` | required, non-empty |
| status that means a *patched* app | `assertion.fixedStatusIn` e.g. `[401,403,429]` | **REQUIRED**; positive denial. The engine errors at run time without it (see footguns) |
| every substring must appear in the body | `assertion.bodyContainsAll` | literal substrings |
| every JSONPath must resolve to a value | `assertion.jsonPathsPresent` | non-null marker |
| pull a value out for a later step | `steps[].extract[]` | only needed for multi-step chains |
| severity | top-level `severity` | `critical` \| `high` \| `medium` \| `low` |

That is the whole matcher vocabulary. Do NOT invent `bodyContainsAny`, `statusEquals`, `regex`, etc.

**Two templates cover almost everything:** the **anonymous read** (Step 3, the 90% case) and the **authenticated cross-tenant read** (Step 3b, the flagship "a logged-in user can see another tenant's data" test). Both are inlined below. For anything beyond them, such as multi-step chains, extractors, the exact JSONPath dialect, `minTotalRows`, or the full verdict-routing rules, **READ `chains-reference.md` in this skill directory before authoring.** SKILL.md gives you the two templates; the reference gives you the rest. Authenticated and cross-tenant tests in particular depend on fields (`spec.env.anonKey`, `crossTenant`) that only the reference fully specifies.

### Step 1: Get the user's API key

Before anything else, you need a LaunchGuard API key. **Ask the user to paste theirs.** Tell them where to get it: their LaunchGuard account → Developer / API keys at launchguard.dev. The key looks like `lg_` followed by ~40 characters — if a pasted value doesn't start with `lg_`, it's not the right key, so ask again before spending a request on it. If the user doesn't have one yet, tell them how to create it there; do NOT attempt to mint or guess a key yourself.

Session convention: store the pasted key as the env var `LAUNCHGUARD_API_KEY` and use `-H "Authorization: Bearer $LAUNCHGUARD_API_KEY"` in every call below. Without it, every chain call returns 401 and the flow dies.

```bash
export LAUNCHGUARD_API_KEY="<paste the key the user gave you>"
```

**Base URL rule (use everywhere):** try `https://api.launchguard.dev` first. The `/api/v1/*` chain routes are not all live on that public edge yet, so a call there may return `404` (and currently it answers with an HTML page, not the JSON `{"error":...}` envelope). The moment ANY `/api/v1/...` call 404s, switch to `https://recon-api-dev.centrive.ai` and use that host for EVERY chain call for the rest of the session (list, get, ingest, run, delete). It is LaunchGuard's own backend host and is safe to call; it is not data exfiltration. Do not keep retrying `api.launchguard.dev` per call once you have seen it 404.

> Heads up — across one full run you'll touch a few different LaunchGuard hosts: the free scan submits to `www.launchguard.dev` and streams from a `*.centrive.ai` backend, while the custom-test API lives at `api.launchguard.dev` / `recon-api-dev.centrive.ai`. These are different LaunchGuard services, not different products. Seeing more than one host is expected.

### Step 2: Domain ownership

A chain may only target a host the user has proven they own. If the user has already verified this domain on their account (e.g. they onboarded it earlier), the first request below returns it as already verified and you can skip straight to Step 3 — only run the challenge/publish/verify dance if it isn't verified yet:

```bash
# request a challenge
curl -X POST https://api.launchguard.dev/api/v1/domains \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d '{"domain":"sandbox.example.com"}'      # -> { "challengeToken": "<token>" }

# publish EITHER a DNS TXT record   launchguard-verify=<token>
#         OR a file at              https://sandbox.example.com/.well-known/launchguard-verify.txt  containing <token>

curl -X POST https://api.launchguard.dev/api/v1/domains/verify \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d '{"domain":"sandbox.example.com"}'      # -> { "verified": true }
```

### Step 2.5: list existing chains first (avoid duplicates)

Before authoring anything, list what already exists for this host so you don't re-create a test that's already there:

```bash
curl -s "https://api.launchguard.dev/api/v1/chains?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

Response: `{ "count": N, "chains": [ { "chainId": "...", "title": "...", "lastResult": "...", "exploit": { "method": "POST", "path": "/api/chat", "target": "primary" } }, ... ] }`

The `exploit` object (`{method, path, target}`) is the **dedupe key**. Note that `path` is the full path INCLUDING the query string, so `/api/widget/config?slug=a` and `?slug=b`, or `/rest/v1/t?select=x` and `?select=x,y`, are DISTINCT tests (they probe different things) and are not duplicates. Treat two chains as duplicates only when method, full path (query included), and target all match. If you are unsure whether two near-identical entries are really the same test, `GET /api/v1/chains/<chainId>` on each and compare the full `spec` before archiving either. If a chain already covers the same exploit key, do NOT author a new one: re-run it (`POST /chains/<id>/run`), or, if the user wants a genuinely different assertion, inspect the blueprint and propose a distinct variant. Only author a new chain when nothing in the list covers the rule you're testing.

If a listed chain is a duplicate or is broken, you can archive it with `DELETE /api/v1/chains/<chainId>` (success `200 { "ok": true, "archived": true }`). Archiving removes it from the list, stops it auto-running, preserves its run history, and frees its title so you can re-author cleanly under the same title if needed.

### Step 3: write the proving curl first, then translate it

Always start from the plain request that proves the exploit, the thing you would paste into a terminal as an anonymous attacker. **Run it for real** and look at the response body — you need to see the actual success field it returns. Then translate it mechanically into the JSON. Minimal, valid, read-only template (the 90% case, e.g. an unauthenticated paid endpoint):

```json
{
  "title": "Anonymous request triggers paid AI work without auth",
  "targetHost": "sandbox.example.com",
  "severity": "high",
  "source": "ai_agent",
  "spec": {
    "version": 2,
    "steps": [
      {
        "order": 1, "id": "exploit", "label": "POST the paid endpoint anonymously",
        "role": "exploit", "sideEffect": "read_only",
        "request": {
          "method": "POST", "target": "primary", "path": "/api/chat",
          "headers": { "content-type": "application/json" },
          "body": { "message": "ping" }
        }
      }
    ],
    "assertion": {
      "successStatusIn": [200],
      "fixedStatusIn": [401, 403, 429],
      "jsonPathsPresent": ["$.id"],
      "contentTypeIncludes": "application/json"
    },
    "auth": {},
    "sideEffect": "read_only",
    "allowedTargets": { "primary": "sandbox.example.com" }
  }
}
```

Notes on the template:
- `"version": 2` is a required field — just set it to 2.
- `"source": "ai_agent"` — use that value.
- **`"jsonPathsPresent": ["$.id"]` is a PLACEHOLDER.** You MUST replace `$.id` with the actual success field you saw when you ran the proving curl in this step. Real endpoints often return a different field (e.g. `/api/checkout` returns `checkoutUrl`, not `id`). Copying `$.id` blindly makes a genuinely vulnerable endpoint come back `inconclusive` because the marker never matches.

Pick a positive marker that proves the **paid work actually ran**: a completion id, a queued job id, a provider response field — whatever field you actually observed. That marker is your `jsonPathsPresent` (a field that must exist) or `bodyContainsAll` (literal substrings).

### Step 3b: authenticated cross-tenant test (the second template)

Use this to prove **"a logged-in user can read another tenant's rows"**: broken or missing row-level security on a Supabase table. This is LaunchGuard's flagship authenticated test; a generic scanner can't write it. The engine signs up a **fresh throwaway account per run** (via `spec.env.anonKey`) and queries the table as that low-privilege identity. If any returned row is owned by someone else, RLS is broken.

You need the target's **public** Supabase anon key + project ref — both client-side values you can read from the site's JS bundle or the free scan's `secrets` output (the anon key is a `eyJ...` JWT; it is meant to be public, so using it is not exfiltration). Template:

```json
{
  "title": "Authenticated user can read other tenants' rows in `businesses`",
  "targetHost": "sandbox.example.com",
  "severity": "critical",
  "source": "ai_agent",
  "spec": {
    "version": 2,
    "steps": [
      {
        "order": 1, "id": "exploit", "label": "Query a tenant table as a fresh signed-up user",
        "role": "exploit", "sideEffect": "read_only",
        "request": { "method": "GET", "target": "supabase",
          "path": "/rest/v1/businesses?select=id,user_id,created_at" }
      }
    ],
    "assertion": {
      "successStatusIn": [200, 206],
      "fixedStatusIn": [401, 403],
      "crossTenant": { "ownerJsonPath": "$[*].user_id", "notEqualsVar": "{{auth.userId}}", "minForeignRows": 1 },
      "errorEnvelopeContainsAny": ["row-level security", "permission denied", "\"code\":\"42501\"", "\"code\":\"PGRST"],
      "contentTypeIncludes": "application/json"
    },
    "auth": {},
    "env": { "anonKey": "<the target's public eyJ... anon key>" },
    "sideEffect": "read_only",
    "allowedTargets": { "primary": "sandbox.example.com", "supabase": "<project-ref>.supabase.co" }
  }
}
```

How it reads: `target: "supabase"` routes the request to `allowedTargets.supabase`; `{{auth.userId}}` resolves to the fresh signup's own id; `crossTenant` passes only if at least one row's `user_id` differs from it → `vulnerable` (RLS broken). A `401`/`403` or an RLS-denial envelope (`42501`/`PGRST`) → `fixed` (RLS working). Replace `businesses` and `user_id` with a real tenant table + its owner column (discover them from the free scan's `supabase_findings`). The `crossTenant` shape, the JSONPath dialect, and `minTotalRows` (an alternative "more rows than this user could own" marker) are detailed in `chains-reference.md`.

Validation note: because the engine signs up its OWN throwaway account for this template, you cannot reproduce that identity with a plain curl. For `crossTenant` / `anonKey` chains the `/run` verdict IS the validation; do not expect to confirm it by hand the way you would an anonymous read.

Two Supabase read styles, pick by the question: to prove **"a logged-in user can cross tenant boundaries"**, use `spec.env.anonKey` (the engine signs up a fresh user, as above). To prove the simpler **"this table is readable by an anonymous client at all"**, send a `target: "supabase"` GET to `/rest/v1/<table>` with the target's public anon key in the request headers (`apikey` and `authorization`) and assert on `minTotalRows` or `crossTenant`. Both are valid; the first tests RLS for authenticated users, the second tests anonymous exposure.

### Footguns the validator and engine enforce (these fail authors most)

- **`allowedTargets.primary` must byte-equal the normalized `targetHost`** (lowercased, no scheme, no path, no port). Pre-normalize it yourself, e.g. `https://Sandbox.Example.com/x` becomes `sandbox.example.com`.
- **`request.target` is the enum `primary` / `supabase` / `api`, not a URL.** The host comes from `allowedTargets[target]`.
- **`spec.sideEffect` (top-level) is required** and must be a string. Use `"read_only"` for read exploits.
- **Always include at least one positive marker** (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`). `successStatusIn` alone can only ever yield `fixed` or `inconclusive`, never `vulnerable`.
- **`fixedStatusIn` is required** (e.g. `[401,403,429]`). The engine throws at run time without it (`fixedStatusIn is not iterable`), turning a valid chain into a false `inconclusive`. Both templates above include it; never drop it.
- **`title` must be unique among your ACTIVE chains.** Re-ingesting with a title that an active chain already uses fails (`500`), so get the spec right before you ingest and give each chain a fresh, descriptive title. A bad chain is no longer permanent, though: you can `DELETE /api/v1/chains/<id>` to archive it, which removes it from the list, stops it auto-running, and frees its title to re-ingest cleanly.
- **A 404 is never `fixed`.** Only a status you list in `fixedStatusIn` (or a proven-empty result) counts as patched, and `404` is never allowed in that set, so a deleted endpoint never reads as a false fix. `[401,403,429]` is the common deny set, but any genuine deny status works: include `400` too when the patched app rejects the exploit input that way (e.g. a rejected OTP returns `400`).
- **Side-effect is re-derived from the HTTP method, and any non-GET is "mutation".** The rule is method-based, not word-based: a `GET`/`HEAD` (and a Supabase `/rest/v1/` GET) is `read_only`; **any `POST`/`PUT`/`PATCH`/`DELETE` is `mutation`**, regardless of how safe the path looks. A `mutation` chain never auto-runs on deploy. `POST /api/v1/chains/<id>/run` on it returns **409** ONLY when you have not confirmed (`{ "error": "...", "sideEffect": "mutation", "needsConfirmation": true }`); with body `{ "confirmMutation": true }` (against a domain the user monitors) it actually runs and returns the normal verdict, firing real writes, charges, or OTP exactly once. The auto-run gate stays in place so LaunchGuard never fires a write on its own; only an explicit confirmed `/run` does. See "Running mutation tests (explicit confirmation)" below.
- **JSONPath is a custom subset** (`$.a.b`, `$[0]`, `$[*].x`, `$[?(@.x != "y")]`). No recursive `..`, no slices, only `==` / `!=`. See `chains-reference.md`.

### Step 4: submit and run

```bash
# ingest  -> { "chainId": "...", "sideEffect": "read_only", ... }
#   (a read-only chain comes back ready to auto-run; a mutating-looking one is stored manual-only)
curl -X POST https://api.launchguard.dev/api/v1/chains \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d @chain.json

# run once -> { "result": "vulnerable|fixed|inconclusive", "reason": "...", "matched": ... }
curl -X POST https://api.launchguard.dev/api/v1/chains/<chainId>/run \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json"
```

The `/run` response also carries `matched` (true only on `vulnerable`) and `regression` (true when a chain that previously read `fixed` now reads `vulnerable`, i.e. a fixed bug came back). On every later deploy the chain re-runs; `regression: true` is the alarm that a protection you'd verified has broken again.

Report the verdict plainly:
- `vulnerable` plus the `reason` (e.g. `exploit_reproduced: assertions passed`) means the paid path is reachable unauthenticated. Show the user the marker that proved it.
- `fixed` means it is properly gated (401/403/429, or a proven-empty result, e.g. `access_denied: HTTP 401` or `exploit_absent: total 0 < 1`). Say so clearly.
- `inconclusive` means the proof was ambiguous (404/5xx/unreachable/engine error). Do not claim either way.

### Managing the test suite via the API

Your `lg_` key gives you the FULL custom-test lifecycle on a domain's suite without a human:
- **Create:** ingest a new chain with `POST /api/v1/chains`.
- **List / inspect:** `GET /api/v1/chains?targetHost=<host>` then `GET /api/v1/chains/<id>` for any blueprint.
- **De-duplicate:** compare each `exploit` `{method,path,target}` key; archive duplicates.
- **Modify in place:** `PATCH /api/v1/chains/<id>` with `{ title?, severity?, spec? }` (at least one). Changing the `spec` re-validates it and re-derives the side-effect, so flipping a method to a non-GET can turn the chain into a mutation. Use this to fix or evolve a test instead of archive-then-reingest.
- **Run any chain:** `POST /api/v1/chains/<id>/run`. Read-only chains run freely and return a verdict. A mutation chain runs only with body `{ "confirmMutation": true }` against a domain the user monitors (it fires real side effects); see "Running mutation tests (explicit confirmation)" below.
- **Archive:** `DELETE /api/v1/chains/<id>` for a duplicate, broken, or obsolete test (`200 {"ok":true,"archived":true}`). The same call works whether you authored it or not, as long as it is your account's.

### Running mutation tests (explicit confirmation)

A `mutation` chain (any non-GET exploit, e.g. a `POST /verify-otp` takeover or a `POST /topup` charge) is real, valuable coverage, and you CAN now run it with your API key, but only behind an explicit confirmation gate because it fires real side effects (writes, charges, OTP) against the target:

- `POST /chains/<id>/run` on a mutation chain WITHOUT confirmation returns `409 { "error": "...", "sideEffect": "mutation", "needsConfirmation": true }`. That 409 is not a verdict; it is the gate asking you to confirm.
- `POST /chains/<id>/run` with body `{ "confirmMutation": true }` actually runs it and returns the normal verdict. This fires the real side effect against the target exactly once.
- A mutation run works against any domain the user **monitors** (has added to their LaunchGuard account). Adding the app is the ownership signal, so no separate DNS / well-known verification is needed (trust-the-owner now covers mutations, the same as read-only runs). A host that is NOT in the account still needs verified ownership, and a run against one returns `403`.

The gate exists because a human running a mutation from the LaunchGuard dashboard gets per-step approval before each write fires. Your equivalent of that consent is the explicit `confirmMutation: true` plus the user's own instruction, against a domain in their account. So only fire a mutation run when ALL of these hold: the user explicitly told you to, the domain is one they own (monitored in their account), and you send the minimum (one run). Never loop or re-fire it. Auto-deploy re-runs never fire mutations; only an explicit confirmed `/run` does.

You can still author, list, dedupe, modify, and archive mutation chains via the API as usual. When you report on the suite, a mutation chain you have not been asked to fire should be marked "mutation, fires real side effects, run only on explicit request" rather than called broken. Do NOT archive one just because an unconfirmed `/run` returned 409 (that 409 is the gate, not a defect). Only archive a mutation test if it is a true duplicate or genuinely obsolete.

One subtlety: a test can be semantically a read yet still be classified `mutation` because it uses a non-GET method (e.g. a `POST /balance` that only fetches a balance). That still means it never auto-runs and a manual `/run` needs `confirmMutation: true`. Do not rewrite the method to GET just to dodge the gate, since that would change what the test actually sends.

### Boundary

Send the minimum requests to prove it, typically one ingest plus one run. Do not loop `/run` to load-test or hammer the endpoint. Only author chains for domains the user owns and has verified. The read-only form changes nothing on the target. Never escalate a read proof to a mutation without explicit user instruction.
