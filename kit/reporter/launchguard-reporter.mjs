// LaunchGuard reporter. Plain ESM, zero dependencies, no build step, no npm.
//
// kit/install.sh copies this file next to your playwright.config. Then add it
// to the config's reporter list:
//
//   reporter: [
//     ['list'],
//     ['./launchguard-reporter.mjs', { app: 'yourdomain.com' }],
//   ],
//
// It rides the CI run you already pay for: no new job, no extra browser launch.
// It never throws and never rejects. Any problem (missing key, unreachable
// endpoint, network error) is one console line and a clean no-op; your build
// result is never touched.
//
// WHAT IT SENDS: test identity (file, title, project), verdict, duration, and a
// sanitized failure message. NEVER your test source. Playwright keeps the source
// snippet in TestError.snippet, a separate field this file deliberately never
// reads.
//
// HOW IT DECIDES app-broke vs test-could-not-run: Playwright's own public
// Reporter API, nothing else. TestCase.expectedStatus, TestResult.status, and
// TestStep.category ('expect' | 'pw:api' | 'hook' | 'fixture' | 'test.step' |
// 'test.attach'). We classify Playwright's answer; we never re-derive it by
// pattern-matching error prose, which drifts with every Playwright release.

const DEFAULT_ENDPOINT = 'https://api.launchguard.dev';
const REPORT_PATH = '/api/v1/report';
const MAX_ERROR_LENGTH = 600;
const POST_TIMEOUT_MS = 15_000;

// ---------------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------------

// Did the failing chain of steps go through an expect()? Playwright nests steps
// arbitrarily (test.step wrapping an expect wrapping a locator call), so an
// expect anywhere in an error-carrying chain means a claim about the app was
// being checked when things went wrong.
//
// We test for ONE category, positively. Playwright has added categories over
// time (test.attach is newer than this product); anything we do not recognize
// falls through to the neutral answer instead of breaking.
function chainHasExpect(steps) {
  for (const step of steps ?? []) {
    if (!step.error) continue;
    if (step.category === 'expect') return true;
    if (chainHasExpect(step.steps)) return true;
  }
  return false;
}

/**
 * Classify one test result.
 *
 * 'passed'         - nothing to report about the app.
 * 'claim_violated' - an expect() on app behavior failed. The app is broken.
 * 'could_not_run'  - the test never got far enough to check anything. NOT a
 *                    verdict about the app, and the safe sink for anything
 *                    ambiguous. We never guess red.
 */
export function classify(test, result) {
  if (result.status === 'skipped') return 'skipped';

  // Playwright's own notion of "this is the outcome the author expected".
  // A test marked test.fail() that duly fails is a GREEN run, not a broken app.
  if (result.status === test.expectedStatus) return 'passed';

  // A test that ran out of time never reached a verdict about the app. This is
  // exactly how allure-playwright maps timedOut, for the same reason.
  if (result.status === 'timedOut') return 'could_not_run';

  return chainHasExpect(result.steps) ? 'claim_violated' : 'could_not_run';
}

/**
 * The status we send, kept consistent with the verdict above.
 *
 * An expected failure (test.fail() that duly failed) is sent as 'passed',
 * exactly as allure-playwright reports it: the author declared this outcome, so
 * the run is green and the app is not news. Sending the raw 'failed' would be a
 * lie by omission, because the server derives a failure kind of its own from the
 * error text whenever we do not send one, and would call this a broken app.
 */
export function statusFor(verdict, result) {
  if (verdict === 'passed') return 'passed';
  if (verdict === 'skipped') return 'skipped';
  return result.status; // failed | timedOut | interrupted
}

// ---------------------------------------------------------------------------
// App identity
// ---------------------------------------------------------------------------

// Which APP do these results belong to? That is a different question from where
// the tests pointed the browser. The documented default target is a per-PR
// preview URL; using it as identity would mint a new "app" on every PR and leave
// the customer's real app empty forever. So an ephemeral host is never taken as
// an identity unless the caller said so explicitly.

