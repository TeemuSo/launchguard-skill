# LaunchGuard — Connect & Monitor

Link a project to LaunchGuard for ongoing protection (re-scan on every deploy), custom tests, and the `/context` bridge loop. This is the power-user layer on top of the free scan in `SKILL.md`.

## Step 0: Authenticate (one-click, first time only)

Power-user features (monitoring, custom tests, connect) use your LaunchGuard account.
Logging in is ONE browser click — no keys to copy or paste.

1. Check for an existing session first:
   ```bash
   cat ~/.launchguard/credentials 2>/dev/null
   ```
   If it has a `token` starting `lg_`, use that as the Bearer and skip the rest.

2. Start a device login:
   ```bash
   curl -s -X POST https://www.launchguard.dev/api/device/code
   ```
   Returns `{ device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval }`.

3. Show the user the link + code, e.g.:
   "Open <verification_uri_complete> and click Authorize (code: <user_code>)."

4. Poll every `interval` seconds until approved:
   ```bash
   curl -s -X POST https://www.launchguard.dev/api/device/token \
     -H "Content-Type: application/json" -d '{"device_code":"<device_code>"}'
   ```
   - `{"status":"authorization_pending"}` (HTTP 202) → wait `interval`s, poll again.
   - `{"access_token":"lg_…"}` (HTTP 200) → success.
   - `{"status":"expired"|"invalid_device_code"|"already_consumed"}` → stop and restart from step 2.

5. Persist it for next time and use it as the Bearer on every `/api/v1` call:
   ```bash
   mkdir -p ~/.launchguard && printf '{"token":"%s"}' "<access_token>" > ~/.launchguard/credentials && chmod 600 ~/.launchguard/credentials
   export LAUNCHGUARD_API_KEY="<access_token>"
   ```
   On later runs, read the token from `~/.launchguard/credentials` instead of logging in again.

---

## Step 0 (funnel): Pairing-code onboarding (hands-free, no human approval)

**Use this INSTEAD of the interactive device login above when the pasted prompt carries a pairing code.** The LaunchGuard website hands a copyable prompt to a visitor who *already signed in through the browser*; that browser session pre-approved a device pairing server-side. So Claude Code does NOT run the human-approval round trip — it just claims the key the website already authorized.

**Trigger.** The prompt you were handed has a `Pairing code:` line (the `device_code`), and the target URL inline in the FIRST sentence (`...review a security boundary on <TARGET_URL>.`) — NOT on a separate `Target:` line. Like this:

```
Use the LaunchGuard skill to review a security boundary on <TARGET_URL>.

Connect, then read /context. Our scan saw the following from the outside — these are observations, not verdicts:
- table `businesses` answered reads without auth (26 rows)

First, decide intent with me: for each, read the code and tell me whether it's public by design or a real leak. Fix and prove only what we agree is a real problem.

Then go deeper: prove or break the one boundary that matters — cross-tenant read, IDOR, paywall, or cost-sink. Author one tailored test, submit it to LaunchGuard as a saved proof, and run it for the verdict.

Pairing code: <DEVICE_CODE>
Exchange the pairing code for your key before connecting.
```

The trigger key is the `Pairing code:` line — its value is the `device_code` you exchange. Extract the target URL from the FIRST sentence ("...review a security boundary on <TARGET_URL>."); there is no `Target:` line anymore. When a `Pairing code:` value is present, take THIS path — do NOT run the interactive device login above.

1. **Exchange the pairing code for a key in ONE call** — no link to open, no human approval, because the browser already authenticated the user and pre-approved this pairing:
   ```bash
   curl -s -X POST https://www.launchguard.dev/api/device/token \
     -H "Content-Type: application/json" -d '{"device_code":"<PAIRING_CODE>"}'
   ```
   - `{"access_token":"lg_…"}` (HTTP 200) → success, IMMEDIATELY. This is the expected case.
   - `{"status":"authorization_pending"}` (HTTP 202) → the pairing was NOT pre-approved. Fall back to the normal interactive device login (Step 0 above) starting at its step 2.
   - HTTP 410 `expired` / HTTP 409 `already_consumed` → the code is stale or already used. Tell the user to regenerate the prompt from the LaunchGuard website, then retry with the fresh pairing code.

