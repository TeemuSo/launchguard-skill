# LaunchGuard — Deep per-app security audit

A systematic, per-app walk through the **~22 fundamental security invariants** (`reference/invariants.md`),
**fitting each to THIS app's real routes, tables, and identities** and proving it with a witnessed chain
or a code-review finding. This goes WAY deeper than the free scan.

> **Why this is valuable even when the scan found nothing.** The free scan proves the *universal floor*
> — the ENGINE invariants (anon table reads, leaked secrets, security headers). That floor is real, but
> it is the part a generic scanner can do precisely because it needs no app knowledge. The boundaries
> that actually break vibe-coded apps — **cross-tenant reads, privilege escalation, forced browsing,
> cost abuse, directory traversal, token handling** — are *per-app*: they depend on which table is the
> tenant table, which column is the owner, which route is the admin function, which param takes a
> filename. A scanner can't author those because it never read the code. **An agent reading the app
> can.** That fitting is this audit's whole job, and it is exactly why a clean scan is the *start* of
> assurance, not the end.

> **Principle — author + surface, never skip, never auto-fire.** LaunchGuard's value is the captured
> test you own and decide to run. For a **DESTRUCTIVE** or **CREDENTIAL-GATED** invariant — a cross-tenant
> or anon write/delete (B2/B7), a paid/outbound call (G1), an authed cross-tenant read whose identity
> can't be provisioned (B1/B3/B5) — the agent **AUTHORS the test and SURFACES it to you**; it does NOT
> skip it, fake it, or auto-fire it. **You (or your explicit confirmation) RUN it.** This is safe because
> the product enforces it server-side: a mutation chain never auto-runs (an unconfirmed run returns
> `409 needsConfirmation` and fires nothing), and a credential-gated test now returns `inconclusive`
> (not a false `fixed`) when the needed identity wasn't provisioned. The captured, unfired test *is* the
> deliverable. **The agent must never auto-fire a mutation/destructive request on a live app** — it
> authors and hands it to you; your confirmation is what runs it.

---

## When to run

Trigger this on: "deep audit", "thorough security review", "audit everything", "go deeper than the
scan", "full security audit before launch", or any request for real pre-launch assurance. Also **offer
it proactively after a scan — especially a clean one** (`SKILL.md` Step 7 / Next steps): a 0-finding
scan means the floor holds, which is the right moment to prove the per-app boundaries the floor doesn't
cover.

## Prerequisites

- **Authenticated + connected (ideal).** To author and run chains you need an `lg_` token and the app
  monitored. Do `CONNECT.md` Step 0 (one-click device login) and the connect handshake first. Without
  it you can still do the CODE-REVIEW invariants and reason about the CHAIN ones, but you can't witness
  a verdict.
- **Read `/context` first.** It tells you what the engine already covers (the ENGINE invariants), the
  discovered `inventory` (tables, anon-reachable endpoints, secrets), and the `recommendations[]`. You
  skip everything it marks `action: "skip"` and fit your chains to the routes/tables it already found —
  do NOT re-recon.
- **Read `reference/methodology.md`.** Every finding goes through the pentester discipline
  (threat-model → reachability-from-fresh-state → enumerability → escalation → honest severity →
  intended-public filter → validation gate). It is what stops a clean audit turning into a pile of false
  positives.
- **Local source helps a lot.** The CHAIN fits and all CODE-REVIEW invariants need to *read the app*. If
  there's no local checkout, fit chains from the `/context` inventory alone and say plainly which
  CODE-REVIEW items you couldn't inspect.

---

## The procedure — walk `reference/invariants.md` category by category

Open `reference/invariants.md` and work it top to bottom (A Auth → B Authz → C Session → D Data
exposure → E Injection → F Surface → G Cost/abuse). For **each** invariant, branch on its **kind**:

### If the invariant is ENGINE (B6, D2, F1–F3)
Confirm it via `/context` and move on — do NOT author anything.
- Find the owning stack's row in `tests[]` (`supabase`, `secrets`, `surface`) or the `recommendations[]`
  entry. `verdict: "fixed"` → engine-covered and clean. `verdict: "vulnerable"` → the scan already found
  it; fold it into the report, don't re-prove it.
- Record each as **engine-covered** in the report.