export function normalizeHost(input) {
  let s = String(input).trim();
  s = s.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, ''); // scheme
  s = s.replace(/^[^/?#]*@/, ''); // userinfo
  const cut = s.search(/[/?#]/);
  if (cut !== -1) s = s.slice(0, cut);

  if (s.startsWith('[')) {
    const close = s.indexOf(']');
    if (close !== -1) s = s.slice(1, close); // bracketed IPv6
  } else {
    // Only strip ":port" when there is exactly one colon, so a bare IPv6
    // literal ("::1") is never mangled.
    const colons = (s.match(/:/g) ?? []).length;
    if (colons === 1) {
      const i = s.indexOf(':');
      if (/^\d+$/.test(s.slice(i + 1))) s = s.slice(0, i);
    }
  }
  return s.toLowerCase();
}

function isIPv4Literal(host) {
  const parts = host.split('.');
  return (
    parts.length === 4 &&
    parts.every((p) => /^\d{1,3}$/.test(p) && Number(p) <= 255)
  );
}

export function isEphemeralHost(hostInput) {
  const host = String(hostInput).trim().toLowerCase();

  if (host.endsWith('.vercel.app')) {
    const leftmost = host.slice(0, -'.vercel.app'.length);
    // A preview host carries Vercel's deployment id; a bare production alias
    // like "myapp.vercel.app" does not, and must read as a real app.
    return /-[a-z0-9]{8,}(-|$)/.test(leftmost);
  }
  if (/^deploy-preview-\d+--/.test(host)) return true;
  if (host.includes('--') && host.endsWith('.netlify.app')) return true;
  if (
    host.endsWith('.ngrok.io') ||
    host.endsWith('.ngrok-free.app') ||
    host.endsWith('.trycloudflare.com') ||
    host.endsWith('.loca.lt')
  ) {
    return true;
  }
  if (host === 'localhost' || host.endsWith('.local') || host.endsWith('.localhost')) return true;
  if (host === '127.0.0.1' || host === '::1') return true;
  if (isIPv4Literal(host)) return true;

  return false;
}

export function resolveAppHost({ app, target, baseURL, env = {} } = {}) {
  // Explicit sources: the caller told us. Honoured even if they look ephemeral.
  const explicit = app ?? env.LAUNCHGUARD_APP ?? target;
  if (explicit) return { kind: 'resolved', host: normalizeHost(explicit) };

  // Inherited from wherever the tests happened to run: check before trusting.
  const fallback = env.TARGET_URL ?? env.BASE_URL ?? baseURL;
  if (!fallback) return { kind: 'none' };

  const host = normalizeHost(fallback);
  return isEphemeralHost(host) ? { kind: 'refused', host } : { kind: 'resolved', host };
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

// Real ANSI escapes: ESC [ ... m. Display hygiene for the message we forward,
// never a classification input.
const ANSI = new RegExp(String.fromCharCode(27) + '\\[[0-9;]*m', 'g');

function truncate(message, max = MAX_ERROR_LENGTH) {
  const cleaned = String(message).replace(ANSI, '').trim();
  return cleaned.length > max ? cleaned.slice(0, max) : cleaned;
}

// Walk the describe chain by hand rather than trusting titlePath() indexing,
// which shifts with how many synthetic root suites Playwright inserts.
function fullTitle(test) {
  const parts = [];
  let s = test.parent;
  while (s && s.type === 'describe') {
    if (s.title) parts.unshift(s.title);
    s = s.parent;
  }
  return [...parts, test.title].join(' > ');
}

function relativeFile(file, rootDir) {
  if (!rootDir || !file.startsWith(rootDir)) return file;
  return file.slice(rootDir.length).replace(/^[/\\]/, '').split('\\').join('/');
}

function resolveBaseUrl(config) {
  for (const project of config.projects ?? []) {
    if (project.use?.baseURL) return project.use.baseURL;
  }
  return undefined;
}

function runUrlFromEnv(env) {
  const { GITHUB_SERVER_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID } = env;
  if (GITHUB_SERVER_URL && GITHUB_REPOSITORY && GITHUB_RUN_ID) {
    return `${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}`;
  }
  return undefined;
}

export default class LaunchGuardReporter {
  constructor(options = {}) {
    this.options = options;
    this.enabled = true;
    this.rootDir = '';
    this.results = new Map();
  }

  // Additive: never suppress the user's own reporter output.
  printsToStdio() {
    return false;
  }

  onBegin(config) {
    this.rootDir = config.rootDir ?? '';
    const env = process.env;

    if (this.options.enabled === false) {
      this.enabled = false;
      return;
    }

    this.apiKey = this.options.apiKey ?? env.LAUNCHGUARD_API_KEY;
    if (!this.apiKey) {
      this.enabled = false;
      console.log('LaunchGuard: LAUNCHGUARD_API_KEY not set, skipping the LaunchGuard report');
      return;
    }

    const rawEndpoint = this.options.endpoint ?? env.LAUNCHGUARD_API_URL ?? DEFAULT_ENDPOINT;
    this.endpoint = rawEndpoint.replace(/\/+$/, '') + REPORT_PATH;

    const resolution = resolveAppHost({
      app: this.options.app,
      target: this.options.target,
      baseURL: resolveBaseUrl(config),
      env,
    });

    if (resolution.kind === 'none') {
      this.enabled = false;
      console.log(
        'LaunchGuard: could not tell which app this run was testing. Set app: "yourdomain.com" in the reporter options (or LAUNCHGUARD_APP) and I will attach these results to that app.',
      );
      return;
    }
    if (resolution.kind === 'refused') {
      this.enabled = false;
      console.log(
        `LaunchGuard: "${resolution.host}" looks like a temporary preview URL, so I cannot tell which app these results belong to. Set app: "yourdomain.com" in the reporter options (or LAUNCHGUARD_APP) and I will attach them to that app.`,
      );
      return;
    }

    this.target = resolution.host;
    this.commit = this.options.commit ?? env.GITHUB_SHA;
    this.branch = this.options.branch ?? env.GITHUB_REF_NAME;
    this.runUrl = this.options.runUrl ?? runUrlFromEnv(env);
  }

  onTestEnd(test, result) {
    if (!this.enabled) return;
    try {
      const file = relativeFile(test.location.file, this.rootDir);
      const title = fullTitle(test);
      const project = test.parent?.project()?.name ?? '';
      // Retries share this identity, so a later attempt overwrites an earlier
      // one: the final attempt is the verdict we report.
      const key = `${file} ${title} ${project}`;

      const verdict = classify(test, result);
      const entry = {
        file,
        title,
        project,
        tags: Array.isArray(test.tags) ? test.tags : [],
        status: statusFor(verdict, result),
        durationMs: result.duration,
      };

      // Always send an explicit failureKind for anything not clean. The server
      // falls back to deriving one from the error text when we stay silent, so
      // silence here is not neutral: it hands the verdict to a guess.
      if (verdict === 'claim_violated' || verdict === 'could_not_run') {
        entry.failureKind = verdict;
        const message = result.error?.message ?? result.errors?.[0]?.message;
        if (message) entry.error = truncate(message);
      }

      this.results.set(key, entry);
    } catch (err) {
      // A bug in our own bookkeeping must never break the customer's run.
      console.log(`LaunchGuard: failed to record a test result (${err?.message ?? err})`);
    }
  }

  async onEnd() {
    if (!this.enabled || !this.apiKey || !this.endpoint || !this.target) return;
    try {
      const tests = [...this.results.values()];
      const payload = {
        target: this.target,
        commit: this.commit,
        branch: this.branch,
        runUrl: this.runUrl,
        tests,
      };

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), POST_TIMEOUT_MS);
      let response;
      try {
        response = await fetch(this.endpoint, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${this.apiKey}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify(payload),
          signal: controller.signal,
        });
      } finally {
        clearTimeout(timer);
      }

      if (!response.ok) {
        console.log(`LaunchGuard: report failed (HTTP ${response.status}), continuing anyway`);
        return;
      }
      const json = await response.json().catch(() => ({}));
      this.logOutcome(tests, json);
    } catch (err) {
      console.log(`LaunchGuard: report failed (${err?.message ?? err}), continuing anyway`);
    }
  }

  logOutcome(tests, json) {
    const passed = tests.filter((t) => t.status === 'passed').length;
    const broken = tests.filter((t) => t.failureKind === 'claim_violated').length;
    const couldNotRun = tests.filter((t) => t.failureKind === 'could_not_run').length;
    const skipped = tests.length - passed - broken - couldNotRun;

    const parts = [`${passed} passed`];
    if (broken) parts.push(`${broken} broken`);
    if (couldNotRun) parts.push(`${couldNotRun} could not run`);
    if (skipped) parts.push(`${skipped} skipped`);

    const dashboardUrl = typeof json.dashboardUrl === 'string' ? json.dashboardUrl : '';
    console.log(
      `LaunchGuard: ${tests.length} test${tests.length === 1 ? '' : 's'} reported (${parts.join(', ')})${
        dashboardUrl ? ` -> ${dashboardUrl}` : ''
      }`,
    );

    if (couldNotRun) {
      console.log(
        "LaunchGuard: tests marked 'could not run' are not verdicts about your app. They mean the test itself never got far enough to check anything, for example a timeout or a page that never loaded.",
      );
    }
    if (json.overQuota) {
      const note = typeof json.note === 'string' ? json.note : '';
      console.log(`LaunchGuard: ${json.overQuota} test(s) were over your plan's limit. ${note}`.trim());
    }
  }
}
