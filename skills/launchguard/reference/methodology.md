# Pentester methodology — the discipline that turns a scan into real findings

Read this BEFORE you author any custom test, and before you call anything a "finding" when a
user says "check my app", "is this secure", or "find my vulnerabilities". The free scan and the
chain *format* are mechanics. This file is the *judgment* layer — the reasoning a professional
pentester applies so a non-expert gets expert-quality results without steering you by hand.

The core failure this prevents: an agent that jumps straight from "the endpoint returned 200" to
"VULNERABLE: CRITICAL". That produces false positives (flagging intended-public data) and
non-weaponizable findings (an "IDOR" the attacker can't actually reach). One false "you're hacked"
alarm and the user mutes LaunchGuard forever. **Your bias is toward producing a finding; this
procedure exists to discipline that bias.**

Run the procedure below, in order, for EVERY candidate. Write the answers down (in `expectations.md`
or your working notes). If a candidate fails a gate, you downgrade it or drop it — you do not author
a scary chain to look productive. A disciplined "this is not exploitable, here's why" is expert work,
not a failure.

---

## The procedure (ordered — run every step, every candidate)

### Step 0 — Threat-model from the app's intent (do this ONCE, before any probing)

Before you touch a single endpoint, write down what THIS app exists to protect, and from whom. You
read the code; a generic scanner did not. Use that.

State, in plain language:
- **What is the asset?** What data, money, or privilege would actually hurt this user to lose? (paid
  compute / another tenant's rows / PII / admin actions / a Pro-only capability / secrets)
- **Who are the attackers?** Enumerate the identities that exist in this app: `anonymous`,
  `free authenticated user`, `tenant A vs tenant B`, `admin`. Each is a different trust boundary.
- **What must hold from the outside?** Turn the asset + attackers into rules, e.g. "a non-paying
  request cannot run the Pro AI analysis", "user A cannot read user B's scans", "an anonymous caller
  cannot trigger the email send".

Your test targets come FROM this model, not from a generic OWASP checklist you ran top-to-bottom.
The checklist (API1–API10) is a coverage *backstop* — the threat model is the *driver*.

> Do: "This app charges per scan and gates AI analysis behind Pro. So the assets are (1) paid scan
> compute and (2) the Pro AI verdict. Attackers: anonymous (can they run a paid scan free?) and
> free-authed (can they reach the Pro verdict?). Those two rules are my first two tests."
>
> Don't: open with "let me test every table for anonymous read" before you know which tables hold
> something worth protecting.

### Step 1 — Reachability from a FRESH anonymous state

A finding only counts if a brand-new attacker, starting from ZERO, can reproduce it. Before you
believe any candidate, ask:

- Can a client that just arrived — **with no account, no session, and no artifact it created
  itself** — reach this?
- **If your PoC reads an object, did the test itself create that object?** If so, it is NOT a
  finding. Reading your own resource is not a vulnerability.

> The canonical false positive (the "don't read your own scan" lesson): the agent ran a scan, got
> back a `scanId`, then fetched `/api/scan/status/<that same scanId>` and called it an IDOR. But the
> attacker created that scan — reading it back is the product working, not a leak. To be a real IDOR
> the attacker must read a scan **they did not create**, which requires a FOREIGN id they shouldn't
> have. See Step 2.

Decision rule: **if the only id/token the PoC uses is one the attacker created or owns → it is not
IDOR. Downgrade or drop it.**

### Step 2 — Enumerability / id-confidentiality (the UUID gate)

An access-control bug is only as exploitable as the attacker's ability to KNOW the id. A perfectly
guessable id and an unguessable one are completely different severities even if the endpoint behaves
identically.

For every candidate that is "protected only by knowing an id", answer:
- **What must the attacker already know to exploit this?** (a user id, a scan id, a token)
- **Where would they get it?** Is there an UNAUTHENTICATED surface that leaks or enumerates a
  *foreign* one — a public listing, a sitemap, a realtime channel, a sequential counter, a
  predictable pattern, an error message that echoes ids?
- **What is the id's entropy?** `sequential` / `short` / `uuid-v4 (~122 bits)` / `opaque token`.

Decision rule: **a `gen_random_uuid()` v4 id is a STRONG protector. An "IDOR" on an unguessable UUID
with NO unauth id-leak surface caps at MEDIUM — regardless of how sensitive the data behind it is.**
It is only HIGH/CRITICAL if you can actually obtain a foreign id from an unauthenticated surface.

> The "UUID is a strong protector — find the id-leak" lesson: don't stop at "the endpoint doesn't
> check ownership". Go hunt for the id-leak that would make it weaponizable. If you find one, you have
> a real high-severity chain. If you look and there is none, that disciplined negative — "medium,
> gated by an unguessable id, no leak surface found" — IS the correct expert finding.

### Step 3 — Escalation chaining (don't stop at the first weak signal)

A single weak signal is rarely the finding. Chain it. For every candidate ask: **"if this is true,
what does it unlock, and can I reach the next link?"**

- leak an id → use it to read the object
- read one object → does it contain a credential / another id / a tenant key that reads more?
- get a foothold (a low-priv session) → can you reach a privileged function from it?
- find a missing gate → does combining it with a second missing gate produce real impact?

Actually TRY the next step. Then write down the result — including the negative. "The id leaks, but
there is no endpoint that accepts a foreign id, so the chain dead-ends at medium" is a complete,
honest finding. (See SKILL.md and `chains-reference.md` §3 on `precondition` extractor steps — that
is the mechanism for wiring a leaked/seeded value into the next request.)

### Step 4 — Stateful preconditions (self-provision the state the test needs)

Some tests only mean something once the world is in a particular state — a balance must be positive
before a send can be attempted, an item must exist before it can be read. Do not skip these and do
not hand-wave them. **Provision the precondition yourself, as explicit steps, every run**, so the test
is self-contained and reproducible from scratch.

> The "topup → send-message" lesson: to prove "a user can send beyond their paid quota" you first
> `precondition` a top-up (or seed a balance), THEN fire the send as the exploit step. A multi-step
> chain with `precondition` steps that set up state (and `extract` the ids the exploit needs) is
> exactly this. See `chains-reference.md` §3 (extractors / multi-step) for the wiring.

Decision rule: **if a candidate needs prior state, encode the setup as `precondition` steps in the
same chain. If you can't set the state up from a fresh start, the test isn't reproducible — say so,
don't fake it.**

### Step 5 — Score every candidate honestly (CVSS / blast-radius triage)

Score EVERY surviving candidate before you decide it's a finding. **A `vulnerable` verdict is not
automatically a finding** — severity comes from real blast radius, not from a 200 status code.

| Severity | Maps to |
|---|---|
| **critical** | service-role/admin reachable, another tenant's data writable, paid work runnable unauth |
| **high** | sensitive data / PII readable, unauth expensive compute with no durable limit |
| **medium** | a callable RPC, minor disclosure, an IDOR gated by an unguessable id (no leak surface) |
| **low** | informational, aggregate public data, best-practice nits |

Aggregate counters ≠ PII ≠ another tenant's rows ≠ secrets ≠ paid compute. If two candidates both
"answered unauthenticated", the one returning a marketing counter and the one returning another
tenant's email are not the same finding. Score them apart.

### Step 6 — False-positive / intended-public filter (the last gate before you call it a finding)

This is the single hardest call and the one most agents get wrong. **A `vulnerable` verdict only
means "an outsider reached this and your marker matched" — it does NOT mean the data is sensitive or
that this is a bug.** Many things answer unauthenticated BY DESIGN.

NOT findings, even though they respond to an anonymous request:
- **Public counters / marketing widgets** — `/api/stats`, "10,000 scans run" (the `/api/stats`
  lesson). Aggregate, non-identifying, meant to be on the homepage.
- **The product's own free tier** — if the app's whole pitch is "free unauthenticated scan", then an
  anonymous request running that scan is the PRODUCT, not a cost-sinkhole bug (the "free unauth scan
  is the product, not a bug" lesson). Distinguish "an attacker abuses expensive work" from "the
  founder intentionally offers this for free".
- **Public pricing, published blog/RSS feeds, public sitemaps, OG metadata** — intended-public.

Decision rules:
- **If the asset is public-by-design AND no trust boundary is crossed → NOT A FINDING. Stop.** Do not
  author a scary chain for it. (This is what kills the `/api/stats` false positive.)
- The intent question — "is this data MEANT to be public?" — needs the product's intent, which you
  partly know from reading the code but cannot always settle. **When it is genuinely ambiguous, do not
  auto-assert a scary severity. Label it "needs product triage" and ask the user ONE question** ("Is
  `/api/stats` meant to be public, or is that an internal leak?"). One question per ambiguous finding
  is honest and still 10x faster than a manual pentest.
- Gut check: **would a senior pentester laugh at this finding?** If you're unsure, it's triage, not a
  CRITICAL.

### Step 7 — Validation gate (re-prove it before you report or submit)

Lifted and adapted from **transilienceai/communitytools** (`skills/coordination/reference/VALIDATION.md`
and `skills/regression-sweep/`, MIT-licensed — attribution below). Before you report a candidate as a
finding or ingest it as a `vulnerable` chain, it must pass ALL of these:

1. **Re-run the PoC fresh.** Run it again from a clean state. A finding that doesn't reproduce on a
   second independent run is not a finding (it was a fluke, a stale cache, or your own leftover state).
2. **Corroborate every claim against raw tool output.** Every sentence in your finding must trace to
   an actual status code / body / marker you observed — not to what you assumed the endpoint does.
   Quote the real field. No claim without evidence.
3. **Prefer a blind re-verification.** Re-verify from the evidence alone (the raw request + response),
   NOT from your own attack narrative. Ask: "if I only had this response and not my story about it,
   would I still conclude it's exploitable?" This is the communitytools "blind validator" idea — it
   strips out the confirmation bias of wanting the finding to be real.
4. **Never submit a passing test as an exploit.** A run that came back `fixed` (the app denied it) is
   the app WORKING. Do not relabel it, do not pad the suite with it as a "finding". A clean sweep of
   `fixed` is the WIN.
5. **CVSS / severity consistency.** The severity you assign must match the blast radius from Step 5.
   A "critical" whose worst case is reading a public counter is inconsistent — fix the severity.
6. **Watch the credential ceiling — never report a false `fixed` as "safe".** If a candidate can only
   be reached by an authenticated-but-limited identity the engine can't mint (a Pro-only route, an
   under-privileged user, a cross-tenant read on a non-Supabase-Auth app), a black-box run hits `401`
   and reads `fixed` — which MASKS the bug. Do not present that `fixed` as "safe". Mark it "cannot
   auto-prove black-box — code-review finding only" (see `chains-reference.md` §8, the credential
   ceiling). A false "you're safe" is worse than no test.
7. **Code is not the live app.** "I read the owner-check in the source" is a hypothesis, not a finding — the deployed target may differ from your checkout. The run's verdict against the live target, not the code, is what you report.

If a candidate fails any check, fix it or drop it. Only a candidate that passes all seven becomes a
reported finding or a `vulnerable` chain.

---

## Quick pre-authoring checklist (copy into your notes, fill per candidate)

```
THREAT MODEL
  [ ] Asset behind it: public-by-design | PII | secret | another tenant's row | paid compute | admin
  [ ] Attacker identity: anon | free-authed | tenant-A | admin-impersonator
  [ ] Trust boundary crossed: none | auth | tenant | plan/paywall | privilege
  -> public-by-design AND boundary=none  => NOT A FINDING. Stop. (kills the /api/stats FP)

REACHABILITY (fresh anonymous state)
  [ ] Reachable with NO artifact the attacker created itself?
  -> only id available is one the attacker created/owns => NOT IDOR. Downgrade/drop. (don't read your own scan)

ENUMERABILITY
  [ ] To exploit, what must the attacker already know? Can they get it from an UNAUTH surface?
  [ ] Protecting id entropy: sequential | short | uuid-v4 | opaque-token
  -> uuid-v4 + no unauth id-leak surface => cap severity at MEDIUM, whatever it returns.

ESCALATION
  [ ] What does this unlock if chained? Did I try the next link and write down the negative?

PRECONDITIONS
  [ ] Needs prior state? -> self-provision it as precondition steps, every run (topup->send).

SEVERITY (from blast radius, not status code) — score it. vulnerable != automatically a finding.

FALSE-POSITIVE FILTER (last gate)
  [ ] Intended-public? Free-tier-by-design? Would a senior pentester laugh?
  -> unsure => "needs product triage", ask ONE question. Do NOT auto-assert a scary severity.

VALIDATION GATE (before reporting/ingesting)
  [ ] Re-ran fresh, reproduces  [ ] Every claim traces to raw output  [ ] Blind re-verify holds
  [ ] Not relabeling a `fixed` pass  [ ] Severity consistent  [ ] No false-`fixed`-as-safe
  [ ] Verdict is the live run's, not the code's
```

---

## What still needs a human (don't fake these)

This procedure encodes ~70% of pentester judgment. Three things it can't fully settle — surface them,
don't auto-assert:

- **Business-logic intent.** "Is this data MEANT to be public?" ultimately needs the product owner.
  Best you can do is read the code, make a call, and on ambiguity ask one question.
- **Novel attack-chain invention.** Executing a chain you reasoned out is encodable; the creative leap
  to a non-obvious multi-step exploit is still partly human.
- **Confident negatives.** Knowing that "no escalation exists, it stays medium" is the real result —
  and resisting the urge to pad the suite to look productive — is the discipline this whole file is
  trying to instill.

When you hit one of these, say so plainly and ask the user. "Your AI drafts; you confirm one question
per finding" is honest and still far faster than a manual pentest.

---

## Attribution

The validation gate (Step 7) and the blind re-verification idea are adapted from
**transilienceai/communitytools** (https://github.com/transilienceai/communitytools), specifically
`skills/coordination/reference/VALIDATION.md` (the 6-check anti-hallucination gate + blind validator)
and `skills/regression-sweep/` (re-run-fresh / normalized-diff / drift classification). That project
is **MIT-licensed** (commercial use permitted with attribution); these patterns are adapted, not
copied verbatim, and reframed for LaunchGuard's "demonstrate, never disrupt" posture (self-serve
founders scanning their OWN apps, read-only by default) rather than offensive bug-bounty engagements.
