# Custom test reference — request + matcher

Deep reference for the Bring Your Own Test section in SKILL.md. Read this when you need more than the single anonymous read in the 90% template: cross-tenant IDOR, multi-step preconditions, extractors, the exact assertion vocabulary, the JSONPath dialect, or the verdict-routing rules.

Mental model unchanged: a custom test is one HTTP request plus a matcher rule, submitted as JSON. One `exploit` step (the request), optional `precondition` steps (setup / variable extraction), and one `assertion` (the matcher block).

All calls need the user's API key. Per SKILL.md, store it as `LAUNCHGUARD_API_KEY` and send `-H "Authorization: Bearer $LAUNCHGUARD_API_KEY"`.

---

## 0. Proof vs Guard — `watched` (applies to EVERY chain, HTTP or script)

Every chain — an HTTP exploit chain OR a functional script chain — is one of two classes, set by the top-level `watched` boolean at ingest and changeable later via PATCH:

- **Proof** (`watched: false`, **the default**) — a one-shot. Author it, run it once, report the verdict; it stays as stored evidence and does **not** re-run on deploy. This is the right class for the many exploit proofs you author while triaging a scan ("show me this is exploitable right now"). Authoring ten proofs during an audit should NOT silently fill the user's watched suite with ten auto-running tests.
- **Guard** (`watched: true`) — joins the deploy-replay suite. On every detected deploy LaunchGuard re-runs it and alerts on regression (a `fixed` chain that comes back `vulnerable`). Reserve this for the rules the user genuinely wants watched forever.

**Default to Proof.** Set `watched: true` only when the intent is explicitly ongoing protection — the user said "watch this on every deploy", you're in the Connect flow, or you/they decide a specific proof is worth guarding. (Functional regression chains are the common case where a Guard is the goal — but still confirm a clean, non-flaky green before you promote; see `functional-methodology.md`.)

Set it two ways:
- **At authoring time:** include `"watched": true` (or omit / `false` for a Proof) in the `POST /api/v1/chains` ingest body.
- **Later, via the API:** `PATCH /api/v1/chains/<id>` with `{ "watched": true }` promotes a Proof to a Guard, `{ "watched": false }` demotes it. The user can also toggle it from the custom-tests page in the UI.

Every list/get row carries `watched` so you can tell Guards from Proofs.

**`watched` is orthogonal to side-effect.** A `mutation` chain never auto-runs regardless (the separate confirmation gate in §7 still applies), so marking a mutation `watched: true` does NOT make it fire on deploy — only read-only Guards (and functional script Guards) auto-run.

---

## 1. The matcher vocabulary (only these fields exist)

These are the only assertion fields that exist. Anything not in this table is ignored or invalid.

| Field | Type | Meaning |
|---|---|---|
| `successStatusIn` | `number[]` (REQUIRED, non-empty) | statuses that mean "the exploit surface answered", e.g. `[200]`, `[200,206]` |
| `fixedStatusIn` | `number[]` (REQUIRED, non-empty) | statuses that positively mean denied. Use `[401,403,429]`. The engine throws (`fixedStatusIn is not iterable`) and the run routes to a false `inconclusive` if you omit it |
| `jsonPathsPresent` | `string[]` | every listed JSONPath must resolve to at least one non-null value |
| `bodyContainsAll` | `string[]` | every literal substring must appear in the raw body (supports `{{var}}` binding) |
| `crossTenant` | `{ ownerJsonPath, notEqualsVar, minForeignRows }` | the sound IDOR positive: prove rows owned by someone other than the replay identity |
| `errorEnvelopeContainsAny` | `string[]` | if any appear in a 2xx body, that is a DISPROOF and routes to `fixed` |
| `minTotalRows` | `number` | requires a PostgREST `content-range` total `>=` this. **You MUST send `"Prefer": "count=exact"` in the request headers**, or PostgREST returns a null total and the run is a false `inconclusive` (`ambiguous_2xx: total null`). With the header, an empty table returns exact `0` → clean `fixed` (`exploit_absent: total 0 < 1`) |
| `contentTypeIncludes` | `string` | response content-type must include this, e.g. `application/json`, else not a positive |

Do not invent `bodyContainsAny`, `statusEquals`, `regex`, `matchers`, etc. They will be silently ignored and your chain will never reach `vulnerable`.

## 2. JSONPath dialect (a focused custom subset, not jsonpath-plus)

Supported:
- `$` whole document
- `$.a.b.c` dotted object dig
- `$[0]`, `$.a[2]`, `$.a[-1]` array index (negative counts from the end)
- `$[*].field`, `$.rows[*].x` wildcard array projection (also iterates object values)
- `$[?(@.user_id != "X")]` predicate filter, operators `==` and `!=` only
- `$[?(@.user_id != "{{auth.userId}}")].user_id` predicate filter with a `{{var}}` literal plus field projection

NOT supported: recursive descent `..`, slices `[1:3]`, functions, and any comparator other than `==` / `!=`. These silently match nothing.

## 3. Extractors (multi-step chains)

A `precondition` step can extract a value into the variable bag for a later step to reference via `{{step<order>.<as>}}` or `{{<stepId>.<as>}}`. Shape:

```json
{ "as": "victimId", "from": "json", "expr": "$[0].id", "index": 0, "required": true }
```

`from` is one of: `json` (uses `expr` JSONPath plus optional `index`), `header` (`expr` = header name), `status`, `content_range_total`, `body_regex` (`expr` = regex, first capture group or whole match). An unbound `{{ref}}` throws, which routes the step to a precondition failure and a verdict of `inconclusive` (never a false `fixed`).

Coupling rule: the assertion is evaluated against the single `exploit` step only. `precondition` steps run first to set up state or extract variables, but the verdict is judged on the exploit step's response.

## 4. Verdict routing (how the engine decides, in order)

- status in `fixedStatusIn` (use `401`/`403`/`429`) -> `fixed` (clean denial)
- status in `successStatusIn` AND all positive markers hold -> `vulnerable`
- status in `successStatusIn` but the body is an error envelope (matched `errorEnvelopeContainsAny`, or a GraphQL `errors` array / `data:null`) -> `fixed` (disproof)
- status in `successStatusIn`, no positive, but the surface proved cleanly empty (a `content-range` total was available and was 0, or body empty) -> `fixed`
- status in `successStatusIn`, ambiguous (no positive, no clean disproof) -> `inconclusive`
- status outside both sets (404, 5xx, unexpected), transport error, unreachable, unparseable body, auth setup failed -> `inconclusive`

Key consequence: a `404` is NEVER `fixed`. To get a clean "the bug is gone" signal the target must return `401`/`403`/`429`, or you must rely on a proven-empty count. This is by design so a deleted or renamed endpoint never falsely reads as patched.

