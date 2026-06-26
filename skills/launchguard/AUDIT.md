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

### If the invariant is ENGINE (B6, B7, D2, F1–F3)
Confirm it via `/context` and move on — do NOT author anything.
- Find the owning stack's row in `tests[]` (`supabase`, `secrets`, `surface`) or the `recommendations[]`
  entry. `verdict: "fixed"` → engine-covered and clean. `verdict: "vulnerable"` → the scan already found
  it; fold it into the report, don't re-prove it.
- For `write_delete` (B7), if it's `off`, offer to toggle it on (`POST /api/v1/coverage`) — and say
  plainly that enabling it fires REAL INSERT/UPDATE/DELETE probes.
- Record each as **engine-covered** in the report.

### If the invariant is CHAIN (A1–A3, B1–B5, C1–C2, D1, D3, G1–G2)
This is the core of the audit. For each:
1. **FIT it to THIS app.** Read the invariant's **"Fit to THIS app"** line, then READ the app — its
   code (if a local checkout exists) and the `/context` `inventory` (discovered routes, tables, owner
   columns, secrets). Decide the concrete target: which route/table/identity, and what marker proves the
   leak. This is the step a scanner cannot do.
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
- **not-applicable** — the invariant has no surface in this app (e.g. no path-taking param for B4, no
  paid route for G1). Say why.

Group it by category (A–G) so it reads as a complete pass, and list the authored chains as the proof
artifacts (with their verdicts). Then promote the chains worth watching to Guards.

> **Be honest about what a clean audit means.** If every fitted chain came back `fixed` and every
> CODE-REVIEW item is clean, say: *the fundamental security floor holds — cross-tenant isolation, auth
> gates, cost boundaries, and token handling are all proven against your real routes.* But it is the
> floor, not "fully secure": business-logic correctness (whether a given role *should* see a given
> record) is per-app intent that still needs you, the owner. Don't oversell a green sweep, and never
> present a black-box `fixed` that was really a credential ceiling (`reference/methodology.md` Step 7)
> as "safe".

---

## Cross-links

- **`reference/invariants.md`** — the catalog this flow walks: the ~22 invariants, each with its kind,
  matcher shape, and "Fit to THIS app" guidance.
- **`CHAINS.md`** — how to author + run the chains (templates, the gate-guard recipe, the verdict
  semantics, the cleanup rules).
- **`CONNECT.md`** — Step 0 auth (device login) + connect, and the `/context` bridge loop you read first.
- **`reference/methodology.md`** — the finding discipline applied to every candidate (intended-public
  filter, honest severity, no false positives).
