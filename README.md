# LaunchGuard — Security Scanner for AI Coding Agents

**Every security skill scans your code. This one scans your app.**

You ship with Cursor, Claude Code, Lovable. You move fast. But your Supabase tables might be wide open, your AI endpoints might be draining your wallet, and your API keys might be sitting in your JavaScript bundles.

LaunchGuard scans your **live, deployed application** from the outside — the same way an attacker would. No code access needed. No credentials. Just a URL.

## What it finds

- **Exposed Supabase tables** — readable or writable without auth, broken RLS policies
- **Leaked secrets** — API keys, service role keys, database credentials in your JS bundles
- **Cost-sinkhole endpoints** — unprotected AI/LLM, email, compute endpoints an attacker can abuse
- **Public storage buckets** — files accessible to anyone
- **Firebase misconfigurations** — open Firestore, unprotected Cloud Functions
- **Callable RPCs and edge functions** — server functions reachable without authentication

## Install

**Claude Code** (paste into your terminal):
```bash
claude plugin marketplace add TeemuSo/launchguard-skill && claude plugin install launchguard@launchguard-skill
```

Then open a new Claude Code session and say "scan my app".

**Other agents (Cursor, Codex, Gemini CLI, Copilot, Windsurf, Cline):**
```
npx skills add TeemuSo/launchguard-skill
```

Note: `npx skills` installs to `.agents/skills/`, which Claude Code does not read. For Claude Code, use the command above.

## Usage

Just talk to your AI agent:

> "Scan my app at myapp.vercel.app"

> "Is my Supabase secure?"

> "Check if my API endpoints are protected before I launch"

> "Audit the security of our production app"

The agent runs a full external security scan (~60-120 seconds), presents findings grouped by severity, and offers to fix issues directly in your code.

## How it works

```
You: "Scan myapp.vercel.app"
  │
  ▼
Agent calls LaunchGuard API (no API key needed)
  │
  ├── Crawls your app (Katana, headless browser)
  ├── Parses JS bundles for API routes and credentials
  ├── Enumerates subdomains
  ├── Fuzzes for hidden endpoints
  ├── Probes Supabase tables, RPCs, edge functions, storage
  ├── Probes Firebase collections, functions, storage
  ├── Detects leaked secrets (TruffleHog)
  │
  ▼
Agent presents findings:
  "Found 4 issues: your 'profiles' table is readable by anyone
   (4,200 rows exposed), your /api/chat endpoint has no auth
   ($0.12/request), and your Supabase service role key is in
   your JS bundle."
  │
  ▼
Agent fixes your code:
  - Writes RLS migration for 'profiles' table
  - Adds auth middleware to /api/chat
  - Moves service role key to server-side env
  │
  ▼
You: "Set up monitoring"
  → Agent enables Ongoing Guard (auto re-scan on every deploy)
```

## Connect and the bridge loop

When you connect your project to LaunchGuard (`"connect this to LaunchGuard"`, `"watch this app on every deploy"`), the agent does not re-recon your app. It starts expert: LaunchGuard already scanned it, and one call hands the agent the whole picture. The loop:

1. **Connect**: a benign handshake links your Claude Code to your app. The response includes a coverage summary and the exact context call to make next.
2. **Read context**: `GET /api/v1/context` returns the engine's inventory (tables tested, anon-reachable endpoints), every test's verdict (built-in engine checks AND your own custom tests), the open coverage gaps, and a list of recommended actions. The agent starts from this instead of re-scanning.
3. **Act on recommendations**: each recommendation tells the agent exactly what to do. `skip` what the engine already covers (no duplicate tests), `toggle_on` a default check that is off, `author_from_template` a ready test for a gap, or `author_gap` a freehand business-logic test the engine cannot write (a paywall, a cross-tenant boundary, a cost-sink).
4. **Run**: the authored test returns a clear verdict (vulnerable / fixed / inconclusive).
5. **Watch**: guarded tests re-run on every deploy and alert on regression.

New endpoints behind the loop:
- `GET /api/v1/context`: the engine's coverage, inventory, gaps, and recommended actions in one call.
- `GET /api/v1/stacks`: the catalog of default checks LaunchGuard runs, with per-app state and verdicts.
- `POST /api/v1/coverage`: toggle a default check (e.g. Firebase, write/delete probing) on or off for an app.

The point: the agent never re-derives what the scanner already knows. The anti-duplication discipline arrives as data, so you get tailored coverage for the gaps and nothing redundant.

## Zero config

- No API key required for scanning
- No CLI to install — the agent calls the API directly with curl
- No account needed for your first scan
- Free. 50 scans/hour.

## What makes this different

| | LaunchGuard | Trail of Bits / Snyk | Manual pentest |
|---|---|---|---|
| **Scans** | Live app (DAST) | Source code (SAST) | Live app |
| **Setup** | One sentence | Config files, CI integration | Weeks of scheduling |
| **Time** | 60-120 seconds | Varies | Days to weeks |
| **Fixes** | Agent writes code for you | Reports only | Reports only |
| **Cost** | Free | Free tier / paid | $5k-50k |
| **Supabase-aware** | Yes (tables, RLS, RPCs, edge functions, storage) | No | Rarely |

**Use both.** Trail of Bits and Snyk catch bugs in your code. LaunchGuard catches what's actually exposed in production. They're complementary.

## Ongoing Guard

After fixing issues, the agent can set up continuous monitoring:

- Detects deploys automatically (checks every 15 minutes)
- Runs a full re-scan when your app changes
- Emails you only when new issues appear
- Free for all users

## Pro features

For teams that need deeper testing: [$29/mo on launchguard.dev](https://launchguard.dev)

- AI analysis with fix prompts for every finding
- Authenticated testing (IDOR detection)
- Attack chain analysis across endpoints
- Full evidence (response bodies, data samples)
- Live probe verification

## Links

- [LaunchGuard](https://launchguard.dev) — Run a scan in your browser
- [Documentation](https://launchguard.dev/docs)
- [GitHub](https://github.com/TeemuSo/launchguard-skill)

---

Built for developers who ship fast and want to stay safe.