> **You author the routing.** The branches above are driven entirely by YOUR `successStatusIn` / `fixedStatusIn` / markers — LaunchGuard supplies no opinion of its own. An `inconclusive` therefore always means the matcher you wrote did not describe the response the endpoint actually returned. The fix is never to accept it: read the real status + body, decide what the endpoint SHOULD do, and adjust the matcher so the observed-secure behavior lands in `fixedStatusIn` (PASS) and the observed-exploited behavior lands in `successStatusIn` + a positive marker (FAIL). Only archive when the engine could not issue the request at all (e.g. `auth_failed: no_credential_resolver`), so there is no response to assert on.

> **Known routing bug — redirect-gated routes.** A `3xx` (e.g. `302 → /login`) currently throws `exploit_body_unparseable` and routes to `inconclusive` BEFORE the `status in fixedStatusIn` check above runs, even though a redirect-to-login is a clean deny that should read `fixed`. Until the engine checks status routing before parsing the body (and treats a 3xx as terminal rather than unparseable), any route behind Cloudflare Access / oauth2-proxy / Vercel/Caddy auth is structurally inconclusive. Workaround: put the redirect status in `fixedStatusIn` and add `bodyContainsAll:["Redirecting","/login"]` so the chain auto-resolves to `fixed` the moment the engine is patched.

The `reason` string in a `/run` response names which branch fired, so you can report precisely:
- `exploit_reproduced: assertions passed` -> `vulnerable`
- `access_denied: HTTP <4xx>` -> `fixed` (status was in `fixedStatusIn`)
- `exploit_absent: total N < M` -> `fixed` (proven empty, e.g. a `content-range` total of 0 or below `minTotalRows`)
- `engine_error: <message>` -> `inconclusive` (a malformed assertion, e.g. a missing `fixedStatusIn`; fix the spec and re-run)

Note: a `mutation` chain never auto-runs, and an UNCONFIRMED `POST /api/v1/chains/:id/run` rejects it with `409 needsConfirmation` before it executes. But a CONFIRMED mutation run (`{ "confirmMutation": true }` against a monitored domain) does execute and reaches verdict routing exactly like a read-only chain, firing the real side effect once (see §7 and the SKILL.md "Running mutation tests (explicit confirmation)" note). A human running it from the dashboard gets the same verdict under per-step approval.

## 5. Worked example: Supabase cross-tenant IDOR

