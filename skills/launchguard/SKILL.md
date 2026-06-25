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

> **Before you call anything a "finding" — from the scan OR a custom test — read `methodology.md` in this skill directory.** It is the pentester judgment layer: an ordered procedure (threat-model → reachability-from-fresh-state → enumerability → escalation → honest severity → intended-public filter → validation gate) that turns raw "the endpoint answered 200" into a defensible finding, and filters out the false positives a non-expert would otherwise ship. Load it for any "check my app" / "is this secure" / "find my vulnerabilities" request.

> **Authoring a FUNCTIONAL test instead (prove a critical flow still WORKS, not that it's exploitable)? Read `functional-methodology.md` in this skill directory.** It is the functional twin of `methodology.md`: how to pick deploy-gate regression chains, the mandatory two-gate authoring pattern (prove you reached the state, then assert the outcome), anti-flake rules, and the `intent:"functional"` verdict mapping (PASS = working/green, FAIL = broken/red, ERROR = inconclusive). Load it whenever the user wants to "watch that signup/checkout/dashboard still works on every deploy" rather than find a vulnerability.

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

**Severity** (use the scan's own field when present): **Critical** = service-role key exposed, tables writable unauth, unprotected AI endpoints. **High** = tables readable with data, public storage with files, unprotected email/SMS. **Medium** = empty public tables, callable RPCs, empty public storage. **Low** = informational / best-practice.

**If 0 findings:** show the checklist all ✓. Clarify this verifies the external surface — internal logic bugs and authenticated-user exploits are NOT tested — but it does prove the data layer and API perimeter are solid.

### Step 5: Code review

After presenting scan results, review the codebase against the code verification checklist above. READ the actual project files — migrations, middleware, env config, API routes. Present as a second `## Code Verification (project review)` checklist in the same ✓/✗ format, grouped by Supabase / API route / Environment, and **cite the file + line** for each item (e.g. `✓ RLS enabled (migration 003_enable_rls.sql)`, `✗ /api/webhooks/stripe has no signature verification (src/app/api/webhooks/stripe/route.ts)`). The file citation is what makes it actionable.

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

Response:
```json
{ "ok": true, "app": "sandbox.example.com", "monitorId": "<id>",
  "dashboardUrl": "https://launchguard.dev/app/<id>", "firstConnect": true, "watchedTests": 0,
  "coverageSummary": {
    "defaultStacks": { "enabled": 4, "covered": 2, "vulnerable": 1, "off": 1 },
    "customChains": { "watched": 13, "vulnerable": 0 },
    "openGaps": 4,
    "contextUrl": "/api/v1/context?targetHost=sandbox.example.com"
  } }
```

- `coverageSummary` is the at-a-glance posture (how many default engine stacks are enabled/covered/vulnerable/off, how many of the user's own watched chains exist and how many are red, and how many open coverage gaps remain). `coverageSummary.contextUrl` hands you the EXACT `/context` call to make next: connect then read `/context` is the natural handoff. Do not author anything until you have read `/context` (see "Start expert: read /context first" below).
- The user mints their `lg_` key (Developer / API keys) — the same key the chain endpoints use. Store it as `LAUNCHGUARD_API_KEY` (see "Get the user's API key" below for how to ask).
- A `404` means they haven't added that app yet — tell them to add it at https://launchguard.dev/apps first, then reconnect.
- Base URL: try `https://api.launchguard.dev`, fall back to `https://recon-api-dev.centrive.ai` on 404. **But `/api/v1/connect` is a special case:** its public-edge deploy is still in progress, so it may not be reachable on `api.launchguard.dev` yet (it works on the dev host). If unreachable on both, connect just isn't deployed everywhere — tell the user the link is pending and proceed with the scan/test rather than blocking. Don't assume the fallback rescues connect the clean way it rescues `/chains`.

### Start expert: read /context first (the bridge loop)

This is THE one new habit, and it is the FIRST thing you do after connecting and BEFORE you author anything. The old flow re-reconned the app and authored one chain per rule from scratch. You no longer do that. The engine already scanned this app: its coverage, inventory, and the gaps it cannot cover are all handed to you in one call. You START expert. You do NOT re-derive what the default scanner already knows; you READ it.

The loop is five steps:

1. **CONNECT**: `POST /api/v1/connect` (above). Returns `coverageSummary` and a `contextUrl`.
2. **READ CONTEXT**: `GET /api/v1/context?targetHost=<host>`. ONE call returns everything you need: the engine's inventory, every test's verdict (engine checks AND the user's own chains), the gaps, and an explicit list of recommended actions. Read this before authoring a single chain.
3. **ACT ON `recommendations[]`**: for each recommendation, do EXACTLY what its `action` field says (the four actions are below). The anti-duplication discipline now arrives as DATA: a `recommendations[].action === "skip"` tells you precisely what the engine already covers, so you author nothing for it. Trust `/context`; do not re-derive the engine.
4. **RUN**: `POST /api/v1/chains/:id/run` on any chain you authored, for its tri-state verdict (unchanged).
5. **WATCH**: ingest the chains you want guarded with `"watched": true` so they re-run on every deploy (unchanged).

#### `GET /api/v1/context?targetHost=<host>`

```bash
curl -s "https://api.launchguard.dev/api/v1/context?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
# 404 on the public edge -> switch to https://recon-api-dev.centrive.ai for the rest of the session
```

`/context` is now callable with an `lg_` key (dogfood-confirmed). Top-level shape (load-bearing fields; full contract in `chains-reference.md` §11):

- `app`, `monitorId`, `dashboardUrl`, `verifiedOwnership`, `lastScan` (with `securityScore`, `status`).
- `inventory`: redacted STRUCTURAL facts the engine already discovered: `supabase` (`tablesDiscovered`, `tablesTested`, `tablesReadableAnon`, `tablesWithDataExposed`, `storageBucketsFound`, `rpcsFound`, plus a per-table `tables[]` with `anonReadable`), `endpoints` (`count`, `anonReachable[]` with method/path/status/auth), `subdomains`, `secretsFound`. No row samples, no secret values, no PII. This is what you would have re-reconned; read it instead.
- `tests[]`: EVERY default engine check is projected here as a first-class, verdict-bearing test, ALONGSIDE the user's own `chain` tests. Each row has a `kind`:
  - `kind: "engine"`: a built-in scanner stack (e.g. `supabase` database exposure, `firebase`, `write_delete`, the synthesized `surface` hardening stack). Carries `state` (`always_on` / `on` / `off`) and `verdict` (`fixed` / `vulnerable` / `inconclusive` / `off`).
  - `kind: "byo_template"`: a gap with a ready prompt template you can author from (e.g. `cost`, `payment`, `idor`, `broken_access`). Carries `state: "not_run"`, `verdict: "not_run"`, `hasCustomChain`, and possibly `requiresPro`.
  - `kind: "chain"`: the user's OWN custom test, with `chainId`, `severity`, `sideEffect`, `enabled`, `watched`, `verdict`, `dispositionState`, `effectiveStatus`.
- `coverageGaps[]`: the bins with no chain covering them, each with a `bin`, `stackId`, and a human `reason`.
- `recommendations[]`: the action list. THIS is the core of the loop (below).
- `findings`: redacted scan findings: `category`, `severity`, a server-synthesized `title`, structural `location`, and the `ownerTest` (which stack/test owns it). No evidence bodies, no secret values, no PII.

#### The four `recommendations[].action` values: do exactly what each says

| `action` | Carries | What you do |
|---|---|---|
| `skip` | `stackId`, `why` | The engine already covers this. Do NOTHING: do not author a chain for it. This is the anti-duplication rule arriving as data (e.g. `supabase`, `secrets`, `surface` are engine-covered). |
| `toggle_on` | `stackId`, `why` | A toggleable engine stack is off. Turn it on with `POST /api/v1/coverage` (below). Only `firebase` and `write_delete` are toggleable. |
| `author_from_template` | `stackId`, `why`, optional `requiresPro` | A `byo_template` gap. Author a chain from that stack's template (e.g. `cost`, `idor`) using the templates in "Bring Your Own Test" below. |
| `author_gap` | `bin`, `why`, optional `requiresPro` | A freehand custom chain for something the engine genuinely cannot test (an authed paywall, IDOR / cross-tenant, business-logic, a cost-sink, SSRF). Author it tailored to the app. |

So: walk `recommendations[]`, skip what is `skip`, toggle what is `toggle_on`, and author one chain for each `author_from_template` / `author_gap` you decide to cover. In the Connect flow you typically pick ONE `author_gap` / `author_from_template` to author as a watched Guard (next subsection) rather than re-deriving a rule blind.

#### `GET /api/v1/stacks[?targetHost=<host>]`: the default-stack catalog

```bash
# catalog only:
curl -s "https://api.launchguard.dev/api/v1/stacks" -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
# with per-domain state + verdict for each stack:
curl -s "https://api.launchguard.dev/api/v1/stacks?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

Lists the default stacks LaunchGuard ships (`supabase`, `secrets`, `firebase`, `write_delete`, `cost`, `payment`, `idor`, `broken_access`, `surface`) with each one's `bin`, `kind` (`engine` / `byo_template`), `isCore`, `toggleable`, `requiresPro`, the `categories[]` it checks, and `scanFlags`. With `targetHost`, each row ALSO carries the per-domain `state` + `verdict` (and `coveredObjects` / `vulnerableObjects` where relevant). Use it to understand what a stack does before toggling or authoring around it. Full table in `chains-reference.md` §11.

#### `POST /api/v1/coverage`: toggle a default check on/off

```bash
curl -s -X POST https://api.launchguard.dev/api/v1/coverage \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d '{"targetHost":"sandbox.example.com","stackId":"write_delete","enabled":true}'
```

Toggles a toggleable engine stack on or off (merge-write, verified-gated). Live success shape:
```json
{ "ok": true, "app": "sandbox.example.com", "monitorId": "...", "stackId": "firebase", "toggleKey": "firebase",
  "enabled": false, "enabledTests": { "firebase": false, "write_delete": false },
  "appliesOnNextScan": true,
  "rescan": { "triggered": false, "note": "Takes effect on the next deploy scan. Pass {\"rescanNow\":true} to run immediately (subject to a per-monitor debounce)." } }
```

- ONLY the two toggleable engine stacks (`firebase`, `write_delete`) can be toggled. Toggling `enabled:false` then back to `true` is a clean reversible round-trip.
- A non-toggleable stack returns **`409 { "error": "<id> is always-on and cannot be toggled", "toggleable": false }`**. This is the real toggle-rejection. ANY non-toggleable stack hits this (a core engine stack like `supabase`/`secrets`/`surface`, OR a non-toggleable Pro `byo_template` like `cost`). A `402` (Pro upsell) would only appear if a TOGGLEABLE stack ever required Pro you don't have, and none of the currently-toggleable stacks are Pro-gated, so the 402 path is not reachable today. Treat the 409 as the answer; mention 402 only as the hypothetical.
- **Toggling `write_delete` on enables REAL INSERT / UPDATE / DELETE probes** against the (verified) domain. Only do this when the user explicitly wants destructive-access testing, and say so plainly first.
- A toggle takes effect on the NEXT scan / deploy by default (`appliesOnNextScan: true`). Pass `{"rescanNow":true}` to run it immediately (subject to a per-monitor debounce).

### Then: author ONE tailored, business-logic test (from /context's recommendations)

Connecting alone is enough to show "Connected". But the moment that makes LaunchGuard worth keeping is a custom test specific to THIS app, the thing a generic scanner cannot write because it never read the code. You no longer derive that rule blind: `/context` already told you the gaps. After reading `/context`:

1. **Pick your ONE test from `recommendations[]` / `coverageGaps[]`** (the engine handed you the candidates). Choose an `author_gap` or `author_from_template` item: a rule the engine genuinely cannot cover, prioritized by impact and by what the `why` flags. These are the same business-logic boundaries that matter most:
   - a plan / quota / usage limit (a non-paying request cannot exceed the free tier), usually a `cost_abuse` / `cost` recommendation,
   - a tenant-ownership / IDOR boundary (user A cannot read user B's record), usually a `data_exposure` / `idor` recommendation,
   - a paywall (a Pro-only route or resource served to an unpaid request), usually a `payment_bypass` / `payment` recommendation,
   - an admin-only or internal route reachable by a guest, usually a `broken_access` recommendation.
   Do NOT pick something `/context` marked `action: "skip"`: the engine already covers it.
2. **Translate that recommendation into a read-only custom test** (use the templates in "Bring Your Own Test" below, or the `byo_template` for an `author_from_template` item) and submit it **as a Guard**, set `"watched": true` in the ingest body. This flow is explicitly about establishing ongoing protection, so it is the one place you watch by default. Choose a positive marker that proves the rule is actually broken: a foreign row's owner id, a completion/job id, a paid resource field.
3. Report the verdict. Because you submitted it `watched: true`, the chain is now a Guard: re-run on every deploy with regression alerts.

Because the app is now **monitored**, a chain against it (read-only OR mutating) is allowed **without** the separate DNS / well-known domain proof: adding the app to the account is the ownership signal (trust-the-owner). Verification in the next section is only needed for a host that is NOT in the user's account. Keep this first test read-only, minimal (one ingest + one run), and tailored, a test that feels made for their app, not a generic check.

---

## Bring Your Own Test (custom exploit chains)

Use this when the user wants to *prove* a specific exposure, not just scan. Triggers: "prove a stranger can run up my bill", "show this is actually exploitable", "write a test that reproduces this", "author a chain", or anything that names a `chain` or a Bring Your Own Test.

> **READ `methodology.md` in this skill directory BEFORE authoring any test or calling anything a "finding".** The chain *format* below is mechanics; `methodology.md` is the *judgment* — the ordered pentester procedure (threat-model from intent → reachability from a fresh anonymous state → enumerability/id-confidentiality → escalation chaining → stateful preconditions → honest CVSS → false-positive/intended-public filter → a validation gate before you report). It is what stops a non-expert's agent from shipping false positives (flagging intended-public `/api/stats`) or non-weaponizable "findings" (an IDOR on an id the test created itself). Apply it to the free-scan results too, not just custom tests.

> **Want to prove a flow WORKS, not that it's exploitable?** That is a *functional* test (a Playwright **script** chain with `intent:"functional"`, where PASS = working/green and FAIL = broken/red), not the HTTP request-plus-matcher chain documented below. Read `functional-methodology.md` in this skill directory for the two-gate authoring pattern and the functional verdict mapping. The HTTP-chain mechanics in this section are for security exploits; functional regression chains are authored as scripts and are the right tool for "watch that my signup / checkout / dashboard still works on every deploy."

**Mental model:** a custom test is ONE HTTP request plus a rule (a "matcher") saying what "exploited" looks like vs "safe/patched". You author it as JSON, submit it, get back a verdict — a TEST OUTCOME:
- `vulnerable` = test **FAIL** — the exploit reproduced (status in your success set AND your positive marker matched). The must-not-happen happened.
- `fixed` = test **PASS** — the app positively denies it (a status in `fixedStatusIn`, e.g. 401/403/429, or a proven-empty result).
- `inconclusive` = **NOT a result — a broken, unfinished test.** Your assertion didn't describe what the endpoint actually does (unhandled status, unparsed body, marker that never matched, setup that failed).

> **The author owns the assertion — the most important rule.** LaunchGuard does NOT decide whether the app is secure; it runs your request and reports which branch of YOUR matcher fired. The `assertion` block IS your assertion, like the `expect(...)` in a unit test. Before authoring, you must be able to say in one sentence *"this endpoint SHOULD do X, and the test PASSES when it does."* If you can't, you have a random ping, not a test.
>
> **Never accept an `inconclusive`.** It means you haven't finished writing the test. The fix is always: READ the actual status + body, decide what the endpoint SHOULD do, and encode it into the matcher (`successStatusIn` / `fixedStatusIn` / a positive marker) so the run routes deterministically. Re-run until it resolves. The ONLY time you archive instead of fix is a genuinely unassertable test — the engine couldn't even issue the request, so there's no response to read (e.g. a cross-tenant chain dying at `no_credential_resolver` before any HTTP call). "I didn't define the expectation" is never that case.

This is a real, opt-in capability, separate from the free scan. It runs only against a domain the user has **proven they own**, sends the **minimum** requests to prove the point, and in the read-only form below changes nothing on the target.

### Proof vs Guard — does this test re-run on every deploy?

Every custom test is one of two classes, set by the top-level `watched` boolean at ingest (and changeable later via PATCH):

- **Proof** (`watched: false`, **the default**) — a one-shot. You author it, run it once, report the verdict, and it stays as stored evidence. It does **not** re-run on deploy. This is the right class for the many exploit proofs you author while triaging a scan ("show me this is exploitable right now"). Authoring ten proofs during an audit should NOT silently fill the user's watched suite with ten auto-running tests.
- **Guard** (`watched: true`) — joins the deploy-replay suite. On every detected deploy LaunchGuard re-runs it and alerts on regression (a `fixed` chain that comes back `vulnerable`). Reserve this for the handful of rules the user genuinely wants watched forever.

**Default to Proof.** Only set `watched: true` when the user's intent is explicitly ongoing protection — they said "watch this on every deploy", you're in the Connect flow, or you/they decide a specific proof is worth guarding. A user can promote a Proof to a Guard (or demote) anytime from the custom-tests page or via `PATCH /api/v1/chains/<id>` with `{ "watched": true|false }`.

`watched` is **orthogonal to side-effect**: a mutation chain never auto-runs regardless (the safety gate is separate), so marking a mutation `watched: true` does not make it fire on deploy — only read-only Guards auto-run.

### `lastResult` values (what each list row's last verdict means)

Every chain row carries `lastResult`, the outcome of its most recent run:

| `lastResult` | Meaning | Healthy state? |
|---|---|---|
| `fixed` | Last run PASSED — the app denied the exploit (or proved empty). For a functional chain, `fixed` = working/green. | ✅ This is the win, not a broken test. |
| `vulnerable` | Last run FAILED — the exploit reproduced (marker matched). For a functional chain, `vulnerable` = broken/red. | ⚠️ A real finding (unless `dispositionState` is `honored`). |
| `inconclusive` | The run was ambiguous/unsound — an unhandled status, unparsed body, a marker that never matched, a setup that failed. Not a result; a test that needs finishing (read the real response, fix the matcher). | 🔧 Fix the assertion; don't report either way. |
| `null` (never run) | The chain has been ingested but never executed. **On a mutation chain this is EXPECTED, not broken** — mutations never auto-run, so a `lastResult:null` mutation is normal stored coverage awaiting an explicit confirmed run. | ✅ for mutations; for a read-only Guard, just run it once. |

### Cleanup / triage pass — curating an existing suite

When the user says "clean up / manage / triage / dedupe / prune / review my tests" (or you're tidying a suite you didn't author), this is decision logic, not authoring. List the suite (`GET /api/v1/chains` for all apps, or `?targetHost=<host>` for one), then apply this checklist **per chain**. When unsure, KEEP — archiving real coverage is the expensive mistake.

The default list is already the **ACTIVE set** — archived chains are excluded, so you're triaging only live coverage; add `?includeArchived=true` to also see archived rows (each carries `archived: true`), e.g. to find one to restore. And you can run a whole cleanup pass directly against `https://recon-api-dev.centrive.ai` — the public edge 404s `/api/v1/*`, so once any call falls back to the dev host, just stay there for the rest of the pass.

**Archive a chain ONLY if one of these is true:**
- **(a) Exact duplicate** of another *custom* chain — same `{method, path, target}` dedupe key, respecting the script-chain carve-out in Step 2.5 (dedupe script/Playwright chains by title or by diffing `spec.script`, **never** by their constant `(PLAYWRIGHT, "(script chain)", primary)` summary). Keep the better-titled / more-recently-passing one; archive the redundant twin.
- **(b) Structurally unassertable** — the matcher has no positive marker (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`), so the chain can only ever route to `fixed` or `inconclusive` and can NEVER reach `vulnerable`. It cannot prove the thing it claims to test. (Confirm by reading the `spec.assertion` via `GET /api/v1/chains/<id>` — don't infer from the row.)
- **(c) Obsolete** — points at a dead/placeholder host or an endpoint that no longer exists (the path was removed). Verify before archiving, inside the **minimum-requests boundary** (one confirming probe, not a sweep): re-run the chain (`POST /chains/<id>/run`) or issue the single proving request by hand and read what comes back. Honest caveat: **a `404` to your probe is NOT proof the route was removed** — a live route can 404 you because it gates anonymous callers, wants a param/slug you didn't supply, or sits behind auth (denying you, not gone). Treat it obsolete only when you can tell removed-from-the-app apart from denying-you (the host itself is dead/placeholder, or sibling routes answer while this exact path is a framework-level not-found). Can't tell? KEEP, and flag the path for a human eyeball rather than archiving on a bare 404.

**NEVER archive (these look broken but are healthy):**
- A **mutation chain that has merely never run** (`lastResult:null` on a non-GET). Mutations never auto-run by design — `null` is the expected resting state, not a defect. Mark it "mutation, fires real side effects, run only on explicit request."
- A chain whose unconfirmed `/run` returned **`409 needsConfirmation`** — that 409 is the mutation gate, not a failure.
- A chain with a **`proposed` or `honored` `dispositionState`** — a human (or you) recorded that its verdict is intended/reviewed. `honored` counts green; `proposed` is awaiting a human's confirmation. Archiving it discards that decision. (`stale_spec` / `stale_escalation` mean re-review, not archive.)
- A **passing `watched` guard just because it might overlap the built-in scanner**, UNLESS `/context` proves the overlap. Don't archive a passing watched guard on a guess. BUT if `GET /api/v1/context` marks that coverage engine-covered (`recommendations.action === "skip"` for the stack), or the chain is a per-table `anon-db-*` read duplicating the `supabase` engine stack (which tests ALL tables as anon), the engine's table-level coverage supersedes the per-table chain and you MAY skip / retire it. Trust `/context`: the anti-duplication rule now arrives as data, not a guess. See "Custom chains vs. the default scanner" below.

Archiving is reversible (`POST /api/v1/chains/<id>/restore`), but treat every archive as if it weren't: report what you're archiving and why before you do it, and prefer leaving a borderline chain in place.

### Custom chains vs. the default scanner: engine coverage is now visible via /context

The engine's coverage is no longer a guess. `GET /api/v1/context` exposes exactly what the default scanner covers: its `tests[]` projects every engine check (kind `engine` / `byo_template`) as a verdict-bearing test, and `recommendations[].action === "skip"` names each stack the engine already owns ("do NOT author a chain for this"). So you CAN now tell when a custom chain duplicates default-scanner coverage:

- **Act on `recommendations.action === "skip"`.** If `/context` marks a stack engine-covered (e.g. `supabase`, `secrets`, `surface`), do not author a chain for it, and if the user already has a per-table custom chain duplicating it, the engine's coverage supersedes the per-table chain. The `supabase` engine stack tests EVERY table / bucket / RPC as the anon role (you'll see `inventory.supabase.tablesTested` covering all of them), so a per-table `anon-db-*` read chain is redundant with it; the engine's table-level coverage supersedes the per-table chain.
- **Custom-chain-vs-custom-chain dedupe is unchanged.** Dedupe two custom chains by their `exploit` `{method, path, target}` key (Step 2.5), respecting the script-chain carve-out. That rule still stands; what changed is that engine coverage is now data you can read, not a guess you must avoid acting on.

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
| watch it on every deploy (Guard) vs one-shot (Proof) | top-level `watched` | boolean, **defaults `false` (Proof)**. See "Proof vs Guard" above |

That is the whole matcher vocabulary. Do NOT invent `bodyContainsAny`, `statusEquals`, `regex`, etc.

**Two templates cover almost everything:** the **anonymous read** (Step 3, the 90% case) and the **authenticated cross-tenant read** (Step 3b, the flagship "a logged-in user can see another tenant's data" test). Both are inlined below. For anything beyond them, such as multi-step chains, extractors, the exact JSONPath dialect, `minTotalRows`, or the full verdict-routing rules, **READ `chains-reference.md` in this skill directory before authoring.** SKILL.md gives you the two templates; the reference gives you the rest. Authenticated and cross-tenant tests in particular depend on fields (`spec.env.anonKey`, `crossTenant`) that only the reference fully specifies.

### Step 1: Get the user's API key

Before anything else, you need a LaunchGuard API key. It is **per-account**, minted by the user under their LaunchGuard account → **Developer / API keys** at launchguard.dev — it is NOT in the app's frontend env, code, or `.env` files, so don't go looking for it there. **Ask the user to paste theirs.** The key is `lg_` + ~40 chars. Reject anything else before spending a request: a value that doesn't start `lg_` is not the key, and a value starting **`lg_scan_`** is a scan-token SECRET (a per-scan credential), NOT the Developer API key — the real key has no `scan_` segment. Never mint or guess a key. Store it and send it on EVERY chain call below; without it every call 401s.

**Confirm you actually hold a valid `lg_`+~40-char key BEFORE the first chain call.** If the key is absent AND you cannot ask a human (an unattended / agentic run), STOP: report the missing Developer API key as the single blocker and do NOT proceed to scan or author anything. There is no fallback that recovers a key the user never gave you — proceeding just burns to a wall of 401s.

```bash
export LAUNCHGUARD_API_KEY="<paste the key the user gave you>"   # then: -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

**Base URL rule (use everywhere):** try `https://api.launchguard.dev` first. The `/api/v1/*` chain routes are not all live on that public edge yet, so a call may return `404` (currently an HTML page, not the JSON `{"error":...}` envelope). The moment ANY `/api/v1/...` call 404s, switch to `https://recon-api-dev.centrive.ai` and use that host for EVERY chain call for the rest of the session — it is LaunchGuard's own backend host, safe to call, not exfiltration. Don't keep retrying `api.launchguard.dev` once you've seen it 404.

> Across one run you'll touch several LaunchGuard hosts: the free scan submits to `www.launchguard.dev` and streams from a `*.centrive.ai` backend; the custom-test API lives at `api.launchguard.dev` / `recon-api-dev.centrive.ai`. Different services, same product — seeing more than one host is expected.

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

Before authoring anything, list what already exists so you don't re-create a test that's already there. To see chains for one app, filter by host; **with NO `targetHost`, the list returns every chain across all monitored hosts — that is how you discover which apps the account has** (the only way to enumerate apps from the API):

```bash
# this host only:
curl -s "https://api.launchguard.dev/api/v1/chains?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
# every app the account monitors (omit targetHost):
curl -s "https://api.launchguard.dev/api/v1/chains" -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

Response: `{ "count": N, "chains": [ { "chainId": "...", "title": "...", "lastResult": "...", "watched": false, "dispositionState": "none", "exploit": { "method": "POST", "path": "/api/chat", "target": "primary" } }, ... ] }`. The `lastResult` values are defined in the table below ("Proof vs Guard" → "`lastResult` values"); the full row shape is in `chains-reference.md` §7.

**The dedupe key for an HTTP request-plus-matcher chain is the `exploit` object `{method, path, target}`** — and ONLY for those chains. `path` is the FULL path including the query string, so `/api/widget/config?slug=a` vs `?slug=b`, or `/rest/v1/t?select=x` vs `?select=x,y`, are DISTINCT tests, not duplicates. Two HTTP chains are duplicates only when method, full path (query included), AND target all match. If unsure, `GET /api/v1/chains/<chainId>` on each and diff the full `spec` before archiving either.

> **⛔ SAFETY-CRITICAL CARVE-OUT — the `{method,path,target}` dedupe key is INVALID for script / Playwright chains.** A script chain (functional regression or captured-session auth test) has no per-request method/path/target — its `exploit` key collapses to a constant like `(PLAYWRIGHT, "(script chain)", primary)`, IDENTICAL across every script chain. Dedupe those by that key and you will flag nearly every functional test as a "duplicate" of the first one and **archive real, distinct coverage.** A script chain's identity is its **script body / title**, not its request tuple. So for any chain whose target/method reads as `PLAYWRIGHT` / `(script chain)`: dedupe by **title**, or by `GET /api/v1/chains/<id>` and diffing the actual `spec.script` body — **NEVER by the exploit summary.** When in doubt, treat two script chains as DISTINCT.

Only author a new chain when nothing covers the rule. If a chain already covers the same exploit key, re-run it (`POST /chains/<id>/run`) instead of duplicating; or, for a genuinely different assertion, inspect the blueprint and author a distinct variant. To remove a true duplicate or broken test, archive it with `DELETE /api/v1/chains/<chainId>` (reversible via `POST /chains/<id>/restore`) — see the **Cleanup / triage pass** section below for the full archive decision rules, and `chains-reference.md` §7 for the archive/restore contract.

### Step 3: write the proving curl first, then translate it

Always start from the plain request that proves the exploit, the thing you would paste into a terminal as an anonymous attacker. **Run it for real** and look at the response body — you need to see the actual success field it returns. Then translate it mechanically into the JSON. Minimal, valid, read-only template (the 90% case, e.g. an unauthenticated paid endpoint):

```json
{
  "title": "Anonymous request triggers paid AI work without auth",
  "targetHost": "sandbox.example.com",
  "severity": "high",
  "source": "ai_agent",
  "watched": false,
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
- **`"watched": false` makes this a Proof** (one-shot, the default — see "Proof vs Guard" above). Leave it `false` for an exploit you're just proving now; set it `true` only when the user wants this re-run on every deploy (a Guard).
- **`"jsonPathsPresent": ["$.id"]` is a PLACEHOLDER.** You MUST replace `$.id` with the actual success field you saw when you ran the proving curl in this step. Real endpoints often return a different field (e.g. `/api/checkout` returns `checkoutUrl`, not `id`). Copying `$.id` blindly makes a genuinely vulnerable endpoint come back `inconclusive` because the marker never matches.

Pick a positive marker that proves the **paid work actually ran**: a completion id, a queued job id, a provider response field — whatever field you actually observed. That marker is your `jsonPathsPresent` (a field that must exist) or `bodyContainsAll` (literal substrings).

### Step 3b: authenticated cross-tenant test (the second template)

Use this to prove **"a logged-in user can read another tenant's rows"**: broken or missing row-level security on a Supabase table. This is LaunchGuard's flagship authenticated test; a generic scanner can't write it. The engine signs up a **fresh throwaway account per run** (via `spec.env.anonKey`) and queries the table as that low-privilege identity. If any returned row is owned by someone else, RLS is broken.

> **PRE-FLIGHT GATE — this template only works on a Supabase-Auth app with a legacy `eyJ...` anon key.** The engine mints the second identity by signing a fresh user up through Supabase Auth (GoTrue). Two things break it — check both BEFORE authoring:
> 1. **Auth provider.** Clerk / Auth0 / NextAuth / Firebase Auth (anything NOT Supabase Auth) has no GoTrue signup path: the run dies at `auth_failed: no_credential_resolver` before any HTTP request, so it is unassertable — do NOT author it.
> 2. **Key format.** A new `sb_publishable_...` key carries no embedded JWT identity; `crossTenant`/`{{auth.userId}}` need a legacy `eyJ...` JWT anon key.
>
> When either is true, use a fallback instead: (a) the **anonymous-exposure** style below (`minTotalRows >= 1` with the public key in headers — works with EITHER key type, no Supabase Auth needed); or (b) a **captured-session script chain** (`chains-reference.md` §9) to run the cross-tenant read as a real provisioned user even on a Clerk/Auth0/Firebase-Auth app.

You need the target's **public** Supabase anon key + project ref — client-side values that are meant to be public (using them is not exfiltration). Get them by grepping the site's JS bundles (`supabase.co` → project ref, `sb_publishable_` or a legacy `eyJ...` token → the key) or from the free scan's `secrets` output. Template:

```json
{
  "title": "Authenticated user can read other tenants' rows in `businesses`",
  "targetHost": "sandbox.example.com",
  "severity": "critical",
  "source": "ai_agent",
  "watched": false,
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

**Do NOT author per-table `anon-db-*` read chains as a default.** The `supabase` engine stack already tests EVERY table / bucket / RPC as the anon role on every scan. You will see this directly in `/context`: `recommendations.action === "skip"` for `supabase` ("Default Supabase stack covers every table/bucket/RPC as the anon role. Do NOT author per-table anon-db read chains"), and `inventory.supabase.tablesTested` covering all discovered tables. Trust `/context`; do not re-derive the engine. Re-authoring a per-table anonymous PostgREST read is redundant coverage the engine already owns.

Reserve the anonymous-read template for GENUINE gaps the engine cannot see:
- **An app route returning a JSON array of sensitive records** (the most common real vibe-coder mass-exposure): the engine does NOT crawl arbitrary app-route bodies, so this IS a real gap. Author it with `jsonPathsPresent` on a sensitive field; full template in `chains-reference.md` §5.1.
- **A specific table `/context` itself flagged as a gap** (e.g. one the engine somehow missed and surfaced in `coverageGaps[]` / a `recommendations` item).

Two Supabase read styles still exist, pick by the question: to prove **"a logged-in user can cross tenant boundaries"**, use `spec.env.anonKey` (the engine signs up a fresh user, as above), which is RLS-for-authenticated-users testing the engine does not do per-table. To prove the simpler **"this table is readable by an anonymous client at all"** on a genuine gap, send a `target: "supabase"` GET to `/rest/v1/<table>` with the target's public anon key in the request headers (`apikey` AND `authorization: Bearer <key>`, plus `"Prefer": "count=exact"`) and assert on `minTotalRows: 1`. This anon style works with EITHER a legacy `eyJ...` JWT or a new `sb_publishable_...` key and does NOT require Supabase Auth, but only reach for it on a gap, since the engine already sweeps every table anonymously by default.

> **API arrays count too — the most common real vibe-coder mass-exposure.** Anonymous mass-exposure is NOT only a PostgREST/`content-range` thing. The everyday case is an **app route returning a JSON array of sensitive records without auth** (e.g. `GET /api/widget/config?slug=x` → an array of names + phone numbers) — a first-class anon mass-exposure finding, rendered as the same structured "rows" evidence card on the dashboard. Assert it with **`jsonPathsPresent` on a sensitive field** (e.g. `["$[0].phone"]`), optionally plus `bodyContainsAll` on a known value — **NOT `minTotalRows`** (it needs a PostgREST `content-range` header a plain API array won't carry → it never fires → false `inconclusive`). Worked template: `chains-reference.md` §5.1.

### Footguns that fail authors most

These are the high-stakes ones — the **judgment and safety** rules. The exhaustive mechanical catalog (host-normalization byte-equality, the `target` enum, the JSONPath subset grammar, the `minTotalRows` `Prefer: count=exact` header, RPC zero-arg rule, redirect-routing limitation, title-uniqueness/`500`) is in **`chains-reference.md` §1–§8** — read it before authoring anything past the two templates.

- **Always include at least one positive marker** (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`). `successStatusIn` alone can only ever yield `fixed` or `inconclusive`, never `vulnerable` — a markerless chain is structurally unassertable (the cleanup-archive criterion (b)).
- **`fixedStatusIn` is required** (e.g. `[401,403,429]`). The engine throws at run time without it (`fixedStatusIn is not iterable`) and the run becomes a false `inconclusive`. Both templates include it; never drop it. Add `400` when the patched app rejects the exploit input that way (e.g. a rejected OTP). **A `404` is never `fixed`** — a deleted endpoint must never read as a false fix.
- **Side-effect is re-derived from the HTTP method — any non-GET is `mutation`.** Method-based, not word-based: `GET`/`HEAD` (and a Supabase `/rest/v1/` GET) is `read_only`; any `POST`/`PUT`/`PATCH`/`DELETE` is `mutation`. A `mutation` chain NEVER auto-runs. An unconfirmed `/run` returns `409 { "needsConfirmation": true }`; only `{ "confirmMutation": true }` (against a monitored domain) fires it, exactly once. The auto-run gate means LaunchGuard never fires a write on its own. See "Running mutation tests" below.
- **A GET that triggers downstream WRITES is a deploy hazard.** Side-effect is method-derived, so a `GET` that proxies to a write / a spend is still classified `read_only` + auto-replay and will fire that write on EVERY deploy. There is no GET→manual downgrade. Do NOT author it (or archive it if you did); cover the endpoint a safer way.
- **Cross-host targeting is the key to backend/Supabase tests.** Only `allowedTargets.primary` must byte-equal `targetHost`; `.api` and `.supabase` are free-form passthrough hosts that may differ from the monitored domain. Use `target: "api"` to hit a separate backend directly — unauth BOLA / object-access holes usually live there, even when the frontend proxy is gated.
- **The matcher cannot express rate-limit, response-time, or response-header assertions.** No "fire N, expect 429", no `maxResponseMs`, no header matcher. A pure missing-rate-limit (OWASP API4) or missing-security-header bug is NOT authorable as a chain — report those as code-review findings, not chains.
- **Severity is yours, set it honestly, and don't cry wolf.** A `vulnerable` verdict only means "an outsider reached this and the marker matched" — it does NOT mean the data is sensitive. Aggregate public counters (`/api/stats`), a published pricing list, or a public blog feed answer unauthenticated BY DESIGN and are NOT findings (the `methodology.md` Step 6 intended-public filter). Reserve `vulnerable` for data that crosses a real trust boundary (another tenant's rows, PII, internal ids/emails, secrets, paid work). When genuinely ambiguous, label it "needs product triage" instead of asserting a scary severity. A clean sweep where every table returns `fixed` is the suite WORKING, not broken assertions.

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

The `/run` response also carries `matched` (true only on `vulnerable`) and `regression` (true when a chain that previously read `fixed` now reads `vulnerable`, i.e. a fixed bug came back). **If you ingested it as a Guard (`watched: true`), it re-runs on every later deploy** and `regression: true` is the alarm that a protection you'd verified has broken again. A Proof (`watched: false`, the default) does NOT re-run on deploy — it stays as the stored verdict from this run until you (or the user) promote it to a Guard.

Report the verdict plainly:
- `vulnerable` plus the `reason` (e.g. `exploit_reproduced: assertions passed`) means the paid path is reachable unauthenticated. Show the user the marker that proved it.
- `fixed` means it is properly gated (401/403/429, or a proven-empty result, e.g. `access_denied: HTTP 401` or `exploit_absent: total 0 < 1`). Say so clearly.
- `inconclusive` means the proof was ambiguous (404/5xx/unreachable/engine error). Do not claim either way.

**Pointing the user at the dashboard:** do NOT hand-build a `https://launchguard.dev/app/<id>` link from a chain row, because chain rows carry no `appId`, so you cannot construct that `<id>` yourself. Instead, get the real `dashboardUrl` from the API and pass that: both `POST /api/v1/connect` and `GET /api/v1/context` return a ready `dashboardUrl` for the app. So call `/context` (it is `lg_`-key-callable) or read the connect response, and point the user at the `dashboardUrl` it hands you. Always use the API-provided URL; never build the link from a chain row.

### Managing the test suite via the API

Your `lg_` key gives you the FULL custom-test lifecycle on a domain's suite without a human. Full request/response contracts (status codes, error shapes, the `archived`/`restore`/`disposition` details) are in `chains-reference.md` §7 + §10; the **archive decision rules** are the **Cleanup / triage pass** section above. The operations:

| Operation | Endpoint | Note |
|---|---|---|
| Read coverage (START HERE) | `GET /api/v1/context?targetHost=<host>` | the bridge call: inventory + every test's verdict + gaps + `recommendations[]`. Read before authoring. See `chains-reference.md` §11 |
| Stack catalog | `GET /api/v1/stacks[?targetHost=<host>]` | default-stack catalog; with `targetHost`, per-domain `state` + `verdict`. See `chains-reference.md` §11 |
| Toggle a default check | `POST /api/v1/coverage { targetHost, stackId, enabled }` | toggle `firebase` / `write_delete` only; non-toggleable stacks `409`; `write_delete` fires real mutations; takes effect next scan unless `rescanNow` |
| Create | `POST /api/v1/chains` | defaults to a Proof; `"watched": true` ingests a Guard |
| List / discover apps | `GET /api/v1/chains[?targetHost=<host>]` | omit `targetHost` to list every app's chains; add `?includeArchived=true` to include archived rows |
| Inspect one | `GET /api/v1/chains/<id>` | full `spec` — diff this to confirm a dedupe, especially for script chains |
| Promote / demote | `PATCH /api/v1/chains/<id> { "watched": true\|false }` | curate the watched suite without re-ingesting |
| Modify in place | `PATCH /api/v1/chains/<id> { title?, severity?, spec?, watched? }` | changing `spec` re-validates + re-derives side-effect (a non-GET method flips it to mutation) |
| Run | `POST /api/v1/chains/<id>/run` | read-only runs freely; a mutation needs `{ "confirmMutation": true }` — see "Running mutation tests" |
| Archive / restore | `DELETE /api/v1/chains/<id>` / `POST /api/v1/chains/<id>/restore` | reversible; restore can `409 titleCollision`. Apply the Cleanup checklist first |

**Dedupe** by the `exploit` `{method,path,target}` key — but for script/Playwright chains use the carve-out in Step 2.5 (dedupe by title / `spec.script`, never the constant exploit summary). These calls work whether or not you authored the chain, as long as it's your account's.

**Disposition (mark a `vulnerable` verdict intended):** `POST /api/v1/chains/<id>/disposition` with `{ "disposition": "proposed", "reason": "..." }`. An `lg_` API key may only **propose** — a human confirms `accepted`. Every row carries `dispositionState` (`none|proposed|stale_spec|stale_escalation|honored`); **branch on that, not raw `disposition`**: `honored` → don't re-flag, read the reason; `stale_spec`/`stale_escalation` → prior acceptance no longer holds, surface for human re-review. Full model in `chains-reference.md` §10.

### Authenticated tests with a captured session

For "logged in but under-privileged" bugs the engine can't mint an identity for — a Pro-only route reachable by a free user, an admin function reachable by a member, an authenticated cross-tenant IDOR on a non-Supabase-Auth (Clerk/Auth0/Firebase) app — the user can hand you a **captured browser session** (a Playwright `storageState`). Upload it once with `POST /api/v1/chains/credentials` and reference the returned `credentialId` from a **script** chain, which then runs authenticated as that real identity. This is the third credential mode (alongside anonymous and Supabase-anon) and the way to prove authenticated/Pro-gated/cross-tenant exposures black-box. Full contract and the non-secret `identity` (`label` + `metadata`) shown per test: `chains-reference.md` §9.

### Running mutation tests (explicit confirmation)

A `mutation` chain (any non-GET exploit, e.g. a `POST /verify-otp` takeover or a `POST /topup` charge) is real, valuable coverage. You CAN run it with your API key, but only behind an explicit confirmation gate because it fires real side effects (writes, charges, OTP) against the target:

- An unconfirmed `POST /chains/<id>/run` returns `409 { "sideEffect": "mutation", "needsConfirmation": true }` — the gate, NOT a verdict and NOT a defect.
- `POST /chains/<id>/run` with `{ "confirmMutation": true }` runs it once and returns the normal verdict, firing the real side effect exactly once. Works against any domain the user **monitors** (trust-the-owner covers mutations like read-only runs); a host not in the account returns `403`.

The gate is your equivalent of the per-step approval a human gets in the dashboard. So fire a mutation run only when ALL hold: the user explicitly told you to, the domain is one they monitor, and you send the minimum (one run, never a loop). Auto-deploy re-runs NEVER fire mutations.

You can still author, list, dedupe, modify, and archive mutation chains as usual. When reporting on a suite, mark a mutation you haven't been asked to fire as "mutation, fires real side effects, run only on explicit request" — do NOT call it broken and do NOT archive it just because an unconfirmed `/run` returned 409. A semantically-read endpoint behind a non-GET method (e.g. `POST /balance`) is still classified `mutation`; don't rewrite it to GET to dodge the gate — that changes what the test sends.

### Boundary

Send the minimum requests to prove it, typically one ingest plus one run. Do not loop `/run` to load-test or hammer the endpoint. Only author chains for domains the user owns and has verified. The read-only form changes nothing on the target. Never escalate a read proof to a mutation without explicit user instruction.
