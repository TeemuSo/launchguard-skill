# LaunchGuard — Bring Your Own Test (custom exploit chains)

> **Authenticate first (see `CONNECT.md` → Step 0: Authenticate) and READ `reference/methodology.md` before authoring.** Step 0 gets your `lg_` token into `LAUNCHGUARD_API_KEY` via one browser click; `reference/methodology.md` is the judgment layer that stops you shipping false positives.

Use this when the user wants to *prove* a specific exposure, not just scan. Triggers: "prove a stranger can run up my bill", "show this is actually exploitable", "write a test that reproduces this", "author a chain", or anything that names a `chain` or a Bring Your Own Test.

> **READ `reference/methodology.md` BEFORE authoring any test or calling anything a "finding".** The chain *format* below is mechanics; `reference/methodology.md` is the *judgment* — the ordered pentester procedure (threat-model from intent → reachability from a fresh anonymous state → enumerability/id-confidentiality → escalation chaining → stateful preconditions → honest CVSS → false-positive/intended-public filter → a validation gate before you report). It is what stops a non-expert's agent from shipping false positives (flagging intended-public `/api/stats`) or non-weaponizable "findings" (an IDOR on an id the test created itself). Apply it to the free-scan results too, not just custom tests.

> **Want to prove a flow WORKS, not that it's exploitable?** That is a *functional* test (a Playwright **script** chain with `intent:"functional"`, where PASS = working/green and FAIL = broken/red), not the HTTP request-plus-matcher chain documented below. Read `reference/functional-methodology.md` for the two-gate authoring pattern and the functional verdict mapping. The HTTP-chain mechanics in this file are for security exploits; functional regression chains are authored as scripts and are the right tool for "watch that my signup / checkout / dashboard still works on every deploy."

> **What to author chains FOR:** `reference/invariants.md` is the catalog of the ~22 fundamental security invariants — each tagged ENGINE / CHAIN / CODE-REVIEW with its matcher shape and a "Fit to THIS app" line. **`AUDIT.md`** is the systematic flow that walks that catalog category by category, fitting and proving each against one app. This file (`CHAINS.md`) is the authoring mechanics those two lean on.

**Mental model:** a custom test is ONE HTTP request plus a rule (a "matcher") saying what "exploited" looks like vs "safe/patched". You author it as JSON, submit it, get back a verdict — a TEST OUTCOME:
- `vulnerable` = test **FAIL** — the exploit reproduced (status in your success set AND your positive marker matched). The must-not-happen happened.
- `fixed` = test **PASS** — the app positively denies it (a status in `fixedStatusIn`, e.g. 401/403/429, or a proven-empty result).
- `inconclusive` = **NOT a result — a broken, unfinished test.** Your assertion didn't describe what the endpoint actually does (unhandled status, unparsed body, marker that never matched, setup that failed).

> **The author owns the assertion — the most important rule.** LaunchGuard does NOT decide whether the app is secure; it runs your request and reports which branch of YOUR matcher fired. The `assertion` block IS your assertion, like the `expect(...)` in a unit test. Before authoring, you must be able to say in one sentence *"this endpoint SHOULD do X, and the test PASSES when it does."* If you can't, you have a random ping, not a test.
>
> **Never accept an `inconclusive`.** It means you haven't finished writing the test. The fix is always: READ the actual status + body, decide what the endpoint SHOULD do, and encode it into the matcher (`successStatusIn` / `fixedStatusIn` / a positive marker) so the run routes deterministically. Re-run until it resolves. The ONLY time you archive instead of fix is a genuinely unassertable test — the engine couldn't even issue the request, so there's no response to read (e.g. a cross-tenant chain dying at `no_credential_resolver` before any HTTP call). "I didn't define the expectation" is never that case.

This is a real, opt-in capability, separate from the free scan. It runs only against a domain the user has **added to their account**, sends the **minimum** requests to prove the point, and in the read-only form below changes nothing on the target.

> The authoring flow below keeps its original step numbers (2, 3, 3b, 4, 5). The old first step — pasting an API key by hand — is gone; authentication is now the one-click device login in `CONNECT.md` (Step 0).

## Proof vs Guard — does this test re-run on every deploy?

Every custom test is one of two classes, set by the top-level `watched` boolean at ingest (and changeable later via PATCH):

- **Proof** (`watched: false`, **the default**) — a one-shot. You author it, run it once, report the verdict, and it stays as stored evidence. It does **not** re-run on deploy. This is the right class for the many exploit proofs you author while triaging a scan ("show me this is exploitable right now"). Authoring ten proofs during an audit should NOT silently fill the user's watched suite with ten auto-running tests.
- **Guard** (`watched: true`) — joins the deploy-replay suite. On every detected deploy LaunchGuard re-runs it and alerts on regression (a `fixed` chain that comes back `vulnerable`). Reserve this for the handful of rules the user genuinely wants watched forever.

**Default to Proof, including the first tailored test in the Connect / onboarding flow.** Only set `watched: true` when the user's intent is explicitly ongoing protection — they said "watch this on every deploy", or you/they decide a specific proof is worth guarding. Onboarding proves ONE boundary and keeps it as a saved Proof; watching it on every deploy (a Guard) is a separate step the user opts into afterward, not the default first action. A user can promote a Proof to a Guard (or demote) anytime from the custom-tests page or via `PATCH /api/v1/chains/<id>` with `{ "watched": true|false }`.

`watched` is **orthogonal to side-effect**: a mutation chain never auto-runs regardless (the safety gate is separate), so marking a mutation `watched: true` does not make it fire on deploy — only read-only Guards auto-run. This separation is exactly what lets you safely **AUTHOR a destructive test** (a cross-tenant / anon write or delete, a paid-call probe) and hand it to the user: stored — or even watched — it fires nothing until they explicitly confirm the run. So the right move on a destructive invariant is **author + surface, never skip and never auto-fire** (see the side-effect footgun and the `409 needsConfirmation` note below).

### `lastResult` values (what each list row's last verdict means)