2. **Persist the `lg_` token exactly like Step 0 step 5** — store it and export it for every `/api/v1` call:
   ```bash
   mkdir -p ~/.launchguard && printf '{"token":"%s"}' "<access_token>" > ~/.launchguard/credentials && chmod 600 ~/.launchguard/credentials
   export LAUNCHGUARD_API_KEY="<access_token>"
   ```

3. **Then fall into the existing flow below — do not re-derive or duplicate it.** With the key set, continue exactly as the normal connect path, then run the two-phase flow. The scan produces OBSERVATIONS, not verdicts — never treat the scanner's `exposed` / `amber` / `secured` state as a decision:
   - **Connect:** `POST /api/v1/connect` using the target URL from the FIRST sentence of the prompt (`...review a security boundary on <TARGET_URL>.`) — there is no `Target:` line (see "Connect to LaunchGuard" below). The moment connect returns, show the human its `dashboardUrl` (`https://launchguard.dev/app/<id>`) right away, so they have a live page to open while the deep step runs: "Open this to follow along and run your test yourself. It'll be ready in a few minutes: <dashboardUrl>."
   - **Read `/context`:** run the bridge loop (see "Start expert: read /context first").
   - **Phase A — orient & verify (only when the scan saw something):** surface what `/context` SAW — its `findings` / `inventory` — to the user in plain language AS OBSERVATIONS. For each, read the code's intent and decide WITH THE USER whether it is intended-public or a real problem, applying the intended-public filter (an aggregate counter, a published pricing list, or a public feed answering anonymously is NOT a finding). Fix and prove ONLY the items the user confirms are real problems. LaunchGuard does not pre-decide this; you and the user do. **Skip Phase A entirely when the scan saw nothing** — a clean / GREEN app has no observations to triage, so go straight to Phase B.
   - **Phase B — go deeper (identical for every outcome; this is exactly where a GREEN / clean app STARTS):** prove or break the ONE boundary that matters — cross-tenant read, IDOR, paywall, or cost-sink — the business-logic boundary a perimeter scan cannot see. Framing is OUTCOME-NEUTRAL: a witnessed GREEN counts as much as a RED; NEVER set out to "find a vulnerability" and never manufacture a finding. Author ONE tailored test from `/context`'s `recommendations[]` / `coverageGaps[]`, submit it as a saved Proof (leave `"watched"` unset; it defaults to `false`), run it, let LaunchGuard's verdict engine adjudicate, and **report the verdict**. (Watching it on every deploy is a separate opt-in step the user takes later, not part of this first run.) This is exactly the "Then: author ONE tailored, business-logic test" section below. RED, AMBER, and GREEN all converge onto this SAME Phase B.

**Why this skips the approval round trip:** the browser already did the auth and created a pre-approved pairing, so Claude Code just claims the key the website authorized — the interactive device-approval step is intentionally skipped, not forgotten.

---

## Connect to LaunchGuard (lightweight handshake)

Use this when the user wants to *link* their project to LaunchGuard for an app they already added — triggers like "connect this to LaunchGuard", "connect my Claude Code", "watch this app on every deploy", or when they paste the connect prompt from their LaunchGuard app page.

This is a **lightweight handshake**: the agent itself makes no probing request to their site. It **auto-registers** the app for your authenticated key (the app page flips to "Connected") and kicks off an initial scan server-side — no website step needed. The first call for a host returns `firstConnect: true`, and `/context` populates within a few seconds as that scan completes.

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

> **Hand the human the live dashboard URL immediately.** The response includes `dashboardUrl` (`https://launchguard.dev/app/<id>`). Show it to the user the moment connect succeeds, so they have a live page to open while the deep step (authoring and running a tailored test) takes a few minutes: "Open this to follow along and run your test yourself. It'll be ready in a few minutes: <dashboardUrl>". Use ONLY the API-provided `dashboardUrl`; never hand-build a per-app link (see `CHAINS.md`).

