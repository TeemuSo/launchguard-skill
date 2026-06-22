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
| `fixedStatusIn` | `number[]` | statuses that positively mean denied. Use `[401,403,429]` |
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

Both require `Authorization: Bearer $LAUNCHGUARD_API_KEY`. Base URL: use `https://api.launchguard.dev`. If any `/api/v1/...` call returns 404, the public edge isn't live yet — fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host, safe to call).

### POST /api/v1/chains (ingest)

Body: `{ title, targetHost, severity, spec, source? }`. Success `201`:
```json
{ "chainId": "<uuid>", "autoReplay": true, "sideEffect": "read_only" }
```
`autoReplay: true` means the chain is allowed to run. If the request looked mutating (write-style method/path), the response instead carries `"note": "Mutating chain stored as manual-only; it will not auto-run."` — meaning it was stored but won't auto-run, and a `/run` call returns 409. Errors: `400` (validation / SSRF), `401` (auth), `500`.

### POST /api/v1/chains/:id/run (re-execute)

No body. Success `200`:
```json
{ "runId": "<uuid>", "result": "vulnerable|fixed|inconclusive",
  "reason": "human-readable gate reason", "matched": true, "regression": false }
```
`matched` is true only on `vulnerable`. `regression` is true when a chain that previously read `fixed` now reads `vulnerable` (i.e. the bug came back). Errors: `401`, `403` (chain belongs to another user), `404`, `409` (chain is disabled, or was treated as mutating and is therefore manual-only — it won't auto-run), `500`.

## 8. Current limitations worth telling the author

- Only two credential modes work without stored secrets today: anonymous (`auth: {}`) and Supabase anon (`spec.env.anonKey` signs up a fresh test account per run). Any bearer / cookie / static-token chain that needs a stored secret resolves to null and routes the run to `inconclusive`.
- `/api/v1/*` may not yet be exposed at the public edge. If a call to `api.launchguard.dev` returns 404 on the route, fall back to `https://recon-api-dev.centrive.ai` (LaunchGuard's own backend host).