Every chain row carries `lastResult`, the outcome of its most recent run:

| `lastResult` | Meaning | Healthy state? |
|---|---|---|
| `fixed` | Last run PASSED — the app denied the exploit (or proved empty). For a functional chain, `fixed` = working/green. | ✅ This is the win, not a broken test. |
| `vulnerable` | Last run FAILED — the exploit reproduced (marker matched). For a functional chain, `vulnerable` = broken/red. | ⚠️ A real finding (unless `dispositionState` is `honored`). |
| `inconclusive` | The run was ambiguous/unsound — an unhandled status, unparsed body, a marker that never matched, a setup that failed. Not a result; a test that needs finishing (read the real response, fix the matcher). | 🔧 Fix the assertion; don't report either way. |
| `null` (never run) | The chain has been ingested but never executed. **On a mutation chain this is EXPECTED, not broken** — mutations never auto-run, so a `lastResult:null` mutation is normal stored coverage awaiting an explicit confirmed run. | ✅ for mutations; for a read-only Guard, just run it once. |

## The format: one request plus a matcher, submitted as JSON

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
| the human story shown to the founder | top-level `interpretation` | `{ headline?, whyItMatters?, whoCanDoIt?, attackerNextStep?, fixHint? }`, all optional free-form prose, rendered VERBATIM. See "The `interpretation` block" below |
| severity (optional) | top-level `severity` | **optional**; omit it and the engine defaults to `critical`. The product shows a binary **Exploitable / Safe** status, not a graded tier, so you no longer pick a level |
| watch it on every deploy (Guard) vs one-shot (Proof) | top-level `watched` | boolean, **defaults `false` (Proof)**. See "Proof vs Guard" above |

That is the whole matcher vocabulary. Do NOT invent `bodyContainsAny`, `statusEquals`, `regex`, etc.

**Two templates cover almost everything:** the **anonymous read** (Step 3, the 90% case) and the **authenticated cross-tenant read** (Step 3b, the flagship "a logged-in user can see another tenant's data" test). Both are inlined below. For anything beyond them, such as multi-step chains, extractors, the exact JSONPath dialect, `minTotalRows`, or the full verdict-routing rules, **READ `reference/chains-reference.md` before authoring.** This file gives you the two templates; the reference gives you the rest. Authenticated and cross-tenant tests in particular depend on fields (`spec.env.anonKey`, `crossTenant`) that only the reference fully specifies.

### The `interpretation` block: your words, shown to the founder verbatim

Every custom test now carries a top-level `interpretation` object. This is the human story a non-technical founder reads on the result card, and it is the ONLY place that meaning comes from: **the engine never writes, summarizes, or infers it from your assertion.** It renders exactly what you put here, word for word, so write it honestly, impact-first, and in plain language a solo founder understands. If you leave it empty, the founder sees a bare HTTP request and a green or red status with no idea whether it matters, which is the exact failure this block fixes.

