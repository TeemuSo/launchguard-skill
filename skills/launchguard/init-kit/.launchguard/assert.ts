/**
 * assert.ts — the verdict helpers. A pass is a POSITIVE signal, never silence.
 *
 * This is what separates a LaunchGuard test from raw Playwright: `expect(status).toBe(403)`
 * cannot tell "denied" from "silently returned an empty 200", and that gap is how an
 * agent writes a false green. These helpers bake the distinction in.
 *
 * Semantics: a denial must be a real 401/403 or an RLS/policy error envelope.
 * A 200, an empty body, or a 404 is INCONCLUSIVE, never a pass.
 */
import type { APIResponse } from '@playwright/test';

/** A denial the caller EXPECTED must be a positive refusal. Throws otherwise. */
export async function expectDenied(res: APIResponse, ctx = 'request'): Promise<void> {
  const status = res.status();
  if (status === 401 || status === 403) return; // positive denial

  const body = await res.text().catch(() => '');
  if (status >= 400 && /permission denied|violates row-level security|not authorized|forbidden|rls/i.test(body)) {
    return; // RLS / policy error envelope is a positive denial
  }
  if (status === 200) {
    throw new Error(`FALSE-GREEN GUARD [${ctx}]: got 200. That is access, not denial. A pass requires a real 401/403/RLS refusal.`);
  }
  if (status === 404) {
    throw new Error(`INCONCLUSIVE [${ctx}]: got 404. Absence is not a proven denial; the route may just be missing.`);
  }
  throw new Error(`INCONCLUSIVE [${ctx}]: got ${status}. Not a positive denial.`);
}

/**
 * No row owned by a foreign tenant may appear in `rows`.
 *
 * IMPORTANT: zero foreign rows only proves isolation if the foreign tenant
 * actually HAS rows to leak. The spec must establish that precondition (provision
 * tenant B with data through the app) before trusting a green here; this helper
 * asserts the relation, not the precondition.
 */
export function expectNoForeignRows(
  rows: unknown[],
  opts: { ownerKey: string; foreignId: string | number; myId?: string | number }
): void {
  const foreign = rows.filter(
    (r) => r != null && String((r as Record<string, unknown>)[opts.ownerKey]) === String(opts.foreignId)
  );
  if (foreign.length > 0) {
    throw new Error(
      `CROSS-TENANT LEAK: ${foreign.length} row(s) owned by ${opts.foreignId}` +
        `${opts.myId != null ? ` returned to ${opts.myId}` : ''}. Identity isolation is broken.`
    );
  }
}

/** A cost/side-effect endpoint hit by an unauthenticated caller must NOT do the work. */
export async function expectNoUnauthWork(
  res: APIResponse,
  opts: { workMarker: RegExp; ctx?: string }
): Promise<void> {
  const ctx = opts.ctx ?? 'unauth cost endpoint';
  const status = res.status();
  if (status === 401 || status === 403 || status === 429) return; // gated or rate-limited: good
  const body = await res.text().catch(() => '');
  if (opts.workMarker.test(body)) {
    throw new Error(`UNAUTH WORK: [${ctx}] returned a work marker (${opts.workMarker}) to an anonymous caller. The endpoint ran paid/outbound work without auth.`);
  }
  // No marker and not a gate: inconclusive, not a pass.
  if (status === 200) {
    throw new Error(`INCONCLUSIVE [${ctx}]: 200 with no work marker matched. Confirm the marker before trusting this.`);
  }
}
