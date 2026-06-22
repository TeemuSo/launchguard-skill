# Custom test reference — request + matcher

Deep reference for the Bring Your Own Test section in SKILL.md. Read this when you need more than the single anonymous read in the 90% template: cross-tenant IDOR, multi-step preconditions, extractors, the exact assertion vocabulary, the JSONPath dialect, or the verdict-routing rules.

Mental model unchanged: a custom test is one HTTP request plus a matcher rule, submitted as JSON. One `exploit` step (the request), optional `precondition` steps (setup / variable extraction), and one `assertion` (the matcher block).

All calls need the user's API key. Per SKILL.md, store it as `LAUNCHGUARD_API_KEY` and send `-H "Authorization: Bearer $LAUNCHGUARD_API_KEY"`.

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
    "enabled": true, "autoReplay": true, "createdAt": "...",
    "archived": false, "archivedAt": null,
    "exploit": { "method": "POST", "path": "/api/chat", "target": "primary" } }
] }
```
`exploit` (`{method, path, target}`) is the **dedupe key** — before authoring a new chain, list the existing ones for the host and skip any whose `exploit` already covers the same request. Owner-scoped. Errors: `400` (bad `targetHost`), `401`, `500`.

### GET /api/v1/chains/:id (read one full blueprint)

Returns a single chain end-to-end, including the complete `spec` (steps + assertion + allowedTargets), plus `declaredSideEffect` / `derivedSideEffect` / `specVersion` / `updatedAt`. Use this to inspect an existing test before re-running it or proposing a variant. Owner-scoped: another user's chain (or a missing one) returns `404`. Errors: `400` (no id), `401`, `404`, `500`.

### POST /api/v1/chains (ingest)

Body: `{ title, targetHost, severity, spec, source? }`. Success `201`:
```json
{ "chainId": "<uuid>", "autoReplay": true, "sideEffect": "read_only" }
```
`autoReplay: true` means the chain is allowed to run. If the request looked mutating (write-style method/path), the response instead carries `"note": "Mutating chain stored as manual-only; it will not auto-run."` — meaning it was stored but won't auto-run, and a `/run` call returns 409. Errors: `400` (validation / SSRF), `401` (auth), `500`.

### PATCH /api/v1/chains/:id (modify)

Owner-scoped in-place edit. Body: `{ title?, severity?, spec? }`, supply at least one. When `spec` changes it is re-validated (same rules as ingest, §6) and the side-effect is re-derived, so changing a method to a non-GET can flip the chain to `mutation` (manual-only). `title` must stay unique among your ACTIVE chains; a rename that collides with another active chain returns `409`. Use this to fix or evolve a test in place instead of archive-then-reingest. Success `200`:
```json
{ "chainId": "<uuid>", "title": "...", "severity": "high",
  "sideEffect": "read_only", "autoReplay": true, "updatedAt": "..." }
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
- A mutation chain run works against any domain the user MONITORS (has added to their account); trust-the-owner covers mutations the same as read-only runs, so no separate DNS verification is needed. A host that is not in the account still needs verified ownership, and a run against one returns `403`.
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

- Only two credential modes work without stored secrets today: anonymous (`auth: {}`) and Supabase anon (`spec.env.anonKey` signs up a fresh test account per run). Any bearer / cookie / static-token chain that needs a stored secret resolves to null and routes the run to `inconclusive`.
- **`spec.env.anonKey` cross-tenant signup requires a Supabase-Auth app + a legacy `eyJ...` JWT anon key.** It signs a fresh user up through Supabase Auth (GoTrue). On a Clerk / Auth0 / Firebase-Auth app there is no GoTrue path → the run dies at `auth_failed: no_credential_resolver` before any HTTP request (unassertable — don't author it). A new-format `sb_publishable_...` key carries no JWT identity, so it also can't drive the signup. On those apps, fall back to the anonymous-exposure style: a plain `target:"supabase"` GET to `/rest/v1/<table>` with the public key in `apikey`/`authorization` headers + `Prefer: count=exact` + `minTotalRows: 1`. The `sb_publishable_` key works fine in that header role.
- **Cross-host targeting is supported.** Only `allowedTargets.primary` must byte-equal `targetHost`; `allowedTargets.api` and `.supabase` are free-form passthrough hosts and may differ from the monitored domain. This is how you reach a separate backend host (`target:"api"`) or the Supabase project (`target:"supabase"`) — essential since unauth object-access holes usually live on the backend, not the gated frontend proxy.
- A GET whose handler causes downstream WRITES still classifies `read_only` + auto-replay (side-effect is method-derived) and will fire its write on every deploy — there is no GET→manual downgrade. Don't author such a chain; cover the endpoint another way or archive it.
- The matcher asserts only on status + body content + JSON markers + content-type. It cannot express rate-limit ("fire N, expect a 429"), response time, or response headers — so missing-rate-limit (API4) and missing-security-header bugs are code-review findings, not chains.
- **The credential ceiling: only anonymous and Supabase-anon identities exist.** Any bug behind "logged in but under-privileged" — a Pro-only route reachable by a free user, an admin function reachable by a member, an authenticated cross-tenant IDOR on a non-Supabase-Auth app — cannot be proven `vulnerable` black-box, because the engine can't mint that authenticated-but-limited identity. A black-box run hits `401 auth_required` and reads `fixed`, masking the bug. Author these as stored coverage + a code-review finding, and tell the user the chain can't auto-prove it until a bring-your-own-session/bearer credential mode ships. Never present that `fixed` as "safe".
- **Object-read (IDOR) chains need a real victim id or they stay `inconclusive`.** A route like `/api/thing/:id` returns `404` for a synthetic id, and `404` is never `fixed`. Add a `precondition` step that `extract`s a real id from a listing/creation endpoint into a `{{var}}` and reference it in the exploit path. Without a seeded real id the chain is permanent-inconclusive noise — don't author it.
- `/api/v1/*` may not yet be exposed at the public edge. If a call to `api.launchguard.dev` returns 404 on the route, fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host).
