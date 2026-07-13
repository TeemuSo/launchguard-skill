# App profile (fill this in for your repo)

The portable discipline lives in the LaunchGuard skill. This file holds what is true only for THIS
app: its environment wiring, its hard-won quirks, and its canonical journeys. An agent reads it
before authoring a test so it does not rediscover the same facts twice.

**Write-back rule:** any discovery that cost more than ~15 minutes becomes one line here, in the same
PR that learned it. When a fix removes a quirk, delete its line. Keep it short; if it grows past
about 20 quirk lines, build a helper instead of documenting the workaround.

## Environment (the concrete values for this repo)

- **Test target:** the per-PR deployment URL (resolved from the deploy event), plus the protection-bypass header. Never a branch alias.
- **Non-prod backend on preview:** which database project and which test-mode payment keys the preview points at, set as preview-scoped env.
- **The non-prod flag:** the env var (and value) that turns on this app's test affordances on a hosted deploy, and everywhere else that flag is read (e.g. a webhook that credits only events tagged with a given environment).
- **Test identity:** how a test provisions a user through the app (a magic OTP, a test password), the identity pool, and how identities are allocated per PR to avoid collisions on a shared backend.
- **Webhooks:** which flows depend on an async webhook, and whether it resolves against the shared backend (no per-PR setup) or is itself under test (forward events to the preview).

## Quirks (the >=15-minute discoveries, one line each)

- (example) Auth cookies are host-only (no domain set), so they work on any preview host with no change.
- (example) A key UI label is localized; match it in every supported language, not just English.

## Journeys (canonical specs are the topology)

List the black-box specs that map a flow, with their entry URL and the one thing each proves. The
numbered step comments in each spec are the real documentation; read the spec before re-deriving a flow.

- (example) `checkout.spec.ts` : lands anonymous, provisions a user through the app, completes the paid journey; proves the purchased state is reached and charged exactly once.

---

If your repo already has a test playbook, this file can point at it as the profile rather than
duplicating it. One place per fact.
