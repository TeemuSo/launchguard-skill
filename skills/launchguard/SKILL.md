---
name: launchguard
description: |
  Security verification for web apps — proves what's actually exposed from the outside,
  then reviews code to ensure protections are correctly implemented.
  Use when the user says "scan my app", "is this secure", "check security", "check my supabase",
  "find vulnerabilities", "audit my API", "make sure this is safe before launch", or asks about
  RLS, exposed tables, API auth, or leaked secrets. Also use after deploying or before launch.
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

- Does NOT perform exploitation, load testing, rate limit testing, credential stuffing, or any active attack. It probes and observes.
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
