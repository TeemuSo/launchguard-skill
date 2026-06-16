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
| Hidden table discovery | Whether tables not referenced in code are still accessible (PGRST205 probing) |

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
  -H "Authorization: Bearer lg_<key>" -H "Content-Type: application/json" \
  -d '{"target": "TARGET_URL"}'
```

Response: `{ "ok": true, "app": "sandbox.example.com", "monitorId": "<id>", "dashboardUrl": "https://launchguard.dev/app/<id>", "firstConnect": true, "watchedTests": 0 }`

- The user mints `lg_<key>` in their LaunchGuard account (Developer / API keys) — the same key the chain endpoints use.
- A `404` means they have not added that app in LaunchGuard yet — tell them to add it at https://launchguard.dev/apps first, then reconnect.
- Base URL is `https://api.launchguard.dev`; if the key was issued on the dev backend, use `https://recon-api-dev.centrive.ai`.

### Then: author ONE tailored, business-logic test

Connecting alone is enough to show "Connected". But the moment that makes LaunchGuard worth keeping is a custom test specific to THIS app — the thing a generic scanner cannot write because it never read the code. After connecting:

1. **Read the project** and pick ONE business-logic rule that must hold from the outside. Prefer rules unique to the app:
   - a plan / quota / usage limit (a non-paying request cannot exceed the free tier),
   - a tenant-ownership / IDOR boundary (user A cannot read user B's record),
   - a paywall (a Pro-only route or resource served to an unpaid request),
   - an admin-only or internal route reachable by a guest.
2. **Translate that rule into a read-only ChainSpecV2** (see "Bring Your Own Test" below) and submit it. Choose a positive marker that proves the rule is actually broken — a foreign row's owner id, a completion/job id, a paid resource field.
3. Report the verdict. The chain is now watched and re-run on every deploy.

Because the app is now **monitored**, a **read-only** chain against it is allowed **without** the separate DNS / well-known domain proof (trust-the-owner). Only *mutating* chains still require the ownership verification in the next section. Keep it read-only, minimal (one ingest + one run), and tailored — a test that feels made for their app, not a generic check.

---

## Bring Your Own Test (custom exploit chains)

Use this when the user wants to *prove* a specific exposure, not just scan. Triggers: "prove a stranger can run up my bill", "show this is actually exploitable", "write a test that reproduces this", "author a chain", or anything that names `ChainSpecV2`, `chain`, or a Bring Your Own Test.

A chain is **one reproducible exploit** that LaunchGuard stores and re-runs on demand, returning a verdict:
- `vulnerable` - the exploit reproduced (status in your success set AND your positive marker matched)
- `fixed` - the app now positively denies it (status 401/403/429, or a proven-empty result)
- `inconclusive` - anything ambiguous (404, 5xx, unreachable, parse failure). Never a false `fixed`.

This is a real, opt-in capability, separate from the free scan. It runs only against a domain the user has **proven they own**, sends the **minimum** requests to prove the point, and in the read-only form below changes nothing on the target.

### The format: think Nuclei, submit JSON

You already know this shape. A LaunchGuard chain is a **Nuclei template expressed as JSON**: one HTTP request plus a matcher block that says "exploited looks like X; patched looks like Y". Author it by mapping from the Nuclei concepts you already know:

| Nuclei concept | LaunchGuard `spec` field | Note |
|---|---|---|
| `http:` method / path | `steps[].request.method` / `.path` | `path` is only the path; the host is resolved from `allowedTargets` |
| request host | `steps[].request.target` = `primary` \| `supabase` \| `api` | an **enum**, never a URL |
| matcher `type: status` (the exploit) | `assertion.successStatusIn` e.g. `[200]` | required, non-empty |
| (Nuclei has no "fixed" idea) | `assertion.fixedStatusIn` e.g. `[401,403,429]` | what a *patched* app returns |
| matcher `type: word, part: body, condition: and` | `assertion.bodyContainsAll` | every substring must appear in the body |
| matcher `type: dsl` / json presence | `assertion.jsonPathsPresent` | every JSONPath must resolve to a non-null value |
| `extractors` (json / regex) | `steps[].extract[]` | only needed for multi-step chains |
| `info.severity` | top-level `severity` | `critical` \| `high` \| `medium` \| `low` |

That is the whole matcher vocabulary. Do NOT invent `bodyContainsAny`, `statusEquals`, `regex`, etc. The full assertion set (cross-tenant IDOR, extractors, JSONPath dialect, verdict routing) is in `chains-reference.md` in this skill directory.

### Step 1: API key and domain ownership

Every call needs `Authorization: Bearer lg_<key>` (the user mints this in their LaunchGuard account, Developer / API keys). A chain may only target a host the user has proven they own:

```bash
# request a challenge
curl -X POST https://api.launchguard.dev/api/v1/domains \
  -H "Authorization: Bearer lg_<key>" -H "Content-Type: application/json" \
  -d '{"domain":"sandbox.example.com"}'      # -> { "challengeToken": "<token>" }

# publish EITHER a DNS TXT record   launchguard-verify=<token>
#         OR a file at              https://sandbox.example.com/.well-known/launchguard-verify.txt  containing <token>

curl -X POST https://api.launchguard.dev/api/v1/domains/verify \
  -H "Authorization: Bearer lg_<key>" -H "Content-Type: application/json" \
  -d '{"domain":"sandbox.example.com"}'      # -> { "verified": true }
```

Base URL is `https://api.launchguard.dev`. If the key was issued on the dev backend, use `https://recon-api-dev.centrive.ai`.

### Step 2: write the proving curl first, then translate it

Always start from the plain request that proves the exploit, the thing you would paste into a terminal as an anonymous attacker. Then translate it mechanically into the JSON. Minimal, valid, read-only template (the 90% case, e.g. an unauthenticated paid endpoint):

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

Pick a positive marker that proves the **paid work actually ran**: a completion id, a queued job id, a provider response field. That marker is your `jsonPathsPresent` (a field that must exist) or `bodyContainsAll` (literal substrings).

### Footguns the validator and engine enforce (these fail authors most)

- **`allowedTargets.primary` must byte-equal the normalized `targetHost`** (lowercased, no scheme, no path, no port). Pre-normalize it yourself, e.g. `https://Sandbox.Example.com/x` becomes `sandbox.example.com`.
- **`request.target` is the enum `primary` / `supabase` / `api`, not a URL.** The host comes from `allowedTargets[target]`.
- **`spec.sideEffect` (top-level) is required** and must be a string. Use `"read_only"` for read exploits.
- **Always include at least one positive marker** (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`). `successStatusIn` alone can only ever yield `fixed` or `inconclusive`, never `vulnerable`.
- **A 404 is never `fixed`.** Only `401` / `403` / `429` (listed in `fixedStatusIn`) or a proven-empty result count as patched, so a deleted endpoint never reads as a false fix.
- **Side-effect is silently re-derived from method+path.** A path that looks mutating (`/reset`, `/delete`, `/send`) gets tainted to `mutation`, which makes the chain manual-only and auto-`/run` refuses with 409. Keep read-only proofs on read-only-looking paths.
- **JSONPath is a custom subset** (`$.a.b`, `$[0]`, `$[*].x`, `$[?(@.x != "y")]`). No recursive `..`, no slices, only `==` / `!=`. See `chains-reference.md`.

### Step 3: submit and run

```bash
# ingest  -> { "chainId": "...", "autoReplay": true, "sideEffect": "read_only" }
curl -X POST https://api.launchguard.dev/api/v1/chains \
  -H "Authorization: Bearer lg_<key>" -H "Content-Type: application/json" \
  -d @chain.json

# run once -> { "result": "vulnerable|fixed|inconclusive", "reason": "...", "matched": ..., "regression": ... }
curl -X POST https://api.launchguard.dev/api/v1/chains/<chainId>/run \
  -H "Authorization: Bearer lg_<key>" -H "Content-Type: application/json"
```

Report the verdict plainly:
- `vulnerable` plus the `reason` (e.g. `exploit_reproduced: assertions passed`) means the paid path is reachable unauthenticated. Show the user the marker that proved it.
- `fixed` means it is properly gated (401/403/429). Say so clearly.
- `inconclusive` means the proof was ambiguous (404/5xx/unreachable). Do not claim either way.

### Boundary

Send the minimum requests to prove it, typically one ingest plus one run. Do not loop `/run` to load-test or hammer the endpoint. Only author chains for domains the user owns and has verified. The read-only form changes nothing on the target. Never escalate a read proof to a mutation without explicit user instruction.
