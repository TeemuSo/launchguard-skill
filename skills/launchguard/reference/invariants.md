# Fundamental security invariants — the catalog the deep audit walks

The ~22 system-agnostic security invariants that hold for **every** app, with how to **test each
against THIS app**. Load this during a deep audit (`AUDIT.md`); it is the catalog of WHAT to prove,
and `AUDIT.md` is the flow that walks it category by category.

These invariants are the **SHOULD that comes free.** Most "is this secure" judgment needs the owner's
intent ("should Elon see Mike's record?"), but these hold from universal law (an anonymous client
can't read another tenant; secrets stay server-side) and from the code's own stated intent (this
route checks `role === "admin"`, so a member reaching it is a bug). You never ask a human whether
they hold — a violation is a bug in any app. That is exactly why they're auditable without steering:
the SHOULD is given, so a finding is just the **diff** between what the app *does* (proven black-box)
and what it *should* (this catalog).

## How to test without knowing the "right" answer — the metamorphic trick

You usually can't know the *correct* response of an arbitrary endpoint (that needs a spec you don't
have). So you don't assert the absolute answer. Instead: **transform a request in a way that must NOT
change the security outcome, and assert the relation between the two runs.**

> Example (cross-tenant read): you don't need to know what `/api/orders` *should* return. You only
> need *the response to identity B must not contain identity A's rows.* Swap the identity, keep the
> request, assert the relation. Relation broken → vulnerable.

This maps straight onto a LaunchGuard chain: a `precondition` step mints/establishes the second
identity or seeds state, the `exploit` step applies the transform, and the `assertion` encodes the
relation (`crossTenant`, `jsonPathsPresent`, `bodyContainsAll`, `fixedStatusIn`). See `CHAINS.md` for
the templates and `reference/chains-reference.md` for the full matcher vocabulary.

## The three kinds — check this before authoring anything

Every invariant is one of three kinds. Most of the value is already wired by the engine, and the
matcher genuinely can't express some of these — don't fake it:

- **ENGINE** — already covered by a default stack on every scan. Do **NOT** author a chain. Confirm
  it via `/context` (the row shows `recommendations[].action === "skip"`) and move on. Listed here so
  the catalog is complete.
- **CHAIN** — authorable today as an HTTP request+matcher or a script chain. This is where the deep
  audit earns its keep: you **fit** the invariant to this app and author a witnessed chain.
