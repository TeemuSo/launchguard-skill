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
| `minTotalRows` | `number` | requires a PostgREST `content-range` total `>=` this |
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

Optional `?targetHost=<host>` filter (normalized the same way ingest derives `host`). Success `200`:
```json
{ "targetHost": "sandbox.example.com", "count": 2, "chains": [
  { "chainId": "<uuid>", "targetHost": "sandbox.example.com", "title": "...",
    "severity": "high", "source": "ai_agent", "sideEffect": "read_only",
    "status": "active", "lastResult": "vulnerable", "lastTestedAt": "...",
    "enabled": true, "autoReplay": true, "createdAt": "...",
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

Soft-deletes (archives) a chain. Internally it stamps `deleted_at` rather than hard-deleting, so the row and its run history are retained server-side, but for your purposes it is a removal: the chain disappears from `GET /api/v1/chains`, stops auto-running on deploys, and cannot be run. There is no un-archive API endpoint, so do not present this as an easily reversible toggle. Archiving frees the title, so the same title can be re-ingested afterward (effectively replacing it). Owner-scoped. Success `200`:
```json
{ "ok": true, "chainId": "<id>", "archived": true }
```
A `404` (`{ "error": "chain not found" }`) means the chain is missing, belongs to another user, or is already archived. Use this to clean up a duplicate or broken chain instead of leaving it stored. Errors: `401`, `404`, `500`.

## 8. Current limitations worth telling the author

- Only two credential modes work without stored secrets today: anonymous (`auth: {}`) and Supabase anon (`spec.env.anonKey` signs up a fresh test account per run). Any bearer / cookie / static-token chain that needs a stored secret resolves to null and routes the run to `inconclusive`.
- `/api/v1/*` may not yet be exposed at the public edge. If a call to `api.launchguard.dev` returns 404 on the route, fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host).