> **B7 (anon write/delete) is no longer an engine-toggle item.** Don't toggle the engine `write_delete`
> stack unattended — it fires REAL INSERT/UPDATE/DELETE probes immediately. Treat B7 as a mutation CHAIN
> below: **author a parked mutation chain and surface it** to the user, whose explicit confirmation runs
> it (it fires nothing until then). That captured, unfired test is the value — don't skip it.

### If the invariant is CHAIN (A1–A3, B1–B5, B7, C1–C2, D1, D3, G1–G2)
This is the core of the audit. For each:
1. **FIT it to THIS app.** Read the invariant's **"Fit to THIS app"** line, then READ the app — its
   code (if a local checkout exists) and the `/context` `inventory` (discovered routes, tables, owner
   columns, secrets). Decide the concrete target: which route/table/identity, and what marker proves the
   leak. This is the step a scanner cannot do.
   - **When inventory is empty (URL-only target).** This fit step assumes `/context` inventory OR a local
     checkout. On a **URL-only** target both can come back empty — e.g. `/context` reports
     `endpoints.count: 1`, `anonReachable: []` while the app really has `/api/admin/verify` and more. Don't
     conclude "nothing to fit"; do the realistic recon instead: **fetch the deployed site and its JS
     bundles and grep them** for (a) the Supabase URL / project ref (`*.supabase.co`), (b) the public anon
     key (`eyJ…` or `sb_publishable_…`), (c) table names (`/rest/v1/<table>`), and (d) app route paths
     (`/api/…`). That recovered surface is what you fit the chains to. This is the realistic path whenever
     neither source nor `/context` inventory is available.
2. **Run the discipline.** Apply `reference/methodology.md` before you commit to a chain: is it reachable
   from a fresh anonymous state, is the id enumerable, what's the honest severity, is it intended-public?
   Drop or downgrade candidates that fail a gate — a disciplined "not exploitable, here's why" is expert
   work, not a miss.
3. **Author the tailored chain.** Use the templates in `CHAINS.md` (anonymous read, cross-tenant read,
   the witnessed-GREEN gate-guard recipe) or the relevant `byo_template`. Cross-tenant and authenticated
   tests use `spec.env.anonKey` or a captured-session script — `reference/chains-reference.md` §5, §9,
   §12.
4. **Run it for a witnessed verdict.** `POST /api/v1/chains/:id/run`. `vulnerable` = the boundary broke
   (show the marker that proved it). `fixed` = the app positively denies it (401/403/429 or proven-empty)
   — a witnessed GREEN, the win. `inconclusive` = the matcher didn't describe the response; fix it and
   re-run, don't report it either way. A mutation chain's `409 needsConfirmation` is healthy parked
   coverage, not a failure.
   - **For a DESTRUCTIVE chain (mutation — B2, B7, G1 on prod): author + submit + SURFACE, do NOT fire.**
     A non-GET parks behind `409 needsConfirmation` and fires nothing, so storing it is zero-risk. Don't
     skip it for being destructive and don't auto-fire it on a live app — hand it to the user with a plain
     line of what it proves (e.g. *"I've prepared a test that proves whether a stranger can write/delete
     your X; it makes a real change, so it won't run until you confirm — run it whenever you're ready"*)
     and let their explicit `{"confirmMutation": true}` run it. That captured, unfired test is the value;
     report it as **authored — awaiting your run**, not skipped. (Fire it yourself only against a sandbox
     you own, with a benign payload.)
   - **⚠️ Credential ceiling — the engine now returns `inconclusive` (not a false `fixed`) when the
     second identity can't be provisioned.** The second-identity mint (`crossTenant` / `spec.env.anonKey` /
     captured-session) is `requiresPro` and also fails on non-Supabase-Auth or `sb_publishable_` keys. When
     it can't be minted, the cross-tenant/authed boundary was never exercised — and the backend now reports
     that honestly as **`inconclusive`** (`credentialProvenance: "none"`, or a body like `"No API key
     found"`), **no longer a misleading `fixed`**, so you won't be fooled into reporting a pass. **Don't
     drop the invariant — AUTHOR the test anyway and SURFACE it as "authored — awaiting your run"**, so the
     user can run it with the credential it needs (a captured session) or on Pro. (Still sanity-check
     `credentialProvenance` on any cross-tenant `fixed` — a real provisioned identity is what makes a
     `fixed` trustworthy.) See `reference/methodology.md` Step 7 (#6), `reference/invariants.md` B1, and
     `CHAINS.md` Step 3b.
   - **Host-redirect footgun on the app's own routes.** A monitored `targetHost` can redirect (apex→`www`,
     `http`→`https`). `allowedTargets.primary` must byte-match the FINAL host, so a chain aimed at the apex
     can 307→`www` and read a false `inconclusive`. Target the canonical / resolved host (e.g. `www.…`).
     See `reference/invariants.md` A2.