- **CODE-REVIEW** — not expressible in the matcher (rate-limit, timing, response-header, and active
  injection assertions don't exist). Inspect the code and report a finding; never a chain that fakes
  a verdict.

**Dedupe rule (do NOT author these):** **B6, B7, D2, F1, F2, F3 are ENGINE-covered.** `/context` is
authoritative (`action: "skip"` for `supabase`, `secrets`, `surface`; `write_delete` is toggled on),
but as a fast filter: never author a per-table anon read, a frontend-secret scan, or a
header/CORS/source-map check — the engine owns them.

**The per-app "fit" is the whole point.** A generic scanner proves the ENGINE floor. It cannot author
the CHAIN rows, because it never read the code: it doesn't know which table is the tenant table, which
column is the owner, which route is the admin function, which param takes a filename, or which marker
proves a leak. Every **"Fit to THIS app"** line below tells you how to derive those from the scan
`inventory` (`/context`) + the app's own source. That fitting is what an agent reading the app can do
and a scanner can't.

Severity is the *default* per the `reference/methodology.md` blast-radius table — always re-score per
app, and keep the Step-6 intended-public filter on (an aggregate counter, a published price list, or a
public feed answering anonymously is intended-public and is NOT a finding).

---

## A. Authentication

### A1 — Credentials only over TLS
- **SHOULD:** the login/token request only succeeds over TLS; an `http://` attempt redirects or refuses.
- **Transform → violation:** swap `https`→`http` on the login request; login still succeeds → RED.
- **Kind:** CHAIN / CODE-REVIEW (header-level HSTS is the engine `surface` stack).
- **LaunchGuard expression:** HTTP chain to the `http://` auth endpoint; `fixedStatusIn:[301,302,308,400]` (must redirect or refuse).
- **Severity:** high
- **Fit to THIS app:** from the `/context` inventory / code, pick the *real* auth route — the Supabase GoTrue path (`/auth/v1/token`), a NextAuth `/api/auth/*`, your own `/api/login` — not a guessed `/login`. If there's no plaintext listener to hit (host is HTTPS-only at the edge), this collapses to a code-review of the HSTS / redirect config and the `surface` stack; say so, don't fake a chain.

### A2 — Protected route denies a missing/empty token
- **SHOULD:** a route that reads/writes user data returns 401/403 when the token is stripped.
- **Transform → violation:** take an authed request, strip `Authorization`/cookie; it still returns protected data → RED.
- **Kind:** CHAIN (the witnessed-GREEN gate-guard recipe in `CHAINS.md`).
- **LaunchGuard expression:** anon HTTP chain to the protected route; `successStatusIn:[200]` + a forward-looking marker on a protected field, `fixedStatusIn:[401,403]`. Expected NOW = `fixed` (the gate denies you).
- **Severity:** high
- **Fit to THIS app:** pick a route that returns the signed-in user's own data from the code / `inventory.endpoints` (a profile, an account, a dashboard list). The marker is a field the leaked body WOULD carry if the gate broke (`$.email`, `$.user_id`, an account field). Author as a Guard so a future regression flips it `vulnerable`.

### A3 — Forged / none-alg / expired token not honored
- **SHOULD:** a crafted, expired, or downgraded token is rejected; the public anon key is never accepted where a privileged one is expected.
- **Transform → violation:** replace the token with `alg:none` / expired / anon-key-as-service-role; a privileged response → RED.
- **Kind:** CHAIN.
- **LaunchGuard expression:** HTTP chain carrying the crafted token in headers; positive marker = a privileged field only the real payload carries.
- **Severity:** critical
- **Fit to THIS app:** read the auth model to learn the token shape (Supabase JWT / Clerk / Auth0 / a homegrown JWT). The classic Supabase test is sending the public anon key into a path that should require service-role, or replaying an `alg:none` re-sign of a captured JWT. Target the most privileged route you can name from the code; marker = a field that appears only for an authorized caller.

### A4 — No brute-force / no default creds
- **SHOULD:** login has lockout/throttle, and no default or seeded credentials remain.
- **Transform → violation:** N login attempts with no lockout (the matcher can't do "fire N, expect 429").
- **Kind:** CODE-REVIEW.
- **LaunchGuard expression:** code-review — the rate-limit / lockout assertion does not exist in the matcher.
- **Fit to THIS app:** read the login handler — any lockout / throttle / captcha middleware on it? Grep migrations, seeds, and env for a seeded admin / default password. Report a finding; never a chain. **Severity:** med.

---

## B. Authorization / access control — the system-agnostic core

### B1 — Cross-tenant READ (BOLA / IDOR)
- **SHOULD:** identity A can't read identity B's object.
- **Transform → violation:** keep the request, swap the identity (or the object id to a foreign one); a foreign-owned row returns → RED.
- **Kind:** CHAIN.
- **LaunchGuard expression:** `crossTenant` matcher via `spec.env.anonKey` (Supabase-Auth) or a captured-session script for Clerk/Auth0 (`CHAINS.md` Step 3b; `reference/chains-reference.md` §5, §9). The engine `idor` is a `byo_template` (partial).
- **Severity:** critical
- **Fit to THIS app:** from `inventory.supabase.tables[]` + the code, pick a real tenant table and its **owner column** (`user_id` / `org_id` / `tenant_id`) — that column is `crossTenant.ownerJsonPath`. For an app-route IDOR, find a `/api/<resource>/:id` route and seed a real **foreign** id via a `precondition` extractor (`reference/methodology.md` Steps 2–4 — an unguessable UUID with no id-leak surface caps at medium). Pre-flight: `eyJ...` anon key + Supabase Auth, else use a captured-session script.

### B2 — Cross-tenant WRITE / DELETE
- **SHOULD:** A can't mutate or delete B's object.
- **Transform → violation:** swap identity on a write to B's object; the write succeeds → RED.
- **Kind:** CHAIN (mutation, gated).
- **LaunchGuard expression:** non-GET → manual-confirm run (`409 needsConfirmation` is healthy parked coverage). Self-provision B's object as a `precondition`.
- **Severity:** critical
- **Fit to THIS app:** pick a write route from the code (`PATCH`/`DELETE /api/<resource>/:id`, an RPC). As a `precondition`, self-provision B's object so you're writing to a row you don't own; the exploit step writes to it as A. Fire only on explicit `{"confirmMutation": true}` — never loop, never auto-run.

### B3 — Bypass-authorization-schema / forced browsing
- **SHOULD:** a URL not in A's UI is inaccessible to A.
- **Transform → violation:** keep low-priv credentials, request the high-priv/admin route directly; an admin-only field returns → RED.
- **Kind:** CHAIN (captured-session script as the low-priv identity).
- **LaunchGuard expression:** captured-session script chain (`reference/chains-reference.md` §9); the engine `broken_access` is a `byo_template`.
- **Severity:** high
- **Fit to THIS app:** enumerate the admin/internal routes from the code (`/admin/*`, `/api/internal/*`, any handler that checks `role === "admin"` or an org-role). Upload a low-priv session and request the admin route as that real identity. Marker = the admin-only field the route returns.

### B4 — Directory traversal / LFI
- **SHOULD:** a path/param can't escape to unauthorized files.
- **Transform → violation:** replace a path/param value with traversal / file payloads; file content or a path leak returns → RED.
- **Kind:** CHAIN.
- **LaunchGuard expression:** HTTP chain, payload in path/query, `bodyContainsAll:["root:x:0:0"]`-style marker; `fixedStatusIn:[400,403]` (404 only with care — a 404 is normally not a clean fix).
- **Severity:** high
- **Fit to THIS app:** find a route that takes a filename / path / template param from the code or `inventory.endpoints` (a download, file, image-proxy, or template route). Inject `../../etc/passwd`-style payloads into THAT param only. Marker = a unique file-content string (`root:x:0:0`) or a leaked absolute path. If no path-taking param exists, mark not-applicable.

### B5 — Privilege escalation
- **SHOULD:** a member can't call an admin function.
- **Transform → violation:** flip the identity admin→member on the privileged action; it still succeeds → RED.
- **Kind:** CHAIN (captured-session script as the member identity).
- **LaunchGuard expression:** captured-session script chain.
- **Severity:** critical
- **Fit to THIS app:** find the privileged action in the code (a role-change endpoint, billing mutation, a user-management RPC, a "promote to admin" route). Run it as a captured **member** session. Marker = the success field of the privileged action firing.

### B6 — Anonymous READ of tenant data
- **SHOULD:** anon can't read tenant tables / buckets / RPCs.
- **Kind:** **ENGINE** (`supabase`). Do **NOT** author per-table — confirm via `/context` (`action: "skip"`); `inventory.supabase.tablesTested` covers every table.
- **Severity:** high

### B7 — Anonymous WRITE / DELETE
- **SHOULD:** anon can't INSERT / UPDATE / DELETE.
- **Kind:** **ENGINE** (`write_delete`, toggleable). Toggle it on via `POST /api/v1/coverage`; do **NOT** author. Toggling on fires REAL mutation probes — say so first.
- **Severity:** critical

---

## C. Session management

### C1 — Session id rotates on auth (no fixation)
- **SHOULD:** signing up / logging in while a session exists mints a NEW session id.
- **Transform → violation:** capture the session id, perform login/signup, compare; same id → RED (fixation).
- **Kind:** CHAIN (script).
- **LaunchGuard expression:** Playwright script chain reading `context.storageState()` cookies before and after auth, asserting the value changed.
- **Severity:** high
- **Fit to THIS app:** from the code, identify the session cookie/token name (Supabase `sb-...`, Clerk `__session`, a NextAuth `next-auth.session-token`). The script captures it, runs the real login flow, re-captures, and asserts it rotated.

### C2 — Logout invalidates the session; token not in URL
- **SHOULD:** a post-logout cookie no longer works on a protected route, and tokens aren't placed in URLs.
- **Transform → violation:** reuse a post-logout cookie on a protected route; it still works → RED.
- **Kind:** CHAIN (script).
- **LaunchGuard expression:** script chain replaying the stale session against a protected route.
- **Severity:** med
- **Fit to THIS app:** capture a real session, hit the logout route from the code, then replay the now-stale cookie against a protected route. Separately, grep the code for tokens/session ids placed in query strings or redirect URLs (a code-review sub-finding).

---

## D. Data exposure

### D1 — No anon mass-read of sensitive arrays via app routes
- **SHOULD:** an app route doesn't hand an array of sensitive records to an anonymous caller.
- **Transform → violation:** GET an app route anonymously; an array of records carrying a sensitive field returns → RED.
- **Kind:** CHAIN.
- **LaunchGuard expression:** `jsonPathsPresent:["$[0].phone"]` (`reference/chains-reference.md` §5.1). The engine does NOT crawl arbitrary app-route bodies — this is a real gap. Do **NOT** use `minTotalRows` here (no PostgREST `content-range` on a plain app array → false `inconclusive`).
- **Severity:** high
- **Fit to THIS app:** scan `inventory.endpoints.anonReachable[]` for JSON routes (`/api/<x>/config`, `/api/<x>/list`, a public widget/feed). Read the body; if it's an array with PII (`name` + `phone`/`email`, internal ids), the marker is `$[0].<sensitiveField>`. Apply the intended-public filter: a public counter, price list, or blog feed is NOT a finding — reserve RED for PII / another tenant's rows / internal ids.

### D2 — No secrets / service-role key / server env in the client bundle
- **SHOULD:** no secrets, service-role keys, or server env vars in the client JS.
- **Kind:** **ENGINE** (`secrets`). Do **NOT** author — confirm via `/context` (`action: "skip"`).
- **Severity:** critical

### D3 — No sensitive data / stack traces in error envelopes
- **SHOULD:** error responses don't leak PII, internal ids, or stack traces.
- **Transform → violation:** trigger an error; PII / internal ids / a stack frame leaks in the body → RED.
- **Kind:** CHAIN / CODE-REVIEW.
- **LaunchGuard expression:** `bodyContainsAll` on a leaked marker if the app returns a 2xx-with-error-body; a raw 5xx stack page is `surface` / code-review (the matcher can't assert on a 5xx).
- **Severity:** med
- **Fit to THIS app:** from the code, find a route that returns a structured error body (a validation error that echoes input, a 2xx error envelope). Trigger it with bad input; marker = a leaked internal field (a stack-frame substring, a table/column name, an internal id). A raw 5xx stack page is a code-review finding.

---

## E. Injection — scope honestly (out of band for the matcher)

### E1 — No SQL / NoSQL injection
- **SHOULD:** user input is parameterized; the database never executes attacker input.
- **Why CODE-REVIEW:** active injection plus the oracle ("the DB executed it") is not expressible in a read-only request+matcher. LaunchGuard's model is **demonstrate, don't disrupt** — it does no payload-injection fuzzing.
- **Kind:** CODE-REVIEW.
- **Fit to THIS app:** read the data layer — are queries parameterized (the Supabase client, an ORM, prepared statements) or string-concatenated from user input? Report from the code; do NOT author a chain that pretends to verdict it.

### E2 — No reflected / stored XSS
- **SHOULD:** user-controlled output is escaped; no DOM execution of attacker input.
- **Why CODE-REVIEW:** the matcher can't assert DOM execution; this is not a LaunchGuard chain.
- **Kind:** CODE-REVIEW.
- **Fit to THIS app:** read the render paths for `dangerouslySetInnerHTML` / `v-html` / unescaped templating fed by user input. Report from the code.

---

## F. Transport / configuration / surface

### F1 — Security headers present (CSP, HSTS, X-Frame-Options)
- **Kind:** **ENGINE** (`surface`). The header matcher doesn't exist; engine-only. Do **NOT** author.

### F2 — No source maps / `.env` / sensitive files served
- **Kind:** **ENGINE** (`surface`). Do **NOT** author.

### F3 — CORS not permissive (`*` + credentials)
- **Kind:** **ENGINE** (`surface`) / CODE-REVIEW. Header relation, engine-owned. Do **NOT** author a chain; if you spot a permissive CORS config in the code, note it as a code-review confirmation.

---

## G. Cost / abuse / quota

### G1 — Unauth can't trigger paid / outbound work
- **SHOULD:** an anonymous caller can't trigger paid AI / email / SMS / compute work.
- **Transform → violation:** POST the paid route anonymously; a paid-work marker (completion id, queued job id, message id) returns → RED.
- **Kind:** CHAIN (`cost` `byo_template`).
- **LaunchGuard expression:** anon POST to the route; positive marker proves the work actually ran.
- **Severity:** high
- **Fit to THIS app:** from `inventory.endpoints` / the code, find the AI/email/SMS/compute route (`/api/chat`, `/api/generate`, `/api/send`). POST it anonymously. Marker = the completion / job / message id that proves the paid call ran. **Intended-public filter:** if the founder *intends* a free anonymous tier (the free scan IS the product), that is NOT a finding — distinguish "an attacker abuses expensive work" from "the founder offers this for free".

### G2 — Free tier / quota can't be exceeded
- **SHOULD:** a non-paying request can't exceed the free tier or quota.
- **Transform → violation:** self-provision usage to the cap as a `precondition`, then exceed it; it succeeds → RED.
- **Kind:** CHAIN.
- **LaunchGuard expression:** multi-step chain with `precondition` steps that set state every run (`reference/methodology.md` Step 4).
- **Severity:** high
- **Fit to THIS app:** find the metered action and its cap from the code (a usage counter, a plan limit, a credits column). `precondition`: drive usage to the cap as a fresh user; exploit: the next call past the cap. Marker = the (cap+1)th call succeeding.

### G3 — No missing rate limit (API4)
- **SHOULD:** expensive routes are rate-limited.
- **Why CODE-REVIEW:** "fire N, expect a 429" is not expressible in the matcher.
- **Kind:** CODE-REVIEW.
- **Fit to THIS app:** read the expensive routes (the same AI/email/compute set from G1) — is there rate-limit middleware in front of them? Report from the code; never a chain. **Severity:** med.

---

## Dedupe at a glance — what NOT to author

`/context` is authoritative, but as a fast filter: **B6, B7, D2, F1, F2, F3 are ENGINE-covered** — do
not author custom chains for them (`recommendations[].action === "skip"`, or toggle for `write_delete`).
Everything in the **CHAIN** rows is a genuine gap to fit and author. Everything in **CODE-REVIEW** is a
finding, not a chain.

> **Honest scope of a clean audit.** Proving every CHAIN row `fixed` and clearing every CODE-REVIEW
> item means the *fundamental* (intent-free) layer holds — the floor is working. It says nothing about
> business-logic correctness ("should this role see this data"), which still needs the owner. A clean
> audit is the floor working, not "the app is secure."