All five fields are optional free-form prose, but `headline` and `whyItMatters` carry the most weight (they are the card's title and body, read first and often the only two the founder reads, see "How the founder reads the card" below), so write those two for every chain. Still write `fixHint` well: it anchors the dashboard "How to fix" block and the copy-able fix prompt:

- **`headline`** (≤200 chars): one plain-language sentence naming who can do what, the line the founder scans first. Use "Anyone with no account can run up your AI bill", not "POST /api/chat returns 200".
- **`whyItMatters`** (≤1000): why this is bad for the business in concrete terms, what data leaks, what it costs, what a customer loses.
- **`whoCanDoIt`** (≤300): the attacker's starting position, framed by the real evidence (see provenance below), for example no login at all, any signed-up user, or an under-privileged member.
- **`attackerNextStep`** (≤500): what an attacker does with this once they find it, such as enumerate, scrape, loop to run up cost, or pivot.
- **`fixHint`** (≤2000): your own plain fix guidance. This is also the **free fallback** the fix-prompt loop hands back when the owner is not on Pro (see Step 5), so make it actionable on its own.

Caps are per field as listed above, with an 8KB total, and unknown keys are rejected, so use only these five names.

**Frame `whoCanDoIt` from the real provenance.** The evidence now distinguishes a credential the attacker **FORGED** (a value they put in the request themselves, e.g. a guessed cookie or the app's public anon key) from a session that was legitimately **CAPTURED** (a real provisioned login). Match your wording to whichever one proved the exploit: "anyone with no login, using a value they can forge" reads very differently from "any logged-in user, using their own real session", and getting that distinction right is what makes the founder trust the finding.

#### How the founder reads the card: write for it, top to bottom

The card (the `HttpTestExecutor`, shown BOTH in the anonymous onboarding funnel AND embedded in the dashboard chain-detail page) renders top to bottom, and a non-technical founder rules on it in that order. Write for that reading order:

1. **`headline`** is the big title line at the top, the very first thing read (it falls back to the chain `title`, then to a generic "Is this intended?").
2. **`whyItMatters`** is the body paragraph directly under the headline, always visible. This is the "body" the owner loves.
3. Then the product prints one or more **step lines** ("We send a GET request to .../items/projects without logging in, exactly like a stranger would") and the **outcome** ("→ The server responded with HTTP 403"). You do NOT write these: they are machine-generated from the request you pick (method, path, resolved host, role, anonymous vs authed) and from the real response. Your only lever here is choosing the request precisely, so its auto-generated sentence reads true.
4. Then the hardcoded chain-level question **"Is this what you intended?"** with two buttons ("No — lock it down" / "This is public on purpose"), and under them a soft nudge line = **`attackerNextStep`**.

The founder must understand **what happened and whether it matters from `headline` + `whyItMatters` alone**, before they ever look at the request, the raw JSON, or the fix. So the whole story goes into those two. Write **`attackerNextStep`** as the stakes line the founder weighs right before ruling ("here is what is at stake, you decide"), not a jargon wall.

On the card, `whoCanDoIt` shows only as a fallback when `whyItMatters` is empty, and `fixHint` shows only after a regression (the "earned red" state), so they are secondary THERE. But the full dashboard chain-detail page (FindingView) renders them as labeled lines around the card ("Who can do this:" = `whoCanDoIt`, "What they do next:" = `attackerNextStep`, "How to fix" = `fixHint`), and server-side ALL FIVE fields feed the assembled "Copy fix prompt" the owner pastes into their coding agent (`fixHint` is also the fallback shown to anonymous, not-signed-in users). Every field is read somewhere, so write all five well; do NOT drop `whoCanDoIt` or `fixHint` just because they are not the card's lead.

**Priority for every chain:** make **`headline` + `whyItMatters`** carry the complete story on their own; `attackerNextStep` sets the stakes; `whoCanDoIt` + `fixHint` complete the dashboard and the fix prompt.

#### RED vs GREEN framing: match the words to the observed verdict

The template above uses the RED framing ("Anyone with no account can run up your AI bill"), which asserts the exploit works RIGHT NOW. But most well-authored guards, and the onboarding default, are witnessed-GREEN gate guards (see the recipe below) where the current result is a 403/denied and the gate HOLDS. For those, an "Anyone can do X" headline is FALSE right now and misleads the founder. Pick the framing by the verdict you actually observed:

- **RED (exploit reproduced, `vulnerable`):** state what an attacker can do right now, e.g. "Anyone with no account can run up your AI bill".
- **GREEN (gate holds, `fixed`, the witnessed-green guard, the common onboarding case):** frame `headline` as what is GUARDED, e.g. "Guards that no-login strangers can never read other companies' data". Frame `whyItMatters` to state the invariant, WHERE it is enforced, the CURRENT safe state (correctly denied, 403), and the REGRESSION TRIGGER that would break it ("a single policy edit or a schema migration that resets permissions would instantly expose every tenant ... this guard turns red the moment that happens"). Frame `attackerNextStep` as the CONDITIONAL blast radius ("if it ever opens, an attacker could page through ... scrape ... leak or sell ... pivot off the ids").

**Gold standard for a witnessed-green guard** (a real Directus multi-tenant example, this is what great looks like):

- **Headline:** "Guards that no-login strangers can never read other companies' construction projects from the Directus backend."
- **Body (`whyItMatters`):** "Sapuri is multi-tenant: each construction company's projects, addresses, phases, members and documents must stay private to that company. That isolation is enforced ONLY by Directus role/policy permissions on the sapuri.directus.app backend, a separate public host whose URL even ships to the browser for file downloads. Right now the anonymous 'public' role is correctly denied (403). But a single Directus policy edit, a role misconfiguration, or a schema migration that resets permissions would instantly expose every tenant's project data to the entire internet with no account needed. This guard turns red the moment that happens."
- **Judge hint (`attackerNextStep`):** "Page through /items/projects, and the sibling collections companies, project_members, directus_users, directus_files, to scrape every tenant's projects, addresses, member emails and files, then leak or sell the data or pivot off the ids and emails."

Why it works: the **headline + body alone tell the whole story** (a non-technical owner learns what is protected and why without reading the request); the body names both the **current safe state** (correctly denied, 403) and the **regression trigger** (the policy edit or migration that would break it), so a future red is self-explaining; and the hint is the **conditional blast radius**, framed as "if it ever opens", not a present-tense claim that the data is already leaking.

## Authoring a chain

### Step 2: list existing chains first (avoid duplicates)

Before authoring anything, list what already exists so you don't re-create a test that's already there. To see chains for one app, filter by host; **with NO `targetHost`, the list returns every chain across all monitored hosts — that is how you discover which apps the account has** (the only way to enumerate apps from the API):

```bash
# this host only:
curl -s "https://api.launchguard.dev/api/v1/chains?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
# every app the account monitors (omit targetHost):
curl -s "https://api.launchguard.dev/api/v1/chains" -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

Response: `{ "count": N, "chains": [ { "chainId": "...", "title": "...", "lastResult": "...", "watched": false, "dispositionState": "none", "exploit": { "method": "POST", "path": "/api/chat", "target": "primary" } }, ... ] }`. The `lastResult` values are defined in the table above ("Proof vs Guard" → "`lastResult` values"); the full row shape is in `reference/chains-reference.md` §7.

**The dedupe key for an HTTP request-plus-matcher chain is the `exploit` object `{method, path, target}`** — and ONLY for those chains. `path` is the FULL path including the query string, so `/api/widget/config?slug=a` vs `?slug=b`, or `/rest/v1/t?select=x` vs `?select=x,y`, are DISTINCT tests, not duplicates. Two HTTP chains are duplicates only when method, full path (query included), AND target all match. If unsure, `GET /api/v1/chains/<chainId>` on each and diff the full `spec` before archiving either.

> **⛔ SAFETY-CRITICAL CARVE-OUT — the `{method,path,target}` dedupe key is INVALID for script / Playwright chains.** A script chain (functional regression or captured-session auth test) has no per-request method/path/target — its `exploit` key collapses to a constant like `(PLAYWRIGHT, "(script chain)", primary)`, IDENTICAL across every script chain. Dedupe those by that key and you will flag nearly every functional test as a "duplicate" of the first one and **archive real, distinct coverage.** A script chain's identity is its **script source (`spec.script.source`) / title**, not its request tuple. So for any chain whose target/method reads as `PLAYWRIGHT` / `(script chain)`: dedupe by **title**, or by `GET /api/v1/chains/<id>` and diffing the actual `spec.script.source` — **NEVER by the exploit summary.** When in doubt, treat two script chains as DISTINCT. (The full script-chain ingest + read-back shape is `reference/chains-reference.md` §12.)

Only author a new chain when nothing covers the rule. If a chain already covers the same exploit key, re-run it (`POST /chains/<id>/run`) instead of duplicating; or, for a genuinely different assertion, inspect the blueprint and author a distinct variant. To remove a true duplicate or broken test, archive it with `DELETE /api/v1/chains/<chainId>` (reversible via `POST /chains/<id>/restore`) — see the **Cleanup / triage pass** section below for the full archive decision rules, and `reference/chains-reference.md` §7 for the archive/restore contract.

### Step 3: write the proving curl first, then translate it

Always start from the plain request that proves the exploit, the thing you would paste into a terminal as an anonymous attacker. **Run it for real** and look at the response body — you need to see the actual success field it returns. Then translate it mechanically into the JSON. Minimal, valid, read-only template (the 90% case, e.g. an unauthenticated paid endpoint):

```json
{
  "title": "Anonymous request triggers paid AI work without auth",
  "targetHost": "sandbox.example.com",
  "source": "ai_agent",
  "watched": false,
  "interpretation": {
    "headline": "Anyone with no account can run up your AI bill",
    "whyItMatters": "Your /api/chat endpoint answers without checking who is calling, so a stranger can send unlimited requests straight to your paid AI provider. Every call costs you money, and nothing stops a bot from looping it thousands of times overnight.",
    "whoCanDoIt": "Anyone on the public internet, with no login and no account. No stolen credentials are needed; the request below carries no auth at all.",
    "attackerNextStep": "Script the same request in a loop to burn your provider credits, exhaust your quota, or push your bill into the thousands before you notice.",
    "fixHint": "Require an authenticated session on POST /api/chat and add a per-user rate limit before the call reaches the AI provider. Reject anonymous callers with 401."
  },
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
- **`interpretation` is the human story the founder actually reads** (rendered verbatim). Write all five fields honestly; `headline` and `fixHint` carry the most weight. See "The `interpretation` block" above.
- **`severity` is omitted on purpose.** It is now optional (the engine defaults to `critical`) and the product shows a binary **Exploitable / Safe** status, so there is no tier to declare.
- **`"jsonPathsPresent": ["$.id"]` is a PLACEHOLDER.** You MUST replace `$.id` with the actual success field you saw when you ran the proving curl in this step. Real endpoints often return a different field (e.g. `/api/checkout` returns `checkoutUrl`, not `id`). Copying `$.id` blindly makes a genuinely vulnerable endpoint come back `inconclusive` because the marker never matches.

Pick a positive marker that proves the **paid work actually ran**: a completion id, a queued job id, a provider response field — whatever field you actually observed. That marker is your `jsonPathsPresent` (a field that must exist) or `bodyContainsAll` (literal substrings).

### Step 3b: authenticated cross-tenant test (the second template)

Use this to prove **"a logged-in user can read another tenant's rows"**: broken or missing row-level security on a Supabase table. This is LaunchGuard's flagship authenticated test; a generic scanner can't write it. The engine signs up a **fresh throwaway account per run** (via `spec.env.anonKey`) and queries the table as that low-privilege identity. If any returned row is owned by someone else, RLS is broken.

> **PRE-FLIGHT GATE — this template only works on a Supabase-Auth app with a legacy `eyJ...` anon key.** The engine mints the second identity by signing a fresh user up through Supabase Auth (GoTrue). Two things break it — check both BEFORE authoring:
> 1. **Auth provider.** Clerk / Auth0 / NextAuth / Firebase Auth (anything NOT Supabase Auth) has no GoTrue signup path: the run dies at `auth_failed: no_credential_resolver` before any HTTP request, so it is unassertable — do NOT author it.
> 2. **Key format.** A new `sb_publishable_...` key carries no embedded JWT identity; `crossTenant`/`{{auth.userId}}` need a legacy `eyJ...` JWT anon key.
>
> When either is true, use a fallback instead: (a) the **anonymous-exposure** style below (`minTotalRows >= 1` with the public key in headers — works with EITHER key type, no Supabase Auth needed); or (b) a **captured-session script chain** (`reference/chains-reference.md` §9) to run the cross-tenant read as a real provisioned user even on a Clerk/Auth0/Firebase-Auth app.

> **⚠️ Credential ceiling: the engine returns `inconclusive` (not a false `fixed`) when it can't mint the second identity.** The second-identity mint is **FREE**, not a Pro gate: the engine provisions a fresh throwaway identity via inline Supabase anon-signup with no server-side Pro check. It can still FAIL on the non-Supabase-Auth / `sb_publishable_` cases above, or on a signup error. When the engine **can't mint** that identity, the cross-tenant boundary was never exercised, and the backend reports that honestly as **`inconclusive`** (`credentialProvenance: "none"`, or a body like `"No API key found"`), **never a misleading `fixed`**, so you won't be fooled into reporting a pass. **So don't drop the test: AUTHOR it and SURFACE it** so the user can run it with the credential it needs: on a non-Supabase-Auth app, a **captured-session script chain** (§9) runs the cross-tenant read as a real provisioned user. Storing the HTTP chain is harmless (a GET cross-tenant read fires nothing on the target), and the captured test you hand over IS the value. (Still sanity-check `credentialProvenance` on any cross-tenant `fixed`: a real provisioned identity is what makes a `fixed` trustworthy.) Cross-reference `reference/methodology.md` Step 7 (#6, the credential ceiling) and `reference/invariants.md` B1.
>
> **The Pro line is browser/custody, not the mint.** The HTTP cross-tenant chain here (the inline anon-signup) is free and unbounded. The Pro signals live on the **browser / captured-session** path: any non-Pro real-browser (script) chain run → `402 browser_testing_requires_pro` (real-browser testing is Pro; there is no free browser proof), and running a chain that carries a STORED credential → `402 stored_credentials_require_pro`. Branch on whichever live server signal you actually get (`requiresPro` / `402` / `locked` / `inconclusive`), never a hardcoded tier.

You need the target's **public** Supabase anon key + project ref — client-side values that are meant to be public (using them is not exfiltration). Get them by grepping the site's JS bundles (`supabase.co` → project ref, `sb_publishable_` or a legacy `eyJ...` token → the key) or from the free scan's `secrets` output. Template:

```json
{
  "title": "Authenticated user can read other tenants' rows in `businesses`",
  "targetHost": "sandbox.example.com",
  "source": "ai_agent",
  "watched": false,
  "interpretation": {
    "headline": "A logged-in user can read every other customer's records",
    "whyItMatters": "The businesses table hands back rows that belong to other accounts when any signed-in user asks for them. Row-level security is not isolating tenants, so one customer can read another customer's private data.",
    "whoCanDoIt": "Any user who can sign up for an ordinary account, using their own legitimate login. No admin rights or special access are needed; the engine proved it with a fresh throwaway signup it created itself.",
    "attackerNextStep": "Page through the table to scrape every tenant's records, then leak or sell the data, or pivot off the ids and emails it exposes for targeted attacks.",
    "fixHint": "Enable row-level security on the businesses table and add a policy that limits each row to its owner (for example user_id = auth.uid()). Re-test that a second account sees zero foreign rows."
  },
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

How it reads: `target: "supabase"` routes the request to `allowedTargets.supabase`; `{{auth.userId}}` resolves to the fresh signup's own id; `crossTenant` passes only if at least one row's `user_id` differs from it → `vulnerable` (RLS broken). A `401`/`403` or an RLS-denial envelope (`42501`/`PGRST`) → `fixed` (RLS working). Replace `businesses` and `user_id` with a real tenant table + its owner column (discover them from the free scan's `supabase_findings`). The `crossTenant` shape, the JSONPath dialect, and `minTotalRows` (an alternative "more rows than this user could own" marker) are detailed in `reference/chains-reference.md`.

Validation note: because the engine signs up its OWN throwaway account for this template, you cannot reproduce that identity with a plain curl. For `crossTenant` / `anonKey` chains the `/run` verdict IS the validation. When the identity can't be minted the engine now returns **`inconclusive`** (not a false `fixed`); that is the honest "untested, needs a real provisioned credential" signal (e.g. a captured-session script on a non-Supabase-Auth app), NOT a tier gate; the mint itself is free. So **AUTHOR and SURFACE the test for the user to run with the right credential** rather than dropping it. A `fixed` here is trustworthy only with `credentialProvenance` showing a real provisioned identity, so still sanity-check it.

**Do NOT author per-table `anon-db-*` read chains as a default.** The `supabase` engine stack already tests EVERY table / bucket / RPC as the anon role on every scan. You will see this directly in `/context`: `recommendations.action === "skip"` for `supabase` ("Default Supabase stack covers every table/bucket/RPC as the anon role. Do NOT author per-table anon-db read chains"), and `inventory.supabase.tablesTested` covering all discovered tables. Trust `/context`; do not re-derive the engine. Re-authoring a per-table anonymous PostgREST read is redundant coverage the engine already owns.

Reserve the anonymous-read template for GENUINE gaps the engine cannot see:
- **An app route returning a JSON array of sensitive records** (the most common real vibe-coder mass-exposure): the engine does NOT crawl arbitrary app-route bodies, so this IS a real gap. Author it with `jsonPathsPresent` on a sensitive field; full template in `reference/chains-reference.md` §5.1.
- **A specific table `/context` itself flagged as a gap** (e.g. one the engine somehow missed and surfaced in `coverageGaps[]` / a `recommendations` item).

Two Supabase read styles still exist, pick by the question: to prove **"a logged-in user can cross tenant boundaries"**, use `spec.env.anonKey` (the engine signs up a fresh user, as above), which is RLS-for-authenticated-users testing the engine does not do per-table. To prove the simpler **"this table is readable by an anonymous client at all"** on a genuine gap, send a `target: "supabase"` GET to `/rest/v1/<table>` with the target's public anon key in the request headers (`apikey` AND `authorization: Bearer <key>`, plus `"Prefer": "count=exact"`) and assert on `minTotalRows: 1`. This anon style works with EITHER a legacy `eyJ...` JWT or a new `sb_publishable_...` key and does NOT require Supabase Auth, but only reach for it on a gap, since the engine already sweeps every table anonymously by default.

> **API arrays count too — the most common real vibe-coder mass-exposure.** Anonymous mass-exposure is NOT only a PostgREST/`content-range` thing. The everyday case is an **app route returning a JSON array of sensitive records without auth** (e.g. `GET /api/widget/config?slug=x` → an array of names + phone numbers) — a first-class anon mass-exposure finding, rendered as the same structured "rows" evidence card on the dashboard. Assert it with **`jsonPathsPresent` on a sensitive field** (e.g. `["$[0].phone"]`), optionally plus `bodyContainsAll` on a known value — **NOT `minTotalRows`** (it needs a PostgREST `content-range` header a plain API array won't carry → it never fires → false `inconclusive`). Worked template: `reference/chains-reference.md` §5.1.

### Recipe: the witnessed-GREEN gate guard (you can NEVER see the 200)

A very common guard type breaks the Step 3 rule "run it and look at the actual success field": guarding that an **auth gate STAYS closed**. To prove a protected route keeps denying anonymous (or under-privileged) callers, the only response you can ever observe is the **401/403** — you will NEVER see the 200 success body, because if you could, the gate would already be broken. So you cannot copy a real success field out of a response you're not allowed to get. Author it forward-looking instead:

- **`successStatusIn: [200]`, `fixedStatusIn: [401, 403]`** (add `429` where a rate-limit denial also counts as the gate holding).
- You STILL need a positive marker, so the chain CAN reach `vulnerable` on a future regression — but you're choosing it for a 200 you can't observe yet. Pick a **forward-looking marker that describes what a LEAK would look like**: a field that WOULD appear in the body if the gate broke open. For a profile route, `jsonPathsPresent: ["$.email"]`; for a checkout route, `bodyContainsAll: ["checkout.stripe.com"]`; for an admin list, a field only the real payload carries. Prefer a marker you're confident the leaked body would contain.
- **Expected outcome NOW: `fixed`** — the gate denies you (401/403), which is a **witnessed GREEN and exactly the win you want**. This is not a broken or unfinished test; it is the protection proving itself. If the gate later regresses to a 200, your forward-looking marker matches the now-leaking body and flips the verdict to `vulnerable` — that's the regression alarm firing. Author these as Guards (`watched: true`) so the deploy-replay suite watches the gate forever.
- **Write the `interpretation` in the GREEN framing** (see "RED vs GREEN framing: match the words to the observed verdict" above): a guard-what-it-protects `headline` and a `whyItMatters` that names the current safe state (correctly denied, 403) plus the regression trigger, NOT the RED "anyone can do X" wording, since the observed result here is the 403 (the gate holding), so an "anyone can do X" claim would be false today.
- **Honest caveat:** because you're guessing the marker for a body you've never seen, a real future regression could surface as **`inconclusive`** (200 returned, but your guessed field wasn't the one that leaked) rather than a clean `vulnerable`. Mitigate by choosing **robust markers** — a field the route's payload almost certainly carries. And don't treat a suite of all-`fixed` gate-guards as a cop-out: **a clean sweep of witnessed-GREEN gate guards is a valid, honest result** — every gate denied you, which is the whole point.

### Footguns that fail authors most

These are the high-stakes ones — the **judgment and safety** rules. The exhaustive mechanical catalog (host-normalization byte-equality, the `target` enum, the JSONPath subset grammar, the `minTotalRows` `Prefer: count=exact` header, RPC zero-arg rule, redirect-routing limitation, title-uniqueness/`500`) is in **`reference/chains-reference.md` §1–§8** — read it before authoring anything past the two templates.

- **Always include at least one positive marker** (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`). `successStatusIn` alone can only ever yield `fixed` or `inconclusive`, never `vulnerable` — a markerless chain is structurally unassertable (the cleanup-archive criterion (b)).
- **`fixedStatusIn` is required** (e.g. `[401,403,429]`). The engine throws at run time without it (`fixedStatusIn is not iterable`) and the run becomes a false `inconclusive`. Both templates include it; never drop it. Add `400` when the patched app rejects the exploit input that way (e.g. a rejected OTP). **A `404` is never `fixed`** — a deleted endpoint must never read as a false fix.
- **Side-effect is re-derived from the HTTP method — any non-GET is `mutation`.** Method-based, not word-based: `GET`/`HEAD` (and a Supabase `/rest/v1/` GET) is `read_only`; any `POST`/`PUT`/`PATCH`/`DELETE` is `mutation`. A `mutation` chain NEVER auto-runs. An unconfirmed `/run` returns `409 { "needsConfirmation": true }`; only `{ "confirmMutation": true }` (against a monitored domain) fires it, exactly once. The auto-run gate means LaunchGuard never fires a write on its own. See "Running mutation tests" below. **This gate is exactly why you AUTHOR destructive tests instead of skipping them:** authoring/storing a mutation chain (a cross-tenant or anon write/delete, a paid-call probe) fires nothing, so you capture the test and **SURFACE it to the user**, whose explicit confirmation is the only thing that runs it. The shift on a destructive invariant is skip → **author + surface + user-runs**, never skip → fire.
- **A GET that triggers downstream WRITES is a deploy hazard.** Side-effect is method-derived, so a `GET` that proxies to a write / a spend is still classified `read_only` + auto-replay and will fire that write on EVERY deploy. There is no GET→manual downgrade. Do NOT author it (or archive it if you did); cover the endpoint a safer way.
- **Cross-host targeting is the key to backend/Supabase tests.** Only `allowedTargets.primary` must byte-equal `targetHost`; `.api` and `.supabase` are free-form passthrough hosts that may differ from the monitored domain. Use `target: "api"` to hit a separate backend directly — unauth BOLA / object-access holes usually live there, even when the frontend proxy is gated.
- **The matcher cannot express rate-limit, response-time, or response-header assertions.** No "fire N, expect 429", no `maxResponseMs`, no header matcher. A pure missing-rate-limit (OWASP API4) or missing-security-header bug is NOT authorable as a chain — report those as code-review findings, not chains.
- **A `vulnerable` verdict is not automatically a finding, so don't cry wolf.** `severity` is now optional (the engine defaults it to `critical`) and the product shows a binary **Exploitable / Safe** status, so there is no tier for you to grade, just an honest call on whether this is real. A `vulnerable` verdict only means "an outsider reached this and the marker matched", it does NOT mean the data is sensitive. Aggregate public counters (`/api/stats`), a published pricing list, or a public blog feed answer unauthenticated BY DESIGN and are NOT findings (the `reference/methodology.md` Step 6 intended-public filter). Reserve `vulnerable` for data that crosses a real trust boundary (another tenant's rows, PII, internal ids/emails, secrets, paid work). When genuinely ambiguous, label it "needs product triage" rather than forcing a verdict. A clean sweep where every table returns `fixed` is the suite WORKING, not broken assertions.

### Step 4: submit and run

```bash
# ingest  -> { "chainId": "...", "sideEffect": "read_only", ... }
#   (a read-only chain comes back ready to auto-run; a mutating-looking one is stored manual-only)
curl -X POST https://api.launchguard.dev/api/v1/chains \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d @chain.json

# run once -> { "result": "vulnerable|fixed|inconclusive", "reason": "...", "matched": ..., "interpretation": {...}, "fixPrompt": {...}|null }
curl -X POST https://api.launchguard.dev/api/v1/chains/<chainId>/run \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json"
```

The `/run` response also carries `matched` (true only on `vulnerable`) and `regression` (true when a chain that previously read `fixed` now reads `vulnerable`, i.e. a fixed bug came back). **If you ingested it as a Guard (`watched: true`), it re-runs on every later deploy** and `regression: true` is the alarm that a protection you'd verified has broken again. A Proof (`watched: false`, the default) does NOT re-run on deploy — it stays as the stored verdict from this run until you (or the user) promote it to a Guard.

Report the verdict plainly:
- `vulnerable` plus the `reason` (e.g. `exploit_reproduced: assertions passed`) means the paid path is reachable unauthenticated. Show the user the marker that proved it.
- `fixed` means it is properly gated (401/403/429, or a proven-empty result, e.g. `access_denied: HTTP 401` or `exploit_absent: total 0 < 1`). Say so clearly.
- `inconclusive` means the proof was ambiguous (404/5xx/unreachable/engine error). Do not claim either way.

> **A `409 needsConfirmation` on a mutation `/run` is HEALTHY gating, not an error — and not an `inconclusive` you must fix.** Many real cost / payment / broken-access gaps live behind POST-only routes, so the only chain you can author for them is a `mutation` (any non-GET; see the side-effect footgun above). A `mutation` never auto-runs: an unconfirmed `/run` returns `409 { "needsConfirmation": true }` and the stored `lastResult` stays `null`. **That is complete, valid coverage** — the chain is parked as a watched Guard with a regression alarm that only ever fires on an explicit confirmed run. **This gate is precisely the mechanism that makes "author the destructive test and let the user decide to run it" SAFE:** the captured, parked test fires nothing until the user's explicit confirm, so on a destructive invariant you **author it and surface it to the user** — you do NOT skip it (that throws away the value) and you do NOT auto-fire it on a live app. The "never accept an `inconclusive`" rule is about READ-ONLY chains whose matcher didn't describe the response; it does NOT mean you must squeeze a clean `vulnerable`/`fixed` out of a mutation you are not authorized to fire. The proving curl you ran by hand IS your evidence; do not rewrite the POST as a GET to dodge the gate (that changes what the test sends). See "Running mutation tests" below.

**Pointing the user at the dashboard:** do NOT hand-build a `https://launchguard.dev/app/<id>` link from a chain row, because chain rows carry no `appId`, so you cannot construct that `<id>` yourself. Instead, get the real `dashboardUrl` from the API and pass that: both `POST /api/v1/connect` and `GET /api/v1/context` return a ready `dashboardUrl` for the app. So call `/context` (it is `lg_`-key-callable) or read the connect response, and point the user at the `dashboardUrl` it hands you. Always use the API-provided URL; never build the link from a chain row.

### Step 5: close the loop with the fix prompt

A `vulnerable` verdict is not the end. `GET /api/v1/chains/<id>` and the `POST /chains/<id>/run` response now both return two extra fields you should act on:

- **`interpretation`**: the author's own block, echoed back verbatim (always present, free).
- **`fixPrompt`**: how to fix it. The assembled, stack-tailored fix prompt is **FREE for any authenticated owner** (free OR Pro); it is NOT a Pro feature. The only locked case is anonymous. Branch on the live shape:
  - **Authenticated owner, confirmed `vulnerable`:** `{ "available": true, "prompt": "<assembled, stack-tailored fix prompt>" }`. Apply `fixPrompt.prompt` directly; it is assembled from the masked evidence, the interpretation, and the detected stack. An AI agent authoring through an `lg_` key IS the authenticated owner, so this is the shape you normally get — apply it.
  - **Anonymous (no owner), confirmed `vulnerable`:** `{ "available": false, "locked": "signup", "fixHint": "<the author's own fixHint, or null>" }`. The wall is a SIGNUP wall, not a paywall; there is no assembled prompt for an anonymous caller, so fall back to `fixPrompt.fixHint` (the `interpretation.fixHint` YOU wrote) and tell the user that signing in unlocks the full stack-tailored prompt (it costs nothing).
  - **No confirmed-vulnerable run yet:** `fixPrompt` is `null`. Run the chain and confirm it `vulnerable` before expecting a fix prompt.

Always branch on the live `fixPrompt` shape (`available` / `locked`), never on a hardcoded tier.

Then **close the loop**: apply the fix to the project, and re-run `POST /api/v1/chains/<id>/run` to confirm the verdict flips from `vulnerable` to `fixed`. That re-run is the external proof the fix actually landed, the chain equivalent of the scan loop in `SKILL.md` Step 6 (Phase A — verify with the user, then fix only what's real; code fix → external proof). If it still reads `vulnerable`, the fix did not hold; iterate.

## Cleanup / triage pass — curating an existing suite

When the user says "clean up / manage / triage / dedupe / prune / review my tests" (or you're tidying a suite you didn't author), this is decision logic, not authoring. List the suite (`GET /api/v1/chains` for all apps, or `?targetHost=<host>` for one), then apply this checklist **per chain**. When unsure, KEEP — archiving real coverage is the expensive mistake.

The default list is already the **ACTIVE set** — archived chains are excluded, so you're triaging only live coverage; add `?includeArchived=true` to also see archived rows (each carries `archived: true`), e.g. to find one to restore. Run the whole cleanup pass against `https://api.launchguard.dev`.

**Archive a chain ONLY if one of these is true:**
- **(a) Exact duplicate** of another *custom* chain — same `{method, path, target}` dedupe key, respecting the script-chain carve-out in Step 2 (dedupe script/Playwright chains by title or by diffing `spec.script.source`, **never** by their constant `(PLAYWRIGHT, "(script chain)", primary)` summary). Keep the better-titled / more-recently-passing one; archive the redundant twin.
- **(b) Structurally unassertable** — the matcher has no positive marker (`jsonPathsPresent` / `bodyContainsAll` / `crossTenant` / `minTotalRows`), so the chain can only ever route to `fixed` or `inconclusive` and can NEVER reach `vulnerable`. It cannot prove the thing it claims to test. (Confirm by reading the `spec.assertion` via `GET /api/v1/chains/<id>` — don't infer from the row.)
- **(c) Obsolete** — points at a dead/placeholder host or an endpoint that no longer exists (the path was removed). Verify before archiving, inside the **minimum-requests boundary** (one confirming probe, not a sweep): re-run the chain (`POST /chains/<id>/run`) or issue the single proving request by hand and read what comes back. Honest caveat: **a `404` to your probe is NOT proof the route was removed** — a live route can 404 you because it gates anonymous callers, wants a param/slug you didn't supply, or sits behind auth (denying you, not gone). Treat it obsolete only when you can tell removed-from-the-app apart from denying-you (the host itself is dead/placeholder, or sibling routes answer while this exact path is a framework-level not-found). Can't tell? KEEP, and flag the path for a human eyeball rather than archiving on a bare 404.

**NEVER archive (these look broken but are healthy):**
- A **mutation chain that has merely never run** (`lastResult:null` on a non-GET). Mutations never auto-run by design — `null` is the expected resting state, not a defect. Mark it "mutation, fires real side effects, run only on explicit request."
- A chain whose unconfirmed `/run` returned **`409 needsConfirmation`** — that 409 is the mutation gate, not a failure.
- A chain with a **`proposed` or `honored` `dispositionState`** — a human (or you) recorded that its verdict is intended/reviewed. `honored` counts green; `proposed` is awaiting a human's confirmation. Archiving it discards that decision. (`stale_spec` / `stale_escalation` mean re-review, not archive.)
- A **passing `watched` guard just because it might overlap the built-in scanner**, UNLESS `/context` proves the overlap. Don't archive a passing watched guard on a guess. BUT if `GET /api/v1/context` marks that coverage engine-covered (`recommendations.action === "skip"` for the stack), or the chain is a per-table `anon-db-*` read duplicating the `supabase` engine stack (which tests ALL tables as anon), the engine's table-level coverage supersedes the per-table chain and you MAY skip / retire it. Trust `/context`: the anti-duplication rule now arrives as data, not a guess. See "Custom chains vs. the default scanner" below.

Archiving is reversible (`POST /api/v1/chains/<id>/restore`), but treat every archive as if it weren't: report what you're archiving and why before you do it, and prefer leaving a borderline chain in place.

### Custom chains vs. the default scanner: engine coverage is visible via /context

The engine's coverage is no longer a guess. `GET /api/v1/context` exposes exactly what the default scanner covers: its `tests[]` projects every engine check (kind `engine` / `byo_template`) as a verdict-bearing test, and `recommendations[].action === "skip"` names each stack the engine already owns ("do NOT author a chain for this"). So you CAN now tell when a custom chain duplicates default-scanner coverage:

- **Act on `recommendations.action === "skip"`.** If `/context` marks a stack engine-covered (e.g. `supabase`, `secrets`, `surface`), do not author a chain for it, and if the user already has a per-table custom chain duplicating it, the engine's coverage supersedes the per-table chain. The `supabase` engine stack tests EVERY table / bucket / RPC as the anon role (you'll see `inventory.supabase.tablesTested` covering all of them), so a per-table `anon-db-*` read chain is redundant with it; the engine's table-level coverage supersedes the per-table chain.
- **Custom-chain-vs-custom-chain dedupe is unchanged.** Dedupe two custom chains by their `exploit` `{method, path, target}` key (Step 2), respecting the script-chain carve-out. That rule still stands; what changed is that engine coverage is now data you can read, not a guess you must avoid acting on.

## The full lifecycle (manage / mutate / authenticate)

Your `lg_` key gives you the WHOLE custom-test lifecycle on a domain's suite without a human — list (`GET /api/v1/chains[?targetHost=<host>]`, `?includeArchived=true` to include archived), inspect (`GET /api/v1/chains/<id>` for the full `spec`, used to confirm a dedupe), create (`POST /api/v1/chains`), `PATCH` (promote/demote `watched`, or change `spec`/`title`/`severity` — changing `spec` re-validates and re-derives side-effect), run, and archive/restore (`DELETE` / `POST .../restore`, reversible, restore can `409 titleCollision`). Dedupe by the `exploit` `{method,path,target}` key, with the script-chain carve-out from Step 2. **Full request/response contracts (status codes, error shapes, the archive/restore + disposition details) are in `reference/chains-reference.md` §7.**

**Mutation runs** (any non-GET): an unconfirmed `/run` returns `409 { "sideEffect": "mutation", "needsConfirmation": true }` — the safety gate, not a verdict and not a defect. Fire it only with `{ "confirmMutation": true }`, against a domain the user monitors, on explicit instruction, exactly once (never a loop). Auto-deploy re-runs NEVER fire mutations. Don't rewrite a `POST` as a `GET` to dodge the gate — that changes what the test sends.

**Captured-session (authenticated) tests** — for "logged in but under-privileged" bugs the engine can't mint an identity for (a Pro-only route reachable by a free user, an admin function reachable by a member, an authed IDOR on a Clerk/Auth0/Firebase app): upload a Playwright `storageState` with `POST /api/v1/chains/credentials` and reference the returned `credentialId` from a **script** chain that runs authenticated as that real identity. The script-chain body is FLAT (top-level `artifact:"script"`, the Playwright spec as a top-level `script` STRING, the `// @lg-intent:` / `// @lg-secure-when:` header tags with **colons required**) — get it exactly right per `reference/chains-reference.md` §9 (credentials) + §12 (script-chain ingest), or the HTTP runner silently wins, the script never runs, and the run routes to a false `inconclusive`.

**Disposition** (mark a `vulnerable` verdict intended, e.g. an intended-public endpoint): `POST /api/v1/chains/<id>/disposition { "disposition": "proposed", "reason": "..." }`. An `lg_` key may only **propose**; a human confirms `accepted`. Branch on the row's `dispositionState` (`none|proposed|stale_spec|stale_escalation|honored`), not raw `disposition` — `honored` counts green, `stale_*` means re-review. Full model in `reference/chains-reference.md` §10.

### Boundary

Send the minimum requests to prove it, typically one ingest plus one run. Do not loop `/run` to load-test or hammer the endpoint. Only author chains for domains the user owns. The read-only form changes nothing on the target. Never escalate a read proof to a mutation without explicit user instruction.

---

For the full depth — the exact assertion vocabulary, the JSONPath dialect, multi-step preconditions and extractors, cross-tenant internals, script-chain ingest (§12), captured-session credentials (§9), disposition (§10), and the `/context` + `/stacks` contracts (§11) — **read `reference/chains-reference.md`.**