- `coverageSummary` is the at-a-glance posture (how many default engine stacks are enabled/covered/vulnerable/off, how many of the user's own watched chains exist and how many are red, and how many open coverage gaps remain). `coverageSummary.contextUrl` hands you the EXACT `/context` call to make next: connect then read `/context` is the natural handoff. Do not author anything until you have read `/context` (see "Start expert: read /context first" below).
- The Bearer is the `lg_` token from **Step 0 (device login)**, stored in `LAUNCHGUARD_API_KEY` — the same key the chain endpoints use. If it's missing, run Step 0 first.
- Connect **auto-registers** the app for the authenticated key and kicks off an initial scan — there is NO website step (no "add it at launchguard.dev/apps first"). The first call for a host returns `firstConnect: true`.
- Base URL: `https://api.launchguard.dev`.

### Start expert: read /context first (the bridge loop)

This is THE one new habit, and it is the FIRST thing you do after connecting and BEFORE you author anything. The old flow re-reconned the app and authored one chain per rule from scratch. You no longer do that. The engine already scanned this app: its coverage, inventory, and the gaps it cannot cover are all handed to you in one call. You START expert. You do NOT re-derive what the default scanner already knows; you READ it.

The loop is six steps:

1. **CONNECT**: `POST /api/v1/connect` (above). Returns `coverageSummary` and a `contextUrl`.
2. **READ CONTEXT**: `GET /api/v1/context?targetHost=<host>`. ONE call returns everything you need: the engine's inventory, every test's verdict (engine checks AND the user's own chains), the gaps, and an explicit list of recommended actions. Read this before authoring a single chain.
3. **VERIFY (Phase A)**: surface `/context`'s `findings` / `inventory` to the user as OBSERVATIONS, not verdicts — the scan SAW things, it did not DECIDE them. Read the code's intent and decide WITH THE USER what (if anything) is a real problem before you author or fix anything, applying the intended-public filter. Skip this step when the scan saw nothing (a clean / GREEN app has nothing to triage — go straight to step 4). See the fuller Phase A / Phase B doctrine in the "Step 0 (funnel)" section above.
4. **ACT ON `recommendations[]`**: only AFTER that verification, and never treating scan state as a decision, do EXACTLY what each recommendation's `action` field says (the four actions are below). The anti-duplication discipline now arrives as DATA: a `recommendations[].action === "skip"` tells you precisely what the engine already covers, so you author nothing for it. Trust `/context`; do not re-derive the engine.
5. **RUN**: `POST /api/v1/chains/:id/run` on any chain you authored, for its tri-state verdict (unchanged).
6. **WATCH**: ingest the chains you want guarded with `"watched": true` so they re-run on every deploy (unchanged).

#### `GET /api/v1/context?targetHost=<host>`

```bash
curl -s "https://api.launchguard.dev/api/v1/context?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

`/context` is now callable with an `lg_` key (dogfood-confirmed). Top-level shape (load-bearing fields; full contract in `reference/chains-reference.md` §11):

> **On a FIRST connect the scan was just triggered, so the first `/context` call may briefly return `lastScan: null` with an empty `inventory` (no endpoints / no Supabase tables) and no `findings`.** That is not "nothing to cover" — the scan is still running. **Poll `/context` every few seconds until `lastScan` is non-null** before you author from `inventory`. The "start expert / don't re-recon" guidance below holds the moment it's populated; ONLY if `/context` stays empty after the scan settles should you fall back to your own recon.

- `app`, `monitorId`, `dashboardUrl`, `lastScan` (with `securityScore`, `status`).
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
| `author_from_template` | `stackId`, `why`, optional `requiresPro` | A `byo_template` gap. Author a chain from that stack's template (e.g. `cost`, `idor`) using the templates in `CHAINS.md`. |
| `author_gap` | `bin`, `why`, optional `requiresPro` | A freehand custom chain for something the engine genuinely cannot test (an authed paywall, IDOR / cross-tenant, business-logic, a cost-sink, SSRF). Author it tailored to the app. |

So: walk `recommendations[]`, skip what is `skip`, toggle what is `toggle_on`, and author one chain for each `author_from_template` / `author_gap` you decide to cover. In the Connect flow you typically pick ONE `author_gap` / `author_from_template` to author as a saved Proof (next subsection) rather than re-deriving a rule blind.

> **A `byo_template` / `author_from_template` recommendation is a STACK LABEL (`cost`, `idor`, `payment`, `broken_access`), not a pre-filled request.** It tells you WHICH class of bug to cover; it does NOT hand you a ready `{method, path}` for THIS app. You still write the proving request yourself — but you do NOT need to re-recon: the engine already discovered the candidate routes and listed them in `/context`'s `inventory.endpoints.anonReachable[]` (each with `method` / `path` / status / `authObserved`). Read that list, pick the route that matches the stack (an AI/compute route for `cost`, a tenant-data route for `idor`), and translate it with the `CHAINS.md` template. And keep the `reference/methodology.md` Step 6 intended-public filter on as you do: an aggregate counter, a published pricing list, or a public feed answering anonymously is intended-public and is NOT a finding — reserve `vulnerable` for another tenant's rows, PII, internal ids/emails, secrets, or paid work that crossed a real trust boundary.

#### `GET /api/v1/stacks[?targetHost=<host>]`: the default-stack catalog

```bash
# catalog only:
curl -s "https://api.launchguard.dev/api/v1/stacks" -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
# with per-domain state + verdict for each stack:
curl -s "https://api.launchguard.dev/api/v1/stacks?targetHost=sandbox.example.com" \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY"
```

Lists the default stacks LaunchGuard ships (`supabase`, `secrets`, `firebase`, `write_delete`, `cost`, `payment`, `idor`, `broken_access`, `surface`) with each one's `bin`, `kind` (`engine` / `byo_template`), `isCore`, `toggleable`, `requiresPro`, the `categories[]` it checks, and `scanFlags`. With `targetHost`, each row ALSO carries the per-domain `state` + `verdict` (and `coveredObjects` / `vulnerableObjects` where relevant). Use it to understand what a stack does before toggling or authoring around it. Full table in `reference/chains-reference.md` §11.

#### `POST /api/v1/coverage`: toggle a default check on/off

```bash
curl -s -X POST https://api.launchguard.dev/api/v1/coverage \
  -H "Authorization: Bearer $LAUNCHGUARD_API_KEY" -H "Content-Type: application/json" \
  -d '{"targetHost":"sandbox.example.com","stackId":"write_delete","enabled":true}'
```

Toggles a toggleable engine stack on or off (merge-write). Live success shape:
```json
{ "ok": true, "app": "sandbox.example.com", "monitorId": "...", "stackId": "firebase", "toggleKey": "firebase",
  "enabled": false, "enabledTests": { "firebase": false, "write_delete": false },
  "appliesOnNextScan": true,
  "rescan": { "triggered": false, "note": "Takes effect on the next deploy scan. Pass {\"rescanNow\":true} to run immediately (subject to a per-monitor debounce)." } }
```

- ONLY the two toggleable engine stacks (`firebase`, `write_delete`) can be toggled. Toggling `enabled:false` then back to `true` is a clean reversible round-trip.
- A non-toggleable stack returns **`409 { "error": "<id> is always-on and cannot be toggled", "toggleable": false }`**. This is the real toggle-rejection. ANY non-toggleable stack hits this (a core engine stack like `supabase`/`secrets`/`surface`, OR a non-toggleable Pro `byo_template` like `cost`). A `402` (Pro upsell) would only appear if a TOGGLEABLE stack ever required Pro you don't have, and none of the currently-toggleable stacks are Pro-gated, so the 402 path is not reachable today. Treat the 409 as the answer; mention 402 only as the hypothetical.
- **Toggling `write_delete` on enables REAL INSERT / UPDATE / DELETE probes** against the domain. Only do this when the user explicitly wants destructive-access testing, and say so plainly first.
- A toggle takes effect on the NEXT scan / deploy by default (`appliesOnNextScan: true`). Pass `{"rescanNow":true}` to run it immediately (subject to a per-monitor debounce).

### Then: author ONE tailored, business-logic test (from /context's recommendations)

Connecting alone is enough to show "Connected". But the moment that makes LaunchGuard worth keeping is a custom test specific to THIS app, the thing a generic scanner cannot write because it never read the code. You no longer derive that rule blind: `/context` already told you the gaps.

**First, Phase A — present the observations, confirm intent.** The scan produces OBSERVATIONS, not verdicts: never treat its `exposed` / `amber` / `secured` state as a decision. When `/context` SAW something (`findings` / `inventory`), surface each item to the user in plain language AS AN OBSERVATION, read the code's intent, and decide WITH THE USER whether it is intended-public or a real problem — applying the `reference/methodology.md` Step 6 intended-public filter (an aggregate counter, a published pricing list, or a public feed answering anonymously is NOT a finding). Fix and prove ONLY what the user confirms is a real problem; LaunchGuard does not pre-decide this. When the scan saw nothing, there is nothing to triage — skip straight to Phase B below.

**Then, Phase B — prove or break the ONE boundary that matters.** This is exactly where a clean / GREEN app STARTS, and where RED / AMBER apps converge onto the same path. The framing is OUTCOME-NEUTRAL: a witnessed GREEN is as valuable as a RED; you are NOT trying to "find a vulnerability" and you never manufacture a finding. You let LaunchGuard's verdict engine adjudicate the run. After reading `/context`:

1. **Pick your ONE test from `recommendations[]` / `coverageGaps[]`** (the engine handed you the candidates). Choose an `author_gap` or `author_from_template` item: a rule the engine genuinely cannot cover, prioritized by impact and by what the `why` flags. These are the same business-logic boundaries that matter most:
   - a plan / quota / usage limit (a non-paying request cannot exceed the free tier), usually a `cost_abuse` / `cost` recommendation,
   - a tenant-ownership / IDOR boundary (user A cannot read user B's record), usually a `data_exposure` / `idor` recommendation,
   - a paywall (a Pro-only route or resource served to an unpaid request), usually a `payment_bypass` / `payment` recommendation,
   - an admin-only or internal route reachable by a guest, usually a `broken_access` recommendation.
   Do NOT pick something `/context` marked `action: "skip"`: the engine already covers it.
2. **Translate that recommendation into a read-only custom test** (use the templates in `CHAINS.md`, or the `byo_template` for an `author_from_template` item) and submit it **as a saved Proof**, leaving `"watched"` unset (it defaults to `false`) in the ingest body. Onboarding is about the user proving ONE boundary and keeping it as evidence; continuous monitoring (a watched Guard that re-runs on every deploy) is the separate step the user opts into later, NOT the default first action. Define the marker that WOULD prove a break if one exists — a foreign row's owner id, a completion/job id, a paid resource field — so the verdict is decided by evidence, not assumption.
3. Report the verdict, and point the user at the `dashboardUrl` (from the connect response or `/context`) so they land on their app page (`/app/<id>`) with the proof saved. If the user then explicitly wants this watched on every deploy, promote it to a Guard (`PATCH /api/v1/chains/<id>` with `{ "watched": true }`). That continuous step is opt-in, not automatic.

Because the app is now **monitored**, a chain against it (read-only OR mutating) is allowed straight away: adding the app to the account is the ownership signal (trust-the-owner). Keep this first test read-only, minimal (one ingest + one run), and tailored, a test that feels made for their app, not a generic check.

---

To author and triage the actual exploit chains, see `CHAINS.md`.
