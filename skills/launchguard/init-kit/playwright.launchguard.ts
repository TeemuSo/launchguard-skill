/**
 * playwright.launchguard.ts — the WATCHED project.
 *
 * Runs the `@watched` black-box subset against a DEPLOYED target (a per-PR
 * preview), never a local dev server. There is no `webServer` here: the target
 * is a URL. Kept separate from the repo's main playwright.config.ts so the full
 * seeded suite is untouched.
 *
 * Defaults are deliberately conservative for the cost-sensitive case (a journey
 * that makes a real test payment): ONE browser, ZERO retries, so nothing pays
 * twice. The agent widens this ONLY after confirming the watched specs are free
 * to repeat (see INIT.md Step 1: reconcile against the repo's existing CI). Add
 * an `iphone` project only for a mobile-specific spec that does not spend money.
 */
import { defineConfig, devices } from '@playwright/test';

const TARGET_URL = process.env.TARGET_URL || process.env.BASE_URL;
if (!TARGET_URL) {
  throw new Error(
    'TARGET_URL is required for the watched project. In CI it is the per-PR ' +
      'deployment URL (github.event.deployment_status.target_url).'
  );
}

// Only needed when Vercel deployment protection is ON. If protection is off,
// this is unset and no header is sent. Sent on every request so navigations,
// sub-resources, and iframes all clear the protection wall.
const bypass = process.env.VERCEL_AUTOMATION_BYPASS_SECRET;

export default defineConfig({
  testDir: './tests',
  grep: /@watched/,
  fullyParallel: true,
  // 1 worker by default: a shared non-prod backend + a fixed test identity means
  // parallel specs can collide. Raise it only when specs use distinct identities.
  workers: 1,
  // No retries: a retry re-runs the flow (a real-payment journey pays again), and
  // a green that only appears on retry is a flake, not a pass.
  retries: 0,
  reporter: [['html'], ['json', { outputFile: 'test-results/results.json' }]],
  use: {
    baseURL: TARGET_URL,
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    screenshot: 'only-on-failure',
    ...(bypass ? { extraHTTPHeaders: { 'x-vercel-protection-bypass': bypass } } : {}),
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
});