5. **Default to Proof.** Author these `watched: false` while auditing so you don't flood the user's
   deploy-replay suite. Promote the handful worth watching forever to Guards (`watched: true`) at the end.

### If the invariant is CODE-REVIEW (A4, E1, E2, F3-as-code, G3)
Inspect the code and report a finding — **never** author a chain that fakes a verdict for it (rate-limit,
injection, and DOM-execution oracles don't exist in the matcher). Cite the file + line. If there's no
local source, say you couldn't inspect it rather than guessing.

> **Don't re-prove the floor; fit the per-app boundaries.** The engine already swept every table as anon,
> scanned every bundle for secrets, and checked the headers. Your value is entirely in the CHAIN fits and
> the CODE-REVIEW reads — the parts that needed someone to read THIS app.

---

## Output — the per-invariant audit report

Produce one comprehensive report covering **every** invariant, each with its disposition:

- **engine-covered** — proven by a default stack (cite the `/context` verdict).
- **clean** — you fitted and ran a chain; it came back `fixed` (witnessed GREEN). Name the route/table.
- **vulnerable** — a chain reproduced the exploit. Show the marker, the honest severity, and the fix
  (lean on the chain's `interpretation.fixHint`; close the loop per `CHAINS.md` Step 5).
- **code-review finding** — a CODE-REVIEW invariant you flagged from the source, cited file + line.
- **authored — awaiting your run** — a DESTRUCTIVE or CREDENTIAL-GATED invariant (a cross-tenant or anon
  write/delete B2/B7, a paid/outbound call G1 on prod, or a cross-tenant/authed read whose identity
  couldn't be provisioned): you **authored and submitted the test and surfaced it to the user**, but did
  NOT fire it. A mutation parks safely (`409 needsConfirmation`, fires nothing) until the user confirms;
  a credential-gated read reads `inconclusive` until run with the needed credential/Pro. This is a real,
  honest disposition — the captured test the user owns and decides to run — **NOT a "skipped" item.**
  Name what it proves and tell the user that they (or their explicit confirmation) run it whenever ready.
- **not-applicable** — the invariant has no surface in this app (e.g. no path-taking param for B4, no
  paid route for G1). Say why.

Group it by category (A–G) so it reads as a complete pass, and list the authored chains as the proof
artifacts (with their verdicts). Then promote the chains worth watching to Guards.

> **Be honest about what a clean audit means.** If every fitted chain came back `fixed` and every
> CODE-REVIEW item is clean, say: *the fundamental security floor holds — cross-tenant isolation, auth
> gates, cost boundaries, and token handling are all proven against your real routes.* But it is the
> floor, not "fully secure": business-logic correctness (whether a given role *should* see a given
> record) is per-app intent that still needs you, the owner. Don't oversell a green sweep. A
> credential-gated test the engine couldn't provision now surfaces honestly as `inconclusive` (not a
> false `fixed`, `reference/methodology.md` Step 7) — so don't count it as "safe"; report it as
> **authored — awaiting your run** and hand it to the user with the credential/Pro it needs. (Still
> sanity-check `credentialProvenance` on any cross-tenant `fixed`.)

---

## Cross-links

- **`reference/invariants.md`** — the catalog this flow walks: the ~22 invariants, each with its kind,
  matcher shape, and "Fit to THIS app" guidance.
- **`CHAINS.md`** — how to author + run the chains (templates, the gate-guard recipe, the verdict
  semantics, the cleanup rules).
- **`CONNECT.md`** — Step 0 auth (device login) + connect, and the `/context` bridge loop you read first.
- **`reference/methodology.md`** — the finding discipline applied to every candidate (intended-public
  filter, honest severity, no false positives).