> **Per-table raw PostgREST anon-read chains are NO LONGER a default to author.** The `supabase` engine stack already tests every table / bucket / RPC as the anon role on every scan (visible in `/api/v1/context`: `recommendations.action === "skip"` for `supabase`, and `inventory.supabase.tablesTested` covering all tables; see §11). Re-authoring a plain `target:"supabase"` GET to `/rest/v1/<table>` with `minTotalRows: 1` just duplicates engine coverage. Reach for the anonymous-read template only for a GENUINE gap the engine cannot see: the §5.1 app-route-array case (the engine does NOT crawl arbitrary app routes' response bodies), or a specific table `/context` itself flagged as a gap. The cross-tenant IDOR below (a logged-in user crossing tenant boundaries via `spec.env.anonKey`) is also NOT something the engine does per-table, so it remains a legitimate authored test.

Prove an anonymous PostgREST select returns rows owned by someone other than the authenticated replay identity:

```json
{
  "successStatusIn": [200, 206],
  "fixedStatusIn": [401, 403],
  "crossTenant": {
    "ownerJsonPath": "$[*].user_id",
    "notEqualsVar": "{{auth.userId}}",
    "minForeignRows": 1
  },
  "errorEnvelopeContainsAny": [
    "row-level security",
    "permission denied",
    "\"code\":\"42501\"",
    "\"code\":\"PGRST"
  ],
  "contentTypeIncludes": "application/json"
}
```

`{{auth.userId}}` resolves to the replay identity's user id. If at least one returned row has a different `user_id`, that is a proven cross-tenant leak and the verdict is `vulnerable`. An RLS denial envelope on a 2xx routes to `fixed` (the codes `42501` and `PGRST*` above are Supabase/PostgREST RLS-denial codes — real markers that the database refused the query).

## 5.1. Worked example: anonymous JSON-array API mass-exposure (the genuine gap)

> **This is the legitimate remaining use of the anonymous-read template.** A raw per-table PostgREST anon read is already covered by the `supabase` engine stack (see §5's note), so do not re-author it. But the engine does NOT crawl arbitrary application routes' response bodies, so an app route leaking an array of records is a real gap the engine cannot see. This is where you author an anonymous-read chain.

The most common real vibe-coder exposure is NOT a raw PostgREST table — it's an **app route that returns a JSON array of sensitive records without auth**: a `GET /api/widget/config?slug=acme` that answers an anonymous request with `[{ "name": "...", "phone": "..." }, ...]`. This is a first-class anonymous mass-exposure finding (names, emails, phone numbers, internal ids leaking to any stranger), and LaunchGuard renders it as the same structured "rows" evidence card on the dashboard as a PostgREST leak.

The trap: do NOT reach for `minTotalRows`. That marker reads a PostgREST `content-range` total header, which a plain application route does not send — so the run lands in `ambiguous_2xx`/`inconclusive` and a genuinely exposed endpoint looks like a non-result. Assert on the **shape of the array itself** instead:

```json
{
  "title": "Anonymous request returns an array of customer phone numbers",
  "targetHost": "sandbox.example.com",
  "severity": "high",
  "source": "ai_agent",
  "watched": false,
  "spec": {
    "version": 2,
    "steps": [
      {
        "order": 1, "id": "exploit", "label": "GET the config route anonymously",
        "role": "exploit", "sideEffect": "read_only",
        "request": { "method": "GET", "target": "primary", "path": "/api/widget/config?slug=acme" }
      }
    ],
    "assertion": {
      "successStatusIn": [200],
      "fixedStatusIn": [401, 403, 404],
      "jsonPathsPresent": ["$[0].phone"],
      "contentTypeIncludes": "application/json"
    },
    "auth": {},
    "sideEffect": "read_only",
    "allowedTargets": { "primary": "sandbox.example.com" }
  }
}
```

- The positive marker is **`jsonPathsPresent` on a sensitive field of the first element** (`$[0].phone`, `$[0].email`, `$[*].ssn`, etc.) — proof the array exists AND carries the sensitive field. Optionally add `bodyContainsAll` with a real value you saw (a known customer name) to bind the assertion harder.
- `fixedStatusIn` here can include `404` only if the patched behavior is genuinely a hard not-found for the anonymous caller — but remember a `404` is normally NOT a clean fix (§4); prefer `[401,403]` when the gated app actually denies. The win you want from a patch is a `401`/`403`, or the array coming back empty (no `$[0]`, so the marker can't resolve → `fixed` by clean-empty).
- This is `target: "primary"` (the app's own host), not `target: "supabase"` — it's an application route, not a PostgREST query.

## 6. Validator rules enforced at ingest (rejection on failure)

| Location | Rule |
|---|---|
| `spec.version` | must equal `2` |
| `spec.steps` | non-empty array |
| `spec.steps` | exactly ONE step with `role === "exploit"` (zero or two-plus is rejected) |
| each step `.id` | non-empty string |
| each step `.order` | a number (uniqueness not checked) |
| each step `.role` | `"precondition"` or `"exploit"` |
| each step `.request.method` | a string |
| each step `.request.path` | a string |
| each step `.request.target` | exactly `"primary"`, `"supabase"`, or `"api"` |
| `spec.assertion` | non-empty object (empty matcher is a hard failure) |
| `spec.assertion.successStatusIn` | non-empty number array |
| `spec.allowedTargets` | an object |
| `spec.allowedTargets.primary` | must byte-equal the normalized `targetHost` |
| `spec.sideEffect` | a string (top-level on the spec) |
| top-level `targetHost` | valid public DNS host AND passes the SSRF guard (private/loopback/metadata IPs rejected) |
| top-level `severity` | one of `critical` / `high` / `medium` / `low` |
| top-level `source` | use `"ai_agent"` (it is optional and defaults to `ai_agent`) |

Optional and passed through to the engine if present: `step.label`, `step.authRef`, `step.extract[]`, `step.request.query` / `.headers` / `.body` / `.timeoutMs`, `spec.auth`, `spec.env`, `spec.inventoryHash`, `allowedTargets.supabase` / `.api`.

## 7. Endpoint contracts

All require `Authorization: Bearer $LAUNCHGUARD_API_KEY`. Base URL: try `https://api.launchguard.dev`, but the `/api/v1/*` chain routes are not all live there yet, so a call may `404` (with an HTML page, not the JSON error envelope). As soon as one `/api/v1/...` call 404s, switch to `https://recon-api-dev.centrive.ai` for every chain call for the rest of the session (LaunchGuard's own backend host, safe to call). Do not retry `api.launchguard.dev` once you have seen it 404.

### GET /api/v1/chains (list — call this BEFORE authoring)

Optional `?targetHost=<host>` filter (normalized the same way ingest derives `host`). Optional `?includeArchived=true` makes the list ALSO include archived chains; without it the list excludes them (the default). Every returned row carries `archived: true|false` and `archivedAt`, so you can tell which rows are archived and grab an archived chain's id to restore it. Success `200`:
```json
{ "targetHost": "sandbox.example.com", "count": 2, "chains": [
  { "chainId": "<uuid>", "targetHost": "sandbox.example.com", "title": "...",
    "severity": "high", "source": "ai_agent", "sideEffect": "read_only",
    "status": "active", "lastResult": "vulnerable", "lastTestedAt": "...",
    "enabled": true, "autoReplay": true, "watched": false, "createdAt": "...",
    "archived": false, "archivedAt": null,
    "exploit": { "method": "POST", "path": "/api/chat", "target": "primary" } }
] }
```
`exploit` (`{method, path, target}`) is the **dedupe key** — before authoring a new chain, list the existing ones for the host and skip any whose `exploit` already covers the same request. Owner-scoped. Errors: `400` (bad `targetHost`), `401`, `500`.

### GET /api/v1/chains/:id (read one full blueprint)

Returns a single chain end-to-end, including the complete `spec` (steps + assertion + allowedTargets), plus `declaredSideEffect` / `derivedSideEffect` / `specVersion` / `updatedAt`. Use this to inspect an existing test before re-running it or proposing a variant. Owner-scoped: another user's chain (or a missing one) returns `404`. Errors: `400` (no id), `401`, `404`, `500`.

### POST /api/v1/chains (ingest)

Body: `{ title, targetHost, severity, spec, source?, watched? }`. `watched` defaults to `false` (a Proof — one-shot, no deploy re-run); pass `"watched": true` to ingest it directly as a Guard (re-runs on every deploy). See §0. Success `201`:
```json
{ "chainId": "<uuid>", "autoReplay": true, "sideEffect": "read_only", "watched": false }
```
`autoReplay: true` means the chain is allowed to run. If the request looked mutating (write-style method/path), the response instead carries `"note": "Mutating chain stored as manual-only; it will not auto-run."` — meaning it was stored but won't auto-run, and a `/run` call returns 409. **`title` must be unique among your ACTIVE chains** — re-ingesting a title an active chain already uses fails (`500`), so get the spec right and give each chain a fresh, descriptive title (archiving a chain frees its title to re-ingest cleanly). Errors: `400` (validation / SSRF), `401` (auth), `500` (incl. duplicate active title).

### PATCH /api/v1/chains/:id (modify)

Owner-scoped in-place edit. Body: `{ title?, severity?, spec?, watched? }`, supply at least one. `{ "watched": true }` promotes a Proof to a Guard (re-runs on deploy); `{ "watched": false }` demotes it back to a one-shot — this is how you curate the watched suite without re-ingesting (see §0). When `spec` changes it is re-validated (same rules as ingest, §6) and the side-effect is re-derived, so changing a method to a non-GET can flip the chain to `mutation` (manual-only). `title` must stay unique among your ACTIVE chains; a rename that collides with another active chain returns `409`. Use this to fix or evolve a test in place instead of archive-then-reingest. Success `200`:
```json
{ "chainId": "<uuid>", "title": "...", "severity": "high",
  "sideEffect": "read_only", "autoReplay": true, "watched": false, "updatedAt": "..." }
```
Errors: `400` (validation / SSRF / no fields), `401`, `403` (chain belongs to another user), `404`, `409` (title collision with another active chain), `500`.

### POST /api/v1/chains/:id/run (re-execute)

Optional body. For a read-only chain, no body is needed. For a `mutation` chain you must send `{ "confirmMutation": true }` to actually run it (it fires a real side effect once). Success `200`:
```json
{ "runId": "<uuid>", "result": "vulnerable|fixed|inconclusive",
  "reason": "human-readable gate reason", "matched": true, "regression": false }
```
`matched` is true only on `vulnerable`. `regression` is true when a chain that previously read `fixed` now reads `vulnerable` (i.e. the bug came back).

Mutation specifics:
- A mutation chain run WITHOUT `confirmMutation` returns `409 { "error": "...", "sideEffect": "mutation", "needsConfirmation": true }` and does not execute. That 409 is the confirmation gate, not a verdict.
- A mutation chain run works against any domain the user MONITORS (has added to their account); trust-the-owner covers mutations the same as read-only runs. A host that is not in the account returns `403`.
- With `{ "confirmMutation": true }` against a monitored domain, it executes and returns the normal verdict, firing the real write/charge/OTP exactly once.

Errors: `401`, `403` (chain belongs to another user, or a run targeting a host not in the user's account), `404`, `409` (chain disabled, or an unconfirmed mutation needing `confirmMutation`), `500`.

### DELETE /api/v1/chains/:id (archive)

Soft-deletes (archives) a chain. Internally it stamps `deleted_at` rather than hard-deleting, so the row and its run history are retained server-side, but for your purposes it is a removal: the chain disappears from the default `GET /api/v1/chains` list, stops auto-running on deploys, and cannot be run. Archiving IS reversible: `POST /api/v1/chains/:id/restore` un-archives it (subject to the title-collision rule below), and `GET /api/v1/chains?includeArchived=true` lists archived chains so you can find the id to restore. Archiving frees the title, so the same title can be re-ingested afterward (effectively replacing it); note that re-using a freed title with a new active chain is what later blocks a restore of the archived original. Owner-scoped. Success `200`:
```json
{ "ok": true, "chainId": "<id>", "archived": true }
```
A `404` (`{ "error": "chain not found" }`) means the chain is missing, belongs to another user, or is already archived. Use this to clean up a duplicate or broken chain instead of leaving it stored. Errors: `401`, `404`, `500`.

### POST /api/v1/chains/:id/restore (un-archive)

Reverses an archive: clears the soft-delete so the chain is active again, reappears in the default `GET /api/v1/chains` list, and resumes auto-running. Find the id of an archived chain first via `GET /api/v1/chains?includeArchived=true` (archived rows carry `archived: true`). Owner-scoped. Success `200`:
```json
{ "ok": true, "chainId": "<id>", "restored": true }
```
Errors:
- `404` (`{ "error": "chain not found" }`): the chain is missing or belongs to another user.
- `409` (`{ "error": "chain is not archived" }`): it was active already, so there is nothing to restore.
- `409` (`{ "error": "...title...", "titleCollision": true }`): an ACTIVE chain already uses the same title for that host (the title was re-used after the archive). Rename or archive that active chain first, then restore.
- `401`, `500`.

## 8. Current limitations worth telling the author

- Three credential modes work today: **anonymous** (`auth: {}`), **Supabase anon** (`spec.env.anonKey` signs up a fresh test account per run), and **captured session** (a Playwright `storageState` you upload once and reference by `credentialId`, for **script** chains — see §9). The captured-session mode is what proves the "logged in but under-privileged" bugs the other two can't: a Pro-only route reachable by a free user, an admin function reachable by a member, an authenticated cross-tenant IDOR on a non-Supabase-Auth app. Any OTHER bearer / cookie / static-token chain that needs a stored secret you did NOT supply still resolves to null and routes the run to `inconclusive`.
- **`spec.env.anonKey` cross-tenant signup requires a Supabase-Auth app + a legacy `eyJ...` JWT anon key.** It signs a fresh user up through Supabase Auth (GoTrue). On a Clerk / Auth0 / Firebase-Auth app there is no GoTrue path → the run dies at `auth_failed: no_credential_resolver` before any HTTP request (unassertable — don't author it). A new-format `sb_publishable_...` key carries no JWT identity, so it also can't drive the signup. On those apps, fall back to the anonymous-exposure style: a plain `target:"supabase"` GET to `/rest/v1/<table>` with the public key in `apikey`/`authorization` headers + `Prefer: count=exact` + `minTotalRows: 1`. The `sb_publishable_` key works fine in that header role.
- **Cross-host targeting is supported.** Only `allowedTargets.primary` must byte-equal `targetHost`; `allowedTargets.api` and `.supabase` are free-form passthrough hosts and may differ from the monitored domain. This is how you reach a separate backend host (`target:"api"`) or the Supabase project (`target:"supabase"`) — essential since unauth object-access holes usually live on the backend, not the gated frontend proxy.
- A GET whose handler causes downstream WRITES still classifies `read_only` + auto-replay (side-effect is method-derived) and will fire its write on every deploy — there is no GET→manual downgrade. Don't author such a chain; cover the endpoint another way or archive it.
- The matcher asserts only on status + body content + JSON markers + content-type. It cannot express rate-limit ("fire N, expect a 429"), response time, or response headers — so missing-rate-limit (API4) and missing-security-header bugs are code-review findings, not chains.
- **The credential ceiling has moved: captured sessions now cross it (for script chains).** The engine can mint anonymous and Supabase-anon identities itself, but it could never mint an "authenticated but under-privileged" identity (a free user, a member, a specific tenant) — so a bug behind one of those used to read a false `fixed` (the black-box run hit `401 auth_required`) and was unprovable. That is no longer true for **script** chains: upload the target session once as a captured credential (§9) and the script runs as that real logged-in identity, so a Pro-only route reachable by a free user, an admin function reachable by a member, or an authenticated cross-tenant IDOR on a non-Supabase-Auth app CAN now be proven `vulnerable`. For an HTTP request-plus-matcher chain (no captured-session support yet) the ceiling still stands: author it as stored coverage + a code-review finding and never present its `401`-driven `fixed` as "safe".
- **Object-read (IDOR) chains need a real victim id or they stay `inconclusive`.** A route like `/api/thing/:id` returns `404` for a synthetic id, and `404` is never `fixed`. Add a `precondition` step that `extract`s a real id from a listing/creation endpoint into a `{{var}}` and reference it in the exploit path. Without a seeded real id the chain is permanent-inconclusive noise — don't author it.
- **A `GET /rest/v1/rpc/<fn>` only works for a zero-argument function.** A Supabase RPC that requires parameters returns `404 PGRST202` to a GET (no matching empty-arg signature) — and `404` is never `fixed`, so the chain is permanently inconclusive. Confirm the function takes no required args before authoring a GET-RPC test; otherwise the RPC is a `mutation` (a POST with a body) and is gated, not an anonymous read.
- `/api/v1/*` may not be exposed at the public edge **per route** — the fallback is route-by-route, not global. If a given `/api/v1/...` call to `api.launchguard.dev` returns 404, fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host) for that route. Note the chain routes (`/chains*`) fall back cleanly, but `/api/v1/connect` is a special case (its connect route must be deployed to the public edge, which is in progress) — see the SKILL.md Connect section. Don't assume the fallback rescues connect the way it rescues `/chains`.
- **Engine coverage IS now visible (this used to be a limitation, it no longer is).** Earlier guidance said the chains API exposed no scanner-origin signal, so a custom chain could not be deduped against default-scanner coverage. That is no longer true: `GET /api/v1/context` (§11) projects every engine check as a verdict-bearing `tests[]` row (kind `engine` / `byo_template`) and names each engine-covered stack via `recommendations.action === "skip"`. So you CAN now tell that a per-table anon-read custom chain duplicates the `supabase` engine stack (which covers all tables as anon) and that the `secrets` / `surface` stacks own their bins. Custom-chain-vs-custom-chain dedupe by the `exploit` key (§7) is still how you dedupe two authored chains; what changed is that engine coverage is data you can read, not a guess.

## 9. Captured-session credentials (bring-your-own-session, for script chains)

The engine can mint anonymous and Supabase-anon identities on its own (§8), but it cannot log itself in as a real, already-provisioned user (a paying Pro account, an admin, a specific tenant). To test those, you **capture the user's logged-in browser session once** as a Playwright `storageState` and upload it. A **script** (Playwright) chain then references it and runs authenticated as that identity. This is the third credential mode, and the one that unlocks the authenticated / Pro-gated / cross-tenant tests the engine couldn't reach before.

> A `storageState` is the JSON Playwright writes via `context.storageState()` — cookies + localStorage for a logged-in session. The user produces it from their own browser/test against their own app; you never mint or guess it. It is a real secret, so the API never echoes it back (see below).

### POST /api/v1/chains/credentials (upload a captured session)

`Authorization: Bearer $LAUNCHGUARD_API_KEY`. Body:
```json
{
  "storageState": { "...": "Playwright storageState JSON" },
  "label": "free-tier user",
  "metadata": { "tier": "free", "tenant": "acme" }
}
```
- `storageState` (required) — the Playwright `storageState` JSON.
- `label` (optional, string) and `metadata` (optional) — the non-secret **identity** describing whose session this is. They may be sent flat (as above) OR nested under an `identity` object: `{ "storageState": ..., "identity": { "label": ..., "metadata": ... } }`. Both forms are accepted.
- `metadata` must be a **FLAT object of string→string**. A nested object or a non-string value returns **400**. The keys/values are ARBITRARY and author-supplied — tiers, roles, plans, tenants, whatever describes the identity. The product interprets NONE of it; it is descriptive metadata for the human reading the test, nothing more.

Success `201`:
```json
{ "credentialId": "<id>", "kind": "storage_state",
  "identity": { "label": "free-tier user", "metadata": { "tier": "free", "tenant": "acme" } } }
```
The response NEVER returns the `storageState` or its ciphertext — only the `credentialId` and the non-secret `identity`. Store the `credentialId`; that is how a chain references the session.

### Using a captured credential in a script chain

A script chain references the credential by its `credentialId` at ingest; the chain then runs authenticated as that captured identity. The non-secret identity `{ label, metadata }` is shown in the UI per test and is returned (redacted — never the storageState) on `GET`/`LIST` as `spec.script.identity`. So when you list chains, an authenticated script chain tells you which identity it ran as.

This is what lets you author "a free user can reach a Pro-only route", "a member can call an admin function", or "user A can read user B's tenant" as a real authenticated test, instead of leaving it as stored coverage + a code-review note (§8 credential ceiling). Anonymous (`auth: {}`) and Supabase-anon (`spec.env.anonKey`) modes still exist and are still the right choice when you don't need a real provisioned login; captured session is the third mode, for when you do.

## 10. Durable disposition (mark a vulnerable verdict reviewed / intended)

Some `vulnerable` verdicts are intended — an intended-public endpoint, a free-tier-is-the-product flow (the `methodology.md` Step 6 intended-public filter). Historically the only ways to stop re-litigating those were to drop the finding (losing the reasoning) or archive the chain (losing the coverage). **Disposition** is the durable, visible third option: mark the specific observed exposure as reviewed, with a reason, WITHOUT ever masking a future change.

### The one property that holds

"Accepted" means *this specific observed exposure is intended* — NOT "any future vulnerable verdict from this test is intended." A reviewed verdict can be suppressed; a *change the human never saw* is never suppressed. Acceptance is bound to both the test definition and the reviewed response shape (status, content-type, top-level JSON keys, size bucket), re-checked every run. If the response later exposes a NEW field, a changed content-type, or jumps a size bucket, acceptance no longer holds and the alarm comes back.

### POST /api/v1/chains/:id/disposition

`Authorization: Bearer $LAUNCHGUARD_API_KEY`, owner-scoped (same load/404 pattern as PATCH). Body:
```json
{ "disposition": "accepted" | "proposed" | null, "reason": "why this is intended" }
```
- `reason` is required and non-empty when setting; `disposition: null` clears it.
- **An `lg_` API-key agent (you) may only set `"proposed"`** — a visible recommendation that does NOT suppress the alarm and does NOT count the chain green. Trying to set `"accepted"` from an API key returns **403** ("an API-key agent may only propose; a human must confirm acceptance"). Only a HUMAN principal (dashboard session / internal token) can confirm `"accepted"`, the suppressing state. The rationale is a real attack: chains return attacker-influenced response bodies into your context, so a confused/injected agent must not be able to self-clear a genuine vuln that every future session then trusts.
- **409/404 if no `vulnerable` run exists** — you cannot accept (or propose acceptance of) a verdict that never reproduced.

### What GET/LIST now return per chain

Alongside the honest `lastResult`, every `GET /api/v1/chains/:id` and `LIST /api/v1/chains` row (and `/api/v1/context`) carries:
- `disposition` — raw `accepted` | `proposed` | `null`.
- `dispositionReason`, `dispositionBy` (`user:<uuid>` or `ai_agent:<keyId>`), `dispositionAt`.
- `dispositionState` — the **load-bearing field you branch on**: `none` | `proposed` | `stale_spec` | `stale_escalation` | `honored`.
- `effectiveStatus` — `green` | `red` | `review`.
- `lastResult` — ALWAYS the honest run verdict, never overwritten by disposition.

### Branch on `dispositionState`, NEVER on raw `disposition`

This is how a future session honors a prior human decision instead of re-flagging an intended-public finding:
- **`honored`** → acceptance holds; the response still matches what was reviewed. Do NOT re-flag. Read `dispositionReason` and move on. This chain counts green.
- **`stale_spec`** → the test definition changed since acceptance; the prior acceptance no longer applies. Surface for human re-review — do not treat as resolved.
- **`stale_escalation`** → the chain is still `vulnerable` AND the response ESCALATED beyond what was accepted (a new JSON key, a changed content-type, or a size-bucket jump). Treat as a likely **REAL new finding** — the endpoint now exposes more than the human ever signed off on. Surface loudly for re-review.
- **`proposed`** → a recommendation is on record but NOT yet accepted (often by a prior agent). It does NOT suppress. You may reaffirm it, but you (an API key) CANNOT accept it — only a human confirms. Do not present it as resolved.
- **`none`** → no disposition; handle the verdict normally.

"All green" = every chain is `lastResult === 'fixed'` OR `dispositionState === 'honored'`. A `proposed` / `stale_spec` / `stale_escalation` chain still counts as red/review.

### How this ties into the intended-public methodology

`methodology.md` Step 6 tells you to FILTER OUT intended-public / free-tier-is-the-product findings (an aggregate `/api/stats` counter, the product's own free unauth scan) rather than ship them as scary verdicts. Disposition gives that filter a durable home: instead of silently dropping such a finding (and re-deciding it from scratch next session), **PROPOSE a disposition with a one-sentence reason** ("scan-status by id is an intended shareable capability"; "the free anonymous scan IS the product"). The human then one-click-confirms `accepted` in the UI (you can't self-accept). The suite goes honestly green, the reasoning is preserved, and the next agent reads `honored` + the reason instead of re-litigating it — while any real escalation still re-alarms via `stale_escalation`.

## 11. The bridge API: context, stacks, coverage

These three read-only/config routes are the **bridge loop**: connect, then READ `/context` so you start expert (the engine already scanned the app), then ACT on its `recommendations[]`, then author / toggle only the gaps. SKILL.md gives the loop; this section is the full contract. All require `Authorization: Bearer $LAUNCHGUARD_API_KEY` and follow the same base-URL fallback as the chain routes (try `https://api.launchguard.dev`, switch to `https://recon-api-dev.centrive.ai` once any `/api/v1/...` call 404s). `/context` is `lg_`-key-callable (dogfood-confirmed); it is no longer human-session-only.

### GET /api/v1/context?targetHost=<host>: the one call that makes you start expert

ONE call returns the engine's full posture for an app: inventory it already discovered, every test's verdict (engine checks AND the user's own chains), the gaps, and the recommended actions. Read it BEFORE authoring anything; do not re-recon what the engine already knows. Abridged live shape (load-bearing fields):

```json
{
  "app": "dev.launchguard.dev",
  "monitorId": "639d1d7b-...",
  "dashboardUrl": "https://launchguard.dev/app/639d1d7b-...",
  "lastScan": { "scanId": "...", "finishedAt": "...", "securityScore": 79, "status": "complete" },
  "inventory": {
    "note": "Redacted structural facts. No row samples, no secret values, no raw response bodies, no PII.",
    "supabase": {
      "present": true, "tablesDiscovered": 21, "tablesTested": 21,
      "tablesReadableAnon": 21, "tablesWithDataExposed": 0,
      "storageBucketsFound": 0, "publicStorageBuckets": 0,
      "rpcsFound": 0, "rpcsCallableAnon": 0,
      "tables": [ { "name": "analytics_events", "anonReadable": true } ]
    },
    "endpoints": { "count": 16, "truncated": false,
      "anonReachable": [ { "method": "GET", "path": "/api/prices", "getStatus": 200, "postStatus": 405, "contentType": "", "authObserved": "none" } ] },
    "subdomains": { "count": 0 },
    "secretsFound": 0
  },
  "tests": [
    { "id": "supabase", "kind": "engine", "bin": "data_exposure", "name": "Database exposure", "isCore": true, "toggleable": false, "state": "always_on", "verdict": "fixed", "coveredObjects": 21, "vulnerableObjects": 0 },
    { "id": "firebase", "kind": "engine", "bin": "data_exposure", "name": "Firebase exposure", "isCore": false, "toggleable": true, "toggleKey": "firebase", "state": "on", "verdict": "inconclusive" },
    { "id": "write_delete", "kind": "engine", "bin": "destructive_access", "name": "Write & delete testing", "isCore": false, "toggleable": true, "toggleKey": "write_delete", "state": "off", "verdict": "off" },
    { "id": "surface", "kind": "engine", "bin": "surface_hardening", "name": "Surface hardening", "isCore": true, "toggleable": false, "synthesized": true, "state": "always_on", "verdict": "vulnerable", "findingsCount": 6 },
    { "id": "cost", "kind": "byo_template", "bin": "cost_abuse", "name": "Cost abuse", "isCore": false, "toggleable": false, "requiresPro": true, "promptTemplateAvailable": true, "state": "not_run", "verdict": "not_run", "hasCustomChain": false },
    { "id": "chain:<uuid>", "kind": "chain", "chainId": "<uuid>", "bin": null, "name": "...", "source": "ai_agent", "severity": "high", "sideEffect": "read_only", "enabled": true, "watched": true, "autoReplay": true, "state": "on", "verdict": "fixed", "lastTestedAt": "...", "dispositionState": "none", "effectiveStatus": "green" }
  ],
  "coverageGaps": [
    { "bin": "cost_abuse", "stackId": "cost", "reason": "5 anon-reachable endpoint(s); cost-sink surface untested by any chain." },
    { "bin": "payment_bypass", "stackId": "payment", "reason": "Paywall bypass is business-logic the engine cannot test; no chain authored." },
    { "bin": "data_exposure", "stackId": "idor", "reason": "No chain covers IDOR / cross-tenant." },
    { "bin": "broken_access", "stackId": "broken_access", "reason": "Authenticated route access untested (no credential bound); no chain authored." }
  ],
  "recommendations": [
    { "action": "skip", "stackId": "supabase", "why": "Default Supabase stack covers every table/bucket/RPC as the anon role. Do NOT author per-table anon-db read chains." },
    { "action": "skip", "stackId": "secrets", "why": "Secrets stack covers frontend key exposure. Do NOT author fe-scan secret chains." },
    { "action": "skip", "stackId": "surface", "why": "Surface stack covers headers/CORS/source-maps/sensitive-files/cookies/frontend secrets. Do NOT author those." },
    { "action": "toggle_on", "stackId": "write_delete", "why": "Off by default; mutation/delete coverage is absent. Enabling fires real INSERT/UPDATE/DELETE probes." },
    { "action": "author_from_template", "stackId": "cost", "why": "5 anon-reachable endpoint(s); cost-sink surface untested by any chain.", "requiresPro": true },
    { "action": "author_gap", "bin": "payment_bypass", "why": "Paywall bypass is business-logic the engine cannot test." },
    { "action": "author_from_template", "stackId": "idor", "why": "No chain covers IDOR / cross-tenant.", "requiresPro": true },
    { "action": "author_gap", "bin": "broken_access", "why": "Broken access control is business-logic the engine cannot test.", "requiresPro": true }
  ],
  "findings": {
    "note": "Redacted: category, severity, server-synthesized title, structural location, ownerTest. No raw stored title, no evidence bodies, no secret values, no PII.",
    "truncated": false,
    "items": [ { "category": "missing_csp", "severity": "low", "title": "Missing security header: Content-Security-Policy", "location": { "kind": "endpoint", "name": "/" }, "ownerTest": "surface", "scanId": "..." } ]
  },
  "generatedAt": "..."
}
```

Field notes:
- `tests[]`: every default engine check is a first-class verdict-bearing test ALONGSIDE the user's `chain` tests. Branch on `kind`: `engine` (built-in stack, carries `state` `always_on`/`on`/`off` + `verdict`), `byo_template` (a gap with a ready prompt template, `state: "not_run"`, possibly `requiresPro`), `chain` (the user's authored test, carries `chainId` + `verdict` + `dispositionState` + `effectiveStatus`). A `synthesized: true` engine test (e.g. `surface`) is assembled from scan findings rather than run as a single probe.
- `chain` rows carry the SAME disposition fields documented in §10 (`dispositionState`, `effectiveStatus`); branch on `dispositionState`, not raw `disposition`.
- `inventory` is what you would have re-reconned (tables tested anon, anon-reachable endpoints, subdomains, secret count). Read it instead of re-scanning.

### The four `recommendations[].action` values

| `action` | Carries | What you do |
|---|---|---|
| `skip` | `stackId`, `why` | Engine already covers this bin. Author NOTHING for it. This is the anti-duplication discipline arriving as data. |
| `toggle_on` | `stackId`, `why` | A toggleable engine stack (`firebase` / `write_delete`) is off; turn it on with `POST /api/v1/coverage`. |
| `author_from_template` | `stackId`, `why`, optional `requiresPro` | A `byo_template` gap; author a chain from that stack's template (`cost`, `idor`, `payment`, `broken_access`). |
| `author_gap` | `bin`, `why`, optional `requiresPro` | A freehand custom chain for something the engine genuinely cannot do (authed paywall, IDOR / cross-tenant, business-logic, cost-sink, SSRF). |

### GET /api/v1/stacks[?targetHost=<host>]: the default-stack catalog

Without `targetHost`, the catalog only. With `targetHost`, each stack ALSO carries the per-domain `state` + `verdict` (and `coveredObjects` / `vulnerableObjects` where relevant). The live stacks:

| id | bin | kind | isCore | toggleable | requiresPro | notes |
|---|---|---|---|---|---|---|
| `supabase` | `data_exposure` | engine | yes | no | no | tests every table/bucket/RPC as anon |
| `secrets` | `leaked_secrets` | engine | yes | no | no | frontend key exposure |
| `firebase` | `data_exposure` | engine | no | **yes** (`toggleKey: "firebase"`) | no | toggleable |
| `write_delete` | `destructive_access` | engine | no | **yes** (`toggleKey: "write_delete"`) | no | toggling on fires REAL INSERT/UPDATE/DELETE probes |
| `cost` | `cost_abuse` | byo_template | no | no | yes | `promptTemplateAvailable` |
| `payment` | `payment_bypass` | byo_template | no | no | **no** | `promptTemplateAvailable`, `testClass: "coming"` |
| `idor` | `data_exposure` | byo_template | no | no | yes | `promptTemplateAvailable` |
| `broken_access` | `broken_access` | byo_template | no | no | yes | `promptTemplateAvailable` |
| `surface` | `surface_hardening` | engine | yes | no | no | synthesized (headers / CORS / source-maps / sensitive-files / cookies / frontend secrets) |

Each row also carries `categories[]` (the specific checks the stack runs) and `scanFlags`.

### POST /api/v1/coverage: toggle a default check

Body `{ targetHost, stackId, enabled }`. Merge-write. Live success shape:

```json
{ "ok": true, "app": "dev.launchguard.dev", "monitorId": "...", "stackId": "firebase", "toggleKey": "firebase",
  "enabled": false, "enabledTests": { "firebase": false, "write_delete": false },
  "appliesOnNextScan": true,
  "rescan": { "triggered": false, "note": "Takes effect on the next deploy scan. Pass {\"rescanNow\":true} to run immediately (subject to a per-monitor debounce)." } }
```

- ONLY the two toggleable engine stacks (`firebase`, `write_delete`) can be toggled. `enabled:false` then `enabled:true` is a clean reversible round-trip (verified: firebase off then on restored).
- **Non-toggleable stack -> `409 { "error": "<id> is always-on and cannot be toggled", "toggleable": false }`.** This is the verified toggle-rejection and it covers ANY non-toggleable stack: a core engine stack (`supabase` / `secrets` / `surface`) OR a non-toggleable Pro `byo_template` like `cost`. A `402` (Pro upsell) would only apply if a TOGGLEABLE stack ever required Pro you don't have, and none of the currently-toggleable stacks are Pro-gated, so that 402 path is not reachable today. Document the 409 as the real rejection; treat 402 as a hypothetical only.
- **Toggling `write_delete` on enables REAL INSERT / UPDATE / DELETE probes** against the domain. Only do this on explicit user request, and say so plainly first.
- A toggle takes effect on the NEXT scan / deploy by default (`appliesOnNextScan: true`). Pass `{"rescanNow":true}` to run immediately (subject to a per-monitor debounce).

## 12. Script / functional chain ingest contract (`artifact:"script"`)

A **script chain** — a self-contained `@playwright/test` spec the runner executes in a headless browser — is ingested through the SAME `POST /api/v1/chains` endpoint as an HTTP chain, but with a DIFFERENT, **FLAT** body shape. This is how you author every `functional-methodology.md` chain and every captured-session authenticated test. Get it exactly right: the script-chain fields are **top-level on the body, NOT nested under `spec`.**

### The discriminator: top-level `artifact: "script"`

The engine picks the **script (Playwright) runner** vs the **HTTP request-plus-matcher runner** on exactly ONE field: the **top-level** `artifact`. `"script"` → the Playwright runner; absent or `"http"` (the default) → the HTTP runner. The script source, the optional credential, the side-effect, and the host allowlist are then read from **top-level body fields** — there is no `spec` object for a script chain; the validator assembles the stored `spec` itself.

> **⛔ THE FOOTGUN THAT SILENTLY DISCARDS YOUR SCRIPT.** If you forget top-level `artifact:"script"` (or you nest the script under `spec`) AND you include an HTTP `spec.steps` + `spec.assertion`, the body validates as an ordinary HTTP chain, ingests `201`, and **the HTTP runner silently wins — your Playwright script is stored but never executed.** The run then tries to JSON-parse the HTML the browser would have rendered and routes to a false `inconclusive` (`exploit_body_unparseable`). For a script chain: set top-level `artifact:"script"`, put the spec in the top-level `script` string, and **do NOT send `spec.steps` / `spec.assertion` at all** — the Playwright `expect()`s ARE the matcher.

### The ingest body (copy-paste, verified shape)

```json
{
  "title": "Marketing home renders with a scan entry point",
  "targetHost": "dev.launchguard.dev",
  "severity": "low",
  "source": "ai_agent",
  "watched": false,
  "artifact": "script",
  "script": "// @lg-intent: functional\n// @lg-secure-when: pass\nimport { test, expect } from \"@playwright/test\";\n\ntest(\"home renders with a scan entry point\", async ({ page, baseURL }) => {\n  await test.step(\"reach the home page\", async () => {\n    await page.goto(\"/\", { waitUntil: \"domcontentloaded\" });\n    await expect(page).toHaveURL(new RegExp(`^${baseURL}/?$`));\n  });\n  await test.step(\"scan entry point is present\", async () => {\n    await expect(page.getByRole(\"button\", { name: /scan/i })).toBeVisible();\n  });\n});",
  "sideEffect": "read_only",
  "allowedTargets": { "primary": "dev.launchguard.dev" }
}
```

`script` is a **single JSON string** carrying the whole `@playwright/test` spec (escape newlines as `\n`). Again: NO `spec` object, NO `spec.steps`, NO `spec.assertion`.

### Required vs optional (all top-level)

| Field | Req? | Notes |
|---|---|---|
| `title` | required | unique among your ACTIVE chains (same rule as HTTP, §7) |
| `targetHost` | required | the monitored host; passes the SSRF / DNS guard |
| `severity` | required | `critical` / `high` / `medium` / `low` |
| `artifact` | **required, = `"script"`** | the discriminator; omit it and you get an HTTP chain (the footgun above) |
| `script` | **required** | the `@playwright/test` spec as a STRING. Must contain a `// @lg-intent:` header, a `test(...)` block, and ≥1 `expect(...)`. Max 200 KB |
| `source` | optional | defaults to `"ai_agent"` |
| `watched` | optional | defaults `false` (Proof). See §0 |
| `sideEffect` | optional | `"read_only"` or `"mutation"`; **defaults to `"mutation"`** (a browser click can write). A read-only functional render chain must set `"read_only"` explicitly so it can auto-run as a Guard |
| `destructive` | optional | boolean; OR'd with the `// @lg-destructive: true` header. When true, forces `sideEffect:mutation` (manual-only) |
| `credentialId` | optional | the opaque envelope id from `POST /api/v1/chains/credentials` (§9) — runs the script authenticated as that captured session |
| `allowedTargets` | optional | `{ primary?, supabase?, api? }`; `primary` defaults to `targetHost`. Scripts use relative paths; the host resolves from here |

> **`intent` and `secureWhen` are read from the SOURCE HEADER TAGS, not from body fields.** The validator parses them out of the `script` string (below). Declare them in the spec header — a top-level `intent` body field does not drive the build.

### The header tags (parsed from the `script` source — the colon is mandatory)

The validator scans for three `//`-comment tags ANYWHERE in the source. **The colon is required** — `// @lg-intent functional` (no colon) is REJECTED with `400 script must declare its intent`:

- `// @lg-intent: security` **or** `// @lg-intent: functional` — **REQUIRED.** Drives the PASS→`fixed` / FAIL→`vulnerable` framing.
- `// @lg-secure-when: pass` — **REQUIRED for `security` intent** (the test PASSES when the app is SECURE, so a broken run routes to `inconclusive`, never a false verdict). Optional for `functional`.
- `// @lg-destructive: true` — optional; forces `sideEffect:mutation` (the same manual-only gate as a non-GET HTTP chain) for a functional script that writes state through the browser.

Import allowlist is strict: a script may import ONLY `@playwright/test` (or `playwright` / `playwright/test`). Any other `import` / `require` / dynamic `import()` is rejected at ingest — move helpers inline.

### Reference a captured session (authenticated script chain)

Upload the session once (`POST /api/v1/chains/credentials`, §9) → get a `credentialId` → pass it as the **top-level `credentialId`** in the body above. The engine owner-binds the envelope to you, decrypts it in-memory at run time only, and runs the script as that real logged-in identity. The non-secret `identity` (`{ label, metadata }`) sealed in the credential is threaded onto `spec.script.identity`, so GET/LIST can show "runs as <email>" without ever decrypting.

### What you get back (GET shape)

`POST` returns `{ chainId, autoReplay, watched, sideEffect }` like any chain. `GET /api/v1/chains/<id>` returns the **stored, redacted** spec — and note the source now lives at **`spec.script.source`** (the validator moved your top-level `script` string into the assembled spec):

```json
{
  "spec": {
    "version": 2,
    "artifact": "script",
    "steps": [],
    "assertion": { "successStatusIn": [], "fixedStatusIn": [] },
    "auth": {},
    "sideEffect": "read_only",
    "allowedTargets": { "primary": "dev.launchguard.dev" },
    "script": {
      "source": "// @lg-intent: functional ...",
      "intent": "functional",
      "secureWhen": "pass",
      "steps": ["reach the home page", "scan entry point is present"],
      "identity": { "label": "free-tier user", "metadata": { "tier": "free" } },
      "hasCredential": true
    }
  }
}
```

- The Playwright source is **`spec.script.source`** on read-back (top-level `script` STRING at ingest, `spec.script.source` once stored). **Dedupe script chains by diffing THIS field** (or by title), never by the constant exploit summary — see SKILL.md Step 2 carve-out.
- `spec.script.steps[]` are the `test.step("…")` titles parsed at ingest (the pre-run checklist), index-aligned with the live `step` SSE events.
- `script.credential` (the encrypted session) is NEVER echoed — it is replaced by a `hasCredential` boolean. `script.identity` (non-secret) IS returned.
- Every script chain's list-row `exploit` summary collapses to the constant `(PLAYWRIGHT, "(script chain)", primary)`.

> **Redirect-gated endpoints: prefer a script chain.** The HTTP-matcher runner mis-routes a `302 → /login` to `inconclusive` (§4 "Known routing bug"). A script chain runs a real browser that follows the redirect, so an auth-gated render flow an HTTP matcher cannot verdict cleanly is exactly what a functional script chain is for.
